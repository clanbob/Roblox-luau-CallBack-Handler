--[[
	============================================================
	CALLBACK SYSTEM
	============================================================

	Purpose:
		Mutation-safe callback dispatcher.

	Author:
		TheRoyalDrew
]]

-- ============================================================
-- Coroutine Runner
-- ============================================================

-- Coroutine runner pattern inspired by @stravant thread-reuse approach.

-- Shared coroutine reused to execute callbacks without creating a new coroutine per listener.
local free_runner_thread: thread

-- Executes one callback via xpcall + traceback.
-- The free runner is temporarily detached to avoid accidental re-entrancy reuse
-- while this callback is in progress.
local function run(call_back: (...any) -> (), ...)
	local cached_runner_thread = free_runner_thread
	free_runner_thread = nil

	local function errorHandler(err)
		return debug.traceback(tostring(err), 2)
	end

	local success, error_message = xpcall(call_back, errorHandler, ...)

	if not success then
		warn(error_message)
	end

	free_runner_thread = cached_runner_thread
end

-- Runner coroutine body: waits for (callback, ...) and then executes it through run().
local function wait_for_work()
	while true do
		run(coroutine.yield())
	end
end

-- Dispatches a listener callback via the shared runner coroutine.
-- The runner is lazily created and primed on first dispatch.
local function run_listener_in_runner_thread(listener: Listener, ...)
	if not free_runner_thread then
		free_runner_thread = coroutine.create(wait_for_work)
		coroutine.resume(free_runner_thread) -- prime to first yield
	end

	task.spawn(free_runner_thread, listener.call_back, ...)
end

-- ============================================================
-- Listener Index Generator
-- ============================================================

-- Monotonic id used as a stable hash-key for listener storage tables.
local index = 1

local function generate_index()
	local cached_index = index
	index += 1
	return cached_index
end

-- ============================================================
-- Instance Cleanup Tracking
-- ============================================================

-- Cleanup for registries:
--   - Players: cleaned via Players.PlayerRemoving
--   - Instances: cleaned via Destroying (or a custom destroy event)
local player_removed_connection: RBXScriptConnection

-- Instance -> { registry, ... } (non-player instances)
local cached_instance = {}

-- Player -> { registry, ... }
local cached_player = {}

-- Registered registry -> connection (destroy event hook)
-- NOTE:
--   This is keyed by registry object (not by instance) so different
--   dispatchers/registries that reference the same instance can still
--   own different destroy signals safely.
local instance_removing_connection = {}

-- Removes one registry from its owning instance/player cache bucket.
-- If the bucket becomes empty, it removes the bucket key entirely.
-- For players, also tears down PlayerRemoving when no player registries remain.
local function remove_registry_from_cache(instance: Instance, registry, is_player: boolean)
	local cach = is_player and cached_player or cached_instance
	local registries = cach[instance]
	if not registries then return end

	for i = #registries, 1, -1 do
		if registries[i] == registry then
			table.remove(registries, i)
			break
		end
	end

	if not next(registries) then
		cach[instance] = nil

		if is_player then
			if not next(cach) and player_removed_connection then
				player_removed_connection:Disconnect()
				player_removed_connection = nil
			end
		end
	end
end

local function disconnect_instance_connection(registry)
	local connection = instance_removing_connection[registry]
	if not connection then return end

	connection:Disconnect()
	instance_removing_connection[registry] = nil
end

-- Clears an entire cache key (instance or player) and all associated cleanup hooks.
-- Used by global cleanup flows where every registry under the key is being removed.
local function clear_cach(instance)
	if cached_instance[instance] then
		for _, registry in pairs(cached_instance[instance]) do
			disconnect_instance_connection(registry)
		end

		cached_instance[instance] = nil
		return
	end

	if cached_player[instance] then
		cached_player[instance] = nil

		if not next(cached_player) and player_removed_connection then
			player_removed_connection:Disconnect()
			player_removed_connection = nil
		end
	end
end

-- Registers a registry under either the player cache or instance cache.
local function add_to_cache(instance: Instance, registry, is_player: boolean)
	local cach = is_player and cached_player or cached_instance

	if not cach[instance] then
		cach[instance] = {}
	end

	table.insert(cach[instance], registry)
end

-- Ensures PlayerRemoving hook is connected once globally for this module state.
local function new_player_removing_connection()
	if player_removed_connection then return end

	player_removed_connection = game.Players.PlayerRemoving:Connect(function(player)
		if not cached_player[player] then return end

		for _, registered_player_objects in pairs(cached_player[player]) do
			registered_player_objects:Destroy(true)
		end

		clear_cach(player)
	end)
end

-- Hooks a one-time destroy event for a specific registry.
-- If this registry already has a hook, it is replaced.
-- Important: the hook destroys only that registry, not every registry under the instance.
local function new_removing_connection(event: RBXScriptSignal, reg)
	disconnect_instance_connection(reg)

	instance_removing_connection[reg] = event:Once(function()
		if reg.destroyed then return end
		reg:Destroy()
	end)
end

-- ============================================================
-- Batch Container
-- ============================================================

-- Batch owns two listener sets:
--   active  -> eligible this cycle
--   pending -> added during Fire(); promoted after cycle
--
-- Invariant: pending listeners never fire in the same cycle they were added.
local batch = {}
batch.__index = batch

-- parent is the table mapping caller_id -> batch.
function batch.New(self, caller_id)
	return setmetatable({
		caller_id = caller_id,
		parent = self,

		is_firing = false,
		pending = {},
		active = {},
		clean_up_buffer = {}
	}, batch)
end

function batch:ToPending(listener: Listener, index: number): Listener
	listener.pending = true
	self.pending[index] = listener
	return listener
end

function batch:ToActive(listener: Listener, index: number): Listener
	self.active[index] = listener
	return listener
end

function batch:RemoveListener(index: number)
	self.pending[index] = nil
	self.active[index] = nil
end

-- Promote pending -> active after Fire().
function batch:FlushPending()
	for _, listener in pairs(self.pending) do
		if listener.connected then
			listener.pending = false
			self:ToActive(listener, listener.index)
		end
	end

	table.clear(self.pending)
end

-- Destroys the batch if it has no listeners.
function batch:CleanUp()
	local empty_active = not next(self.active)
	local empty_pending = not next(self.pending)

	if empty_active and empty_pending then
		self:Destroy()
		return
	end

	if empty_active then
		table.clear(self.active)
	end
	if empty_pending then
		table.clear(self.pending)
	end
end

-- After Fire(): remove disconnected/dirty listeners safely.
function batch:CleanUpAfterFire()
	local clean_up = self.clean_up_buffer

	for _, listener in pairs(self.active) do
		if (not listener.connected) or listener.dirty then
			table.insert(clean_up, listener)
		end
	end

	for _, listener in ipairs(clean_up) do
		listener:Disconnect()
	end

	table.clear(clean_up)
	self:CleanUp()
end

-- Removes batch from parent and clears tables.
function batch:Destroy()
	if self.destroyed then return end
	self.destroyed = true

	if self.parent then
		self.parent[self.caller_id] = nil
	end

	table.clear(self.pending)
	table.clear(self.active)
	table.clear(self.clean_up_buffer)

	self.parent = nil
	self.caller_id = nil
end

-- ============================================================
-- Listener Class
-- ============================================================

-- Listener handle returned by Listen().
-- Supports explicit disconnection and direct callback execution.
local Listener = {}
Listener.__index = Listener

-- pending=true means the listener was created during an active Fire() cycle
-- and must not run until the next cycle.
function Listener.New(self, call_back: (...any) -> (), index: number, once: boolean, pending: boolean)
	return setmetatable({
		call_back = call_back,
		once = once,
		index = index,

		connected = true,
		dirty = false, -- set when disconnecting during Fire()
		pending = pending,
		batch = self
	}, Listener)
end

-- Disconnect behavior:
--   - if not firing: remove immediately
--   - if firing: mark dirty and defer structural cleanup until post-fire
function Listener:Disconnect()
	if not self.connected then return end
	self.connected = false

	if not self.batch.is_firing then
		self.batch:RemoveListener(self.index)
		self.dirty = false
		self.batch:CleanUp()
	else
		self.dirty = true
	end
end

-- Fires this one listener asynchronously.
-- `once` listeners disconnect before dispatch to guarantee at-most-once execution.
function Listener:Fire(...)
	if self.pending then
		warn("Attempted to execute a pending listener during active firing.")
		return
	end

	if self.once then
		self:Disconnect()
	end

	run_listener_in_runner_thread(self, ...)
end

-- ============================================================
-- Default Callback Group (Global Scope)
-- ============================================================

local default = {}
default.__index = default

-- Registers a listener into caller_id's batch.
-- If Fire() is in progress, the listener is created as pending for next cycle.
function default:Listen(caller_id: string, once: boolean, call_back: (...any) -> ()): Listener
	if not self.listener_list[caller_id] then
		self.listener_list[caller_id] = batch.New(self.listener_list, caller_id)
	end

	local batch = self.listener_list[caller_id]
	local id = generate_index()

	local listener = Listener.New(batch, call_back, id, once, false)

	if batch.is_firing then
		listener.pending = true
		return batch:ToPending(listener, id)
	end

	return batch:ToActive(listener, id)
end

-- Fire cycle:
--   - mark firing
--   - dispatch active
--   - unmark
--   - promote pending
--   - cleanup disconnected/dirty
function default:Fire(caller_id: string, ...)
	local batch = self.listener_list[caller_id]
	if not batch then return end

	batch.is_firing = true

	for _, listener in pairs(batch.active) do
		if listener.connected and not listener.pending then
			listener:Fire(...)
		end
	end

	batch.is_firing = false

	batch:FlushPending()
	batch:CleanUpAfterFire()
end

function default:Destroy()
	for _, batches in pairs(self.listener_list) do
		batches:Destroy()
	end

	table.clear(self.listener_list)
	table.clear(self)
	setmetatable(self, nil)
end

-- ============================================================
-- Per-Player / Per-Instance Callback Group
-- ============================================================

-- Registry object owning caller_id -> batch mappings for one player/instance key.
local registered = {}
registered.__index = registered

-- Creates a registry and enrolls it into ownership caches.
-- For instance registries, attaches the initial destroy signal (default: Destroying).
function registered.New(self, instance: Instance, is_player: boolean, destroy_event: RBXScriptSignal)
	local reg = setmetatable({
		listener_list = {},
		instance = instance,
		parent = self,

		is_player = is_player,
	}, registered)

	add_to_cache(instance, reg, is_player)

	if is_player then
		new_player_removing_connection()
	else
		new_removing_connection(destroy_event or instance.Destroying, reg)
	end

	return reg
end

function registered:Connect(caller_id: string, once: boolean, call_back: (...any) -> ())
	if not self.listener_list[caller_id] then
		self.listener_list[caller_id] = batch.New(self.listener_list, caller_id)
	end

	local batch = self.listener_list[caller_id]
	local id = generate_index()

	local listener = Listener.New(batch, call_back, id, once, false)

	if batch.is_firing then
		listener.pending = true
		return batch:ToPending(listener, id)
	end

	return batch:ToActive(listener, id)
end

-- Destroys this registry.
-- dont_clear_cach=true is used by cleanup handlers that already removed the cache key.
function registered:Destroy(dont_clear_cach: boolean)
	if self.destroyed then return end
	self.destroyed = true

	if not self.is_player then
		disconnect_instance_connection(self)
	end

	if not dont_clear_cach then
		remove_registry_from_cache(self.instance, self, self.is_player)
	end

	table.clear(self.listener_list)

	if self.parent then
		self.parent.registered[self.instance] = nil
	end

	setmetatable(self, nil)
end

-- ============================================================
-- By-Instance Interface
-- ============================================================

local by_instance = {}
by_instance.__index = by_instance

function by_instance:Listen(instance: Instance, caller_id: string, once: boolean, call_back: (...any) -> ())
	if not self.registered[instance] then
		self.registered[instance] = registered.New(self, instance, self.is_player)
	end

	return self.registered[instance]:Connect(caller_id, once, call_back)
end

function by_instance:Fire(instance: Instance, caller_id: string, ...)
	local reg = self.registered[instance]
	if not reg then return end

	local batch = reg.listener_list[caller_id]
	if not batch then return end

	batch.is_firing = true

	for _, listener in pairs(batch.active) do
		if listener.connected and not listener.pending then
			listener:Fire(...)
		end
	end

	batch.is_firing = false

	-- registry may have been destroyed during Fire()
	if not batch.parent then
		return
	end

	batch:FlushPending()
	batch:CleanUpAfterFire()
end

function by_instance:GetRegistered(instance: Instance)
	return self.registered[instance]
end

-- Sets a custom destroy signal for one instance registry.
-- lock=true prevents replacing that signal later for this registry.
function by_instance:UseCustomDestroyEventForInstance(instance: Instance, lock: boolean, event: RBXScriptSignal)
	if self.is_player then
		error("players can not have custom destroyed events")
	end

	if not self.registered[instance] then
		self.registered[instance] = registered.New(self, instance, false, event)
		self.registered[instance].lock_event = lock
	elseif not self.registered[instance].lock_event then
		new_removing_connection(event, self.registered[instance])
		self.registered[instance].lock_event = lock
	end
end

function by_instance:Destroy()
	for _, reg in pairs(self.registered) do
		reg:Destroy()
	end

	table.clear(self.registered)
	table.clear(self)
	setmetatable(self, nil)
end

-- ============================================================
-- Public Factory
-- ============================================================

local CallBack = {}

function CallBack.New(): default
	return setmetatable({
		listener_list = {}
	}, default)
end

function CallBack.NewByPlayer(): by_instance
	if not game:GetService("RunService"):IsServer() then
		warn("CallBack.NewByPlayer() should only used from the server")
		return
	end

	return setmetatable({
		registered = {},
		is_player = true
	}, by_instance)
end

function CallBack.NewByInstance(): by_instance
	return setmetatable({
		registered = {},
	}, by_instance)
end


-- ============================================================
-- Types
-- ============================================================

export type Listener = {
	Disconnect: (self: Listener) -> (),
	Fire: (self: Listener, ...any) -> (),
}

export type default = {
	Fire: (self: default, caller_id: string, ...any) -> (),
	Listen: (self: default, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	Destroy: (self: default) -> (),
}

export type by_player = {
	Fire: (self: by_instance, player: Player, caller_id: string, ...any) -> (),
	Listen: (self: by_instance, player: Player, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_instance, player: Player) -> { listener_list: { [string]: Listener } },
	Destroy: (self: by_instance) -> (),
}

export type by_instance = {
	Fire: (self: by_instance, instance: Instance, caller_id: string, ...any) -> (),
	Listen: (self: by_instance, instance: Instance, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_instance, instance: Instance) -> { listener_list: { [string]: Listener } },
	UseCustomDestroyEventForInstance: (self: by_instance, instance: Instance, lock: boolean, event: RBXScriptSignal) -> (),
	Destroy: (self: by_instance) -> (),
}

return CallBack

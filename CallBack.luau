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

-- credit to @stravant for thread reuse desgin

-- Shared coroutine used to execute callbacks.
local free_runner_thread: thread

-- Executes a callback under xpcall with traceback.
-- free_runner_thread is temporarily cleared to avoid re-entrancy reuse.
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

-- Runner coroutine body: waits for (callback, ...) then calls run(callback, ...).
local function wait_for_work()
	while true do
		run(coroutine.yield())
	end
end

-- Dispatches a listener callback using the shared runner coroutine.
-- Runner is created + primed on first use.
local function run_lisenter_in_runner_thread(listener: Listener, ...)
	if not free_runner_thread then
		free_runner_thread = coroutine.create(wait_for_work)
		coroutine.resume(free_runner_thread) -- prime to first yield
	end

	task.spawn(free_runner_thread, listener.call_back, ...)
end

-- ============================================================
-- Listener Index Generator
-- ============================================================

-- Monotonic id used as a stable key for listeners.
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
local cached_istance = {}

-- Player -> { registry, ... }
local cached_player = {}

-- Instance -> connection (destroy event hook)
local istance_removing_connection = {}

-- Removes an entry from the proper cache.
-- Also disconnects any associated cleanup connection when no longer needed.
local function clear_cach(istance)
	local is_player = false

	local cach
	if cached_istance[istance] then
		cach = cached_istance
	elseif cached_player[istance] then
		cach = cached_player
		is_player = true
	else
		return
	end

	cach[istance] = nil

	if is_player then
		if not next(cach) and player_removed_connection then
			player_removed_connection:Disconnect()
			player_removed_connection = nil
		end
	else
		if istance_removing_connection[istance] then
			istance_removing_connection[istance]:Disconnect()
			istance_removing_connection[istance] = nil
		end
	end
end

-- Registers a registry under either the player cache or instance cache.
local function add_to_cache(istance: Instance, registry, is_player: boolean)
	local cach = is_player and cached_player or cached_istance

	if not cach[istance] then
		cach[istance] = {}
	end

	table.insert(cach[istance], registry)
end

-- Ensures PlayerRemoving is connected once.
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

-- Hooks a one-time destroy event for an instance (Destroying or custom).
-- If a hook already exists, it is replaced (unless you lock it at a higher level).
local function new_removing_connection(event: RBXScriptSignal, reg, istance : Instance)
	if istance_removing_connection[reg] then
		istance_removing_connection[reg]:Disconnect()
		istance_removing_connection[reg] = nil
	end

	istance_removing_connection[reg] = event:Once(function()
		if not cached_istance[istance] then return end

		for _, registered_objects in pairs(cached_istance[istance]) do
			registered_objects:Destroy(true)
		end

		clear_cach(istance)
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
		active = {}
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
	local clean_up = {}

	for _, listener in pairs(self.active) do
		if (not listener.connected) or listener.dirty then
			table.insert(clean_up, listener)
		end
	end

	for _, listener in ipairs(clean_up) do
		listener:Disconnect()
	end

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

	self.parent = nil
	self.caller_id = nil
end

-- ============================================================
-- Listener Class
-- ============================================================

-- Listener handle returned to callers.
-- Supports :Disconnect() and :Fire()
local Listener = {}
Listener.__index = Listener

-- pending=true means it was created during an active Fire() cycle.
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

-- Disconnects immediately unless batch is currently firing (then marks dirty).
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

-- Fires asynchronously. once listeners disconnect before dispatch.
function Listener:Fire(...)
	if self.pending then
		warn("Attempted to execute a pending listener during active firing.")
		return
	end

	if self.once then
		self:Disconnect()
	end

	run_lisenter_in_runner_thread(self, ...)
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

-- Registry holding batches scoped to one instance/player.
local registered = {}
registered.__index = registered

-- Creates a new registry and enrolls it into cleanup caches.
-- Note: the first destroy event hooked "wins" unless you replace it later (and it's not locked).
function registered.New(self, istance: Instance, is_player: boolean, destroy_event: RBXScriptSignal)
	local reg = setmetatable({
		listener_list = {},
		istance = istance,
		parent = self,

		is_player = is_player,
	}, registered)

	add_to_cache(istance, reg, is_player)

	if is_player then
		new_player_removing_connection()
	else
		new_removing_connection(destroy_event or istance.Destroying, reg, istance)
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
-- dont_clear_cach=true is used by cleanup handlers that already clear the cache key.
function registered:Destroy(dont_clear_cach: boolean)
	local cach = self.is_player and cached_player or cached_istance

	if cach[self.istance] and not dont_clear_cach then
		clear_cach(self.istance)
	end

	table.clear(self.listener_list)
	setmetatable(self, nil)

	self.parent.registered[self.istance] = nil
end

-- ============================================================
-- By-Instance Interface
-- ============================================================

local by_istance = {}
by_istance.__index = by_istance

function by_istance:Listen(istance: Instance, caller_id: string, once: boolean, call_back: (...any) -> ())
	if not self.registered[istance] then
		self.registered[istance] = registered.New(self, istance, self.is_player)
	end

	return self.registered[istance]:Connect(caller_id, once, call_back)
end

function by_istance:Fire(istance: Instance, caller_id: string, ...)
	local reg = self.registered[istance]
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

function by_istance:GetRegistered(istance: Instance)
	return self.registered[istance]
end

-- Allows setting a custom destroy signal for an instance registry.
-- lock=true prevents future overrides for that instance.
function by_istance:UseCustomDestroyEventForIstance(istance: Instance, lock: boolean, event: RBXScriptSignal)
	if self.is_player then
		error("players can not have custom destroyed events")
	end

	if not self.registered[istance] then
		self.registered[istance] = registered.New(self, istance, false, event)
		self.registered[istance].lock_event = lock
	elseif not self.registered[istance].lock_event then
		new_removing_connection(event, self.registered[istance], istance)
		self.registered[istance].lock_event = lock
	end
end

function by_istance:Destroy()
	for istance, reg in pairs(self.registered) do
		reg:Destroy(true)
		clear_cach(istance)
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

function CallBack.NewByPlayer(): by_istance
	if not game:GetService("RunService"):IsServer() then
		warn("CallBack.NewByPlayer() should only used from the server")
		return
	end

	return setmetatable({
		registered = {},
		is_player = true
	}, by_istance)
end

function CallBack.NewByIstance(): by_istance
	return setmetatable({
		registered = {},
	}, by_istance)
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
	Fire: (self: by_istance, player: Player, caller_id: string, ...any) -> (),
	Listen: (self: by_istance, player: Player, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_istance, player: Player) -> { listener_list: { [string]: Listener } },
	Destroy: (self: by_istance) -> (),
}

export type by_istance = {
	Fire: (self: by_istance, istance: Instance, caller_id: string, ...any) -> (),
	Listen: (self: by_istance, istance: Instance, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_istance, istance: Instance) -> { listener_list: { [string]: Listener } },
	UseCustomDestroyEventForIstance: (self: by_istance, istance: Instance, lock: boolean, event: RBXScriptSignal) -> (),
	Destroy: (self: by_istance) -> (),
}

return CallBack

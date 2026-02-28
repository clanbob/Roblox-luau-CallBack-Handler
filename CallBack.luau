--[[
	CALLBACK SYSTEM

	Purpose:
		callback dispatcher with:
			- Global groups
			- Per-player and per-instance registries
			- bulit in maid system, auto cleans it's self up.

	Author:
		TheRoyalDrew
]]

-- Coroutine runner pattern inspired by @stravant thread-reuse approach.

-- Shared coroutine reused to execute callbacks without creating a new coroutine per listener.
local free_runner_thread: thread


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
local function run_listener_in_runner_thread(listener: Listener, ...)
	if not free_runner_thread then
		free_runner_thread = coroutine.create(wait_for_work)
		coroutine.resume(free_runner_thread) -- prime to first yield
	end

	task.spawn(free_runner_thread, listener.call_back, ...)
end



-- Monotonic id used as a stable hash-key for listener storage tables.
local index = 1
local function generate_index()
	local cached_index = index
	index += 1
	return cached_index
end

local player_removed_connection: RBXScriptConnection

-- Instance -> { registry, ... } (non-player instances)
local cached_instance = {}

-- Player -> { registry, ... }
local cached_player = {}

-- Registered registry -> connection (destroy event hook)
local instance_removing_connection = {}



local function remove_registry_from_cache(instance: Instance, registry, is_player: boolean)
	local cach = is_player and cached_player or cached_instance
	local registries = cach[instance]
	if not registries then return end

	for i = #registries, 1, -1 do
		if registries[i] == registry then
			-- O(1) swap-remove, registry order is not semantically important.
			local last = #registries
			registries[i] = registries[last]
			registries[last] = nil
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


-- Note: the hook destroys only that registry, not every registry under the instance.
local function new_removing_connection(event: RBXScriptSignal, reg)
	disconnect_instance_connection(reg)

	instance_removing_connection[reg] = event:Once(function()
		if reg.destroyed then return end
		reg:Destroy()
	end)
end

-- Batch Container

local batch = {}
batch.__index = batch


-- parent is the table mapping caller_id -> batch.
function batch.New(self, caller_id)
	return setmetatable({
		caller_id = caller_id,
		parent = self,

		is_firing = false,
		destroyed = false,
		dirty = false,

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

function batch:CleanUpAfterFire()
	if self.drity then self:Destroy() return end

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


-- cleans up the batch object
function batch:Destroy()
	if self.destroyed then return end
	self.destroyed = true

	if self.is_firing then 
		self.drity = true
		return 
	end

	if self.parent then
		self.parent[self.caller_id] = nil
	end

	table.clear(self.pending)
	table.clear(self.active)
	table.clear(self.clean_up_buffer)

	self.parent = nil
	self.caller_id = nil
end

-- Listener Class



local Listener = {}
Listener.__index = Listener

-- pending means the listener was created during an active Fire() cycle
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


-- Fires a listener asynchronously.
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

-- Default Callback Group

local default = {}
default.__index = default


-- Registers a listener into caller_id's batch.
function default:Listen(caller_id: string, once: boolean, call_back: (...any) -> ()): Listener
	if not self.batch_list[caller_id] then
		self.batch_list[caller_id] = batch.New(self.batch_list, caller_id)
	end

	local batch = self.batch_list[caller_id]
	local id = generate_index()

	local listener = Listener.New(batch, call_back, id, once, false)

	if batch.is_firing then
		listener.pending = true
		return batch:ToPending(listener, id)
	end

	return batch:ToActive(listener, id)
end


function default:Fire(caller_id: string, ...)
	local batch = self.batch_list[caller_id]
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
	for _, batches in pairs(self.batch_list) do
		batches:Destroy()
	end

	table.clear(self.batch_list)
	table.clear(self)
	setmetatable(self, nil)
end

function default:GetListenerBatch(caller_id : string): batch
	return self.batch_list[caller_id]
end

function default:GeCurrentIds(): {string}
	local ids = {}	
	for id, batch in pairs(self.batch_list) do
		table.insert(ids, id)
	end

	return ids
end

-- returns false if no active lisenters, else true	
function default:CheckStatus(caller_id : string): boolean	
	if not caller_id then
		return if not next(self.batch_list) then false else true
	end

	if not self.batch_list[caller_id] then
		return false
	end

	if not next(self.batch_list[caller_id].active)
		and not next(self.batch_list[caller_id].pending) then

		return false
	else
		return true
	end
end

-- Per-Player / Per-Instance Callback Group

-- Registry object owning caller_id -> batch mappings for one player/instance key.
local registered = {}
registered.__index = registered

-- Creates a registry and enrolls it into ownership caches.
-- For instance registries, attaches the initial destroy signal (default: Destroying).
function registered.New(self, instance: Instance, is_player: boolean, destroy_event: RBXScriptSignal)
	local reg = setmetatable({
		batch_list = {},
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
	if not self.batch_list[caller_id] then
		self.batch_list[caller_id] = batch.New(self.batch_list, caller_id)
	end

	local batch = self.batch_list[caller_id]
	local id = generate_index()

	local listener = Listener.New(batch, call_back, id, once, false)

	if batch.is_firing then
		listener.pending = true
		return batch:ToPending(listener, id)
	end

	return batch:ToActive(listener, id)
end

-- Destroys this registry.
-- dont_clear_cach is used by cleanup handlers that already removed the cache key, should not be passed in manually.
function registered:Destroy(dont_clear_cach: boolean)
	if self.destroyed then return end
	self.destroyed = true

	if not self.is_player then
		disconnect_instance_connection(self)
	end

	if not dont_clear_cach then
		remove_registry_from_cache(self.instance, self, self.is_player)
	end

	table.clear(self.batch_list)

	if self.parent then
		self.parent.registered[self.instance] = nil
	end

	setmetatable(self, nil)
end

-- returns a table of the currently active caller_ids
function registered:GeCurrentIds(): {string}
	local ids = {}	
	for id, batch in pairs(self.batch_list) do
		table.insert(ids, id)
	end

	return ids
end

function registered:GetListenerBatch(caller_id : string): batch
	return self.batch_list[caller_id]
end

-- By-Instance Interface

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

	local batch = reg.batch_list[caller_id]
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

-- returns false if no active lisenters, else true
-- each param is optional
function by_instance:CheckStatus(istance : Instance, caller_id : string): boolean	
	if not caller_id or not istance then
		return if not next(self.registered) then false else true
	end

	local reg = self:GetRegistered(istance)
	if not reg then
		return false
	end

	local batch = reg.batch_list[caller_id]
	if not batch then
		return false
	end

	if not next(batch.active)
		and not next(batch.pending) then

		return false
	else
		return true
	end
end


-- Sets a custom destroy signal for one instance registry.
-- lock prevents replacing that signal later for this registry.
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
	-- Copy first to avoid mutating self.registered while iterating it.
	local to_destroy = {}
	for _, reg in pairs(self.registered) do
		table.insert(to_destroy, reg)
	end

	for _, reg in ipairs(to_destroy) do
		reg:Destroy()
	end

	table.clear(to_destroy)
	table.clear(self.registered)
	table.clear(self)
	setmetatable(self, nil)
end


-- Public

local CallBack = {}

function CallBack.New(): default
	return setmetatable({
		batch_list = {}
	}, default)
end

function CallBack.NewByPlayer(): by_player
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


-- Types

export type Listener = {
	Disconnect: (self: Listener) -> (),
}

export type batch = {
	Destroy: (self: batch) -> (),
}

export type default = {
	Fire: (self: default, caller_id: string, ...any) -> (),
	Listen: (self: default, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	CheckStatus: (self: default, caller_id: string) -> boolean,
	GetListenerBatch: (self: default, caller_id: string) -> batch,
	GeCurrentIds : (self : default) -> {string},
	Destroy: (self: default) -> (),
}

export type reg = {
	Destroy: (self: reg) -> (),
	GeCurrentIds : (self : reg) -> {string},
	GetListenerBatch: (self: reg, caller_id: string) -> batch,
}

export type by_player = {
	Fire: (self: by_player, player: Player, caller_id: string, ...any) -> (),
	Listen: (self: by_player, player: Player, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_player, player: Player) -> reg,
	CheckStatus: (self: by_player, player: Player, caller_id: string) -> boolean,
	Destroy: (self: by_player) -> (),
}

export type by_instance = {
	Fire: (self: by_instance, instance: Instance, caller_id: string, ...any) -> (),
	Listen: (self: by_instance, instance: Instance, caller_id: string, once: boolean, call_back: (...any) -> ()) -> Listener,
	GetRegistered: (self: by_instance, instance: Instance) -> reg,
	CheckStatus: (self: by_instance, instance: Instance, caller_id: string) -> boolean,
	UseCustomDestroyEventForInstance: (self: by_instance, instance: Instance, lock: boolean, event: RBXScriptSignal) -> (),
	Destroy: (self: by_instance) -> (),
}

return CallBack

--[[
	CALLBACK SYSTEM

	Purpose:
		callback dispatcher with:
			- Global groups
			- Per-player and per-instance

	Author:
		TheRoyalDrew
]]

-- Dynamic coroutine pool inspired by clanbob/Luau-Thread-Pool.
-- This replaces the single shared runner thread with a bounded reusable pool
-- plus an overload coroutine when the pool is saturated.

local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local coroutine_running = coroutine.running
local coroutine_yield = coroutine.yield
local math_clamp = math.clamp
local os_clock = os.clock
local table_clear = table.clear
local table_insert = table.insert
local task_spawn = task.spawn
local task_wait = task.wait

local DEFAULT_THREAD_POOL_SIZE_CAP = 16
local DEFAULT_THREAD_POOL_IDLE_TIME = 30

local Queue = {}
Queue.__index = Queue

function Queue.New()
	return setmetatable({
		items = {},
		first = 1,
		last = 1,
		size = 0,
	}, Queue)
end

function Queue:Enqueue(item)
	self.items[self.last] = item
	self.last += 1
	self.size += 1
	return item
end

function Queue:Dequeue()
	if self.size <= 0 then return end

	local item = self.items[self.first]
	self.items[self.first] = nil
	self.first += 1
	self.size -= 1

	if self.size <= 0 then
		self.first = 1
		self.last = 1
	end

	return item
end

function Queue:DropFront(amount: number): number
	if amount <= 0 or self.size <= 0 then return 0 end

	local removed = math.min(amount, self.size)
	local first = self.first
	local last_removed = first + removed - 1

	for index = first, last_removed do
		self.items[index] = nil
	end

	self.size -= removed
	self.first = last_removed + 1

	if self.size <= 0 then
		self.first = 1
		self.last = 1
	end

	return removed
end

function Queue:Destroy()
	table_clear(self.items)
	self.first = 1
	self.last = 1
	self.size = 0
end

local DynamicThreadPool = {}
DynamicThreadPool.__index = DynamicThreadPool

function DynamicThreadPool:_DetermineThreadPoolUsage()
	if self.size_cap <= 0 then return end

	local threads_not_in_use = self.threads.size
	if threads_not_in_use < self.threads_not_used_since_last_audit then
		self.threads_not_used_since_last_audit = threads_not_in_use
	end
end

function DynamicThreadPool:_ScheduleWorkerAudit()
	if self.idle_time <= 0 then return end
	if self.is_auditing then return end

	self.is_auditing = true
	task_spawn(function()
		while self.threads do
			if self.idle_time <= 0 then
				self.is_auditing = false
				break
			end

			task_wait(self.idle_time)
			if not self.threads then return end

			local audit_time = os_clock()
			local removed = self.threads:DropFront(self.threads_not_used_since_last_audit)
			self.current_size -= removed
			self.threads_not_used_since_last_audit = self.threads.size

			if self.overload_thread and audit_time - self.used_overload_thread_time >= self.idle_time then
				self.overload_thread = nil
			end
		end
	end)
end

function DynamicThreadPool:_RunTask(fn: (...any) -> (), ...)
	fn(...)
end

function DynamicThreadPool:_CreateWorker(): thread
	return coroutine_create(function()
		while true do
			self:_RunTask(coroutine_yield())
			if not self.threads then return end

			if self.current_size > self.size_cap then
				self.current_size -= 1
				return
			end

			self.threads:Enqueue(coroutine_running())
		end
	end)
end

function DynamicThreadPool:_RunOverload(fn: (...any) -> (), ...)
	local cached_overload_runner = self.overload_thread
	self.overload_thread = nil

	self:_RunTask(fn, ...)

	self.overload_thread = cached_overload_runner
end

function DynamicThreadPool:_CreateOverloadThread(): thread
	return coroutine_create(function()
		while true do
			self:_RunOverload(coroutine_yield())
		end
	end)
end

function DynamicThreadPool.new(size_cap: number?, idle_time: number?)
	local resolved_size_cap = if size_cap == nil then DEFAULT_THREAD_POOL_SIZE_CAP else size_cap
	local resolved_idle_time = if idle_time == nil then DEFAULT_THREAD_POOL_IDLE_TIME else idle_time

	if resolved_size_cap < 0 then
		error("Thread pool size cap must be greater than or equal to 0")
	end

	if resolved_idle_time < 0 then
		error("Thread pool idle time must be greater than or equal to 0")
	end

	local self = setmetatable({
		threads = Queue.New(),
		overload_thread = nil,
		size_cap = resolved_size_cap,
		idle_time = resolved_idle_time,
		threads_not_used_since_last_audit = 0,
		used_overload_thread_time = os_clock(),
		is_auditing = false,
		current_size = 0,
	}, DynamicThreadPool)

	self:_ScheduleWorkerAudit()
	return self
end

function DynamicThreadPool:AdjustSizeCap(new_size_cap: number)
	if new_size_cap < 0 then
		error("Thread pool size cap must be greater than or equal to 0")
	end

	if new_size_cap == self.size_cap then return end
	self.size_cap = new_size_cap

	local difference = self.current_size - self.size_cap
	if difference <= 0 then return end

	local removed = self.threads:DropFront(math.min(difference, self.threads.size))
	self.current_size -= removed
	self.threads_not_used_since_last_audit = math_clamp(
		self.threads_not_used_since_last_audit - removed,
		0,
		self.size_cap
	)
end

function DynamicThreadPool:Spawn(fn: (...any) -> (), ...)
	local runner_thread: thread

	if not self.overload_thread then
		local thread = self.threads:Dequeue()
		if thread then
			runner_thread = thread
			self:_DetermineThreadPoolUsage()
		elseif self.size_cap > self.current_size then
			local new_thread = self:_CreateWorker()
			coroutine_resume(new_thread)
			self.current_size += 1
			runner_thread = new_thread
		else
			self.overload_thread = self:_CreateOverloadThread()
			coroutine_resume(self.overload_thread)
			runner_thread = self.overload_thread
		end
	else
		runner_thread = self.overload_thread
	end

	if runner_thread == self.overload_thread then
		self.used_overload_thread_time = os_clock()
	end

	task_spawn(runner_thread, fn, ...)
end

function DynamicThreadPool:Destroy()
	if not self.threads then return end
	self.threads:Destroy()
	table_clear(self)
	setmetatable(self, nil)
end

local listener_thread_pool = DynamicThreadPool.new()

local function run_listener_in_runner_thread(listener: Listener, ...)
	listener_thread_pool:Spawn(listener.call_back, ...)
end


local player_removed_connection: RBXScriptConnection

-- Instance -> { registry, ... } (non-player instances)
local cached_instance = {}

-- Player -> { registry, ... }
local cached_player = {}

-- Registered registry -> connection (destroy event hook)
local instance_removing_connection = {}



local function remove_registry_from_cache(instance: Instance, registry : reg, is_player: boolean)
	local cache = is_player and cached_player or cached_instance
	local registries = cache[instance]
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
		cache[instance] = nil

		if is_player then
			if not next(cache) and player_removed_connection then
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



local function clear_cache(instance)
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
	local cache = is_player and cached_player or cached_instance

	if not cache[instance] then
		cache[instance] = {}
	end

	local registries = cache[instance]
	registries[#registries + 1] = registry
end


-- Ensures PlayerRemoving hook is connected once globally for this module state.
local function new_player_removing_connection()
	if player_removed_connection then return end

	player_removed_connection = game.Players.PlayerRemoving:Connect(function(player)
		if not cached_player[player] then return end

		for _, registered_player_objects in pairs(cached_player[player]) do
			registered_player_objects:Destroy(true)
		end

		clear_cache(player)
	end)
end


-- Note: the hook destroys only that registry, not every registry under the instance.
local function new_removing_connection(event: RBXScriptSignal, reg)
	disconnect_instance_connection(reg)

	if not event then return end
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
			
		next_index = 0,	-- Monotonic id used as a stable hash-key for listeners.
			
		is_firing = false,
		destroyed = false,
		dirty = false,
		
		dirty_listeners = {}, -- {index : number}		

		pending = {},
		active = {},
	}, batch)
end

function batch:NextIndex()
	self.next_index += 1
	return self.next_index
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
	
	self:CleanUp()
end

-- Promote pending -> active after Fire().
function batch:FlushPending()
	if not next(self.pending) then return end
	
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
	if not next(self.active) and not next(self.pending) then
		self:Destroy()
	end
end

function batch:CleanUpAfterFire()
	if self.dirty then self:Destroy() return end

	if next(self.dirty_listeners) then		
		for _, index in ipairs(self.dirty_listeners) do
			self.pending[index] = nil
			self.active[index] = nil
		end
		
		table.clear(self.dirty_listeners)
	end
	
	self:CleanUp()
end


-- cleans up the batch object
function batch:Destroy()
	if self.destroyed then return end

	if self.is_firing then
		self.dirty = true
		return
	end

	self.destroyed = true

	if self.parent then
		self.parent[self.caller_id] = nil
	end

	table.clear(self.pending)
	table.clear(self.active)

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
		pending = pending,
		batch = self
	}, Listener)
end


function Listener:Disconnect()
	if not self.connected then return end
	self.connected = false

	if not self.batch.is_firing then
		self.batch:RemoveListener(self.index)
	else	
		table_insert(self.batch.dirty_listeners, self.index)
	end
end


-- Fires a listener asynchronously.
function Listener:Fire(...)
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
	local id = batch:NextIndex()

	local listener = Listener.New(batch, call_back, id, once, false)

	if batch.is_firing then
		listener.pending = true
		return batch:ToPending(listener, id)
	end

	return batch:ToActive(listener, id)
end


local function fire_batch(current_batch: batch, ...)
	current_batch.is_firing = true

	local k, listener = next(current_batch.active)
	while k do
		if listener.connected and not listener.pending then
			listener:Fire(...)
		end

		k, listener = next(current_batch.active, k)
	end

	current_batch.is_firing = false

	if current_batch.parent then
		current_batch:FlushPending()
		current_batch:CleanUpAfterFire()
	end
end

function default:Fire(caller_id: string, ...)
	local batch = self.batch_list[caller_id]
	if not batch then return end

	fire_batch(batch, ...)
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

function default:GetCurrentIds(): {string}
	local ids = {}	
	for id in pairs(self.batch_list) do
		table_insert(ids, id)
	end

	return ids
end

function default:Wait(caller_id : string)
	if not caller_id then return end
	local running_thread = coroutine.running()

	self:Listen(caller_id, true, function(...)
		task.spawn(running_thread, ...)
	end)
	return coroutine.yield()
end

-- returns false if no active lisenters, else true	
function default:CheckStatus(caller_id : string): boolean	
	if not caller_id then
		return if not next(self.batch_list) then false else true
	end

	if not self.batch_list[caller_id] then
		return false
	end

	return next(self.batch_list[caller_id].active) ~= nil 
		or next(self.batch_list[caller_id].pending) ~= nil
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
	local id = batch:NextIndex()

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
function registered:GetCurrentIds(): {string}
	local ids = {}	
	for id in pairs(self.batch_list) do
		table_insert(ids, id)
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

	fire_batch(batch, ...)
end

function by_instance:GetRegistered(instance: Instance)
	return self.registered[instance]
end

-- returns false if no active lisenters, else true
-- each param is optional
function by_instance:CheckStatus(instance : Instance, caller_id : string): boolean	
	if not caller_id or not instance then
		return if not next(self.registered) then false else true
	end

	local reg = self:GetRegistered(instance)
	if not reg then
		return false
	end

	local batch = reg.batch_list[caller_id]
	if not batch then
		return false
	end

	return next(batch.active) ~= nil or next(batch.pending) ~= nil
end


-- Sets a custom destroy signal for one instance registry.
-- lock prevents replacing that signal later for this registry.
-- passing nil for event will remove the current destroy event, leaving no clean-up events. can save memory
-- if you know the instance will not be destroyed
function by_instance:UseCustomDestroyEventForInstance(instance: Instance, lock: boolean, event: RBXScriptSignal)
	if self.is_player then
		error("players can not have custom destroyed events")
	end

	if not self.registered[instance] then
		self.registered[instance] = registered.New(self, instance, false, event)
	elseif not self.registered[instance].lock_event then
		new_removing_connection(event, self.registered[instance])
	end
	self.registered[instance].lock_event = lock
end

function by_instance:Wait(instance : Instance, caller_id : string)
	if not instance or not caller_id then return end
	local running_thread = coroutine.running()
	
	self:Listen(instance, caller_id, true, function(...)
		task.spawn(running_thread, ...)
	end)
	return coroutine.yield()
end

function by_instance:Destroy()
	-- Copy first to avoid mutating self.registered while iterating it.
	local to_destroy = {}
	for _, reg in pairs(self.registered) do
		to_destroy[#to_destroy + 1] = reg
	end

	for _, reg in ipairs(to_destroy) do
		reg:Destroy()
	end

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



function CallBack.ConfigureThreadPool(size_cap: number?, idle_time: number?)
	if size_cap ~= nil then
		listener_thread_pool:AdjustSizeCap(size_cap)
	end

	if idle_time ~= nil then
		if idle_time < 0 then
			error("Thread pool idle time must be greater than or equal to 0")
		end

		listener_thread_pool.idle_time = idle_time
		listener_thread_pool:_ScheduleWorkerAudit()
	end
end

function CallBack.GetThreadPoolSize()
	return listener_thread_pool.current_size
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
	GetCurrentIds : (self : default) -> {string},
	Wait : (self : default, caller_id : string) -> (...any),
	Destroy: (self: default) -> (),
}

export type reg = {
	Destroy: (self: reg) -> (),
	GetCurrentIds : (self : reg) -> {string},
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
	Wait : (self : by_instance, instance : Instance, caller_id : string) -> (...any),
	Destroy: (self: by_instance) -> (),
}

return CallBack

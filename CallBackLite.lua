--[[
	CALLBACK SYSTEM

	Purpose:
		callback dispatcher with global groups

	Author:
		TheRoyalDrew

	Ported to standard Lua 5.1/5.2+
]]

-- Coroutine runner pattern inspired by @stravant thread-reuse approach.

local free_runner_thread
local table_insert = table.insert

local function run(call_back, ...)
	local cached_runner_thread = free_runner_thread
	free_runner_thread = nil

	call_back(...)
	free_runner_thread = cached_runner_thread
end

local function wait_for_work()
	while true do
		run(coroutine.yield())
	end
end

local function run_listener_in_runner_thread(listener, ...)
	if not free_runner_thread then
		free_runner_thread = coroutine.create(wait_for_work)
		coroutine.resume(free_runner_thread)
	end

	coroutine.resume(free_runner_thread, listener.call_back, ...)
end

-- Batch Container

local batch = {}
batch.__index = batch

function batch.New(self, caller_id)
	return setmetatable({
		caller_id = caller_id,
		parent = self,

		next_index = 0,

		is_firing = false,
		destroyed = false,
		dirty = false,

		dirty_listeners = {},

		pending = {},
		active = {},
	}, batch)
end

function batch:NextIndex()
	self.next_index = self.next_index + 1
	return self.next_index
end

function batch:ToPending(listener, index)
	listener.pending = true
	self.pending[index] = listener
	return listener
end

function batch:ToActive(listener, index)
	self.active[index] = listener
	return listener
end

function batch:RemoveListener(index)
	self.pending[index] = nil
	self.active[index] = nil

	self:CleanUp()
end

function batch:FlushPending()
	if not next(self.pending) then return end

	for _, listener in pairs(self.pending) do
		if listener.connected then
			listener.pending = false
			self:ToActive(listener, listener.index)
		end
	end

	for k in pairs(self.pending) do
		self.pending[k] = nil
	end
end

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

		for k in pairs(self.dirty_listeners) do
			self.dirty_listeners[k] = nil
		end
	end

	self:CleanUp()
end

function batch:Destroy()
	if self.destroyed then return end
	self.destroyed = true

	if self.is_firing then
		self.dirty = true
		return
	end

	if self.parent then
		self.parent[self.caller_id] = nil
	end

	for k in pairs(self.pending) do self.pending[k] = nil end
	for k in pairs(self.active) do self.active[k] = nil end

	self.parent = nil
	self.caller_id = nil
end

-- Listener Class

local Listener = {}
Listener.__index = Listener

function Listener.New(self, call_back, index, once, pending)
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

function Listener:Fire(...)
	if self.pending then
		print("Warning: Attempted to execute a pending listener during active firing.")
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

local function fire_batch(b, ...)
	b.is_firing = true

	local k, listener = next(b.active)
	while k do
		if listener.connected and not listener.pending then
			listener:Fire(...)
		end
		k, listener = next(b.active, k)
	end

	b.is_firing = false

	if b.parent then
		b:FlushPending()
		b:CleanUpAfterFire()
	end
end

function default:Listen(caller_id, once, call_back)
	if not self.batch_list[caller_id] then
		self.batch_list[caller_id] = batch.New(self.batch_list, caller_id)
	end

	local b = self.batch_list[caller_id]
	local id = b:NextIndex()

	local listener = Listener.New(b, call_back, id, once, false)

	if b.is_firing then
		listener.pending = true
		return b:ToPending(listener, id)
	end

	return b:ToActive(listener, id)
end

function default:Fire(caller_id, ...)
	local b = self.batch_list[caller_id]
	if not b then return end

	fire_batch(b, ...)
end

function default:Destroy()
	for _, b in pairs(self.batch_list) do
		b:Destroy()
	end

	for k in pairs(self.batch_list) do self.batch_list[k] = nil end
	for k in pairs(self) do self[k] = nil end
	setmetatable(self, nil)
end

function default:GetListenerBatch(caller_id)
	return self.batch_list[caller_id]
end

function default:GetCurrentIds()
	local ids = {}
	for id in pairs(self.batch_list) do
		table_insert(ids, id)
	end
	return ids
end

function default:CheckStatus(caller_id)
	if not caller_id then
		return next(self.batch_list) ~= nil
	end

	if not self.batch_list[caller_id] then
		return false
	end

	return next(self.batch_list[caller_id].active) ~= nil
		or next(self.batch_list[caller_id].pending) ~= nil
end

-- Public

local CallBack = {}

function CallBack.New()
	return setmetatable({
		batch_list = {}
	}, default)
end

return CallBack

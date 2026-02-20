--[[
	CALLBACK LITE (Lua-compatible)

	Purpose:
		Mutation-safe callback dispatcher with:
			- Global groups (caller_id -> listeners)
			- "Once" listeners
			- Safe Connect/Disconnect during Fire() (no mutation hazards)

	This lite build intentionally excludes:
		- per-instance registries
		- per-player registries
		- Luau type annotations
]]

local table_clear = table.clear or function(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

local function warn_message(msg)
	if warn then
		warn(msg)
	else
		print(msg)
	end
end

local function spawn_thread(thread, ...)
	if task and task.spawn then
		task.spawn(thread, ...)
	else
		local args = { ... }
		coroutine.wrap(function()
			coroutine.resume(thread, table.unpack(args))
		end)()
	end
end

local free_runner_thread

local function run(call_back, ...)
	local cached_runner_thread = free_runner_thread
	free_runner_thread = nil

	local function errorHandler(err)
		if debug and debug.traceback then
			return debug.traceback(tostring(err), 2)
		end
		return tostring(err)
	end

	local success, error_message = xpcall(call_back, errorHandler, ...)
	if not success then
		warn_message(error_message)
	end

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

	spawn_thread(free_runner_thread, listener.call_back, ...)
end

local index = 1
local function generate_index()
	local cached_index = index
	index = index + 1
	return cached_index
end

local batch = {}
batch.__index = batch

function batch.New(self, caller_id)
	return setmetatable({
		caller_id = caller_id,
		parent = self,
		is_firing = false,
		destroyed = false,
		dirty = false,
		pending = {},
		active = {},
		clean_up_buffer = {},
	}, batch)
end

function batch:ToPending(listener, id)
	listener.pending = true
	self.pending[id] = listener
	return listener
end

function batch:ToActive(listener, id)
	self.active[id] = listener
	return listener
end

function batch:RemoveListener(id)
	self.pending[id] = nil
	self.active[id] = nil
end

function batch:FlushPending()
	for _, listener in pairs(self.pending) do
		if listener.connected then
			listener.pending = false
			self:ToActive(listener, listener.index)
		end
	end

	table_clear(self.pending)
end

function batch:CleanUp()
	local empty_active = not next(self.active)
	local empty_pending = not next(self.pending)

	if empty_active and empty_pending then
		self:Destroy()
		return
	end

	if empty_active then
		table_clear(self.active)
	end
	if empty_pending then
		table_clear(self.pending)
	end
end

function batch:CleanUpAfterFire()
	if self.dirty then
		self:Destroy()
		return
	end

	local clean_up = self.clean_up_buffer
	for _, listener in pairs(self.active) do
		if (not listener.connected) or listener.dirty then
			table.insert(clean_up, listener)
		end
	end

	for _, listener in ipairs(clean_up) do
		listener:Disconnect()
	end

	table_clear(clean_up)
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

	table_clear(self.pending)
	table_clear(self.active)
	table_clear(self.clean_up_buffer)

	self.parent = nil
	self.caller_id = nil
end

local Listener = {}
Listener.__index = Listener

function Listener.New(self, call_back, id, once, pending)
	return setmetatable({
		call_back = call_back,
		once = once,
		index = id,
		connected = true,
		dirty = false,
		pending = pending,
		batch = self,
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

function Listener:Fire(...)
	if self.pending then
		warn_message("Attempted to execute a pending listener during active firing.")
		return
	end

	if self.once then
		self:Disconnect()
	end

	run_listener_in_runner_thread(self, ...)
end

local default = {}
default.__index = default

function default:Listen(caller_id, once, call_back)
	if not self.batch_list[caller_id] then
		self.batch_list[caller_id] = batch.New(self.batch_list, caller_id)
	end

	local batch_obj = self.batch_list[caller_id]
	local id = generate_index()
	local listener = Listener.New(batch_obj, call_back, id, once, false)

	if batch_obj.is_firing then
		listener.pending = true
		return batch_obj:ToPending(listener, id)
	end

	return batch_obj:ToActive(listener, id)
end

function default:Fire(caller_id, ...)
	local batch_obj = self.batch_list[caller_id]
	if not batch_obj then return end

	batch_obj.is_firing = true
	for _, listener in pairs(batch_obj.active) do
		if listener.connected and not listener.pending then
			listener:Fire(...)
		end
	end
	batch_obj.is_firing = false

	batch_obj:FlushPending()
	batch_obj:CleanUpAfterFire()
end

function default:Destroy()
	for _, batches in pairs(self.batch_list) do
		batches:Destroy()
	end

	table_clear(self.batch_list)
	table_clear(self)
	setmetatable(self, nil)
end

function default:GetListenerBatch(caller_id)
	return self.batch_list[caller_id]
end

function default:GeCurrentIds()
	local ids = {}
	for id in pairs(self.batch_list) do
		table.insert(ids, id)
	end
	return ids
end

function default:CheckStatus(caller_id)
	if caller_id == nil then
		return not not next(self.batch_list)
	end

	if not self.batch_list[caller_id] then
		return false
	end

	return not (not next(self.batch_list[caller_id].active) and not next(self.batch_list[caller_id].pending))
end

local CallBackLite = {}

function CallBackLite.New()
	return setmetatable({
		batch_list = {},
	}, default)
end

return CallBackLite

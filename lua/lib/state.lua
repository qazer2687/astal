local astal = require("astal")
local Variable = astal.Variable
local Debug = require("lua.lib.debug")

local State = {}
local subscribers = {}
local state_objects = {}
local STATE_DIR = os.getenv("HOME") .. "/.local/share/astal/state"

local function ensure_state_dir()
	os.execute("mkdir -p " .. STATE_DIR)
end

function State.create(name, initial_value)
	if state_objects[name] then
		Debug.warn("State", "State object '%s' already exists, returning existing instance", name)
		return state_objects[name]
	end

	local state = Variable(initial_value)
	state_objects[name] = state
	subscribers[name] = {}

	return state
end

function State.get(name)
	if not state_objects[name] then
		Debug.warn("State", "State object '%s' does not exist", name)
		return nil
	end

	return state_objects[name]
end

function State.set(name, value)
	if not state_objects[name] then
		Debug.error("State", "Cannot set state: object '%s' does not exist", name)
		return false
	end

	state_objects[name]:set(value)
	return true
end

function State.update(name, updater_fn)
	if not state_objects[name] then
		Debug.error("State", "Cannot update state: object '%s' does not exist", name)
		return false
	end

	local current = state_objects[name]:get()
	local new_value = updater_fn(current)
	state_objects[name]:set(new_value)
	return true
end

function State.subscribe(name, callback)
	if not state_objects[name] then
		Debug.error("State", "Cannot subscribe: state object '%s' does not exist", name)
		return nil
	end

	local subscription = state_objects[name]:subscribe(callback)
	table.insert(subscribers[name], subscription)

	return {
		unsubscribe = function()
			subscription:unsubscribe()
			for i, sub in ipairs(subscribers[name]) do
				if sub == subscription then
					table.remove(subscribers[name], i)
					break
				end
			end
		end,
	}
end

function State.cleanup(name)
	if not state_objects[name] then
		return
	end

	for _, subscription in ipairs(subscribers[name] or {}) do
		pcall(function()
			subscription:unsubscribe()
		end)
	end

	subscribers[name] = {}

	pcall(function()
		state_objects[name]:drop()
	end)
	state_objects[name] = nil
end

function State.cleanup_all()
	for name, _ in pairs(state_objects) do
		State.cleanup(name)
	end

	subscribers = {}
	state_objects = {}
end

function State.derive(name, dependencies, transform_fn)
	local dep_vars = {}
	for _, dep_name in ipairs(dependencies) do
		local state = State.get(dep_name)
		if not state then
			Debug.error("State", "Cannot derive: dependency '%s' does not exist", dep_name)
			return nil
		end
		table.insert(dep_vars, state)
	end

	local derived = Variable.derive(dep_vars, transform_fn)
	state_objects[name] = derived
	subscribers[name] = {}

	return derived
end

function State.persist(name, storage_key)
	if not state_objects[name] then
		Debug.error("State", "Cannot persist: state object '%s' does not exist", name)
		return false
	end

	local key = storage_key or name
	local value = state_objects[name]:get()

	local success, err = pcall(function()
		local serialized
		if type(value) == "table" then
			serialized = astal.json_encode(value)
		else
			serialized = tostring(value)
		end

		ensure_state_dir()

		local file = io.open(STATE_DIR .. "/" .. key .. ".json", "w")
		if file then
			file:write(serialized)
			file:close()
			return true
		end
		return false
	end)

	if not success then
		Debug.error("State", "Failed to persist state '%s': %s", name, err)
		return false
	end

	return true
end

function State.load(name, storage_key)
	local key = storage_key or name
	local path = STATE_DIR .. "/" .. key .. ".json"

	local success, content = pcall(function()
		local file = io.open(path, "r")
		if not file then
			return nil
		end

		local content = file:read("*all")
		file:close()
		return content
	end)

	if not success or not content then
		Debug.warn("State", "Failed to load state '%s' from storage", name)
		return nil
	end

	local parsed
	success, parsed = pcall(function()
		return astal.json_decode(content)
	end)

	if not success then
		Debug.warn("State", "Failed to parse state '%s' from storage, trying as raw value", name)
		return content
	end

	return parsed
end

function State.create_persisted(name, initial_value, storage_key)
	local stored_value = State.load(name, storage_key)
	local state = State.create(name, stored_value or initial_value)

	State.subscribe(name, function()
		State.persist(name, storage_key)
	end)

	return state
end

function State.poll(name, interval, getter_fn)
	if state_objects[name] then
		Debug.warn("State", "State '%s' already exists, will update with poll", name)
	else
		State.create(name, getter_fn())
	end

	local timer_id = astal.timeout_interval(interval, function()
		local value = getter_fn()
		State.set(name, value)
		return true
	end)

	return {
		stop = function()
			astal.clear_timeout(timer_id)
		end,
	}
end

return State

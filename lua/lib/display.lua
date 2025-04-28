local astal = require("astal")
local Variable = astal.Variable
local exec = astal.exec
local GLib = astal.require("GLib")
local Debug = require("lua.lib.debug")

local Display = {}

local STATE_FILE = GLib.get_user_cache_dir() .. "/astal/display.json"
local DEFAULT_STATE = {
	enabled = false,
	temp = 3500,
}

local function load_state()
	local file = io.open(STATE_FILE, "r")
	if not file then
		return DEFAULT_STATE
	end

	local content = file:read("*all")
	file:close()

	local success, data = pcall(astal.json_decode, content)
	return success and data or DEFAULT_STATE
end

local function save_state(enabled, temp)
	os.execute("mkdir -p " .. GLib.get_user_cache_dir() .. "/astal")
	local file = io.open(STATE_FILE, "w")
	if not file then
		Debug.error("Display", "Failed to open state file for writing")
		return false
	end

	local data = {
		enabled = enabled and true or false,
		temp = tonumber(temp) or 3500,
	}

	local success, result = pcall(function()
		return string.format('{"enabled":%s,"temp":%d}', data.enabled and "true" or "false", data.temp)
	end)

	if not success then
		Debug.error("Display", "Failed to format state data: " .. tostring(result))
		file:close()
		return false
	end

	file:write(result)
	file:close()

	return true
end

function Display:init_night_light_state()
	local function check_gammastep_status()
		local success, ps_out = pcall(exec, "pgrep gammastep")
		if success and ps_out and ps_out ~= "" then
			local _, cmdline = pcall(exec, "ps -o args= -p " .. ps_out:gsub("%s+", ""))
			local temp = cmdline and cmdline:match("-O%s*(%d+)")

			if temp then
				temp = tonumber(temp)
				self.actual_temp = temp
				local normalized = (temp - 2500) / 4000
				self.night_light_temp:set(normalized)
				self.night_light_enabled:set(true)
				return true
			end
		end
		self.night_light_enabled:set(false)
		return false
	end

	pcall(check_gammastep_status)
end

function Display:New()
	local stored_state = load_state()
	local initial_temp = stored_state.temp or 3500
	local normalized_temp = (initial_temp - 2500) / 4000

	local instance = {
		brightness = Variable.new(tonumber(exec("brightnessctl get")) / 255 or 0.75),
		night_light_enabled = Variable.new(stored_state.enabled or false),
		night_light_temp = Variable.new(normalized_temp),
		actual_temp = initial_temp,
		update_timeout = nil,
		initialized = false,
	}
	setmetatable(instance, self)
	self.__index = self

	instance.night_light_enabled:subscribe(function(enabled)
		save_state(enabled == true, math.floor(instance.actual_temp))
	end)

	instance.night_light_temp:subscribe(function()
		save_state(instance.night_light_enabled:get() == true, math.floor(instance.actual_temp))
	end)

	instance:init_night_light_state()
	instance.initialized = true

	if stored_state.enabled then
		instance:apply_night_light()
	end

	return instance
end

function Display:set_brightness(value)
	if value < 0 or value > 1 then
		Debug.error("Display", "Invalid brightness value: %f", value)
		return false
	end

	local percentage = math.floor(value * 100)
	local _, err = exec(string.format("brightnessctl set %d%%", percentage))
	if err then
		Debug.error("Display", "Failed to set brightness: %s", err)
		return false
	end

	self.brightness:set(value)
	return true
end

function Display:apply_night_light()
	if not self.initialized then
		return
	end

	local proc_success, ps_out = pcall(exec, "pgrep gammastep")
	if proc_success and ps_out and ps_out ~= "" then
		local _, cmdline = pcall(exec, "ps -o args= -p " .. ps_out:gsub("%s+", ""))
		local current_temp = cmdline and cmdline:match("-O%s*(%d+)")

		if current_temp and tonumber(current_temp) == self.actual_temp then
			self.night_light_enabled:set(true)
			return
		end
	end

	self.actual_temp = math.floor(2500 + (self.night_light_temp:get() * 4000))

	if proc_success and ps_out and ps_out ~= "" then
		local kill_success, _ = pcall(exec, "pkill gammastep")
		if not kill_success then
			Debug.error("Display", "Failed to kill existing gammastep process")
		end
		GLib.usleep(100000)
	end

	local spawn_success, _, _, stderr = pcall(function()
		return GLib.spawn_command_line_async(string.format("gammastep -O %d", self.actual_temp))
	end)

	if not spawn_success or stderr then
		Debug.error("Display", "Failed to start gammastep: %s", stderr or "unknown error")
		self.night_light_enabled:set(false)
	else
		self.night_light_enabled:set(true)
		save_state(true, self.actual_temp)
	end
end

function Display:toggle_night_light()
	if not self.initialized then
		Debug.error("Display", "Display not properly initialized")
		return
	end

	local new_state = not self.night_light_enabled:get()

	if new_state then
		self:apply_night_light()
	else
		local kill_success, _ = pcall(exec, "pkill gammastep")
		if not kill_success then
			Debug.error("Display", "Failed to kill gammastep process")
		end

		GLib.usleep(100000)

		local reset_success, _ = pcall(function()
			return GLib.spawn_command_line_async("gammastep -x")
		end)

		if not reset_success then
			Debug.error("Display", "Failed to reset gammastep")
		end

		self.night_light_enabled:set(false)
		save_state(false, self.actual_temp)
	end
end

function Display:set_night_light_temp(value)
	if value < 0 or value > 1 then
		Debug.error("Display", "Invalid temperature value: %f", value)
		return false
	end

	self.night_light_temp:set(value)

	if self.night_light_enabled:get() then
		if self.update_timeout then
			GLib.source_remove(self.update_timeout)
			self.update_timeout = nil
		end

		self.update_timeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, function()
			self:apply_night_light()
			self.update_timeout = nil
			return GLib.SOURCE_REMOVE
		end)
	end

	return true
end

function Display:cleanup()
	if self.update_timeout then
		GLib.source_remove(self.update_timeout)
		self.update_timeout = nil
	end

	if self.night_light_enabled then
		save_state(self.night_light_enabled:get() == true, math.floor(self.actual_temp))
	end

	if self.brightness then
		self.brightness:drop()
		self.brightness = nil
	end
	if self.night_light_enabled then
		self.night_light_enabled:drop()
		self.night_light_enabled = nil
	end
	if self.night_light_temp then
		self.night_light_temp:drop()
		self.night_light_temp = nil
	end

	self.initialized = false
end

local instance = nil
function Display.get_default()
	if not instance then
		instance = Display:New()
	end
	return instance
end

function Display.cleanup_singleton()
	if instance then
		instance:cleanup()
		instance = nil
	end
end

return Display

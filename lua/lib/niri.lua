local astal = require("astal")
local cjson = require("cjson")
local GLib = require("lgi").GLib
local Debug = require("lua.lib.debug")
local Variable = astal.Variable
local utils = require("lua.lib.utils")

local DEFAULT_CONFIG = {
	monitor_order = { "eDP-1", "HDMI-A-1" },
	monitor_poll_interval = 5000,
	workspace_poll_interval = 250,
	window_poll_interval = 450,
	window_debounce_threshold = 100000,
}

local cache = {
	monitors = { timestamp = 0, data = {}, max_age = 5 },
	workspaces = { hash = "", data = {}, max_entries = 50 },
	windows = { data = {}, timestamp = 0 },
}

local rate_limiter = {
	last_monitor_fetch = 0,
	last_workspace_fetch = 0,
	last_window_fetch = 0,
}

local window_event_handlers = {}
local window_watcher_source_id = nil

local function exec_niri_cmd(cmd)
	local full_cmd = "niri msg --json " .. cmd
	local out, err = astal.exec(full_cmd)

	if err then
		Debug.error("Niri", "Failed to execute niri command: %s, error: %s", full_cmd, err)
		return nil
	end

	if not out or out == "" then
		Debug.debug("Niri", "Empty output from niri command: %s (this may be normal)", cmd)
		return nil
	end

	local success, data = pcall(cjson.decode, out)
	if not success then
		Debug.error("Niri", "Failed to decode JSON from niri command: %s, output: %s", cmd, out)
		return nil
	end

	return data
end

local function get_monitors(config)
	config = config or DEFAULT_CONFIG
	local monitor_order = config.monitor_order or DEFAULT_CONFIG.monitor_order
	local current_time = GLib.get_monotonic_time() / 1000000

	if current_time - cache.monitors.timestamp < cache.monitors.max_age then
		return cache.monitors.data
	end

	if
		current_time - rate_limiter.last_monitor_fetch
		< ((config.monitor_poll_interval or DEFAULT_CONFIG.monitor_poll_interval) / 1000)
	then
		return cache.monitors.data
	end

	rate_limiter.last_monitor_fetch = current_time

	local monitors = exec_niri_cmd("outputs")
	if not monitors then
		return {}
	end

	local monitor_array = {}
	for _, name in ipairs(monitor_order) do
		if monitors[name] then
			table.insert(monitor_array, {
				name = name,
				id = name:gsub("-", "_"),
				logical = monitors[name].logical,
			})
		end
	end

	cache.monitors.timestamp = current_time
	cache.monitors.data = monitor_array

	return monitor_array
end

local function process_workspaces(config)
	config = config or DEFAULT_CONFIG
	local current_time = GLib.get_monotonic_time() / 1000000

	if
		current_time - rate_limiter.last_workspace_fetch
		< ((config.workspace_poll_interval or DEFAULT_CONFIG.workspace_poll_interval) / 1000)
	then
		return cache.workspaces.data
	end

	rate_limiter.last_workspace_fetch = current_time

	local workspaces = exec_niri_cmd("workspaces")
	if not workspaces then
		return cache.workspaces.data
	end

	local state_hash = ""
	for i, w in ipairs(workspaces) do
		state_hash = state_hash .. w.output .. "-" .. w.idx .. "-" .. (w.is_active and "1" or "0")
		if i < #workspaces then
			state_hash = state_hash .. "|"
		end
	end

	if cache.workspaces.hash == state_hash then
		return cache.workspaces.data
	end

	local monitors = get_monitors(config)
	local output_workspaces = {}

	for _, workspace in ipairs(workspaces) do
		output_workspaces[workspace.output] = output_workspaces[workspace.output] or {}
		table.insert(output_workspaces[workspace.output], {
			id = workspace.idx,
			is_active = workspace.is_active,
			workspace_id = workspace.id,
		})
	end

	local workspace_data = {}
	for _, monitor in ipairs(monitors) do
		local monitor_workspaces = output_workspaces[monitor.name] or {}
		table.sort(monitor_workspaces, function(a, b)
			return a.id < b.id
		end)
		table.insert(workspace_data, {
			monitor = monitor.id,
			name = monitor.name,
			workspaces = monitor_workspaces,
		})
	end

	cache.workspaces.hash = state_hash
	cache.workspaces.data = workspace_data

	return workspace_data
end

local function get_active_window()
	local window = exec_niri_cmd("focused-window")

	if window == nil then
		return { app_id = "Desktop", title = "niri" }
	end

	if type(window) ~= "table" then
		local type_str = type(window)
		if type_str == "userdata" then
			return { app_id = "Desktop", title = "niri" }
		end
		Debug.error("Niri", "Focused window has unexpected format: %s, type: %s", tostring(window), type_str)
		return { app_id = "Desktop", title = "niri" }
	end

	cache.windows.data = window
	cache.windows.timestamp = GLib.get_monotonic_time()
	return window
end

local function get_all_windows()
	local windows = exec_niri_cmd("windows")
	return windows or {}
end

local function perform_action(action, ...)
	local args = { ... }
	local cmd_args = action

	for _, arg in ipairs(args) do
		cmd_args = cmd_args .. " " .. tostring(arg)
	end

	local full_cmd = string.format("niri msg action %s", cmd_args)
	local out, err = astal.exec(full_cmd)

	if err then
		Debug.error("Niri", "Failed to perform action: %s, error: %s", action, err)
		return false, err
	end

	return true, out
end

local function register_window_callback(callback)
	if not callback or type(callback) ~= "function" then
		return nil
	end

	table.insert(window_event_handlers, callback)

	if not window_watcher_source_id and #window_event_handlers == 1 then
		local last_windows_hash = ""

		window_watcher_source_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function()
			local windows = get_all_windows()

			local hash = ""
			for _, window in ipairs(windows) do
				hash = hash .. (window.app_id or "") .. (window.is_focused and "1" or "0")
			end

			if hash ~= last_windows_hash then
				last_windows_hash = hash

				for _, handler in ipairs(window_event_handlers) do
					handler(windows)
				end
			end

			return GLib.SOURCE_CONTINUE
		end)
	end

	local function unregister()
		for i, handler in ipairs(window_event_handlers) do
			if handler == callback then
				table.remove(window_event_handlers, i)
				break
			end
		end

		if #window_event_handlers == 0 and window_watcher_source_id then
			GLib.source_remove(window_watcher_source_id)
			window_watcher_source_id = nil
		end
	end

	return { unregister = unregister }
end

local function register_window_state_callback(callback)
	local last_state = {}
	return register_window_callback(function(windows)
		local current_state = {}
		for _, window in ipairs(windows) do
			if window.app_id then
				current_state[window.app_id] = true
			end
		end

		local changed = false
		for app_id in pairs(current_state) do
			if not last_state[app_id] then
				changed = true
				break
			end
		end
		for app_id in pairs(last_state) do
			if not current_state[app_id] then
				changed = true
				break
			end
		end

		if changed then
			last_state = current_state
			callback(current_state)
		end
	end)
end

local function create_workspace_variables(config)
	config = config or DEFAULT_CONFIG
	local is_destroyed = false

	local workspace_data = Variable(process_workspaces(config))
	local monitors_var = Variable(get_monitors(config))

	local workspaces = Variable.derive({ workspace_data, monitors_var }, function(ws_data, monitors)
		if is_destroyed then
			return {}
		end
		return (ws_data and monitors) and ws_data or {}
	end)

	local workspace_source = nil
	workspace_source = GLib.timeout_add(
		GLib.PRIORITY_DEFAULT,
		config.workspace_poll_interval or DEFAULT_CONFIG.workspace_poll_interval,
		function()
			if is_destroyed then
				return GLib.SOURCE_REMOVE
			end
			workspace_data:set(process_workspaces(config))
			return GLib.SOURCE_CONTINUE
		end
	)

	local monitor_source = nil
	monitor_source = GLib.timeout_add(
		GLib.PRIORITY_DEFAULT,
		config.monitor_poll_interval or DEFAULT_CONFIG.monitor_poll_interval,
		function()
			if is_destroyed then
				return GLib.SOURCE_REMOVE
			end
			monitors_var:set(get_monitors(config))
			return GLib.SOURCE_CONTINUE
		end
	)

	return {
		workspace_data = workspace_data,
		monitors_var = monitors_var,
		workspaces = workspaces,
		cleanup = function()
			is_destroyed = true
			if workspace_source then
				GLib.source_remove(workspace_source)
				workspace_source = nil
			end
			if monitor_source then
				GLib.source_remove(monitor_source)
				monitor_source = nil
			end
			workspace_data:drop()
			monitors_var:drop()
			workspaces:drop()
			cache.monitors.data = {}
			cache.workspaces.data = {}
		end,
	}
end

local function create_window_variable(config)
	config = config or DEFAULT_CONFIG
	local var = Variable({ app_id = "Desktop", title = "niri" })
	local source_id
	local window_callback = nil
	local is_cleaned_up = false

	local function safe_get_window()
		local ok, window = pcall(get_active_window)
		if not ok or window == nil or type(window) ~= "table" then
			Debug.debug("Niri", "No active window or invalid data, using default")
			return { app_id = "Desktop", title = "niri" }
		end
		return window
	end

	window_callback = register_window_callback(utils.debounce(function()
		if not is_cleaned_up then
			var:set(safe_get_window())
		end
	end, 50))

	source_id = GLib.timeout_add(
		GLib.PRIORITY_LOW,
		config.window_poll_interval or DEFAULT_CONFIG.window_poll_interval,
		function()
			if is_cleaned_up then
				return GLib.SOURCE_REMOVE
			end
			var:set(safe_get_window())
			return GLib.SOURCE_CONTINUE
		end
	)

	local function cleanup()
		is_cleaned_up = true

		if window_callback then
			window_callback.unregister()
			window_callback = nil
		end

		if source_id then
			GLib.source_remove(source_id)
			source_id = nil
		end

		var:drop()
		cache.windows.data = {}
		cache.windows.timestamp = 0
	end

	return var, source_id, cleanup
end

local function reset_caches()
	for k in pairs(cache.monitors.data) do
		cache.monitors.data[k] = nil
	end
	cache.monitors.timestamp = 0

	for k in pairs(cache.workspaces.data) do
		cache.workspaces.data[k] = nil
	end
	cache.workspaces.hash = ""

	for k in pairs(cache.windows.data) do
		cache.windows.data[k] = nil
	end
	cache.windows.timestamp = 0
end

local function cleanup_all()
	if window_watcher_source_id then
		GLib.source_remove(window_watcher_source_id)
		window_watcher_source_id = nil
	end

	window_event_handlers = {}
	reset_caches()
end

return {
	get_monitors = get_monitors,
	get_workspaces = process_workspaces,
	get_active_window = get_active_window,
	get_all_windows = get_all_windows,
	perform_action = perform_action,
	create_workspace_variables = create_workspace_variables,
	create_window_variable = create_window_variable,
	register_window_state_callback = register_window_state_callback,
	reset_caches = reset_caches,
	cleanup = cleanup_all,
	exec_cmd = exec_niri_cmd,
	DEFAULT_CONFIG = DEFAULT_CONFIG,
}

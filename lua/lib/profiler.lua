local astal = require("astal")
local profile = require("lua.lib.profile")
local Debug = require("lua.lib.debug")
local GLib = astal.require("GLib")

local Profiler = {}
local is_profiling = false
local auto_save_timer
local components_data = {}

local HOME = os.getenv("HOME")
local PROFILE_DIR = HOME .. "/.local/share/astal/profiler"

if not astal.file_exists(PROFILE_DIR) then
	os.execute("mkdir -p " .. PROFILE_DIR)
end

local config = {
	enabled = false,
	auto_save = true,
	save_interval = 300,
	report_limit = 30,
	reset_after_save = true,
	component_reports = true,
	output_dir = PROFILE_DIR,
}

function Profiler.configure(options)
	if not options then
		return
	end

	for k, v in pairs(options) do
		if config[k] ~= nil then
			config[k] = v
		end
	end

	if not astal.file_exists(config.output_dir) then
		os.execute("mkdir -p " .. config.output_dir)
	end
end

function Profiler.load_config()
	local user_vars = require("user-variables")
	if user_vars.profiling then
		Profiler.configure(user_vars.profiling)
	end
	return config.enabled
end

function Profiler.start()
	if is_profiling then
		return
	end

	is_profiling = true
	profile.reset()
	profile.start()
	Debug.info("Profiler", "Profiling started")

	if config.auto_save and not auto_save_timer then
		auto_save_timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, config.save_interval, function()
			Profiler.save_report()
			if config.reset_after_save then
				profile.reset()
			end
			return true
		end)
	end

	return true
end

function Profiler.stop()
	if not is_profiling then
		return
	end

	is_profiling = false
	profile.stop()
	Debug.info("Profiler", "Profiling stopped")

	if auto_save_timer then
		GLib.source_remove(auto_save_timer)
		auto_save_timer = nil
	end

	return true
end

function Profiler.reset()
	profile.reset()
	Debug.info("Profiler", "Profiler data reset")
	return true
end

function Profiler.save_report(filename, limit)
	if not is_profiling then
		return nil
	end

	limit = limit or config.report_limit
	local timestamp = os.date("%Y%m%d-%H%M%S")

	if not filename then
		filename = config.output_dir .. "/profile-" .. timestamp .. ".txt"
	end

	local report = profile.report(limit)
	if not report then
		Debug.error("Profiler", "No profiling data to save")
		return nil
	end

	local file = io.open(filename, "w")
	if not file then
		Debug.error("Profiler", "Failed to create profiling report file: " .. filename)
		return nil
	end

	file:write(report)
	file:close()

	Debug.info("Profiler", "Profiling report saved to " .. filename)
	return filename
end

function Profiler.component_start(component_name)
	if not is_profiling or not config.component_reports then
		return
	end

	components_data[component_name] = components_data[component_name] or {}
	components_data[component_name].start_time = os.clock()
	return true
end

function Profiler.component_stop(component_name)
	if not is_profiling or not config.component_reports then
		return
	end

	local comp_data = components_data[component_name]
	if not comp_data or not comp_data.start_time then
		return
	end

	local elapsed = os.clock() - comp_data.start_time
	comp_data.executions = (comp_data.executions or 0) + 1
	comp_data.total_time = (comp_data.total_time or 0) + elapsed
	comp_data.avg_time = comp_data.total_time / comp_data.executions

	Debug.debug("Profiler", "Component '" .. component_name .. "': " .. string.format("%0.6f", elapsed) .. " sec")
	return elapsed
end

function Profiler.wrap(func, name)
	if not func or type(func) ~= "function" then
		return func
	end

	name = name or debug.getinfo(func, "n").name or "anonymous"

	return function(...)
		if not is_profiling then
			return func(...)
		end

		local args = { ... }
		Profiler.component_start(name)

		local results = { xpcall(function()
			return func(table.unpack(args))
		end, debug.traceback) }

		Profiler.component_stop(name)

		local success = table.remove(results, 1)
		if not success then
			Debug.error("Profiler", "Function '" .. name .. "' error: " .. results[1])
			return nil, results[1]
		end

		return table.unpack(results)
	end
end

function Profiler.get_component_data()
	local result = {}
	for name, data in pairs(components_data) do
		if type(data) == "table" and data.executions and data.executions > 0 then
			result[name] = {
				executions = data.executions,
				total_time = data.total_time,
				avg_time = data.avg_time,
			}
		end
	end
	return result
end

function Profiler.save_component_report(filename)
	if not is_profiling then
		return nil
	end

	local timestamp = os.date("%Y%m%d-%H%M%S")
	if not filename then
		filename = config.output_dir .. "/components-" .. timestamp .. ".txt"
	end

	local data = Profiler.get_component_data()
	if not next(data) then
		Debug.warn("Profiler", "No component profiling data to save")
		return nil
	end

	local components = {}
	for name, stats in pairs(data) do
		table.insert(components, {
			name = name,
			executions = stats.executions,
			total_time = stats.total_time,
			avg_time = stats.avg_time,
		})
	end

	table.sort(components, function(a, b)
		return a.total_time > b.total_time
	end)

	local lines = {
		" +-----+----------------------------------+----------+----------------+----------------+",
		" | #   | Component                        | Calls    | Total Time (s) | Avg Time (s)   |",
		" +-----+----------------------------------+----------+----------------+----------------+",
	}

	for i, comp in ipairs(components) do
		local row = string.format(
			" | %-3d | %-32s | %-8d | %-14.6f | %-14.6f |",
			i,
			comp.name,
			comp.executions,
			comp.total_time,
			comp.avg_time
		)
		table.insert(lines, row)
	end

	table.insert(lines, " +-----+----------------------------------+----------+----------------+----------------+")

	local report = table.concat(lines, "\n")
	local file = io.open(filename, "w")
	if not file then
		Debug.error("Profiler", "Failed to create component report file: " .. filename)
		return nil
	end

	file:write(report)
	file:close()

	Debug.info("Profiler", "Component report saved to " .. filename)
	return filename
end

function Profiler.window_load(window, name)
	if not is_profiling or not window then
		return
	end
	name = name or window.class_name or "unknown_window"

	Profiler.component_start("window_load:" .. name)
	window:hook(window, "map", function()
		Profiler.component_stop("window_load:" .. name)
	end)
end

function Profiler.trace_memory()
	if not is_profiling then
		return
	end

	local before = collectgarbage("count")
	collectgarbage("collect")
	local after = collectgarbage("count")

	Debug.info(
		"Profiler",
		"Memory usage: "
			.. string.format("%0.2f", after)
			.. " KB (freed: "
			.. string.format("%0.2f", before - after)
			.. " KB)"
	)

	return after, before - after
end

function Profiler.init_app_profiling()
	if not Profiler.load_config() then
		return false
	end

	Debug.info("Profiler", "Initializing application profiling")
	Profiler.start()

	GLib.timeout_add_seconds(GLib.PRIORITY_LOW, 120, function()
		if is_profiling then
			Profiler.trace_memory()
			return true
		end
		return false
	end)

	return true
end

function Profiler.cleanup()
	Profiler.stop()
	if auto_save_timer then
		GLib.source_remove(auto_save_timer)
		auto_save_timer = nil
	end
	components_data = {}
	collectgarbage("collect")
end

function Profiler.is_enabled()
	return is_profiling
end

return Profiler

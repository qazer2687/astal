local GLib = require("astal").require("GLib")

local utils = {}

function utils.debounce(func, wait, immediate)
	local timeout_id = nil
	local function debounced(...)
		local args = { ... }

		if timeout_id then
			GLib.source_remove(timeout_id)
			timeout_id = nil
		end

		if immediate and not timeout_id then
			func(table.unpack(args))
		end

		timeout_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, wait, function()
			if not immediate then
				func(table.unpack(args))
			end
			timeout_id = nil
			return GLib.SOURCE_REMOVE
		end)

		return function()
			if timeout_id then
				GLib.source_remove(timeout_id)
				timeout_id = nil
			end
		end
	end

	return debounced
end

function utils.throttle(func, limit)
	local last = 0
	local timeout_id = nil

	return function(...)
		local now = GLib.get_monotonic_time() / 1000
		local args = { ... }

		if (now - last) > limit then
			last = now
			return func(table.unpack(args))
		else
			if timeout_id then
				GLib.source_remove(timeout_id)
			end

			timeout_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, limit - (now - last), function()
				last = GLib.get_monotonic_time() / 1000
				func(table.unpack(args))
				timeout_id = nil
				return GLib.SOURCE_REMOVE
			end)
		end
	end
end

function utils.memoize(func)
	local cache = {}

	return function(...)
		local args = { ... }
		local key = table.concat(args, "|")

		if cache[key] == nil then
			cache[key] = func(table.unpack(args))
		end

		return cache[key]
	end
end

function utils.safe_cleanup(callback)
	return function(...)
		local success, err = pcall(callback, ...)
		if not success then
			local Debug = require("lua.lib.debug")
			Debug.error("SafeCleanup", "Error during cleanup: %s", err)
		end
	end
end

function utils.delay(ms, callback)
	return GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, function()
		callback()
		return GLib.SOURCE_REMOVE
	end)
end

function utils.create_rate_limiter(limit_ms)
	local last_call_time = 0
	local pending_call = nil

	local function execute_call(func, args)
		if pending_call then
			GLib.source_remove(pending_call)
			pending_call = nil
		end

		last_call_time = GLib.get_monotonic_time() / 1000
		return func(table.unpack(args))
	end

	return function(func)
		return function(...)
			local args = { ... }
			local current_time = GLib.get_monotonic_time() / 1000
			local time_since_last = current_time - last_call_time

			if time_since_last >= limit_ms then
				return execute_call(func, args)
			else
				if pending_call then
					GLib.source_remove(pending_call)
				end

				pending_call = GLib.timeout_add(GLib.PRIORITY_DEFAULT, limit_ms - time_since_last, function()
					execute_call(func, args)
					pending_call = nil
					return GLib.SOURCE_REMOVE
				end)
			end
		end
	end
end

function utils.once(func)
	local called = false
	local result

	return function(...)
		if not called then
			called = true
			result = func(...)
		end
		return result
	end
end

return utils

local astal = require("astal")
local Debug = require("lua.lib.debug")
local GLib = astal.require("GLib")
local Gio = astal.require("Gio")

local DBus = {}

local subscriptions = {}
local connections = {
	session = nil,
	system = nil,
}

function DBus.initialize()
	if connections.session then
		return
	end

	connections.session = Gio.bus_get_sync(Gio.BusType.SESSION, nil)
	connections.system = Gio.bus_get_sync(Gio.BusType.SYSTEM, nil)

	if not connections.session or not connections.system then
		Debug.error("DBus", "Failed to initialize D-Bus connections")
		return false
	end

	return true
end

function DBus.cleanup()
	for _, sub in ipairs(subscriptions) do
		if sub.connection and sub.id then
			sub.connection:signal_unsubscribe(sub.id)
		end
	end

	subscriptions = {}
	connections.session = nil
	connections.system = nil
end

function DBus.subscribe(bus_type, sender, object_path, interface, signal, callback)
	if not connections.session then
		if not DBus.initialize() then
			return nil
		end
	end

	local connection = (bus_type == "system") and connections.system or connections.session
	if not connection then
		Debug.error("DBus", "No D-Bus connection available")
		return nil
	end

	local subscription_id = connection:signal_subscribe(
		sender,
		interface,
		signal,
		object_path,
		nil,
		Gio.DBusSignalFlags.NONE,
		function(_, _, _, _, _, parameters)
			local args = {}
			if parameters then
				for i = 0, parameters:get_n_children() - 1 do
					table.insert(args, parameters:get_child_value(i))
				end
			end
			callback(table.unpack(args))
		end
	)

	if subscription_id > 0 then
		local sub = {
			connection = connection,
			id = subscription_id,
			bus_type = bus_type,
			sender = sender,
			path = object_path,
			interface = interface,
			signal = signal,
		}
		table.insert(subscriptions, sub)
		return sub
	end

	Debug.error("DBus", "Failed to subscribe to signal: %s, %s, %s", sender or "", interface or "", signal or "")
	return nil
end

function DBus.call(bus_type, destination, object_path, interface, method, parameters, callback)
	if not connections.session then
		if not DBus.initialize() then
			return false
		end
	end

	local connection = (bus_type == "system") and connections.system or connections.session
	if not connection then
		Debug.error("DBus", "No D-Bus connection available")
		return false
	end

	local params = nil
	if parameters then
		params = GLib.Variant.new_tuple(parameters, #parameters)
	end

	if callback then
		connection:call(
			destination,
			object_path,
			interface,
			method,
			params,
			nil,
			Gio.DBusCallFlags.NONE,
			-1,
			nil,
			function(conn, result)
				local success, ret = pcall(function()
					return conn:call_finish(result)
				end)

				if success and ret then
					callback(true, ret)
				else
					callback(false, ret)
				end
			end
		)
		return true
	else
		local success, ret = pcall(function()
			return connection:call_sync(
				destination,
				object_path,
				interface,
				method,
				params,
				nil,
				Gio.DBusCallFlags.NONE,
				-1,
				nil
			)
		end)

		if success and ret then
			return true, ret
		else
			Debug.error(
				"DBus",
				"Call failed: %s, %s, %s.%s: %s",
				destination or "",
				object_path or "",
				interface or "",
				method or "",
				tostring(ret)
			)
			return false, ret
		end
	end
end

function DBus.watch_name(bus_type, name, callback)
	if not connections.session then
		if not DBus.initialize() then
			return nil
		end
	end

	local connection = (bus_type == "system") and connections.system or connections.session
	if not connection then
		Debug.error("DBus", "No D-Bus connection available")
		return nil
	end

	local watcher_id = Gio.bus_watch_name_on_connection(connection, name, Gio.BusNameWatcherFlags.NONE, function()
		callback(true)
	end, function()
		callback(false)
	end)

	if watcher_id > 0 then
		return {
			unwatch = function()
				Gio.bus_unwatch_name(watcher_id)
			end,
		}
	end

	return nil
end

return DBus

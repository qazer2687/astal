local astal = require("astal")
local Widget = require("astal.gtk3").Widget
local Variable = astal.Variable
local bind = astal.bind
local utf8 = require("lua-utf8")
local niri = require("lua.lib.niri")
local Debug = require("lua.lib.debug")

local SANITIZE_PATTERN = "[%z\1-\31\127]"

local function sanitize_utf8(text)
	if not text then
		return ""
	end

	if type(text) ~= "string" then
		text = tostring(text)
	end

	local gsub_ok, result = pcall(utf8.gsub, text, SANITIZE_PATTERN, "")
	if not gsub_ok then
		Debug.warn("ActiveClient", "Failed to sanitize UTF-8 text: %s", result)
		return tostring(text)
	end

	return result
end

local function truncate_text(text, length)
	if not text then
		return ""
	end

	local sanitized = sanitize_utf8(text)

	local len_ok, len = pcall(utf8.len, sanitized)
	if not len_ok then
		Debug.warn("ActiveClient", "Failed to get UTF-8 length: %s", len)
		return sanitized
	end

	if len > length then
		local sub_ok, result = pcall(utf8.sub, sanitized, 1, length)
		if not sub_ok then
			Debug.warn("ActiveClient", "Failed to truncate UTF-8 text: %s", result)
			return sanitized
		end
		return result .. "..."
	end

	return sanitized
end

return function()
	local config = {
		window_poll_interval = 450,
		window_debounce_threshold = 100000,
	}

	local window_var, _, cleanup_fn = niri.create_window_variable(config)

	local app_id_var = Variable.derive({ bind(window_var) }, function(window)
		if not window or type(window) ~= "table" then
			return "Desktop"
		end
		return sanitize_utf8(window.app_id or "Desktop")
	end)

	local title_var = Variable.derive({ bind(window_var) }, function(window)
		if not window or type(window) ~= "table" then
			return "niri"
		end
		return truncate_text(window.title or "niri", 40)
	end)

	return Widget.Box({
		class_name = "ActiveClient",
		setup = function(self)
			self:hook(self, "destroy", function()
				if cleanup_fn then
					cleanup_fn()
				end
				app_id_var:drop()
				title_var:drop()
			end)
		end,
		Widget.Box({
			orientation = "VERTICAL",
			Widget.Label({
				class_name = "app-id",
				label = bind(app_id_var),
				halign = "START",
			}),
			Widget.Label({
				class_name = "window-title",
				label = bind(title_var),
				halign = "START",
				ellipsize = "END",
			}),
		}),
	})
end

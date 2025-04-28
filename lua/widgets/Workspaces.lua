local astal = require("astal")
local Widget = require("astal.gtk3.widget")
local bind = astal.bind
local niri = require("lua.lib.niri")
local Debug = require("lua.lib.debug")

local function WorkspaceButton(props)
	return Widget.Button({
		class_name = "workspace-button" .. (props.is_active and " active" or ""),
		on_clicked = function()
			if not niri.switch_to_workspace(props.id, props.monitor_name) then
				Debug.error("Workspaces", "Failed to switch to workspace %d on %s", props.id, props.monitor_name)
			end
		end,
	})
end

local function MonitorWorkspaces(props)
	local monitor_number = props.name == "HDMI-A-1" and 2 or 1
	local buttons = {}
	local workspaces = props.workspaces

	for i = 1, #workspaces do
		local ws = workspaces[i]
		buttons[i] = WorkspaceButton({
			id = ws.id,
			monitor = monitor_number,
			monitor_name = props.name,
			is_active = ws.is_active,
			workspace_id = ws.workspace_id,
		})
	end

	return Widget.Box({
		class_name = string.format("monitor-workspaces monitor-%d", monitor_number),
		orientation = "HORIZONTAL",
		spacing = 3,
		Widget.Box({
			orientation = "HORIZONTAL",
			spacing = 3,
			table.unpack(buttons),
		}),
	})
end

return function()
	local config = {
		monitor_order = { "eDP-1", "HDMI-A-1" },
		monitor_poll_interval = 5000,
		workspace_poll_interval = 250,
	}

	local vars = niri.create_workspace_variables(config)

	return Widget.Box({
		class_name = "Workspaces",
		orientation = "HORIZONTAL",
		spacing = 2,
		bind(vars.workspaces):as(function(ws)
			local new_widgets = {}

			for i = 1, #ws do
				local monitor = ws[i]
				new_widgets[i] = MonitorWorkspaces({
					monitor = monitor.monitor,
					name = monitor.name,
					workspaces = monitor.workspaces,
				})
			end

			return new_widgets
		end),
		setup = function(self)
			self:hook(self, "destroy", function()
				if vars and vars.cleanup then
					vars.cleanup()
					vars = nil
				end
			end)
		end,
	})
end

local astal = require("astal")
local Widget = require("astal.gtk3").Widget
local Apps = astal.require("AstalApps")
local dock_config = require("lua.lib.dock-config")
local GLib = astal.require("GLib")
local Debug = require("lua.lib.debug")
local State = require("lua.lib.state")
local utils = require("lua.lib.utils")

local apps_singleton
local function get_apps_service()
	if not apps_singleton then
		apps_singleton = Apps.Apps.new()
		if apps_singleton and apps_singleton.reload then
			apps_singleton:reload()
		else
			Debug.error("Dock", "Failed to initialize Apps service")
		end
	end
	return apps_singleton
end

local function DockIcon(props)
	if not props.icon then
		Debug.warn("Dock", "Creating dock icon without icon for entry: %s", props.desktop_entry or "unknown")
	end

	return Widget.Button({
		class_name = "dock-icon",
		on_clicked = props.on_clicked,
		Widget.Box({
			orientation = "VERTICAL",
			spacing = 2,
			Widget.Icon({
				icon = props.icon or "application-x-executable",
				pixel_size = 48,
			}),
			Widget.Box({
				class_name = "indicator",
				visible = props.is_running or false,
				hexpand = false,
				halign = "CENTER",
				width_request = 3,
				height_request = 3,
			}),
		}),
	})
end

local function DockContainer()
	local apps = get_apps_service()
	if not apps then
		Debug.error("Dock", "Failed to initialize Apps service")
		return Widget.Box({})
	end

	local container_active = true
	local subscription_apps, subscription_running, subscription_pinned
	local visibility_subscription
	local is_visible = false

	local initial_apps = {}
	local app_list = apps:get_list()
	if app_list then
		for _, app in ipairs(app_list) do
			if app and app.entry then
				initial_apps[app.entry] = app
			end
		end
	end

	State.create("dock_available_apps", initial_apps)
	State.create("dock_running_apps", {})
	State.create("dock_pinned_apps", {})

	dock_config.init()

	local function cleanup_container()
		container_active = false

		if subscription_apps then
			subscription_apps:unsubscribe()
			subscription_apps = nil
		end

		if subscription_running then
			subscription_running:unsubscribe()
			subscription_running = nil
		end

		if subscription_pinned then
			subscription_pinned:unsubscribe()
			subscription_pinned = nil
		end

		if visibility_subscription then
			visibility_subscription:unsubscribe()
			visibility_subscription = nil
		end

		State.cleanup("dock_available_apps")
		State.cleanup("dock_running_apps")
		State.cleanup("dock_pinned_apps")
	end

	local update_apps_state = utils.debounce(function()
		if not container_active or not is_visible then
			return
		end

		local app_list = apps:get_list()
		if not app_list then
			return
		end

		local available = {}
		for _, app in ipairs(app_list) do
			if app and app.entry then
				available[app.entry] = app
			end
		end

		State.set("dock_available_apps", available)
	end, 1000)

	local render_icons = utils.throttle(function(self)
		if not self or not container_active then
			return
		end

		local available_apps = State.get("dock_available_apps"):get() or {}
		local pinned_apps = State.get("dock_pinned_apps"):get() or {}
		local running_apps = State.get("dock_running_apps"):get() or {}

		local children = self:get_children()
		if children then
			for _, child in ipairs(children) do
				self:remove(child)
				child:destroy()
			end
		end

		local icon_box = Widget.Box({
			spacing = 8,
			homogeneous = false,
			halign = "CENTER",
			hexpand = true,
		})

		for _, desktop_entry in ipairs(pinned_apps) do
			local app = available_apps[desktop_entry]
			if app then
				icon_box:add(DockIcon({
					icon = app.icon_name,
					is_running = running_apps[desktop_entry] or false,
					desktop_entry = desktop_entry,
					on_clicked = function()
						if app.launch then
							app:launch()
						end
					end,
				}))
			end
		end

		for entry, app in pairs(available_apps) do
			if running_apps[entry] and not dock_config.is_pinned(entry) then
				icon_box:add(DockIcon({
					icon = app.icon_name,
					is_running = true,
					desktop_entry = entry,
					on_clicked = function()
						if app.launch then
							app:launch()
						end
					end,
				}))
			end
		end

		self:add(icon_box)
	end, 250)

	return Widget.Box({
		class_name = "dock-container",
		spacing = 8,
		homogeneous = false,
		halign = "CENTER",
		hexpand = true,
		width_request = 50,
		setup = function(self)
			visibility_subscription = State.subscribe("dock_visible", function(value)
				is_visible = value
				if value then
					update_apps_state()
				end
			end)

			subscription_apps = State.subscribe("dock_available_apps", function()
				render_icons(self)
			end)

			subscription_running = State.subscribe("dock_running_apps", function()
				render_icons(self)
			end)

			subscription_pinned = State.subscribe("dock_pinned_apps", function()
				render_icons(self)
			end)

			self:hook(self, "destroy", cleanup_container)

			render_icons(self)
		end,
	})
end

local function create_revealer(content)
	if not content then
		Debug.error("Dock", "Attempting to create revealer with nil content")
		return nil
	end

	return Widget.Revealer({
		transition_type = "SLIDE_UP",
		transition_duration = 200,
		reveal_child = true,
		content,
	})
end

return function(gdkmonitor)
	if not gdkmonitor then
		Debug.error("Dock", "Failed to initialize: gdkmonitor is nil")
		return nil
	end

	local Anchor = astal.require("Astal").WindowAnchor
	State.create("dock_enabled", true)
	State.create("dock_visible", true)

	local hide_timeout
	local revealer
	local dock_window
	local detector_window
	local subscription
	local is_cleaned_up = false

	local cleanup = utils.safe_cleanup(function()
		if is_cleaned_up then
			return
		end
		is_cleaned_up = true

		if hide_timeout and tonumber(hide_timeout) > 0 then
			GLib.source_remove(hide_timeout)
			hide_timeout = nil
		end

		if subscription then
			subscription:unsubscribe()
			subscription = nil
		end

		State.cleanup("dock_visible")
		dock_config.cleanup()

		if detector_window then
			detector_window:destroy()
			detector_window = nil
		end

		if revealer then
			revealer = nil
		end
	end)

	local show_dock = utils.throttle(function()
		if is_cleaned_up then
			return
		end

		if hide_timeout and tonumber(hide_timeout) > 0 then
			GLib.source_remove(hide_timeout)
			hide_timeout = nil
		end

		State.set("dock_visible", true)
	end, 250)

	local hide_dock = utils.throttle(function()
		if is_cleaned_up then
			return
		end
		State.set("dock_visible", false)
	end, 250)

	local schedule_hide = function(delay)
		if is_cleaned_up then
			return
		end

		if hide_timeout and tonumber(hide_timeout) > 0 then
			GLib.source_remove(hide_timeout)
			hide_timeout = nil
		end

		hide_timeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delay or 500, function()
			hide_dock()
			hide_timeout = nil
			return GLib.SOURCE_REMOVE
		end)
	end

	local dock_container = DockContainer()

	dock_window = Widget.Window({
		class_name = "Dock",
		gdkmonitor = gdkmonitor,
		anchor = Anchor.BOTTOM + Anchor.LEFT + Anchor.RIGHT,
		setup = function(self)
			subscription = State.subscribe("dock_visible", function(value)
				if revealer then
					revealer.reveal_child = value
				end

				if self and not is_cleaned_up then
					if value then
						self:get_style_context():add_class("revealed")
					else
						self:get_style_context():remove_class("revealed")
					end
				end
			end)

			self:hook(self, "destroy", cleanup)
		end,
		Widget.EventBox({
			on_hover_lost = function()
				schedule_hide(500)
			end,
			on_hover = show_dock,
			Widget.Box({
				class_name = "dock-wrapper",
				halign = "CENTER",
				hexpand = false,
				setup = function(self)
					if dock_container then
						revealer = create_revealer(dock_container)
						if revealer then
							self:add(revealer)
						end
					end
				end,
			}),
		}),
	})

	detector_window = Widget.Window({
		class_name = "DockDetector",
		gdkmonitor = gdkmonitor,
		anchor = Anchor.BOTTOM + Anchor.LEFT + Anchor.RIGHT,
		Widget.EventBox({
			height_request = 1,
			on_hover = show_dock,
		}),
	})

	detector_window:show_all()
	schedule_hide(1500)

	return dock_window
end

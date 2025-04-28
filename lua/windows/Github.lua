local astal = require("astal")
local Widget = require("astal.gtk3.widget")
local bind = astal.bind
local Variable = astal.Variable
local GLib = astal.require("GLib")
local map = require("lua.lib.common").map
local Github = require("lua.lib.github")
local Debug = require("lua.lib.debug")

local function format_event_type(type)
	return type:gsub("Event", ""):lower()
end

local function format_repo_name(repo)
	return repo.name or ""
end

local function AvatarImage(url)
	return Widget.Box({
		class_name = "avatar-image",
		css = string.format(
			[[
            background-image: url('%s');
            background-size: cover;
            border-radius: 8px;
        ]],
			url
		),
		width_request = 40,
		height_request = 40,
	})
end

local function LoadingIndicator()
	return Widget.Box({
		class_name = "loading-indicator",
		valign = "CENTER",
		halign = "CENTER",
		vexpand = true,
		Widget.Label({ label = "Loading GitHub events..." }),
	})
end

local function ErrorIndicator()
	return Widget.Box({
		class_name = "error-indicator",
		valign = "CENTER",
		halign = "CENTER",
		vexpand = true,
		Widget.Label({ label = "Failed to fetch events" }),
	})
end

local function EventItem(props, close_window)
	return Widget.Button({
		class_name = "github-event-item",
		on_clicked = function()
			close_window()
			GLib.spawn_command_line_async("xdg-open " .. props.url)
		end,
		child = Widget.Box({
			orientation = "HORIZONTAL",
			spacing = 10,
			AvatarImage(props.avatar_url),
			Widget.Box({
				orientation = "VERTICAL",
				spacing = 4,
				hexpand = true,
				Widget.Box({
					orientation = "HORIZONTAL",
					spacing = 5,
					Widget.Label({
						class_name = "actor-name",
						label = props.actor,
						xalign = 0,
					}),
					Widget.Label({
						class_name = "event-type",
						label = props.type,
						xalign = 0,
					}),
					Widget.Label({
						class_name = "repo-name",
						label = props.repo,
						xalign = 0,
						hexpand = true,
					}),
				}),
				Widget.Label({
					class_name = "event-time",
					label = props.time,
					xalign = 0,
				}),
			}),
		}),
	})
end

local function process_events(github_events)
	if not github_events then
		Debug.warn("GitHub", "Failed to process events: empty data")
		return { error = true }
	end
	if #github_events == 0 then
		Debug.debug("GitHub", "No events received from API")
		return { empty = true }
	end

	local result = {}
	for i, event in ipairs(github_events) do
		if event.actor and event.repo then
			result[i] = {
				type = format_event_type(event.type),
				actor = event.actor.login,
				repo = format_repo_name(event.repo),
				time = Github.format_time(event.created_at),
				avatar_url = event.actor.avatar_url,
				url = "https://github.com/" .. event.repo.name,
			}
		end
	end

	if #result == 0 then
		return { empty = true }
	end
	return result
end

local GithubWindow = {}

function GithubWindow.new(gdkmonitor)
	local Anchor = astal.require("Astal").WindowAnchor
	local cleanup_refs = {}
	local is_destroyed = false
	local window
	local first_map = true

	local cached_events, cached_timestamp = Github.get_events()
	local has_valid_cache = cached_events and #cached_events > 0

	local function close_window()
		if window and not is_destroyed then
			window:hide()
		end
	end

	local processed_data
	if has_valid_cache then
		processed_data = process_events(cached_events)
	else
		processed_data = { loading = true }
	end

	cleanup_refs.events_var = Variable.new(processed_data)
	cleanup_refs.last_update_var =
		Variable.new(cached_timestamp > 0 and Github.format_last_update(cached_timestamp) or "")
	cleanup_refs.is_loading_var = Variable.new(false)
	cleanup_refs.update_label_visible = Variable.new(cached_timestamp > 0)

	local function start_update_timer()
		if cleanup_refs.update_timer_id then
			GLib.source_remove(cleanup_refs.update_timer_id)
		end

		cleanup_refs.update_timer_id = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 60, function()
			if is_destroyed then
				return false
			end
			local timestamp = Github.get_last_update_time()
			if timestamp and timestamp > 0 and cleanup_refs.update_label_visible:get() then
				cleanup_refs.last_update_var:set(Github.format_last_update(timestamp))
			end
			return true
		end)
	end

	local function refresh_data_async()
		if is_destroyed or cleanup_refs.is_loading_var:get() then
			return
		end

		cleanup_refs.is_loading_var:set(true)
		cleanup_refs.last_update_var:set("Updating...")

		GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, function()
			if is_destroyed then
				return false
			end

			local fresh_events, update_timestamp = Github.update_events()
			local success, new_processed_data = pcall(process_events, fresh_events)

			if success and new_processed_data and not new_processed_data.empty and not new_processed_data.error then
				cleanup_refs.events_var:set(new_processed_data)
			end

			cleanup_refs.last_update_var:set(Github.format_last_update(update_timestamp))
			cleanup_refs.update_label_visible:set(true)
			cleanup_refs.is_loading_var:set(false)
			return false
		end)
	end

	if has_valid_cache then
		start_update_timer()
	end

	window = Widget.Window({
		class_name = "GithubWindow",
		gdkmonitor = gdkmonitor,
		anchor = Anchor.TOP + Anchor.RIGHT,
		width_request = 420,
		height_request = 400,
		child = Widget.Box({
			orientation = "VERTICAL",
			spacing = 8,
			Widget.Box({
				class_name = "header",
				orientation = "HORIZONTAL",
				spacing = 10,
				Widget.Icon({
					icon = os.getenv("PWD") .. "/icons/github-symbolic.svg",
				}),
				Widget.Label({
					label = "GitHub Activity",
					xalign = 0,
					hexpand = true,
				}),
			}),
			Widget.Box({
				class_name = "update-bar",
				orientation = "HORIZONTAL",
				spacing = 8,
				visible = bind(cleanup_refs.update_label_visible),
				Widget.Label({
					label = bind(cleanup_refs.last_update_var),
					xalign = 0,
					hexpand = true,
				}),
				Widget.Button({
					class_name = "refresh-button",
					child = Widget.Icon({
						icon = "view-refresh-symbolic",
					}),
					on_clicked = function()
						if not cleanup_refs.is_loading_var:get() then
							refresh_data_async()
						end
					end,
				}),
			}),
			Widget.Box({
				vexpand = true,
				hexpand = true,
				class_name = "github-feed-container",
				child = bind(cleanup_refs.events_var):as(function(evt)
					if evt.error then
						return ErrorIndicator()
					end
					if evt.empty or #evt == 0 or evt.loading then
						return LoadingIndicator()
					end
					return Widget.Scrollable({
						vscrollbar_policy = "AUTOMATIC",
						hscrollbar_policy = "NEVER",
						class_name = "github-feed",
						child = Widget.Box({
							orientation = "VERTICAL",
							spacing = 8,
							map(evt, function(event)
								return EventItem(event, close_window)
							end),
						}),
					})
				end),
			}),
		}),
		setup = function(self)
			self:hook(self, "destroy", function()
				if is_destroyed then
					return
				end
				is_destroyed = true

				if cleanup_refs.update_timer_id then
					GLib.source_remove(cleanup_refs.update_timer_id)
				end

				for _, ref in pairs(cleanup_refs) do
					if type(ref) == "table" and ref.drop then
						ref:drop()
					end
				end

				cleanup_refs = nil
				collectgarbage("collect")
			end)

			self:hook(self, "map", function()
				if first_map then
					first_map = false
					if not has_valid_cache then
						refresh_data_async()
					else
						GLib.idle_add(GLib.PRIORITY_LOW, function()
							if not is_destroyed and not cleanup_refs.is_loading_var:get() then
								refresh_data_async()
							end
							return false
						end)
					end
					Github.mark_viewed()
				end
			end)
		end,
	})

	return window
end

return GithubWindow

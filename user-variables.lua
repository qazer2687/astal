return {
	dock = {
		pinned_apps = {
			"nautilus",
			"ghostty",
			"zen",
			"telegram",
			"obs",
			"zed",
			"resources",
		},
	},
	github = {
		username = "linuxmobile",
	},
	monitor = {
		mode = "specific", -- Can be "primary", "all", or "specific"
		specific_monitor = 1,
	},
	profile = {
		picture = os.getenv("HOME") .. "/Downloads/fastfetch/greenish/fastfech.png",
	},
	media = {
		preferred_players = {
			"zen",
			"firefox",
		},
	},
	display = {
		night_light_temp_initial = 3500,
	},
}

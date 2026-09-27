--[[
	EnvironmentCommands  --  Kohl's Admin addon (new loader)
	-----------------------------------------------------------------
	PLACEMENT: Kohl's Admin > Config > Addons   (as a ModuleScript)

	Adds:
	  ;freezetime      pause the day/night cycle
	  ;unfreezetime    resume it           (the "un" prefix triggers undo)
	  ;daylength <n>   set day length in real minutes  (06:00 -> 18:00)
	  ;nightlength <n> set night length in real minutes (18:00 -> 06:00)
	  ;season <Summer|Winter>
	                   Summer = rain and thunderstorms.  Winter = snow and
	                   blizzards. Takes effect on the NEXT storm, so it doesn't
	                   snap the weather mid-storm. To force it through now:
	                   ;weather clear  then  ;weather auto
	  ;weather <Storm|Overcast|Snow|Blizzard|Clear|Auto>
	                   Anything but Auto = force + HOLD that weather (overrides
	                   the automatic cycle, and ignores the season -- asking for
	                   snow in July works).
	                   Auto        = release override, back to automatic
	  ;time <hour>     jump the clock (0-24, e.g. 23 or 6.5). Keeps running
	                   unless time is frozen.
	  ;aurora <Quiet|Active|Storm|Off|Auto|Reroll>
	                   Quiet/Active/Storm = force that kind of aurora, on all
	                   night (still only visible in the dark and clear skies).
	                   Off    = no aurora until ;aurora auto
	                   Auto   = back to a random aurora each night
	                   Reroll = a new random sky, same mode
	  ;aurorasurge [power] [seconds]
	                   flare the aurora up right now (power ~0.3 calm .. 1.5
	                   wild, default random; seconds default random)
	  ;aurorasurges <On|Off>
	                   automatic surges on or off (manual ;aurorasurge still works)

	Talks to the environment scripts only through:
	  - Lighting attributes: FreezeTime, DayMinutes, NightMinutes, Season,
	    AuroraAutoSurges, and Lighting.ClockTime
	  - ServerStorage.WeatherControl BindableEvent  (WeatherServer listens)
	  - ServerStorage.AuroraControl BindableEvent   (AuroraServer listens)
	No direct dependencies, so nothing breaks if a script is missing.
]]

return function(_K)
	local Lighting = game:GetService("Lighting")
	local Registry = _K.Registry

	-------------------------------------------------------------------
	-- FREEZE / UNFREEZE TIME
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "freezetime",
		aliases = { "timefreeze" },
		description = "Pause the day/night cycle.",
		group = "Environment",
		run = function(context)
			Lighting:SetAttribute("FreezeTime", true)
			_K.log("Day/night cycle FROZEN", "INFO")
		end,
	})

	Registry.registerCommand(_K, {
		name = "unfreezetime",
		aliases = { "timeunfreeze", "resumetime" },
		description = "Resume the day/night cycle.",
		group = "Environment",
		run = function(context)
			Lighting:SetAttribute("FreezeTime", false)
			_K.log("Day/night cycle RESUMED", "INFO")
		end,
	})

	-------------------------------------------------------------------
	-- DAY LENGTH
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "daylength",
		aliases = { "setdaylength" },
		description = "Set day length in real minutes (06:00 -> 18:00).",
		group = "Environment",
		args = {
			{ type = "number", name = "Minutes", description = "Real minutes for a full day." },
		},
		run = function(context, minutes: number)
			minutes = math.max(0.1, minutes)
			Lighting:SetAttribute("DayMinutes", minutes)
			_K.log(("Day length set to %.2f minutes"):format(minutes), "INFO")
		end,
	})

	-------------------------------------------------------------------
	-- NIGHT LENGTH
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "nightlength",
		aliases = { "setnightlength" },
		description = "Set night length in real minutes (18:00 -> 06:00).",
		group = "Environment",
		args = {
			{ type = "number", name = "Minutes", description = "Real minutes for a full night." },
		},
		run = function(context, minutes: number)
			minutes = math.max(0.1, minutes)
			Lighting:SetAttribute("NightMinutes", minutes)
			_K.log(("Night length set to %.2f minutes"):format(minutes), "INFO")
		end,
	})

	-------------------------------------------------------------------
	-- SEASON
	--   Decides which precipitation automatic storms use. WeatherServer reads it
	--   when a storm FORMS, so this never snaps the weather mid-storm.
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "season",
		aliases = { "setseason" },
		description = "Set the season (Summer = rain/thunder, Winter = snow/blizzard).",
		group = "Environment",
		args = {
			{ type = "Summer,Winter", name = "Season", description = "Summer or Winter." },
		},
		run = function(context, season: string)
			local normalized = season:sub(1, 1):upper() .. season:sub(2):lower()
			Lighting:SetAttribute("Season", normalized)
			_K.log(("Season set to %s (applies to the next storm)"):format(normalized), "INFO")
		end,
	})

	-------------------------------------------------------------------
	-- WEATHER OVERRIDE
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "weather",
		aliases = { "setweather" },
		description = "Force weather (Storm/Overcast/Snow/Blizzard/Clear and hold), or Auto to resume automatic.",
		group = "Environment",
		args = {
			{
				type = "Storm,Overcast,Snow,Blizzard,Clear,Auto",
				name = "Mode",
				description = "Storm (lightning), Overcast (no lightning), Snow, Blizzard, Clear, or Auto.",
			},
		},
		run = function(context, mode: string)
			local ServerStorage = game:GetService("ServerStorage")
			local control = ServerStorage:FindFirstChild("WeatherControl")
			if not control then
				_K.log("WeatherControl not found - is WeatherServer running?", "WARN")
				return
			end
			control:Fire(string.lower(mode))
			_K.log(("Weather set to %s"):format(mode), "INFO")
		end,
	})
	-------------------------------------------------------------------
	-- TIME
	-------------------------------------------------------------------
	Registry.registerCommand(_K, {
		name = "time",
		aliases = { "settime", "clocktime" },
		description = "Jump the clock to an hour (0-24, e.g. 23 or 6.5).",
		group = "Environment",
		args = {
			{ type = "number", name = "Hour", description = "0-24. 12 = noon, 0 = midnight." },
		},
		run = function(context, hour: number)
			hour = hour % 24
			Lighting.ClockTime = hour
			_K.log(("Clock set to %02d:%02d"):format(math.floor(hour), math.floor(hour % 1 * 60)), "INFO")
		end,
	})

	-------------------------------------------------------------------
	-- AURORA
	--   AuroraServer makes ServerStorage.AuroraControl; everything goes
	--   through that.
	-------------------------------------------------------------------
	local function auroraControl()
		local control = game:GetService("ServerStorage"):FindFirstChild("AuroraControl")
		if not control then
			_K.log("AuroraControl not found - is AuroraServer running?", "WARN")
		end
		return control
	end

	Registry.registerCommand(_K, {
		name = "aurora",
		aliases = { "setaurora", "northernlights" },
		description = "Force the aurora (Quiet/Active/Storm), turn it Off, go back to Auto, or Reroll a new sky.",
		group = "Environment",
		args = {
			{
				type = "Quiet,Active,Storm,Off,Auto,Reroll",
				name = "Mode",
				description = "Quiet, Active, Storm, Off, Auto (random each night), or Reroll (new sky, same mode).",
			},
		},
		run = function(context, mode: string)
			local control = auroraControl()
			if not control then return end
			control:Fire(string.lower(mode))
			_K.log(("Aurora set to %s"):format(mode), "INFO")
		end,
	})

	Registry.registerCommand(_K, {
		name = "aurorasurge",
		aliases = { "surge", "substorm" },
		description = "Make the aurora flare up right now.",
		group = "Environment",
		args = {
			{ type = "number", name = "Power", description = "About 0.3 (calm) to 1.5 (wild). Random if left out.", optional = true },
			{ type = "number", name = "Seconds", description = "How long it lasts. Random if left out.", optional = true },
		},
		run = function(context, power: number?, seconds: number?)
			local control = auroraControl()
			if not control then return end
			if power then power = math.clamp(power, 0, 3) end
			if seconds then seconds = math.max(2, seconds) end
			control:Fire("surge", power, seconds)
			_K.log("Aurora surge triggered", "INFO")
		end,
	})

	Registry.registerCommand(_K, {
		name = "aurorasurges",
		aliases = { "autosurges" },
		description = "Turn the aurora's automatic surges On or Off.",
		group = "Environment",
		args = {
			{ type = "On,Off", name = "State", description = "On = random surges during the night. Off = only when triggered." },
		},
		run = function(context, state: string)
			local on = string.lower(state) == "on"
			Lighting:SetAttribute("AuroraAutoSurges", on)
			_K.log(("Automatic aurora surges %s"):format(on and "ON" or "OFF"), "INFO")
		end,
	})
end

--[[
	HeroConfig  (OverkillUI.HeroConfig)
	The playable heroes, in roster order. Each one is a forced R6 model (OverkillUI.Heroes.<Id>,
	built from the crater statues) that your character turns into when you pick it.

	Id        model name under OverkillUI.Heroes (and the saved choice)
	Name      shown big on the select screen
	Title     the epithet under the name
	Blurb     one or two lines about how they fight
	Accent    the hero's colour pair (roster ring, name, select button glow)
	Style     two short tags
	Difficulty 1-3
	Aura      the matching aura in the shop (for the "signature aura" line), optional
	Moves     the moveset panel: Key, Name, Type, Desc. An empty list shows four blank
	          "coming soon" slots.
]]

local rgb = Color3.fromRGB

return {
	Order = { "Goki", "Gojen", "Naroto" },
	Heroes = {
		Goki = {
			Id = "Goki",
			Name = "GOKI",
			Title = "The Limit Breaker",
			Blurb = "A cheerful martial artist who lives for the next big fight - every battle pushes him past his limits.",
			Accent = { rgb(255, 196, 52), rgb(232, 118, 16) },
			Style = { "RUSHDOWN", "BEAMS" },
			Difficulty = 2,
			Aura = "Aura_Radiant",
			Lore = {
				Origin = "The Mountain Dojo",
				Text = "Raised alone in the high mountains, Goki learned to fight before he learned to read. He trains from sunrise to sunset, eats enough for ten, and treats every opponent like a teacher. When the Nexus cracked open he didn't see a disaster - he saw a tournament that never ends.",
				Quote = "You're strong! Let's go again!",
			},
			Moves = {
				{
					Key = "1",
					Name = "Azure Tide Cannon",
					Type = "BEAM",
					Desc = "Plant your feet, draw the energy back to your hip, then thrust it forward in a roaring wave.",
				},
				{
					Key = "2",
					Name = "Genesis Nova",
					Type = "CHARGE",
					Desc = "Rise high into the sky, gather a colossal sphere overhead and hurl it down at your foe.",
				},
				{
					Key = "3",
					Name = "Silver Reflex",
					Type = "EVADE",
					Desc = "Your body moves before thought - slip, lean and duck through a whole flurry untouched.",
				},
				{
					Key = "R",
					Name = "Zenith Onslaught",
					Type = "ULTIMATE",
					Desc = "A cinematic barrage of blinding strikes. Every hit lands, and they feel every one.",
				},
			},
		},
		Gojen = {
			Id = "Gojen",
			Name = "GOJEN",
			Title = "The Untouchable",
			Blurb = "Cool, cocky and impossible to reach - an endless barrier keeps every strike a hair away.",
			Accent = { rgb(96, 190, 255), rgb(84, 70, 232) },
			Style = { "ZONER", "BARRIERS" },
			Difficulty = 3,
			Aura = "Aura_Infinity",
			Lore = {
				Origin = "The Sealed Academy",
				Text = "The most gifted sorcerer of his generation, Gojen reads every movement before it happens. A barrier of endless space wraps around him, so no blow ever quite arrives. He teaches, he teases, and he never takes a fight seriously - right up until someone makes him.",
				Quote = "Relax. You were never going to reach me.",
			},
			Moves = {},
		},
		Naroto = {
			Id = "Naroto",
			Name = "NAROTO",
			Title = "The Fox Shinobi",
			Blurb = "A loud, never-give-up ninja with a fox's fire sealed inside. Never, ever counts himself out.",
			Accent = { rgb(255, 150, 60), rgb(222, 70, 34) },
			Style = { "SWARM", "CLONES" },
			Difficulty = 1,
			Aura = "Aura_Spirit",
			Lore = {
				Origin = "The Village in the Pines",
				Text = "Once ignored by the whole village, Naroto answered with noise, pranks and a promise to become its greatest protector. A fox spirit sealed inside him lends him fire whenever his own runs out. He is reckless, stubborn and loud - and he has never once stayed down.",
				Quote = "I don't quit. That's kind of my whole thing.",
			},
			Moves = {},
		},
	},
}

--!nocheck
-- (tuning aid) how far each strike's hitbox reaches: the largest root-to-root distance at which the
-- limb registers on a body facing the attacker, at the Hit frame and over the whole active window
local Env = require("./sim/env")
local V3, CF = Env.Vector3, Env.CFrame
local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local HD = Env.load("ReplicatedStorage/Combat/HitDetect")
for _, name in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "DashAttack" }) do
	local def = Config.Attacks[name]
	local path = HD.Paths[name]
	local r = HD.Radius(name)
	local acf = CF.lookAt(V3.new(0, 3, 0), V3.new(0, 3, -1))
	local function reach(t0, t1)
		local lo, hi = 0.5, 8
		for _ = 1, 30 do
			local mid = (lo + hi) / 2
			local vcf = CF.lookAt(V3.new(0, 3, -mid), V3.new(0, 3, 0))
			if HD.Sweep(name, acf, vcf, t0, t1, r) then
				lo = mid
			else
				hi = mid
			end
		end
		return lo
	end
	print(("%-10s hit-frame %.2f  window %.2f   (Ideal %.2f, visual touch at hit %.2f)"):format(name, reach(def.Hit - 0.001, def.Hit + 0.001), reach(path.From, path.To), def.Ideal, def.Reach))
end

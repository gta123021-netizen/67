--[[
	fluid_test.lua - the blood on the ground as a liquid (BloodPools) in the mock world: it follows the
	Terrain, collects in a hollow, runs down a slope, trickles down a cliff, seeps through the crack
	between two platforms and pours off a ledge onto the floor below, never stays on water, and soaks
	into grass while it lies on plastic.
	  luaurun tools/tests/fluid_test.lua <repo root>
]]
local ROOT = ARGS[2] or "."
local M = loadchunk(readfile(ROOT .. "/tools/tests/rbxmock.lua"), "rbxmock")()
local RS = game:GetService("ReplicatedStorage")
local combat = M.folder(RS, "Combat")
local function src(name)
	return ROOT .. "/src/ReplicatedStorage__Combat__" .. name .. ".lua"
end
for _, n in ipairs({ "CombatConfig", "CombatVFX", "BloodPools", "CombatBlood" }) do
	M.module(combat, n, src(n))
end
M.folder(combat, "VFX")
local Config = require(combat.CombatConfig)
local Blood = require(combat.CombatBlood)
local Pools = require(combat.BloodPools)
math.randomseed(11)
-- (the camera over whatever is being tested, so nothing is out of view)
local function look(p)
	workspace.CurrentCamera.CFrame = CFrame.lookAt(p + Vector3.new(0, 20, 20), p)
end

local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	else
		print("ok   " .. msg)
	end
end

-- blood poured at (x, z) from a little above, n drops
local function pourAt(x, z, y, n)
	for _ = 1, n do
		Blood.Launch(Vector3.new(x + (math.random() - 0.5) * 0.3, y + 1.5, z + (math.random() - 0.5) * 0.3), Vector3.new(0, -2, 0), 0.12, "Blob")
		M.run(1 / 30)
	end
end
local function cellsIn(fn)
	local out = {}
	for _, c in ipairs(Pools.Debug().Ground) do
		if fn(c) then
			table.insert(out, c)
		end
	end
	return out
end
local function total(list)
	local a = 0
	for _, c in ipairs(list) do
		a += c.Area
	end
	return a
end
local function centroid(list)
	local x, z, a = 0, 0, 0
	for _, c in ipairs(list) do
		x += c.Cu * c.Area
		z += c.Cv * c.Area
		a += c.Area
	end
	return x / math.max(a, 1e-9), z / math.max(a, 1e-9)
end

---------------------------------------------------------------------------
print("-- terrain: a hollow at (-45, 0) fills from blood poured on its side")
look(Vector3.new(-45, 0, 0))
local h0 = M.TerrainH(-42.5, 0)
pourAt(-42.5, 0, h0, 70)
M.run(8)
local hollow = cellsIn(function(c)
	return c.Cu < -38 and c.Cu > -52
end)
local cx = centroid(hollow)
print(string.format("   %d cells, blood centred at x %.2f (poured at -42.5; the hollow's bottom at -45)", #hollow, cx))
check(#hollow > 6, "a pool on the terrain")
check(cx < -43.2, "it ran down into the hollow")
local off = 0
for _, c in ipairs(hollow) do
	off = math.max(off, math.abs(c.Y - M.TerrainH(c.GX, c.GZ)))
end
check(off < 0.05, string.format("every cell lies on the terrain (worst %.3f)", off))
local lowest = math.huge
for _, c in ipairs(hollow) do
	lowest = math.min(lowest, c.Y)
end
print(string.format("   deepest cell's ground %.2f, the hollow's bottom %.2f", lowest, M.TerrainH(-45, 0)))

---------------------------------------------------------------------------
print("-- terrain: blood on the rise (x -57) runs downhill (toward +x)")
look(Vector3.new(-57, 2, 8))
local h1 = M.TerrainH(-57, 8)
pourAt(-57, 8, h1, 45)
M.run(8)
local slope = cellsIn(function(c)
	return c.Cu < -52 and c.Cu > -62 and c.Cv > 4
end)
local sx = centroid(slope)
print(string.format("   %d cells, centred at x %.2f", #slope, sx))
check(#slope > 3 and sx > -56.7, "it ran down the slope")

---------------------------------------------------------------------------
print("-- terrain: a cliff (x < -62) doesn't hold it - it trickles to its foot")
look(Vector3.new(-62, 4, -8))
for _ = 1, 20 do
	Blood.Launch(Vector3.new(-58, 8, -8 + math.random()), Vector3.new(-12, 0, 0), 0.1, "Drop")
	M.run(1 / 20)
end
M.run(4)
local onCliff = cellsIn(function(c)
	return c.Cu < -62.6 and c.Cv < -4
end)
local foot = cellsIn(function(c)
	return c.Cu >= -62.6 and c.Cu < -55 and c.Cv < -4
end)
print(string.format("   cells on the cliff face %d, at its foot %d", #onCliff, #foot))
check(#onCliff == 0, "nothing stays on the cliff face")
check(#foot > 0, "it gathered at the cliff's foot")

---------------------------------------------------------------------------
print("-- the crack between the two platforms (x 39.9 .. 40.1): it seeps through to the floor below")
look(Vector3.new(40, 1, 0))
pourAt(39.4, 0, 2, 60)
M.run(10)
local below = cellsIn(function(c)
	return c.Y < 0.3 and c.Cu > 38.5 and c.Cu < 41.5
end)
local onA = cellsIn(function(c)
	return c.Y > 1.8 and c.Cu < 40
end)
print(string.format("   on the platform %d cells, under the crack %d cells", #onA, #below))
check(#onA > 3, "a pool on the platform")
check(#below > 0, "blood came through the crack onto the floor below")

---------------------------------------------------------------------------
print("-- the platform's open edge (x = 50): it pours off onto the floor below")
look(Vector3.new(50, 1, 3))
pourAt(49.3, 3, 2, 60)
M.run(10)
local under = cellsIn(function(c)
	return c.Y < 0.3 and c.Cu > 49.5 and c.Cu < 53
end)
local over = cellsIn(function(c)
	return c.Y > 1.8 and c.Cu > 50.01
end)
print(string.format("   under the edge %d cells, hanging past it %d", #under, #over))
check(#under > 0, "blood poured off the edge and pooled below")
check(#over == 0, "nothing hangs past the edge")

---------------------------------------------------------------------------
print("-- water: nothing stays on the pond")
look(Vector3.new(-7, 0, 16))
pourAt(-7, 16, 0.2, 25)
M.run(3)
local pond = cellsIn(function(c)
	return c.Cu > -10 and c.Cu < -4 and c.Cv > 12 and c.Cv < 20
end)
check(#pond == 0, "no blood lying on the water")

---------------------------------------------------------------------------
print("-- grass drinks it in, plastic doesn't (two pools poured at the same time)")
local function onGrass(c)
	return c.Cu > -38 and c.Cu < -32 and c.Cv > 6 and c.Cv < 14
end
local function onPlastic(c)
	return c.Y > 1.8 and c.Cu > 42 and c.Cu < 48 and c.Cv < -1
end
for _ = 1, 40 do
	Blood.Launch(Vector3.new(-35, M.TerrainH(-35, 10) + 1.5, 10), Vector3.new(0, -2, 0), 0.12, "Blob")
	Blood.Launch(Vector3.new(45, 3.5, -4), Vector3.new(0, -2, 0), 0.12, "Blob")
	M.run(1 / 30)
end
M.run(3)
local grassAt, plasticAt = total(cellsIn(onGrass)), total(cellsIn(onPlastic))
M.run(12, 1 / 20)
local grassNow, plasticNow = total(cellsIn(onGrass)), total(cellsIn(onPlastic))
print(string.format("   grass %.2f -> %.2f   plastic %.2f -> %.2f", grassAt, grassNow, plasticAt, plasticNow))
check(grassAt > 0 and plasticAt > 0, "both pooled")
check(grassNow < grassAt * 0.8, "the grass drank a good share of it")
check(plasticNow > plasticAt * 0.95, "the plastic kept it")

print("-- it all goes in the end")
M.run(Config.Blood.Pool.Life + 20, 1 / 10)
local st = Pools.Stats()
check(st.Cells == 0 and st.Specks == 0, "all soaked away")
check(M.heartbeatConns() == 0, "nothing left running")
check((M.Warnings or 0) == 0, "no warnings")
print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
if failures > 0 then
	error("fluid test failed")
end

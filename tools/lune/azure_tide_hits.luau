--!nocheck
-- The server's beam hits (ServerScriptService.Combat.AbilityService, Runners.Beam) run in Lune against a
-- small world of boxes: which bodies each tick and the blast hit, and when.
--   lune run tools/lune/azure_tide_hits.luau <place.rbxl> <src dir>
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local process = require("@lune/process")

local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local srcDir = process.args[2]
local Vector3, Enum = roblox.Vector3, roblox.Enum
local RCF = roblox.CFrame
local function lookAt(pos, target, up)
	local look = (target - pos).Unit
	local right = look:Cross(up or Vector3.yAxis)
	if right.Magnitude < 1e-6 then
		right = look:Cross(Vector3.xAxis)
	end
	right = right.Unit
	return RCF.fromMatrix(pos, right, right:Cross(look).Unit, -look)
end
local CFrame = setmetatable({ lookAt = lookAt }, { __index = RCF })

roblox.implementMethod("Instance", "WaitForChild", function(self, name)
	return assert(self:FindFirstChild(name), "missing " .. name)
end)

local simT = 0
local function signal()
	return { Connect = function() return { Disconnect = function() end } end }
end
local fakeGame = setmetatable({}, { __index = function(_, k)
	if k == "GetService" then
		return function(_, name)
			if name == "RunService" then
				return { Heartbeat = signal(), IsStudio = function() return false end }
			elseif name == "Players" then
				return { PlayerRemoving = signal() }
			end
			return game:GetService(name)
		end
	end
	return game[k]
end })
local base = getfenv()
local env = { game = fakeGame, workspace = game:GetService("Workspace"), warn = print }
for k, v in roblox do
	if type(k) == "string" and k:sub(1, 1):match("%u") then
		env[k] = v
	end
end
env.CFrame = CFrame
for _, k in ipairs({ "math", "string", "table", "typeof", "type", "pairs", "ipairs", "select", "tostring", "tonumber", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "next", "error", "assert", "print", "unpack", "utf8", "bit32", "buffer", "coroutine", "debug", "pcall", "xpcall", "os", "task" }) do
	env[k] = base[k]
end
local cache = {}
local function req(mod)
	if cache[mod] then
		return cache[mod]
	end
	local path = mod:GetFullName():gsub("%.", "/")
	local file = srcDir .. "/" .. path:gsub("/", "__"):gsub(" ", "_") .. (if mod.ClassName == "ModuleScript" then ".lua" else ".server.lua")
	local src = if fs.isFile(file) then fs.readFile(file) else mod.Source
	local menv = table.clone(env)
	menv.script = mod
	local r = luau.load(src, { debugName = mod.Name, environment = menv, injectGlobals = false })()
	cache[mod] = r
	return r
end
env.require = req

local RS = game:GetService("ReplicatedStorage")
local AbilityConfig = req(RS.Abilities.AbilityConfig)
local AbilityService = req(game:GetService("ServerScriptService").Combat.AbilityService)
local def = AbilityConfig.Abilities.AzureTideCannon
local T, B = def.Timeline, def.Beam

-- the world: a floor at y = 0 and boxes
local boxes = {}
local function box(minV, maxV)
	table.insert(boxes, { Min = minV, Max = maxV })
end
local function rayBox(o, v, b)
	local tmin, tmax = 0, 1
	for _, ax in ipairs({ "X", "Y", "Z" }) do
		local ov, dv, lo, hi = o[ax], v[ax], b.Min[ax], b.Max[ax]
		if math.abs(dv) < 1e-9 then
			if ov < lo or ov > hi then
				return nil
			end
		else
			local t1, t2 = (lo - ov) / dv, (hi - ov) / dv
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end
local function worldRay(o, v)
	local best, bn = math.huge, nil
	if o.Y >= 0 and o.Y + v.Y < 0 then
		best, bn = o.Y / -v.Y, Vector3.yAxis
	end
	for _, b in ipairs(boxes) do
		local t = rayBox(o, v, b)
		if t and t > 1e-6 and t < best then
			local p = o + v * t
			local n = Vector3.zero
			for _, ax in ipairs({ "X", "Y", "Z" }) do
				if math.abs(p[ax] - b.Min[ax]) < 1e-4 then
					n = Vector3.new(ax == "X" and -1 or 0, ax == "Y" and -1 or 0, ax == "Z" and -1 or 0)
				elseif math.abs(p[ax] - b.Max[ax]) < 1e-4 then
					n = Vector3.new(ax == "X" and 1 or 0, ax == "Y" and 1 or 0, ax == "Z" and 1 or 0)
				end
			end
			best, bn = t, n
		end
	end
	if bn then
		return { Position = o + v * best, Normal = bn, Distance = (v * best).Magnitude }
	end
	return nil
end

local function body(name, at)
	local root = { Position = at, CFrame = CFrame.new(at), AssemblyLinearVelocity = Vector3.zero }
	return { Name = name, Char = { Name = name, Parent = true }, Root = root, Hum = { Health = 100 } }
end
local hitLog
local A = {
	now = function()
		return simT
	end,
	hittable = function()
		return true
	end,
	seenFrame = function(_, v)
		return v.Root.CFrame
	end,
	worldRay = worldRay,
	applyHit = function(_, v, attack, _at, _job)
		table.insert(hitLog, string.format("%.2f %s %s", simT - T.Fire, v.Name, if attack.Class == "BeamBlast" then "BLAST" else "tick"))
	end,
	fought = function() end,
}
local entities = {}
local Service = { Entities = entities, _ability = A, Get = function() end }
AbilityService.Init(Service)
local Runners = AbilityService.Runners

local function run(label, bodies, walls, aim, expect)
	table.clear(boxes)
	for _, w in ipairs(walls or {}) do
		box(w[1], w[2])
	end
	table.clear(entities)
	local caster = body("Caster", Vector3.new(0, 3, 0))
	entities[caster] = caster
	for _, b in ipairs(bodies) do
		local v = body(b[1], b[2])
		entities[v] = v
	end
	hitLog = {}
	local cast = { E = caster, Def = def, Aim = (aim or Vector3.new(0, 0, -1)).Unit, Start = 0, HitSerial = 0, ChainId = 1 }
	simT = 0
	while simT < T.Fire + T.Sustain + 0.05 do
		simT += 1 / 60
		Runners.Beam.Step(cast, simT)
	end
	local counts = {}
	for _, l in ipairs(hitLog) do
		local name, kind = l:match("^[%d%.%-]+ (%S+) (%S+)$")
		counts[name .. " " .. kind] = (counts[name .. " " .. kind] or 0) + 1
	end
	local ok = true
	for k, n in pairs(expect) do
		if (counts[k] or 0) ~= n then
			ok = false
		end
	end
	for k, n in pairs(counts) do
		if expect[k] == nil and n > 0 then
			ok = false
		end
	end
	print((if ok then "PASS " else "FAIL ") .. label)
	if not ok then
		for _, l in ipairs(hitLog) do
			print("   ", l)
		end
	else
		local first = {}
		for _, l in ipairs(hitLog) do
			local t, name = l:match("^([%d%.%-]+) (%S+)")
			if not first[name] then
				first[name] = t
				print(string.format("     %s first hit %ss after the release", name, t))
			end
		end
	end
	return ok
end

local all = true
local function check(...)
	all = run(...) and all
end
-- on the line, mid range: every tick from the first, and the blast (the beam ends on it)
check("body on the line at 30", { { "Near", Vector3.new(0, 3, -30) } }, nil, nil, { ["Near tick"] = 6, ["Near BLAST"] = 1 })
-- on the line, far: the head reaches it after the first tick
check("body on the line at 70 (the head reaches it after the first tick)", { { "Far", Vector3.new(0, 3, -70) } }, nil, nil, { ["Far tick"] = 5, ["Far BLAST"] = 1 })
-- out of range
check("body at 90 (past its end at 80: in the blast only)", { { "Past", Vector3.new(0, 3, -90) } }, nil, nil, { ["Past BLAST"] = 1 })
check("body at 100 (out of range)", { { "Gone", Vector3.new(0, 3, -100) } }, nil, nil, {})
-- a beam fired along the floor is drawn narrower (it is let into the ground by a third of its radius at
-- most): a body at the edge of its full width but outside the narrowed one is not in it
check("low beam: body 4.5 beside it, the beam squeezed by the floor", { { "Low", Vector3.new(4.5, 3, -30) } }, nil, Vector3.new(0, -0.04, -1), {})
-- beside the line: in it once the beam has swollen enough
check("body 4.5 beside the line at 30 (in it as it swells)", { { "Side", Vector3.new(4.5, 3, -30) } }, nil, nil, { ["Side tick"] = 3 })
-- beside the line, a wall between it and the beam
check("body beside the line behind a wall", { { "Hidden", Vector3.new(4.5, 3, -30) } }, { { Vector3.new(2.6, 0, -40), Vector3.new(3.1, 12, -20) } }, nil, {})
-- behind the wall the beam ends on
check("body behind the wall it ends on", { { "Behind", Vector3.new(0, 3, -27) } }, { { Vector3.new(-10, 0, -25.5), Vector3.new(10, 12, -24.5) } }, nil, {})
-- in the blast round its end, off the line, in the open
check("body by the wall it ends on (blast only)", { { "Blasted", Vector3.new(6, 3, -21) } }, { { Vector3.new(-10, 0, -25.5), Vector3.new(10, 12, -24.5) } }, nil, { ["Blasted BLAST"] = 1 })
-- beyond the blast
check("body 14 from its end (outside the blast)", { { "Safe", Vector3.new(14, 3, -21) } }, { { Vector3.new(-10, 0, -25.5), Vector3.new(10, 12, -24.5) } }, nil, {})
print(if all then "ALL PASS" else "SOME FAILED")
if not all then
	process.exit(1)
end

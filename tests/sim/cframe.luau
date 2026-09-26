--!nocheck
-- A small CFrame in plain Luau with Roblox's conventions (LookVector = -Z column), for the headless
-- combat simulation (Lune's own CFrame.lookAt faces +Z, which would mirror every strike).
local roblox = require("@lune/roblox")
local V3 = roblox.Vector3

local CF = {}
CF.__index = function(self, k)
	if k == "Position" or k == "p" then
		return rawget(self, "_p")
	elseif k == "LookVector" then
		return -rawget(self, "_z")
	elseif k == "RightVector" then
		return rawget(self, "_x")
	elseif k == "UpVector" then
		return rawget(self, "_y")
	elseif k == "X" then
		return rawget(self, "_p").X
	elseif k == "Y" then
		return rawget(self, "_p").Y
	elseif k == "Z" then
		return rawget(self, "_p").Z
	end
	return CF[k]
end

local function make(p, x, y, z)
	return setmetatable({ _p = p, _x = x, _y = y, _z = z }, CF)
end

local X, Y, Z = V3.new(1, 0, 0), V3.new(0, 1, 0), V3.new(0, 0, 1)

function CF.new(a, b, c, ...)
	if a == nil then
		return make(V3.zero, X, Y, Z)
	end
	if type(a) == "number" then
		if select("#", ...) >= 9 then
			-- (x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22): the rows of the rotation
			local m = { ... }
			return make(V3.new(a, b, c), V3.new(m[1], m[4], m[7]), V3.new(m[2], m[5], m[8]), V3.new(m[3], m[6], m[9]))
		end
		return make(V3.new(a, b, c), X, Y, Z)
	end
	if b ~= nil then
		return CF.lookAt(a, b)
	end
	return make(a, X, Y, Z)
end

function CF.fromMatrix(p, vx, vy, vz)
	vz = vz or vx:Cross(vy)
	return make(p, vx, vy, vz)
end

function CF.lookAt(at, target, up)
	up = up or Y
	local look = target - at
	if look.Magnitude < 1e-9 then
		return make(at, X, Y, Z)
	end
	look = look.Unit
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then
		right = look:Cross(Z)
	end
	right = right.Unit
	local upv = right:Cross(look).Unit
	return make(at, right, upv, -look)
end

local function rotX(a)
	local c, s = math.cos(a), math.sin(a)
	return make(V3.zero, X, V3.new(0, c, s), V3.new(0, -s, c))
end
local function rotY(a)
	local c, s = math.cos(a), math.sin(a)
	return make(V3.zero, V3.new(c, 0, -s), Y, V3.new(s, 0, c))
end
local function rotZ(a)
	local c, s = math.cos(a), math.sin(a)
	return make(V3.zero, V3.new(c, s, 0), V3.new(-s, c, 0), Z)
end
function CF.Angles(rx, ry, rz)
	return rotX(rx) * rotY(ry) * rotZ(rz)
end

-- a rotation of `angle` radians about the unit `axis` (Rodrigues)
function CF.fromAxisAngle(axis, angle)
	local u = axis.Unit
	local c, s = math.cos(angle), math.sin(angle)
	local function r(v)
		return v * c + u:Cross(v) * s + u * (u:Dot(v) * (1 - c))
	end
	return make(V3.zero, r(X), r(Y), r(Z))
end

local function rot(self, v)
	return self._x * v.X + self._y * v.Y + self._z * v.Z
end
local function rotT(self, v)
	return V3.new(self._x:Dot(v), self._y:Dot(v), self._z:Dot(v))
end

CF.__mul = function(a, b)
	if getmetatable(b) == CF then
		return make(a._p + rot(a, b._p), rot(a, b._x), rot(a, b._y), rot(a, b._z))
	end
	return a._p + rot(a, b)
end
CF.__add = function(a, v)
	return make(a._p + v, a._x, a._y, a._z)
end
CF.__sub = function(a, v)
	return make(a._p - v, a._x, a._y, a._z)
end
CF.__tostring = function(a)
	return string.format("CF(%.2f, %.2f, %.2f | look %.2f %.2f %.2f)", a._p.X, a._p.Y, a._p.Z, -a._z.X, -a._z.Y, -a._z.Z)
end

function CF:Inverse()
	local x, y, z = self._x, self._y, self._z
	local nx = V3.new(x.X, y.X, z.X)
	local ny = V3.new(x.Y, y.Y, z.Y)
	local nz = V3.new(x.Z, y.Z, z.Z)
	local inv = make(V3.zero, nx, ny, nz)
	return make(-rot(inv, self._p), nx, ny, nz)
end
function CF:ToObjectSpace(o)
	return self:Inverse() * o
end
function CF:ToWorldSpace(o)
	return self * o
end
function CF:GetComponents()
	local p, x, y, z = self._p, self._x, self._y, self._z
	return p.X, p.Y, p.Z, x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z
end
function CF:PointToWorldSpace(v)
	return self * v
end
function CF:PointToObjectSpace(v)
	return rotT(self, v - self._p)
end
function CF:VectorToObjectSpace(v)
	return rotT(self, v)
end
function CF:VectorToWorldSpace(v)
	return rot(self, v)
end
function CF:Lerp(o, k)
	local p = self._p:Lerp(o._p, k)
	local zz = self._z:Lerp(o._z, k)
	local yy = self._y:Lerp(o._y, k)
	if zz.Magnitude < 1e-6 then
		return make(p, o._x, o._y, o._z)
	end
	zz = zz.Unit
	local xx = yy:Cross(zz)
	if xx.Magnitude < 1e-6 then
		return make(p, o._x, o._y, o._z)
	end
	xx = xx.Unit
	yy = zz:Cross(xx).Unit
	return make(p, xx, yy, zz)
end

CF.identity = make(V3.zero, X, Y, Z)
CF._is = function(v)
	return getmetatable(v) == CF
end
return CF

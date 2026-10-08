--[[
	AbilityBus  (ReplicatedStorage.Abilities.AbilityBus)
	The local player's abilities, shared between the fight (CombatClient.Abilities: input, the cast,
	its prediction) and the hotbar (OverkillHUD.AbilityBar), so the two never disagree:

	  Bus.Press(slot)            press a slot (the hotbar's click / tap): the fight decides
	  Bus.Casting                the ability id being cast now (nil: none)
	  Bus.Predicted[id]          a cooldown this screen started on its own press, before the server's
	                             word arrives: { Until = server time, Len = seconds }
	  Bus.On(name, fn) / Fire    "Changed" (anything above changed), "Refused" (slot, why),
	                             "Pressed" (slot), "Cast" (slot, id)
	Client-side only.
]]

local Bus = {}

Bus.Casting = nil :: string?
Bus.CastSlot = nil :: string?
Bus.Predicted = {} :: { [string]: { Until: number, Len: number } }

local listeners: { [string]: { (...any) -> () } } = {}
function Bus.On(name: string, fn: (...any) -> ()): () -> ()
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
	return function()
		local list = listeners[name]
		local i = list and table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end
function Bus.Fire(name: string, ...: any)
	for _, fn in ipairs(listeners[name] or {}) do
		task.spawn(fn, ...)
	end
end

-- the fight sets this (CombatClient.Abilities); the hotbar calls it
local pressFn: ((slot: string) -> ())? = nil
function Bus.SetPress(fn: (slot: string) -> ())
	pressFn = fn
end
function Bus.Press(slot: string)
	if pressFn then
		pressFn(slot)
	end
end

return Bus

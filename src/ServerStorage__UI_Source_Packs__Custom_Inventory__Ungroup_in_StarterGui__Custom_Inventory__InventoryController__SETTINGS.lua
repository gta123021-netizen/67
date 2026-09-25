local module = {OBJECTS = {}, SETTINGS = {}, slotAmount = 9}
module.OBJECTS.HotBar = {}
module.OBJECTS.Inventory = {}

-- SETTINGS
local SETTINGS = module.SETTINGS
SETTINGS.DEFAULT_COLOR = Color3.fromRGB(0, 0, 0) -- ToolFrame background color when unequipped
SETTINGS.EQUIPPED_COLOR = Color3.fromRGB(128, 128, 128) -- ToolFrame background color when equipped
SETTINGS.DISABLED_COLOR = Color3.fromRGB(128, 64, 65) -- ToolFrame background color when the tool is disabled
SETTINGS.DEFAULT_IMAGEID = ""
SETTINGS.EQUIPPED_IMAGEID = ""
SETTINGS.DISABLED_IMAGEID = ""
SETTINGS.INVENTORY_KEYBIND = Enum.KeyCode.Backquote -- KeyCode to open the Inventory itself (set to nil to disable the Inventory or Backpack)
SETTINGS.DRAG_OUTSIDE_TO_DROP = false -- If set to true any tool you drag outside of the Inventory or HotBar will be dropped to the floor
SETTINGS.SHOW_EMPTY_TOOL_FRAMES_IN_HOTBAR = false -- If set to true it will display all the tool frames in the HotBar even if they are empty and the Inventory closed
SETTINGS.SCROLL_HOTBAR_WITH_WHEEL = false -- If set to true it will enable you to scroll the HotBar with the mouse wheel
SETTINGS.EQUIP_TOUCH_SENSITIVITY = 60 -- The limit of how much you can drag a tool before it dosent equips/unequips it when you release it
SETTINGS.OPEN_BUTTON = true
SETTINGS.ALWAYS_SHOW_TOOL_NAME = true

































-- services
local ContextActionService = game:GetService("ContextActionService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

--// PLAYER
local player = game:GetService("Players").LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

--// INVENTORY_SYSTEM \\--
local inventoryGui = script.Parent.Parent
local hotbar = inventoryGui.hotBar
local inventoryFrame = inventoryGui.Inventory
local toolButton = script.Parent.toolButton

local EnumKeys = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}
-- tool object methods
local toolObjectMetatable = {}
toolObjectMetatable.__index = toolObjectMetatable

function toolObjectMetatable:isEquipped() -- Checks if the current object.Tool is equipped
	local character = player.Character

	if character then
		return self.Tool.Parent == player.Character
	else
		return false
	end
end

function toolObjectMetatable:DisconnectAll() -- Makes a cleanup of connections and binds as well as deletes object.Frame
	for _, v in pairs(self.CONNECTIONS) do
		v:Disconnect()
	end

	self.didRemoval = true

	if (inventoryFrame.Visible or module.SETTINGS.SHOW_EMPTY_TOOL_FRAMES_IN_HOTBAR) and self.Frame.Parent ~= inventoryGui and self.Frame.Parent ~= inventoryFrame.Frame then
		local toolName = self.Frame:FindFirstChild("toolName")
		local toolAmount = self.Frame:FindFirstChild("toolAmount")
		local toolIcon = self.Frame:FindFirstChild("toolIcon")

		if toolName and toolAmount and toolIcon then
			toolName.Text = ""
			toolAmount.Text = ""
			toolIcon.Image = ""
		end
		self.Frame.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
		self.Frame.Image = SETTINGS.DEFAULT_IMAGEID
	else
		self.Frame:Destroy()
	end

	if self.Parent == "HotBar" and self.Position then
		ContextActionService:UnbindAction(self.Position .. "hotBar")
		module.OBJECTS.HotBar[self.Position] = nil
	elseif self.Parent == "Inventory" then
		module.OBJECTS.Inventory[self.Tool.Name] = nil
	end
	self = nil
end

function toolObjectMetatable:updateIcon() -- Updates the tool Texture
	local tool = self.Tool
	local frame = self.Frame
	local textureId = tool.TextureId

	if textureId == "" or textureId == nil then
		frame.toolName.Visible = true
		frame.toolIcon.Visible = false
		frame.toolIcon.Image = ""
	else
		frame.toolName.Visible = SETTINGS.ALWAYS_SHOW_TOOL_NAME
		frame.toolIcon.Visible = true
		frame.toolIcon.Image = textureId
	end
end

function toolObjectMetatable:getParentInstance()
	return self.Parent == "Inventory" and inventoryFrame.Frame or hotbar
end

function toolObjectMetatable:showDescription() -- Shows the object.Tool.ToolTip
	local toolDescription = self.Tool.ToolTip
	local frame = self.Frame
	if toolDescription == "" then
		return
	end

	local descriptionFrame = Instance.new("TextLabel")
	descriptionFrame.Name = "descriptionFrame"
	descriptionFrame.AnchorPoint = Vector2.new(0.5, 0)
	descriptionFrame.Font = Enum.Font.SourceSansSemibold
	descriptionFrame.TextColor = BrickColor.Black()
	descriptionFrame.TextSize = 14
	descriptionFrame.BorderSizePixel = 0
	descriptionFrame.BackgroundColor = BrickColor.White()
	descriptionFrame.ZIndex = 99
	descriptionFrame.TextWrapped = true
	descriptionFrame.Parent = inventoryGui

	local corner = Instance.new("UICorner")
	corner.Parent = descriptionFrame
	corner.CornerRadius = UDim.new(0.12, 0)

	local textBounds = TextService:GetTextSize(toolDescription, descriptionFrame.TextSize, descriptionFrame.Font, Vector2.new(400, 1000)) + Vector2.new(10, 4)
	descriptionFrame.Size = UDim2.new(0, textBounds.X, 0, textBounds.Y)
	descriptionFrame.Position = UDim2.new(0, frame.AbsolutePosition.X + (frame.AbsoluteSize.X / 2), 0, frame.AbsolutePosition.Y - textBounds.Y - 2 + 57)
	descriptionFrame.Text = toolDescription
	self.DescriptionFrame = descriptionFrame
	game:GetService("Debris"):AddItem(descriptionFrame, 15)
end

function toolObjectMetatable:removeDescription() -- Destroys the object.DescriptionFrame created by object:showDescription()
	if self.DescriptionFrame then
		self.DescriptionFrame:Destroy()
	end
end

function module:removeCurrentDescription() -- Destroys any current active descriptionFrame
	local descriptionFrame = inventoryGui:FindFirstChild("descriptionFrame")
	if descriptionFrame then
		descriptionFrame:Destroy()
	end
end

function module:getObjectFromTool(tool: Tool) -- Returns the ToolObject of a Tool
	local function searchToolObject(toolParent)
		for _, toolObject in pairs(toolParent) do
			if toolObject.Tool == tool then 
				return toolObject 
			end
		end
	end
	
	return searchToolObject(self.OBJECTS.HotBar) or searchToolObject(self.OBJECTS.Inventory)
end

function module:getToolPosition(tool: Tool) -- Returns the tool position on the hotbar (if in inventory retuns nil)
	local toolObject = self:getObjectFromTool(tool)
	return toolObject and toolObject.Position
end

function module:searchTool() -- Handler for the tool search feature in the inventory
	local toolName: string = inventoryFrame.SearchBox.Text
	if toolName == "" then
		for _, toolObject in pairs(self.OBJECTS["Inventory"]) do
			toolObject.Frame.Visible = true
		end
	elseif toolName then
		for _, toolObject in pairs(self.OBJECTS["Inventory"]) do
			toolObject.Frame.Visible = string.find(toolObject.Name:lower(), toolName:lower()) and true or false
		end
	end
end

function module:lockSlots(unequipCurrentTool: boolean) -- Locks the slots so they cant be equipped or unequipped
	self.slotsLocked = true
	
	if unequipCurrentTool then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
		end
	end
end
function module:unlockSlots() -- Unlocks the slots so they can be equipped and unequipped again
	self.slotsLocked = false
end
function module:lockSlotsPosition() -- Locks the slots position so they cant be moved around
	self.slotsPositionLocked = true
end
function module:unlockSlotsPosition() -- Unlocks the slots positions so they can be moved again
	self.slotsPositionLocked = false
end

function module:newTool(tool: Tool)
	if tool:GetAttribute("toolAdded") or not tool:IsA("Tool") then
		return
	end

	local length = 0
	for _, _ in pairs(module.OBJECTS.HotBar) do
		length += 1
	end

	module:addTool(tool, length == self.slotAmount and "Inventory" or "HotBar", tool:GetAttribute("position"))
end

function module:addTool(tool: Tool, parent: string, position: number)
	tool:SetAttribute("position", nil)
	if position == -1 then
		parent = "Inventory"
		position = nil
	end

	if not position and parent == "HotBar" then
		for index = 1, self.slotAmount do
			if self.OBJECTS.HotBar[index] == nil then
				position = index
				break
			end
		end
	end

	if position and hotbar:FindFirstChild(position) then
		hotbar:FindFirstChild(position):Destroy()
	end

	local frame = toolButton:Clone()
	local amount = tool:GetAttribute("amount") or 1
	if amount > 1 then
		frame.toolAmount.Text = "x" .. amount
	end
	frame.toolName.Text = tool.Name
	frame.Parent = parent == "Inventory" and inventoryFrame.Frame or hotbar
	frame.Name = parent == "Inventory" and tool.Name or position
	frame.toolNumber.Text = parent == "Inventory" and "" or position

	local object = {}
	setmetatable(object, toolObjectMetatable)

	object.Tool = tool
	object.Frame = frame
	object.Parent = parent
	object.Position = position
	object.Name = tool.Name
	self.OBJECTS[parent][position == nil and frame.Name or position] = object
	local function manageTool(_, inputState, inputObject)
		if inputObject and inputObject.UserInputType ~= Enum.UserInputType.Keyboard and inputObject.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if
			not humanoid
			or humanoid.Health <= 0
			or not tool.Parent
			or inputState == Enum.UserInputState.End
			or self.slotsLocked
		then
			return
		end

		if object:isEquipped() then -- if tool is equipped then unequip it
			humanoid:UnequipTools()
			frame.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
			frame.Image = SETTINGS.DEFAULT_IMAGEID
			module.currentlyEquipped = nil
		elseif tool.Enabled then -- if tool isnt equipped then equip it
			humanoid:EquipTool(tool)
			if module.currentlyEquipped and module.currentlyEquipped.Parent then
				module.currentlyEquipped.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
				module.currentlyEquipped.Image = SETTINGS.DEFAULT_IMAGEID
			end
			module.currentlyEquipped = frame
			frame.BackgroundColor3 = SETTINGS.EQUIPPED_COLOR
			frame.Image = SETTINGS.EQUIPPED_IMAGEID
		end
	end

	local function updateEquipped()
		if object:isEquipped() and tool.Enabled then
			if module.currentlyEquipped and module.currentlyEquipped.Parent then
				module.currentlyEquipped.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
				module.currentlyEquipped.Image = SETTINGS.DEFAULT_IMAGEID
			end
			module.currentlyEquipped = frame
			frame.BackgroundColor3 = SETTINGS.EQUIPPED_COLOR
			frame.Image = SETTINGS.EQUIPPED_IMAGEID
		else
			frame.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
			frame.Image = SETTINGS.DEFAULT_IMAGEID
			module.currentlyEquipped = nil
		end
	end

	local function updateEnabled()
		if tool.Enabled then
			frame.Image = SETTINGS.DEFAULT_IMAGEID
			frame.BackgroundColor3 = SETTINGS.DEFAULT_COLOR
			frame.ImageTransparency = 0
			frame.toolIcon.ImageTransparency = 0
			frame.toolName.TextTransparency = 0
			frame.toolNumber.TextTransparency = 0
			frame.toolAmount.TextTransparency = 0

			frame.toolAmount.UIStroke.Transparency = 0
			--frame.toolNumber.Transparency = 0
			frame.toolName.UIStroke.Transparency = 0
		else
			frame.Image = SETTINGS.DISABLED_IMAGEID
			frame.BackgroundColor3 = SETTINGS.DISABLED_COLOR
			frame.ImageTransparency = 0.35
			frame.toolIcon.ImageTransparency = 0.5
			frame.toolName.TextTransparency = 0.6
			frame.toolNumber.TextTransparency = 0.6
			frame.toolAmount.TextTransparency = 0.6

			frame.toolAmount.UIStroke.Transparency = 0.6
			--frame.toolNumber.Transparency = 0.6
			frame.toolName.UIStroke.Transparency = 0.6
		end
	end
	updateEnabled()
	updateEquipped()
	object:updateIcon()

	--// CONNECTIONS
	object.CONNECTIONS = {}
	object.CONNECTIONS.EnabledConn = tool:GetPropertyChangedSignal("Enabled"):Connect(updateEnabled)
	object.CONNECTIONS.ToolRemoved = tool.AncestryChanged:Connect(function(_, newParent)
		if player and (newParent == nil or (newParent ~= player.Backpack and newParent ~= player.Character)) then
			object:DisconnectAll()
			tool:SetAttribute("toolAdded", false)
		end
		updateEquipped()
	end)
	object.CONNECTIONS.NameChanged = tool:GetPropertyChangedSignal("Name"):Connect(function()
		frame.toolName.Text = tool.Name
		object.Name = tool.Name
	end)
	object.CONNECTIONS.TextureIdChanged = tool:GetPropertyChangedSignal("TextureId"):Connect(function()
		object:updateIcon()
	end)
	object.CONNECTIONS.AmountChanged = tool:GetAttributeChangedSignal("amount"):Connect(function()
		amount = tool:GetAttribute("amount") or 1
		if amount > 1 then
			frame.toolAmount.Text = "x" .. amount
		else
			frame.toolAmount.Text = ""
		end
	end)
	object.CONNECTIONS.MouseEnter = frame.MouseEnter:Connect(function()
		if object.isGrabbed then
			return
		end
		object:showDescription()
	end)
	object.CONNECTIONS.MouseLeave = frame.MouseLeave:Connect(function()
		object:removeDescription()
	end)
	object.CONNECTIONS.GrabConn = frame.MouseButton1Down:Connect(function()
		if self.slotsPositionLocked then
			return
		end

		local mouseEnd
		local mouseConn
		local newFrame
		local CellSize = inventoryFrame.Frame.Grid.CellSize
		local frameStartPosition = frame.AbsolutePosition
		object:removeDescription()

		local function endGrab()
			mouseEnd:Disconnect()
			mouseConn:Disconnect()
			object.isGrabbed = false

			local droppedGuis = playerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y)
			local wasSwapped = false
			local dropTool = true
			for _, newSlot in pairs(droppedGuis) do
				if newSlot:IsA("ImageButton") and (newSlot.Parent == hotbar or newSlot.Parent == inventoryFrame.Frame) then
					local newSlotObject = self.OBJECTS[newSlot.Parent == hotbar and "HotBar" or "Inventory"][newSlot.Parent == hotbar and tonumber(newSlot.Name) or newSlot.Name]
					if newSlotObject == object then
						dropTool = false
						if newFrame then
							newFrame:Destroy()
						end
						continue
					end

					if newSlotObject then -- Swap between tools
						wasSwapped = true
						
						object:DisconnectAll()
						newSlotObject:DisconnectAll()

						self:addTool(newSlotObject.Tool, parent, position)
						self:addTool(tool, newSlotObject.Parent, newSlotObject.Position)

						if newFrame then
							newFrame:Destroy()
						end
					elseif newSlot.Parent == hotbar then -- Send to Hotbar
						wasSwapped = true
						
						object:DisconnectAll()
						self:addTool(tool, "HotBar", tonumber(newSlot.Name))
						if parent == "Inventory" and newFrame then
							newFrame:Destroy()
						end
						newSlot:Destroy()
					end

					if newSlotObject then
						newSlotObject:removeDescription()
					end
					if object then
						object:removeDescription()
					end
				elseif newSlot:IsA("ImageLabel") and newSlot == inventoryFrame and not wasSwapped and parent == "HotBar" then -- Send to Inventory
					wasSwapped = true
					object:DisconnectAll()
					self:addTool(tool, "Inventory")
					self:searchTool()
					break
				end
			end
			
			if not wasSwapped then
				if newFrame then
					newFrame:Destroy()
				end
				frame.Parent = object:getParentInstance()
				
				if SETTINGS.DRAG_OUTSIDE_TO_DROP and dropTool and tool.CanBeDropped then
					local character = player.Character
					if character then
						tool.Parent = character
						RunService.RenderStepped:Wait()
						tool.Parent = workspace
					end
				end
				
				if (frameStartPosition - Vector2.new(mouse.X, mouse.Y)).Magnitude <= SETTINGS.EQUIP_TOUCH_SENSITIVITY then
					manageTool()
				end
			end
		end
		mouseEnd = UserInputService.InputEnded:Connect(function(inputObject)
			if
				inputObject.UserInputType == Enum.UserInputType.MouseButton1
				or inputObject.UserInputType == Enum.UserInputType.Touch
			then
				endGrab()
			end
		end)

		local function updateFramePos()
			if not object.isGrabbed then
				object.isGrabbed = true
				newFrame = toolButton:Clone()
				newFrame.toolName.Text = ""
				newFrame.toolAmount.Text = ""
				newFrame.toolNumber.Text = position or ""
				newFrame.Name = frame.Name
				newFrame.Size = frame.Size
				newFrame.Parent = object:getParentInstance()

				frame.Size = CellSize
				frame.Parent = inventoryGui
			end

			local mousePos = Vector2.new(mouse.X, mouse.Y)
			frame.Position = UDim2.new(0, mousePos.X - (CellSize.X.Offset / 2), 0, mousePos.Y - (CellSize.Y.Offset / 2) + 57)
		end
		mouseConn = mouse.Move:Connect(updateFramePos)
	end)

	tool:SetAttribute("toolAdded", true)
	if parent == "HotBar" and position then
		ContextActionService:BindAction(position .. "hotBar", manageTool, false, EnumKeys[position])
	end
end

return module

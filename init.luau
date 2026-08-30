--  ____                      _
-- |  _ \ _ __ ___  _ __   __| | _____      ___ __
-- | | | | '__/ _ \| '_ \ / _` |/ _ \ \ /\ / / '_ \
-- | |_| | | | (_) | |_) | (_| | (_) \ V  V /| | | |
-- |____/|_|  \___/| .__/ \__,_|\___/ \_/\_/ |_| |_|
--                 |_|

-- made with ❤️ by biotoxin495

-- Dropdown
-- Dependency-free dropdown UI controller for Roblox.
--
-- Turns any GuiButton into a managed dropdown: option rendering, selection state,
-- positioning, outside-click detection, and cleanup are all handled for you. It can
-- generate its own dropdown interface automatically, or control a fully custom
-- Studio-authored dropdown and entry templates.
--
-- Place this ModuleScript somewhere client code can require it, such as ReplicatedStorage.
--
-- Usage:
--   local Dropdown = require(ReplicatedStorage:WaitForChild("Dropdown"))
--
--   local dropdown = Dropdown.new(triggerButton, {
--     Options = {
--       { Id = "rarity", Text = "Rarity" },
--       { Id = "newest", Text = "Newest" },
--     },
--   })
--
--   dropdown.Selected:Connect(function(option)
--     print("Selected:", option.Id)
--   end)
--
--   dropdown:Destroy() -- disconnects everything and cleans up module-owned UI
--
-- Main features:
--   * Generated dropdown UI, or custom dropdown instances/templates
--   * Custom entry templates, entry creation, and entry renderers
--   * Single, multiple, and action-only ("None") selection modes
--   * Dynamic options (SetOptions/AddOption/RemoveOption/ClearOptions)
--   * Automatic placement, edge-flip, and screen clamping
--   * Automatic sizing and scrolling for generated dropdowns
--   * Outside-click / Escape closing, with exclusive (one-at-a-time) dropdown behavior
--   * Optional trigger text synchronization (UpdateTriggerText / RenderTrigger)
--   * Overlay rendering under the trigger's ScreenGui to avoid ClipsDescendants clipping
--   * Instant open/close visibility with simple entry hover/press feedback
--   * Signals: Opened, Closed, Selected, SelectionChanged
--   * Complete per-controller cleanup via Destroy()
--
-- Scope: this module owns behavior and state; visual presentation is either generated
-- automatically or supplied by the caller through templates/renderers.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Dropdown = {}
Dropdown.__index = Dropdown

local activeExclusiveDropdown = nil

----------------------------------------------------------------
-- Signal
----------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
	local self = setmetatable({}, Signal)
	self._event = Instance.new("BindableEvent")
	self._destroyed = false
	return self
end

function Signal:Connect(callback)
	assert(not self._destroyed, "Cannot connect to a destroyed Signal")
	return self._event.Event:Connect(callback)
end

function Signal:Once(callback)
	assert(not self._destroyed, "Cannot connect to a destroyed Signal")
	local connection
	connection = self._event.Event:Connect(function(...)
		if connection then
			connection:Disconnect()
		end
		callback(...)
	end)
	return connection
end

function Signal:Fire(...)
	if self._destroyed then
		return
	end
	self._event:Fire(...)
end

function Signal:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._event:Destroy()
end

----------------------------------------------------------------
-- Defaults / utilities
----------------------------------------------------------------

local DEFAULTS = {
	Options = {},

	SelectionMode = "Single", -- "Single", "Multiple", "None"
	Selected = nil,

	Enabled = true,
	ToggleOnTrigger = true,
	CloseOnSelect = nil, -- nil = true for Single/None, false for Multiple
	CloseOnOutsideClick = true,
	CloseOnEscape = true,
	Exclusive = true,

	Placement = "Auto", -- "Auto", "Bottom", "Top", "Left", "Right"
	Alignment = "Start", -- "Start", "Center", "End"
	Offset = Vector2.new(0, 6),
	ScreenPadding = 8,
	AutoFlip = true,
	ClampToScreen = true,

	Width = nil, -- nil = at least trigger width
	MinWidth = 160,
	MaxHeight = 280,
	EntryHeight = 38,
	EntryPadding = 4,
	ContentPadding = 6,

	ZIndex = 100,

	UpdateTriggerText = false,

	Interaction = {
		Enabled = true,
		Duration = 0.08,
		HoverBrightness = 0.08,
		PressedBrightness = 0.12,
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.Out,
	},

	Style = {
		Container = {
			BackgroundColor3 = Color3.fromRGB(25, 27, 32),
			BackgroundTransparency = 0,
		},
		Entry = {
			BackgroundColor3 = Color3.fromRGB(38, 41, 48),
			BackgroundTransparency = 0,
			TextColor3 = Color3.fromRGB(235, 238, 245),
			TextTransparency = 0,
			Font = Enum.Font.Gotham,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutoButtonColor = false,
		},
		EntrySelected = {
			BackgroundColor3 = Color3.fromRGB(57, 102, 220),
			TextColor3 = Color3.fromRGB(255, 255, 255),
		},
		EntryDisabled = {
			BackgroundTransparency = 0.35,
			TextTransparency = 0.45,
		},
	},
}

local function shallowCopy(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function deepMerge(base, overrides)
	local result = {}
	for key, value in pairs(base) do
		if type(value) == "table" then
			result[key] = deepMerge(value, {})
		else
			result[key] = value
		end
	end

	if overrides then
		for key, value in pairs(overrides) do
			if type(value) == "table" and type(result[key]) == "table" then
				result[key] = deepMerge(result[key], value)
			else
				result[key] = value
			end
		end
	end

	return result
end

local function applyProperties(instance, properties)
	if not properties then
		return
	end

	for property, value in pairs(properties) do
		local ok, err = pcall(function()
			instance[property] = value
		end)

		if not ok then
			warn(
				string.format(
					"[Dropdown] Could not apply property %s to %s: %s",
					tostring(property),
					instance:GetFullName(),
					tostring(err)
				)
			)
		end
	end
end

local function findFirstDescendantOfClass(root, className)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

local function normalizeOption(option, index)
	if type(option) ~= "table" then
		return {
			Id = index,
			Text = tostring(option),
			Value = option,
			Disabled = false,
			_original = option,
		}
	end

	local normalized = shallowCopy(option)

	if normalized.Id == nil then
		normalized.Id = index
	end

	if normalized.Text == nil then
		if normalized.Name ~= nil then
			normalized.Text = tostring(normalized.Name)
		elseif normalized.Value ~= nil then
			normalized.Text = tostring(normalized.Value)
		else
			normalized.Text = tostring(normalized.Id)
		end
	end

	if normalized.Value == nil then
		normalized.Value = normalized.Id
	end

	normalized.Disabled = normalized.Disabled == true
	normalized._original = option

	return normalized
end

local function getScreenGui(instance)
	local current = instance
	while current do
		if current:IsA("ScreenGui") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function pointInside(guiObject, point)
	if not guiObject or not guiObject:IsA("GuiObject") or not guiObject.Visible then
		return false
	end

	local position = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize

	return point.X >= position.X
		and point.X <= position.X + size.X
		and point.Y >= position.Y
		and point.Y <= position.Y + size.Y
end

local function isPointerInput(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

----------------------------------------------------------------
-- Construction
----------------------------------------------------------------

function Dropdown.new(trigger, config)
	assert(typeof(trigger) == "Instance" and trigger:IsA("GuiButton"), "Dropdown.new requires a GuiButton trigger")

	local self = setmetatable({}, Dropdown)

	self.Trigger = trigger
	self.Config = deepMerge(DEFAULTS, config or {})
	self._initialTriggerText = trigger:IsA("TextButton") and trigger.Text or nil

	assert(
		self.Config.SelectionMode == "Single"
			or self.Config.SelectionMode == "Multiple"
			or self.Config.SelectionMode == "None",
		"SelectionMode must be 'Single', 'Multiple', or 'None'"
	)

	self.Opened = Signal.new()
	self.Closed = Signal.new()
	self.Selected = Signal.new()
	self.SelectionChanged = Signal.new()

	self._destroyed = false
	self._isOpen = false
	self._enabled = self.Config.Enabled ~= false
	self._connections = {}
	self._entryConnections = {}
	self._entries = {}
	self._options = {}
	self._optionById = {}
	self._selectedId = nil
	self._selectedIds = {}
	self._generatedDropdown = false
	self._generatedOverlay = false
	self._generatedEntryTemplate = false
	self._originalDropdownVisible = nil

	self:_createUI()
	self:_connectCore()
	self:SetOptions(self.Config.Options or {})

	if self.Config.Selected ~= nil then
		if self.Config.SelectionMode == "Multiple" and type(self.Config.Selected) == "table" then
			for _, id in ipairs(self.Config.Selected) do
				self:SetSelected(id, true, true)
			end
			self:_fireSelectionChanged()
		elseif self.Config.SelectionMode == "Single" then
			self:SetSelected(self.Config.Selected, true, true)
			self:_fireSelectionChanged()
		end
	end

	self:_updateTrigger()
	self:_setVisibleImmediate(false)

	return self
end

----------------------------------------------------------------
-- UI creation
----------------------------------------------------------------

function Dropdown:_createOverlay()
	local screenGui = getScreenGui(self.Trigger)
	assert(screenGui, "Dropdown trigger must be a descendant of a ScreenGui")

	local overlay = Instance.new("Frame")
	overlay.Name = "DropdownOverlay"
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.ClipsDescendants = false
	overlay.Active = false
	overlay.ZIndex = self.Config.ZIndex
	overlay.Parent = screenGui

	self._overlay = overlay
	self._generatedOverlay = true

	return overlay
end

function Dropdown:_createGeneratedDropdown(parent)
	local container = Instance.new("Frame")
	container.Name = "Dropdown"
	container.BackgroundColor3 = Color3.fromRGB(25, 27, 32)
	container.BorderSizePixel = 0
	container.Size = UDim2.fromOffset(self.Config.MinWidth, 100)
	container.ClipsDescendants = true
	container.ZIndex = self.Config.ZIndex
	container.Visible = false
	container.Parent = parent
	applyProperties(container, self.Config.Style.Container)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(72, 76, 88)
	stroke.Transparency = 0.35
	stroke.Thickness = 1
	stroke.Parent = container

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Entries"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.ScrollBarThickness = 4
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.ZIndex = self.Config.ZIndex + 1
	scroll.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, self.Config.ContentPadding)
	padding.PaddingBottom = UDim.new(0, self.Config.ContentPadding)
	padding.PaddingLeft = UDim.new(0, self.Config.ContentPadding)
	padding.PaddingRight = UDim.new(0, self.Config.ContentPadding)
	padding.Parent = scroll

	local layout = Instance.new("UIListLayout")
	layout.Name = "Layout"
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, self.Config.EntryPadding)
	layout.Parent = scroll

	self._generatedDropdown = true
	self._dropdown = container
	self._entryContainer = scroll
	self._layout = layout
end

function Dropdown:_resolveEntryContainer(dropdown)
	if self.Config.GetEntryContainer then
		local resolved = self.Config.GetEntryContainer(dropdown)
		assert(typeof(resolved) == "Instance", "GetEntryContainer must return an Instance")
		return resolved
	end

	local configured = self.Config.EntryContainer
	if typeof(configured) == "Instance" then
		return configured
	elseif type(configured) == "string" then
		local found = dropdown:FindFirstChild(configured, true)
		assert(found, string.format("Could not find EntryContainer named %q", configured))
		return found
	end

	local entries = dropdown:FindFirstChild("Entries", true)
		or dropdown:FindFirstChild("Scroll", true)
		or dropdown:FindFirstChild("Content", true)

	if entries then
		return entries
	end

	local scrollingFrame = findFirstDescendantOfClass(dropdown, "ScrollingFrame")
	if scrollingFrame then
		return scrollingFrame
	end

	return dropdown
end

function Dropdown:_createUI()
	local configuredParent = self.Config.Parent
	local dropdownInstance = self.Config.DropdownInstance
	local dropdownTemplate = self.Config.DropdownTemplate

	if dropdownInstance then
		assert(dropdownInstance:IsA("GuiObject"), "DropdownInstance must be a GuiObject")
		self._dropdown = dropdownInstance
		self._originalDropdownVisible = dropdownInstance.Visible

		if configuredParent then
			self._dropdown.Parent = configuredParent
		end

		self._entryContainer = self:_resolveEntryContainer(self._dropdown)
		return
	end

	local parent = configuredParent or self:_createOverlay()

	if dropdownTemplate then
		assert(dropdownTemplate:IsA("GuiObject"), "DropdownTemplate must be a GuiObject")
		self._dropdown = dropdownTemplate:Clone()
		self._dropdown.Name = "Dropdown"
		self._dropdown.Parent = parent
		self._dropdown.Visible = false
		self._entryContainer = self:_resolveEntryContainer(self._dropdown)
		return
	end

	self:_createGeneratedDropdown(parent)
end

----------------------------------------------------------------
-- Connections
----------------------------------------------------------------

function Dropdown:_connect(connection)
	table.insert(self._connections, connection)
	return connection
end

function Dropdown:_connectEntry(connection)
	table.insert(self._entryConnections, connection)
	return connection
end

function Dropdown:_clearEntryConnections()
	for _, connection in ipairs(self._entryConnections) do
		connection:Disconnect()
	end
	table.clear(self._entryConnections)
end

function Dropdown:_connectCore()
	if self.Config.ToggleOnTrigger then
		self:_connect(self.Trigger.Activated:Connect(function()
			if self._enabled then
				self:Toggle()
			end
		end))
	end

	self:_connect(UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if not self._isOpen or self._destroyed then
			return
		end

		if self.Config.CloseOnEscape and input.KeyCode == Enum.KeyCode.Escape then
			self:Close()
			return
		end

		if not self.Config.CloseOnOutsideClick or not isPointerInput(input) then
			return
		end

		local point = Vector2.new(input.Position.X, input.Position.Y)

		if pointInside(self.Trigger, point) or pointInside(self._dropdown, point) then
			return
		end

		self:Close()
	end))

	self:_connect(self.Trigger:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		if self._isOpen then
			self:_updatePosition()
		end
	end))

	self:_connect(self.Trigger:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if self._isOpen then
			self:_resizeGeneratedDropdown()
			self:_updatePosition()
		end
	end))

	if self._dropdown then
		self:_connect(self._dropdown:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if self._isOpen and not self._generatedDropdown then
				self:_updatePosition()
			end
		end))
	end

	local camera = Workspace.CurrentCamera
	if camera then
		self:_connect(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if self._isOpen then
				self:_updatePosition()
			end
		end))
	end
end

----------------------------------------------------------------
-- Options / entries
----------------------------------------------------------------

function Dropdown:_createGeneratedEntry(option, index)
	local button = Instance.new("TextButton")
	button.Name = "Option_" .. tostring(option.Id)
	button.Size = UDim2.new(1, 0, 0, self.Config.EntryHeight)
	button.BorderSizePixel = 0
	button.Text = tostring(option.Text)
	button.LayoutOrder = index
	button.ZIndex = self.Config.ZIndex + 2
	button.Parent = self._entryContainer
	applyProperties(button, self.Config.Style.Entry)

	local horizontalPadding = Instance.new("UIPadding")
	horizontalPadding.PaddingLeft = UDim.new(0, 12)
	horizontalPadding.PaddingRight = UDim.new(0, 12)
	horizontalPadding.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	return button
end

function Dropdown:_getEntryButton(entry, option)
	if self.Config.GetEntryButton then
		local button = self.Config.GetEntryButton(entry, option)
		if button then
			assert(button:IsA("GuiButton"), "GetEntryButton must return a GuiButton")
		end
		return button
	end

	if entry:IsA("GuiButton") then
		return entry
	end

	return findFirstDescendantOfClass(entry, "GuiButton")
end

function Dropdown:_getEntryLabel(entry, option)
	if self.Config.GetEntryLabel then
		return self.Config.GetEntryLabel(entry, option)
	end

	if entry:IsA("TextButton") or entry:IsA("TextLabel") then
		return entry
	end

	for _, descendant in ipairs(entry:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			return descendant
		end
	end

	return nil
end

function Dropdown:_isSelected(id)
	if self.Config.SelectionMode == "Single" then
		return self._selectedId == id
	elseif self.Config.SelectionMode == "Multiple" then
		return self._selectedIds[id] == true
	end
	return false
end

function Dropdown:_updateEntryInteraction(entryData, immediate)
	local button = entryData.Button
	local restingColor = entryData.RestingBackgroundColor3

	if not button or not button.Parent or not restingColor then
		return
	end

	if entryData.InteractionTween then
		local previousTween = entryData.InteractionTween
		entryData.InteractionTween = nil
		previousTween:Cancel()
		previousTween:Destroy()
	end

	local targetColor = restingColor
	local interaction = self.Config.Interaction
	if interaction.Enabled and not entryData.Option.Disabled then
		if entryData.Pressed then
			targetColor = restingColor:Lerp(Color3.new(0, 0, 0), interaction.PressedBrightness)
		elseif entryData.Hovered then
			targetColor = restingColor:Lerp(Color3.new(1, 1, 1), interaction.HoverBrightness)
		end
	end

	if immediate or interaction.Duration <= 0 then
		button.BackgroundColor3 = targetColor
		return
	end

	local tween = TweenService:Create(
		button,
		TweenInfo.new(interaction.Duration, interaction.EasingStyle, interaction.EasingDirection),
		{ BackgroundColor3 = targetColor }
	)
	entryData.InteractionTween = tween
	tween.Completed:Connect(function()
		if entryData.InteractionTween ~= tween then
			return
		end
		entryData.InteractionTween = nil
		tween:Destroy()
	end)
	tween:Play()
end

function Dropdown:_setEntryInteraction(entryData, hovered, pressed)
	if entryData.Option.Disabled then
		return
	end

	entryData.Hovered = hovered
	entryData.Pressed = pressed
	self:_updateEntryInteraction(entryData, false)
end

function Dropdown:_renderEntry(entryData)
	local option = entryData.Option
	local entry = entryData.Instance
	local button = entryData.Button
	local state = {
		Selected = self:_isSelected(option.Id),
		Disabled = option.Disabled == true,
		Index = entryData.Index,
	}

	-- Restore the resting color before a renderer computes the entry's next state.
	if button and entryData.RestingBackgroundColor3 then
		button.BackgroundColor3 = entryData.RestingBackgroundColor3
	end

	if self.Config.RenderOption then
		self.Config.RenderOption(entry, option, state, self)
	else
		local label = self:_getEntryLabel(entry, option)
		if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
			label.Text = tostring(option.Text)
		end

		if self._generatedDropdown and entry:IsA("TextButton") then
			applyProperties(entry, self.Config.Style.Entry)

			if state.Selected then
				applyProperties(entry, self.Config.Style.EntrySelected)
			end

			if state.Disabled then
				applyProperties(entry, self.Config.Style.EntryDisabled)
			end
		end
	end

	entry.Visible = true

	if button then
		entryData.RestingBackgroundColor3 = button.BackgroundColor3
		self:_updateEntryInteraction(entryData, true)
	end
end

function Dropdown:_renderAllEntries()
	for _, entryData in pairs(self._entries) do
		self:_renderEntry(entryData)
	end
end

function Dropdown:_activateOption(option, index)
	if option.Disabled or not self._enabled then
		return
	end

	local mode = self.Config.SelectionMode

	if mode == "Single" then
		self:SetSelected(option.Id, true)
	elseif mode == "Multiple" then
		self:SetSelected(option.Id, not self._selectedIds[option.Id])
	end

	self.Selected:Fire(option, index)

	local closeOnSelect = self.Config.CloseOnSelect
	if closeOnSelect == nil then
		closeOnSelect = mode ~= "Multiple"
	end

	if closeOnSelect then
		self:Close()
	end
end

function Dropdown:_createEntry(option, index)
	local entry

	if self.Config.CreateEntry then
		entry = self.Config.CreateEntry(option, index, self)
		assert(typeof(entry) == "Instance" and entry:IsA("GuiObject"), "CreateEntry must return a GuiObject")
		entry.Parent = self._entryContainer
	elseif self.Config.EntryTemplate then
		entry = self.Config.EntryTemplate:Clone()
		entry.Name = "Option_" .. tostring(option.Id)
		entry.LayoutOrder = index
		entry.Visible = true
		entry.Parent = self._entryContainer
	else
		entry = self:_createGeneratedEntry(option, index)
	end

	local button = self:_getEntryButton(entry, option)
	local entryData = {
		Instance = entry,
		Button = button,
		Option = option,
		Index = index,
		Hovered = false,
		Pressed = false,
	}

	self._entries[option.Id] = entryData

	if button then
		self:_connectEntry(button.MouseEnter:Connect(function()
			self:_setEntryInteraction(entryData, true, entryData.Pressed)
		end))
		self:_connectEntry(button.MouseLeave:Connect(function()
			self:_setEntryInteraction(entryData, false, false)
		end))
		self:_connectEntry(button.MouseButton1Down:Connect(function()
			self:_setEntryInteraction(entryData, true, true)
		end))
		self:_connectEntry(button.MouseButton1Up:Connect(function()
			self:_setEntryInteraction(entryData, true, false)
		end))
		self:_connectEntry(button.Activated:Connect(function()
			self:_activateOption(option, index)
		end))
	else
		warn(
			string.format(
				"[Dropdown] Option %s has no GuiButton. Supply GetEntryButton or make the entry a GuiButton.",
				tostring(option.Id)
			)
		)
	end

	self:_renderEntry(entryData)

	if self.Config.OnEntryCreated then
		self.Config.OnEntryCreated(entry, option, self)
		if button then
			entryData.RestingBackgroundColor3 = button.BackgroundColor3
			self:_updateEntryInteraction(entryData, true)
		end
	end
end

function Dropdown:_destroyEntries()
	self:_clearEntryConnections()

	for _, entryData in pairs(self._entries) do
		if entryData.InteractionTween then
			local tween = entryData.InteractionTween
			entryData.InteractionTween = nil
			tween:Cancel()
			tween:Destroy()
		end

		if self.Config.OnEntryDestroyed then
			self.Config.OnEntryDestroyed(entryData.Instance, entryData.Option, self)
		end

		if entryData.Instance and entryData.Instance.Parent then
			entryData.Instance:Destroy()
		end
	end

	table.clear(self._entries)
end

function Dropdown:SetOptions(options)
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")
	assert(type(options) == "table", "SetOptions expects an array")

	self:_destroyEntries()
	table.clear(self._options)
	table.clear(self._optionById)

	local seenIds = {}

	for index, rawOption in ipairs(options) do
		local option = normalizeOption(rawOption, index)

		assert(not seenIds[option.Id], string.format("Duplicate dropdown option Id: %s", tostring(option.Id)))
		seenIds[option.Id] = true

		table.insert(self._options, option)
		self._optionById[option.Id] = option

		self:_createEntry(option, index)
	end

	-- Drop selection values that no longer exist.
	if self.Config.SelectionMode == "Single" then
		if self._selectedId ~= nil and not self._optionById[self._selectedId] then
			self._selectedId = nil
			self:_fireSelectionChanged()
		end
	elseif self.Config.SelectionMode == "Multiple" then
		local changed = false
		for id in pairs(self._selectedIds) do
			if not self._optionById[id] then
				self._selectedIds[id] = nil
				changed = true
			end
		end

		if changed then
			self:_fireSelectionChanged()
		end
	end

	self:_resizeGeneratedDropdown()
	self:_renderAllEntries()

	if self._isOpen then
		self:_updatePosition()
	end

	return self
end

function Dropdown:GetOptions()
	local copy = {}
	for index, option in ipairs(self._options) do
		copy[index] = option
	end
	return copy
end

function Dropdown:GetOption(id)
	return self._optionById[id]
end

function Dropdown:AddOption(option)
	local options = self:GetOptions()
	table.insert(options, option)
	return self:SetOptions(options)
end

function Dropdown:RemoveOption(id)
	local options = {}

	for _, option in ipairs(self._options) do
		if option.Id ~= id then
			table.insert(options, option)
		end
	end

	return self:SetOptions(options)
end

function Dropdown:ClearOptions()
	return self:SetOptions({})
end

----------------------------------------------------------------
-- Selection
----------------------------------------------------------------

function Dropdown:_fireSelectionChanged()
	self:_renderAllEntries()
	self:_updateTrigger()
	self.SelectionChanged:Fire(self:GetSelected(), self:GetSelectedOptions())
end

function Dropdown:SetSelected(id, selected, suppressSignal)
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")

	local mode = self.Config.SelectionMode
	if mode == "None" then
		return self
	end

	if id ~= nil then
		local option = self._optionById[id]
		assert(option, string.format("Unknown dropdown option Id: %s", tostring(id)))

		if option.Disabled then
			return self
		end
	end

	if mode == "Single" then
		if selected == false then
			if self._selectedId == id then
				self._selectedId = nil
			end
		else
			self._selectedId = id
		end
	else
		if id == nil then
			return self
		end
		self._selectedIds[id] = selected ~= false and true or nil
	end

	if not suppressSignal then
		self:_fireSelectionChanged()
	else
		self:_renderAllEntries()
		self:_updateTrigger()
	end

	return self
end

function Dropdown:ClearSelection()
	if self.Config.SelectionMode == "Single" then
		self._selectedId = nil
	elseif self.Config.SelectionMode == "Multiple" then
		table.clear(self._selectedIds)
	end

	self:_fireSelectionChanged()
	return self
end

function Dropdown:GetSelected()
	if self.Config.SelectionMode == "Single" then
		return self._selectedId
	elseif self.Config.SelectionMode == "Multiple" then
		local ids = {}
		for _, option in ipairs(self._options) do
			if self._selectedIds[option.Id] then
				table.insert(ids, option.Id)
			end
		end
		return ids
	end

	return nil
end

function Dropdown:GetSelectedOption()
	if self.Config.SelectionMode ~= "Single" or self._selectedId == nil then
		return nil
	end
	return self._optionById[self._selectedId]
end

function Dropdown:GetSelectedOptions()
	local options = {}

	if self.Config.SelectionMode == "Single" then
		local option = self:GetSelectedOption()
		if option then
			table.insert(options, option)
		end
	elseif self.Config.SelectionMode == "Multiple" then
		for _, option in ipairs(self._options) do
			if self._selectedIds[option.Id] then
				table.insert(options, option)
			end
		end
	end

	return options
end

----------------------------------------------------------------
-- Trigger display
----------------------------------------------------------------

function Dropdown:_updateTrigger()
	if self.Config.RenderTrigger then
		self.Config.RenderTrigger(self.Trigger, self:GetSelectedOptions(), self)
		return
	end

	if not self.Config.UpdateTriggerText or not self.Trigger:IsA("TextButton") then
		return
	end

	if self.Config.SelectionMode == "Single" then
		local option = self:GetSelectedOption()
		if option then
			self.Trigger.Text = tostring(option.Text)
		elseif self._initialTriggerText then
			self.Trigger.Text = self._initialTriggerText
		end
	elseif self.Config.SelectionMode == "Multiple" then
		local selectedOptions = self:GetSelectedOptions()
		if #selectedOptions > 0 then
			self.Trigger.Text = string.format("%d selected", #selectedOptions)
		elseif self._initialTriggerText then
			self.Trigger.Text = self._initialTriggerText
		end
	end
end

----------------------------------------------------------------
-- Size / placement
----------------------------------------------------------------

function Dropdown:_resizeGeneratedDropdown()
	if not self._generatedDropdown then
		return
	end

	local optionCount = #self._options
	local contentPadding = self.Config.ContentPadding * 2
	local contentHeight = contentPadding

	if optionCount > 0 then
		contentHeight += optionCount * self.Config.EntryHeight
		contentHeight += math.max(optionCount - 1, 0) * self.Config.EntryPadding
	end

	local height = math.min(contentHeight, self.Config.MaxHeight)
	if optionCount == 0 then
		height = math.min(self.Config.EntryHeight + contentPadding, self.Config.MaxHeight)
	end

	local triggerWidth = self.Trigger.AbsoluteSize.X
	local width = self.Config.Width or math.max(triggerWidth, self.Config.MinWidth)

	self._dropdown.Size = UDim2.fromOffset(width, height)

	if self._entryContainer:IsA("ScrollingFrame") then
		self._entryContainer.CanvasSize = UDim2.fromOffset(0, contentHeight)
		self._entryContainer.ScrollBarImageTransparency = contentHeight > height and 0 or 1
	end
end

function Dropdown:_getPositionReference()
	local parent = self._dropdown.Parent

	if parent and parent:IsA("GuiObject") then
		return parent.AbsolutePosition, parent.AbsoluteSize
	end

	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)

	local insetTopLeft = Vector2.zero
	local screenGui = getScreenGui(self._dropdown)
	if screenGui and not screenGui.IgnoreGuiInset then
		local topLeftInset = GuiService:GetGuiInset()
		insetTopLeft = topLeftInset
	end

	return insetTopLeft, viewport
end

function Dropdown:_calculatePosition()
	local triggerPos = self.Trigger.AbsolutePosition
	local triggerSize = self.Trigger.AbsoluteSize
	local dropdownSize = self._dropdown.AbsoluteSize

	local referencePos, referenceSize = self:_getPositionReference()

	local localTriggerPos = triggerPos - referencePos
	local offset = self.Config.Offset

	local function alignedX()
		if self.Config.Alignment == "Center" then
			return localTriggerPos.X + (triggerSize.X - dropdownSize.X) * 0.5
		elseif self.Config.Alignment == "End" then
			return localTriggerPos.X + triggerSize.X - dropdownSize.X
		end
		return localTriggerPos.X
	end

	local function alignedY()
		if self.Config.Alignment == "Center" then
			return localTriggerPos.Y + (triggerSize.Y - dropdownSize.Y) * 0.5
		elseif self.Config.Alignment == "End" then
			return localTriggerPos.Y + triggerSize.Y - dropdownSize.Y
		end
		return localTriggerPos.Y
	end

	local padding = self.Config.ScreenPadding
	local spaceBelow = referenceSize.Y - (localTriggerPos.Y + triggerSize.Y) - padding
	local spaceAbove = localTriggerPos.Y - padding
	local spaceRight = referenceSize.X - (localTriggerPos.X + triggerSize.X) - padding
	local spaceLeft = localTriggerPos.X - padding

	local placement = self.Config.Placement

	if placement == "Auto" then
		if spaceBelow >= dropdownSize.Y or spaceBelow >= spaceAbove then
			placement = "Bottom"
		else
			placement = "Top"
		end
	end

	if self.Config.AutoFlip then
		if placement == "Bottom" and spaceBelow < dropdownSize.Y and spaceAbove > spaceBelow then
			placement = "Top"
		elseif placement == "Top" and spaceAbove < dropdownSize.Y and spaceBelow > spaceAbove then
			placement = "Bottom"
		elseif placement == "Right" and spaceRight < dropdownSize.X and spaceLeft > spaceRight then
			placement = "Left"
		elseif placement == "Left" and spaceLeft < dropdownSize.X and spaceRight > spaceLeft then
			placement = "Right"
		end
	end

	local x
	local y

	if placement == "Bottom" then
		x = alignedX() + offset.X
		y = localTriggerPos.Y + triggerSize.Y + offset.Y
	elseif placement == "Top" then
		x = alignedX() + offset.X
		y = localTriggerPos.Y - dropdownSize.Y - offset.Y
	elseif placement == "Right" then
		x = localTriggerPos.X + triggerSize.X + offset.X
		y = alignedY() + offset.Y
	else -- Left
		x = localTriggerPos.X - dropdownSize.X - offset.X
		y = alignedY() + offset.Y
	end

	if self.Config.ClampToScreen then
		local maxX = math.max(padding, referenceSize.X - dropdownSize.X - padding)
		local maxY = math.max(padding, referenceSize.Y - dropdownSize.Y - padding)

		x = math.clamp(x, padding, maxX)
		y = math.clamp(y, padding, maxY)
	end

	return Vector2.new(x, y)
end

function Dropdown:_updatePosition()
	if not self._dropdown or not self._dropdown.Parent then
		return
	end

	if self._generatedDropdown then
		self:_resizeGeneratedDropdown()
	end

	local position = self:_calculatePosition()
	local anchorPoint = self._dropdown.AnchorPoint
	local size = self._dropdown.AbsoluteSize

	self._dropdown.Position = UDim2.fromOffset(position.X + size.X * anchorPoint.X, position.Y + size.Y * anchorPoint.Y)
end

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------

function Dropdown:_setVisibleImmediate(visible)
	self._dropdown.Visible = visible
end

function Dropdown:Open()
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")

	if self._isOpen or not self._enabled then
		return self
	end

	if self.Config.Exclusive and activeExclusiveDropdown and activeExclusiveDropdown ~= self then
		activeExclusiveDropdown:Close()
	end

	if self.Config.Exclusive then
		activeExclusiveDropdown = self
	end

	self._isOpen = true
	self:_resizeGeneratedDropdown()
	self:_setVisibleImmediate(true)

	-- AbsoluteSize updates after visibility in some UI arrangements.
	task.defer(function()
		if self._destroyed or not self._isOpen then
			return
		end
		self:_updatePosition()
	end)

	self:_updatePosition()
	self.Opened:Fire()

	return self
end

function Dropdown:Close()
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")

	if not self._isOpen then
		return self
	end

	self._isOpen = false

	if activeExclusiveDropdown == self then
		activeExclusiveDropdown = nil
	end

	self:_setVisibleImmediate(false)
	self.Closed:Fire()

	return self
end

function Dropdown:Toggle()
	if self._isOpen then
		return self:Close()
	end
	return self:Open()
end

function Dropdown:IsOpen()
	return self._isOpen
end

function Dropdown:SetEnabled(enabled)
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")

	self._enabled = enabled == true

	if not self._enabled then
		self:Close()
	end

	return self
end

function Dropdown:IsEnabled()
	return self._enabled
end

function Dropdown:Refresh()
	assert(not self._destroyed, "Cannot use a destroyed Dropdown")

	self:_renderAllEntries()
	self:_resizeGeneratedDropdown()

	if self._isOpen then
		self:_updatePosition()
	end

	self:_updateTrigger()
	return self
end

----------------------------------------------------------------
-- Destruction
----------------------------------------------------------------

function Dropdown:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._isOpen = false

	if activeExclusiveDropdown == self then
		activeExclusiveDropdown = nil
	end

	self:_destroyEntries()

	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)

	self.Opened:Destroy()
	self.Closed:Destroy()
	self.Selected:Destroy()
	self.SelectionChanged:Destroy()

	if self._generatedDropdown and self._dropdown then
		self._dropdown:Destroy()
	elseif self.Config.DropdownTemplate and self._dropdown then
		self._dropdown:Destroy()
	else
		-- Existing DropdownInstance belongs to the caller.
		if self._dropdown then
			self._dropdown.Visible = self._originalDropdownVisible == true
		end
	end

	if self._generatedOverlay and self._overlay then
		self._overlay:Destroy()
	end

	setmetatable(self, nil)
end

return Dropdown

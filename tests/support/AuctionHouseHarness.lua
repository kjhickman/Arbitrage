return function()
  local eventFrames = {}
  local createdFrames = {}
  local createdFontStrings = {}
  local createdTextures = {}
  local createdLines = {}
  local windowTitle
  local auctionHouseShown = false
  local scanCalls = 0
  local quickScanCalls = 0
  local settingsCalls = 0
  local requestedItemIDs = {}
  local opportunityCalls = 0
  local currentTime = 200
  local tooltipHideCalls = 0
  local tooltipLines = {}
  local tooltipDoubleLines = {}
  local pendingSaleItemIDs = {}
  local timers = {}
  -- Timers waiting on a delay, which run once a test lets that time pass.
  local delayedTimers = {}

  C_Timer = {
    After = function(seconds, callback)
      if seconds > 0 then
        delayedTimers[#delayedTimers + 1] = callback
      else
        timers[#timers + 1] = callback
      end
    end,
  }

  local function NewRegion(parent, template)
    local region = {
      parent = parent,
      template = template,
      points = {},
      scripts = {},
      frameLevel = 1,
    }

    function region:SetScript(scriptName, callback)
      self.scripts[scriptName] = callback
    end

    function region:GetScript(scriptName)
      return self.scripts[scriptName]
    end

    -- A test puts the mouse over a region by setting mouseOver.
    function region:IsMouseOver()
      return self.mouseOver == true
    end

    function region:HookScript(scriptName, callback)
      local original = self.scripts[scriptName]
      self.scripts[scriptName] = function(...)
        if original then
          original(...)
        end
        callback(...)
      end
    end

    function region:SetID(id)
      self.id = id
    end

    function region:GetID()
      return self.id
    end

    -- Like the game, anchoring a point the region already has replaces that anchor.
    function region:SetPoint(point, ...)
      for index, existing in ipairs(self.points) do
        if existing[1] == point then
          self.points[index] = { point, ... }
          return
        end
      end
      self.points[#self.points + 1] = { point, ... }
    end

    function region:SetAllPoints()
      self.allPoints = true
    end

    function region:ClearAllPoints()
      self.points = {}
      self.allPoints = nil
    end

    function region:SetSize(width, height)
      self.width = width
      self.height = height
    end

    function region:SetWidth(width)
      self.width = width
    end

    function region:SetHeight(height)
      self.height = height
    end

    function region:SetFrameLevel(level)
      self.frameLevel = level
    end

    function region:GetFrameLevel()
      return self.frameLevel
    end

    function region:SetToplevel(toplevel)
      self.toplevel = toplevel
    end

    function region:EnableMouse(enabled)
      self.mouseEnabled = enabled
    end

    function region:EnableMouseWheel(enabled)
      self.mouseWheelEnabled = enabled
    end

    function region:SetMovable(movable)
      self.movable = movable
    end

    function region:SetClampedToScreen(clamped)
      self.clampedToScreen = clamped
    end

    function region:RegisterForDrag(...)
      self.dragButtons = { ... }
    end

    function region:StartMoving()
      self.moving = true
    end

    function region:StopMovingOrSizing()
      self.moving = false
    end

    function region:SetMotionScriptsWhileDisabled(enabled)
      self.motionScriptsWhileDisabled = enabled
    end

    function region:SetText(text)
      self.text = text
    end

    function region:SetScrollChild(child)
      self.scrollChild = child
    end

    function region:SetVerticalScroll(offset)
      self.verticalScroll = offset
    end

    -- The game rejects anything but numbers, such as the hex string GetItemQualityColor returns fourth.
    function region:SetTextColor(...)
      local red, green, blue, alpha = ...
      assert(type(red) == "number" and type(green) == "number" and type(blue) == "number", "SetTextColor takes numbers")
      assert(alpha == nil or type(alpha) == "number", "SetTextColor's alpha is a number")
      assert(select("#", ...) <= 4, "SetTextColor takes at most four values")
      self.textColor = { ... }
    end

    function region:SetJustifyH(justify)
      self.justifyH = justify
    end

    function region:SetWordWrap(wrap)
      self.wordWrap = wrap
    end

    function region:SetMaxLines(maxLines)
      self.maxLines = maxLines
    end

    function region:SetShown(shown)
      if shown then
        self:Show()
      else
        self:Hide()
      end
    end

    function region:IsShown()
      return self.shown == true
    end

    -- Like the game, a region is visible while it and every parent are shown.
    function region:IsVisible()
      local current = self
      while current do
        if current.IsShown and not current:IsShown() then
          return false
        end
        current = current.parent
      end
      return true
    end

    function region:SetTexCoord(...)
      self.texCoord = { ... }
    end

    function region:SetHitRectInsets() end

    function region:LockHighlight()
      self.highlightLocked = true
    end

    function region:UnlockHighlight()
      self.highlightLocked = false
    end

    function region:SetAtlas(atlas, useAtlasSize)
      self.atlas = atlas
      self.useAtlasSize = useAtlasSize
    end

    function region:SetBlendMode(blendMode)
      self.blendMode = blendMode
    end

    function region:SetAlpha(alpha)
      self.alpha = alpha
    end

    function region:SetScale(scale)
      self.scale = scale
    end

    -- Like the game, scripts fire only when the shown state actually changes.
    function region:Hide()
      local wasShown = self.shown
      self.shown = false
      if wasShown and self.scripts.OnHide then
        self.scripts.OnHide(self)
      end
    end

    function region:Show()
      local wasShown = self.shown
      self.shown = true
      if not wasShown and self.scripts.OnShow then
        self.scripts.OnShow(self)
      end
    end

    function region:Enable()
      self.enabled = true
    end

    function region:Disable()
      self.enabled = false
    end

    function region:SetEnabled(enabled)
      self.enabled = enabled == true
    end

    function region:IsEnabled()
      return self.enabled ~= false
    end

    function region:Click()
      if self.enabled ~= false and self.scripts.OnClick then
        self.scripts.OnClick(self)
      end
    end

    function region:CreateFontString(_, _, fontTemplate)
      local fontString = NewRegion(self, fontTemplate)
      createdFontStrings[#createdFontStrings + 1] = fontString
      return fontString
    end

    function region:CreateTexture(_, drawLayer)
      local texture = NewRegion(self, drawLayer)
      createdTextures[#createdTextures + 1] = texture
      function texture:SetTexture(value)
        self.texture = value
      end
      function texture:SetColorTexture(...)
        self.color = { ... }
      end
      return texture
    end

    function region:CreateLine(_, drawLayer)
      local line = NewRegion(self, drawLayer)
      createdLines[#createdLines + 1] = line
      function line:SetThickness(thickness)
        self.thickness = thickness
      end
      function line:SetColorTexture(...)
        self.color = { ... }
      end
      function line:SetStartPoint(...)
        self.startPoint = { ... }
      end
      function line:SetEndPoint(...)
        self.endPoint = { ... }
      end
      return line
    end

    return region
  end

  UIParent = NewRegion()
  UIParent.shown = true
  UISpecialFrames = {}

  -- A dropdown's menu as the entries its generator adds; Pick on one runs it, then afterPick.
  local function NewMenu(label, afterPick)
    local menu = { label = label, entries = {} }
    local function AddItem(_, itemLabel, isSelected, onSelect, data)
      local item = {
        label = itemLabel,
        value = data,
        data = data,
        IsSelected = function()
          return isSelected(data)
        end,
        Pick = function()
          onSelect(data)
          afterPick()
        end,
        SetTitleAndTextTooltip = function(entry, title, text)
          entry.tooltipTitle, entry.tooltipText = title, text
        end,
      }
      menu.entries[#menu.entries + 1] = item
      return item
    end
    menu.SetTag = function(self, tag)
      self.tag = tag
    end
    menu.SetTitleAndTextTooltip = function(self, title, text)
      self.tooltipTitle, self.tooltipText = title, text
    end
    menu.CreateButton = function(self, buttonLabel)
      local submenu = NewMenu(buttonLabel, afterPick)
      self.entries[#self.entries + 1] = submenu
      return submenu
    end
    menu.CreateRadio = AddItem
    menu.CreateCheckbox = AddItem
    menu.CreateTitle = function(self, text)
      local title = { title = text }
      self.entries[#self.entries + 1] = title
      return title
    end
    menu.CreateTemplate = function(self, template)
      local element = { template = template, initializers = {} }
      function element:AddInitializer(initializer)
        self.initializers[#self.initializers + 1] = initializer
      end
      self.entries[#self.entries + 1] = element
      return element
    end
    return menu
  end

  -- The templates WoW Forever loads that the addon and LibAHTab use. Blizzard keeps some templates
  -- in only one family's files: WowStyle1ThinDropdownTemplate is Classic's, and Forever loads the
  -- Mainline ones, so creating it fails in game. Check a new template is in the files Forever
  -- loads before adding it here.
  local KNOWN_TEMPLATES = {
    AuctionHouseFrameDisplayModeTabTemplate = true,
    ColoredProgressBarTemplate = true,
    ColumnDisplayButtonShortTemplate = true,
    MinimalCheckboxTemplate = true,
    MinimalScrollBar = true,
    NineSlicePanelTemplate = true,
    NumericInputSpinnerTemplate = true,
    PanelTabButtonTemplate = true,
    PanelTopTabButtonTemplate = true,
    PortraitFrameTemplate = true,
    SearchBoxTemplate = true,
    SpinnerTemplate = true,
    UIPanelButtonTemplate = true,
    UIPanelCloseButtonNoScripts = true,
    WowScrollBoxList = true,
    WowStyle1FilterDropdownTemplate = true,
  }

  function CreateFrame(frameType, name, parent, template)
    assert(template == nil or KNOWN_TEMPLATES[template], "WoW Forever has no template " .. tostring(template))
    local frame = NewRegion(parent, template)
    -- Like the game's, a new frame is shown until something hides it.
    frame.shown = true
    frame.frameType = frameType
    frame.name = name
    createdFrames[#createdFrames + 1] = frame
    if type(name) == "string" and name ~= "" then
      _G[name] = frame
    end

    function frame:IsObjectType(objectType)
      return objectType == "Frame" or objectType == frameType
    end

    if frameType == "Button" then
      function frame:SetNormalAtlas(atlas)
        self.normalAtlas = atlas
      end
      function frame:SetHighlightAtlas(atlas, blendMode)
        self.highlightAtlas = atlas
        self.highlightBlendMode = blendMode
      end
      function frame:RegisterForClicks(...)
        self.clickButtons = { ... }
      end
      -- Like the game, a click passes the mouse button, which is the left one unless a test says.
      function frame:Click(button)
        if self.enabled ~= false and self.scripts.OnClick then
          self.scripts.OnClick(self, button or "LeftButton")
        end
      end
    end

    if parent == nil then
      frame.registeredEvents = {}
      eventFrames[#eventFrames + 1] = frame
      function frame:RegisterEvent(eventName)
        self.registeredEvents[eventName] = true
      end
    end

    if template == "ColumnDisplayButtonShortTemplate" then
      frame.Text = NewRegion(frame)
    elseif template == "ColoredProgressBarTemplate" then
      frame.Fill = frame:CreateTexture(nil, "BORDER")
      function frame.Fill:SetVertexColor(...) end
      function frame:SetFillPercent(fraction)
        self.fillFraction = fraction
      end
    elseif template == "MinimalCheckboxTemplate" then
      -- Like the game, a click checks or unchecks it before its script runs.
      function frame:SetChecked(checked)
        self.checked = checked == true
      end
      function frame:GetChecked()
        return self.checked == true
      end
      function frame:Click()
        self.checked = not self.checked
        if self.scripts.OnClick then
          self.scripts.OnClick(self, "LeftButton")
        end
      end
    elseif template == "NumericInputSpinnerTemplate" then
      -- Blizzard's NumericInputSpinnerMixin with its template's scripts: a number kept in its range
      -- and shown as the box's text, stepped by an arrow, again on each OnUpdate while it's held, or
      -- by the mouse wheel, Shift for ten. Typing goes through OnTextChanged.
      frame.editText = ""
      frame.registeredEvents = {}
      eventFrames[#eventFrames + 1] = frame
      function frame:RegisterEvent(eventName)
        self.registeredEvents[eventName] = true
      end
      function frame:UnregisterEvent(eventName)
        self.registeredEvents[eventName] = nil
      end
      function frame:SetNumber(number)
        self.editText = tostring(number)
        if self.scripts.OnTextChanged then
          self.scripts.OnTextChanged(self, false)
        end
      end
      function frame:GetNumber()
        return tonumber(self.editText) or 0
      end
      function frame:SetMinMaxValues(min, max)
        self.min, self.max = min, max
        self:SetValue(self:GetValue())
      end
      function frame:GetValue()
        return self.currentValue or self.min or 0
      end
      function frame:SetValue(value)
        local clamped = math.max(self.min or -math.huge, math.min(self.max or math.huge, value))
        if clamped ~= self.currentValue then
          self.currentValue = clamped
          self:SetNumber(clamped)
        end
      end
      function frame:Increment(amount)
        self:SetValue(self:GetValue() + (amount or 1))
      end
      function frame:Decrement(amount)
        self:SetValue(self:GetValue() - (amount or 1))
      end
      function frame:StartIncrement()
        self:SetScript("OnUpdate", function(spinner)
          spinner:Increment()
        end)
        self:Increment()
        self:ClearFocus()
      end
      function frame:StartDecrement()
        self:SetScript("OnUpdate", function(spinner)
          spinner:Decrement()
        end)
        self:Decrement()
        self:ClearFocus()
      end
      function frame:EndIncrement()
        self:SetScript("OnUpdate", nil)
      end
      frame.EndDecrement = frame.EndIncrement
      function frame:HasFocus()
        return self.focused == true
      end
      function frame:SetFocus()
        if not self.focused then
          self.focused = true
          if self.scripts.OnEditFocusGained then
            self.scripts.OnEditFocusGained(self)
          end
        end
      end
      function frame:ClearFocus()
        if self.focused then
          self.focused = false
          if self.scripts.OnEditFocusLost then
            self.scripts.OnEditFocusLost(self)
          end
        end
      end
      function frame:HighlightText() end
      frame.scripts.OnEscapePressed = frame.ClearFocus
      frame.scripts.OnEditFocusLost = function(self)
        self:HighlightText(0, 0)
      end
      frame.scripts.OnEditFocusGained = function(self)
        self:HighlightText()
      end
      frame.scripts.OnTextChanged = function(self)
        self:SetValue(self:GetNumber())
      end
      local function NewArrow(start, finish)
        local arrow = CreateFrame("Button", nil, frame)
        arrow.scripts.OnMouseDown = function(self)
          if self:IsEnabled() then
            frame[start](frame)
          end
        end
        arrow.scripts.OnMouseUp = function()
          frame[finish](frame)
        end
        return arrow
      end
      frame.IncrementButton = NewArrow("StartIncrement", "EndIncrement")
      frame.DecrementButton = NewArrow("StartDecrement", "EndDecrement")
      frame.MouseWheelCatcher = CreateFrame("Frame", nil, frame)
      frame.MouseWheelCatcher.scripts.OnMouseWheel = function(_, delta)
        local amount = IsShiftKeyDown() and 10 or 1
        if delta > 0 then
          frame:Increment(amount)
        else
          frame:Decrement(amount)
        end
        frame:ClearFocus()
      end

      -- What a player does: types into the box, presses Enter or Escape, holds an arrow for some
      -- frames, or turns the wheel over it.
      function frame:Type(text)
        self:SetFocus()
        self.editText = text
        if self.scripts.OnTextChanged then
          self.scripts.OnTextChanged(self, true)
        end
      end
      function frame:PressEnter()
        if self.scripts.OnEnterPressed then
          self.scripts.OnEnterPressed(self)
        end
      end
      function frame:PressEscape()
        self.scripts.OnEscapePressed(self)
      end
      function frame:HoldArrow(arrow, frames)
        arrow.scripts.OnMouseDown(arrow)
        for _ = 1, frames or 0 do
          self.scripts.OnUpdate(self, 0.1)
        end
        arrow.scripts.OnMouseUp(arrow)
      end
      function frame:Wheel(delta)
        self.MouseWheelCatcher.scripts.OnMouseWheel(self.MouseWheelCatcher, delta)
      end
    elseif template == "MinimalScrollBar" then
      function frame:SetHideIfUnscrollable(hide)
        self.hideIfUnscrollable = hide
      end
    elseif template == "PanelTabButtonTemplate" or template == "PanelTopTabButtonTemplate" then
      -- The template's parentArray collects every tab on its parent.
      parent.Tabs = parent.Tabs or {}
      parent.Tabs[#parent.Tabs + 1] = frame
    elseif template == "SearchBoxTemplate" then
      frame.Instructions = NewRegion(frame)
      frame.editText = ""
      function frame:SetAutoFocus(autoFocus)
        self.autoFocus = autoFocus
      end
      function frame:GetText()
        return self.editText
      end
      function frame:SetText(text)
        self.editText = text
        if self.scripts.OnTextChanged then
          self.scripts.OnTextChanged(self, false)
        end
      end
      function frame:Type(text)
        self.editText = text
        if self.scripts.OnTextChanged then
          self.scripts.OnTextChanged(self, true)
        end
      end
    elseif template == "PortraitFrameTemplate" then
      frame.CloseButton = CreateFrame("Button", (name or "") .. "CloseButton", frame)
      frame.CloseButton.scripts.OnClick = function()
        error("default CloseButton calls HideUIPanel")
      end
      function frame:SetTitle(title)
        self.title = title
      end
      function frame:SetPortraitToAsset(asset)
        self.portraitAsset = asset
      end
    elseif template == "WowScrollBoxList" then
      frame.frames = {}
      frame.callbacks = {}
      frame.offset = 0

      local function RefreshFrames(self)
        local elements = self.dataProvider and self.dataProvider.elements or {}
        local visibleCount = math.min(16, math.max(0, #elements - self.offset))
        for index = 1, visibleCount do
          local row = self.frames[index]
          if not row then
            row = CreateFrame(self.view.template, nil, self)
            self.frames[index] = row
          end
          row.elementData = elements[self.offset + index]
          self.view.initializer(row, row.elementData)
          if self.alternateRowCallback then
            self.alternateRowCallback(row, index % 2 == 0)
          end
          row:Show()
        end
        for index = visibleCount + 1, #self.frames do
          self.frames[index]:Hide()
        end
      end

      function frame:RegisterCallback(event, callback)
        self.callbacks[event] = callback
      end
      function frame:ForEachFrame(callback)
        for _, row in ipairs(self.frames) do
          if row:IsShown() then
            callback(row, row.elementData)
          end
        end
      end
      function frame:SetDataProvider(dataProvider, retainScrollPosition)
        self.dataProvider = dataProvider
        if not retainScrollPosition then
          self.offset = 0
        end
        RefreshFrames(self)
      end
      function frame:SetScrollOffset(offset)
        self.offset = offset
        RefreshFrames(self)
        local callback = self.callbacks.Scroll
        if callback then
          callback()
        end
      end
    elseif template == "WowStyle1FilterDropdownTemplate" then
      frame.ResetButton = NewRegion(frame)
      frame.ResetButton:Hide()
      frame.ResetButton.scripts.OnClick = function(button)
        frame.defaultCallback()
        button:Hide()
      end
      function frame:SetIsDefaultCallback(callback)
        self.isDefaultCallback = callback
      end
      function frame:SetDefaultCallback(callback)
        self.defaultCallback = callback
      end
      function frame:ValidateResetState()
        if self.isDefaultCallback then
          self.ResetButton:SetShown(not self.isDefaultCallback())
        end
      end
      function frame:SetupMenu(generator)
        self.menuGenerator = generator
      end
      function frame:OpenMenu()
        local root = NewMenu(nil, function()
          frame:ValidateResetState()
        end)
        self.menuGenerator(self, root)
        self:ValidateResetState()
        return root
      end
    end

    return frame
  end

  -- Like Blizzard's object pools, the reset runs on each new object and on each one released.
  function CreateObjectPool(create, reset)
    local active, inactive = {}, {}
    local pool = {}
    function pool:Acquire()
      local object = table.remove(inactive)
      if not object then
        object = create(self)
        reset(self, object, true)
      end
      active[#active + 1] = object
      return object
    end
    function pool:ReleaseAll()
      for _, object in ipairs(active) do
        reset(self, object, false)
        inactive[#inactive + 1] = object
      end
      active = {}
    end
    return pool
  end

  function CreateScrollBoxListLinearView()
    local view = {}
    function view:SetElementExtent(extent)
      self.extent = extent
    end
    function view:SetElementInitializer(template, initializer)
      self.template = template
      self.initializer = initializer
    end
    return view
  end

  -- Like Blizzard's index range provider, each element is just its position.
  function CreateIndexRangeDataProvider(size)
    local elements = {}
    for index = 1, size do
      elements[index] = index
    end
    return { elements = elements }
  end

  ScrollBoxConstants = {
    RetainScrollPosition = true,
    DiscardScrollPosition = false,
  }

  MenuResponse = { Refresh = 2 }

  ScrollBoxListMixin = {
    Event = {
      OnScroll = "Scroll",
    },
  }

  ScrollUtil = {
    InitScrollBoxListWithScrollBar = function(scrollBox, scrollBar, view)
      scrollBox.view = view
      scrollBox.scrollBar = scrollBar
    end,
    RegisterAlternateRowBehavior = function(scrollBox, callback)
      scrollBox.alternateRowCallback = callback
    end,
    InitScrollFrameWithScrollBar = function(scrollFrame, scrollBar)
      scrollFrame.scrollBar = scrollBar
    end,
  }

  function PanelTemplates_DeselectTab(tab)
    tab.selected = false
  end

  function PanelTemplates_SelectTab(tab)
    tab.selected = true
  end

  function PanelTemplates_SetNumTabs(frame, numTabs)
    frame.numTabs = numTabs
  end

  function PanelTemplates_SetTab(frame, id)
    frame.selectedTab = id
    for index, tab in ipairs(frame.Tabs) do
      if index == id then
        PanelTemplates_SelectTab(tab)
      else
        PanelTemplates_DeselectTab(tab)
      end
    end
  end

  SOUNDKIT = { IG_CHARACTER_INFO_TAB = 841, IG_MAINMENU_OPTION_CHECKBOX_ON = 856, LOOT_WINDOW_COIN_SOUND = 120 }
  local playedSounds = {}
  function PlaySound(soundKitID)
    playedSounds[#playedSounds + 1] = soundKitID
  end

  -- Work never runs out of its frame budget unless a test makes each clock read take time.
  local profileClock = 0
  local profileStep = 0
  function debugprofilestop()
    profileClock = profileClock + profileStep
    return profileClock
  end

  function PanelTemplates_TabResize() end

  function hooksecurefunc(target, methodName, callback)
    local original = target[methodName]
    target[methodName] = function(...)
      original(...)
      callback(...)
    end
  end

  function time()
    return currentTime
  end

  -- What the addon says in chat.
  local chatMessages = {}
  function print(message)
    chatMessages[#chatMessages + 1] = message
  end

  -- The Auction House's search: what each commodity has listed, cheapest first, as
  -- { unitPrice, quantity, numOwnerItems }, and the searches sent. A test answers a search by firing
  -- COMMODITY_SEARCH_RESULTS_UPDATED.
  local commodityListings = {}
  local sentSearches = {}
  local auctionHouseReady = true
  -- What isn't a commodity: each item's auctions as { auctionID, quantity, buyoutAmount }, answered by
  -- firing ITEM_SEARCH_RESULTS_UPDATED with its item key.
  local itemAuctions = {}
  local nonCommodities = {}
  -- Purchases the addon asked for, in order, as { call, ... }.
  local purchaseCalls = {}
  local money = 1000000
  function GetMoney()
    return money
  end
  C_AuctionHouse = {
    GetItemKeyInfo = function(itemKey)
      return { itemID = itemKey.itemID, isCommodity = not nonCommodities[itemKey.itemID] }
    end,
    GetNumItemSearchResults = function(itemKey)
      return #(itemAuctions[itemKey.itemID] or {})
    end,
    GetItemSearchResultInfo = function(itemKey, index)
      local auction = itemAuctions[itemKey.itemID][index]
      return {
        itemKey = itemKey,
        auctionID = auction[1],
        quantity = auction[2],
        buyoutAmount = auction[3],
        containsOwnerItem = false,
      }
    end,
    HasFullItemSearchResults = function()
      return true
    end,
    StartCommoditiesPurchase = function(itemID, quantity)
      purchaseCalls[#purchaseCalls + 1] = { "start", itemID, quantity }
    end,
    ConfirmCommoditiesPurchase = function(itemID, quantity)
      purchaseCalls[#purchaseCalls + 1] = { "confirm", itemID, quantity }
    end,
    CancelCommoditiesPurchase = function()
      purchaseCalls[#purchaseCalls + 1] = { "cancel" }
    end,
    GetQuoteDurationRemaining = function()
      return 30
    end,
    PlaceBid = function(auctionID, bid)
      purchaseCalls[#purchaseCalls + 1] = { "bid", auctionID, bid }
    end,
    IsThrottledMessageSystemReady = function()
      return auctionHouseReady
    end,
    MakeItemKey = function(itemID)
      return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end,
    SendSearchQuery = function(itemKey, sorts, separateOwnerItems)
      assert(sorts[1].sortOrder == Enum.AuctionHouseSortOrder.Price and not separateOwnerItems)
      sentSearches[#sentSearches + 1] = itemKey.itemID
    end,
    GetNumCommoditySearchResults = function(itemID)
      return #(commodityListings[itemID] or {})
    end,
    GetCommoditySearchResultInfo = function(itemID, index)
      local listing = commodityListings[itemID][index]
      return { itemID = itemID, unitPrice = listing[1], quantity = listing[2], numOwnerItems = listing[3] or 0 }
    end,
    HasFullCommoditySearchResults = function()
      return true
    end,
  }

  C_CurrencyInfo = {
    GetCoinTextureString = function(value)
      assert(value >= 0, "only passes nonnegative values to the coin formatter")
      return tostring(value) .. "c"
    end,
  }

  WHITE_FONT_COLOR = {
    GetRGB = function()
      return 1, 1, 1
    end,
  }

  NORMAL_FONT_COLOR = {
    GetRGB = function()
      return 1, 0.82, 0
    end,
  }

  local itemInfo = {
    [100] = { "Flask", "item:100", 1, 1, 1, "", "", 20, "", 1000 },
  }
  -- How many of each item are in your bags and banks.
  local ownedItems = {}
  -- Instant item data by item ID; every item the client knows about has it, cached or not.
  local itemClasses = {}
  local itemSubClasses = {}
  local itemEquipLocs = {}
  local itemClassNames = { [0] = "Consumable", [2] = "Weapon", [4] = "Armor", [7] = "Tradeskill" }
  local itemSubClassNames = {
    [2] = { [7] = "One-Handed Swords" },
    [4] = { [1] = "Cloth", [4] = "Plate", [8] = "Idols" },
    [7] = { [0] = "Trade Goods" },
  }
  local qualityColors = {
    [1] = { 1, 1, 1, "ffffffff" },
    [2] = { 0.12, 1, 0, "ff1eff00" },
    [3] = { 0, 0.44, 0.87, "ff0070dd" },
    [4] = { 0.64, 0.21, 0.93, "ffa335ee" },
  }
  ITEM_QUALITY1_DESC, ITEM_QUALITY2_DESC = "Common", "Uncommon"
  ITEM_QUALITY3_DESC, ITEM_QUALITY4_DESC = "Rare", "Epic"
  INVTYPE_HEAD, INVTYPE_CHEST, INVTYPE_ROBE, INVTYPE_WEAPON = "Head", "Chest", "Chest", "One-Hand"
  INVTYPE_RELIC = "Relic"
  ITEM_MOD_STRENGTH_SHORT, ITEM_MOD_STAMINA_SHORT = "Strength", "Stamina"
  ITEM_MOD_AGILITY_SHORT = "Agility"
  ITEM_MOD_INTELLECT_SHORT, ITEM_MOD_SPIRIT_SHORT = "Intellect", "Spirit"
  ITEM_MOD_ATTACK_POWER_SHORT, RESISTANCE2_NAME = "Attack Power", "Fire Resistance"
  RESISTANCE0_NAME, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "Armor", "Damage Per Second"
  -- Stats by item link or item ID, as GetItemStats reports them for loaded items.
  local itemStats = {}
  -- WoW Forever's item enums.
  Enum = {
    ItemClass = { Weapon = 2, Armor = 4 },
    ItemWeaponSubclass = {
      Axe1H = 0,
      Axe2H = 1,
      Bows = 2,
      Guns = 3,
      Mace1H = 4,
      Mace2H = 5,
      Polearm = 6,
      Sword1H = 7,
      Sword2H = 8,
      Warglaive = 9,
      Staff = 10,
      Unarmed = 13,
      Generic = 14,
      Dagger = 15,
      Thrown = 16,
      Crossbow = 18,
      Wand = 19,
      Fishingpole = 20,
    },
    ItemArmorSubclass = { Libram = 7, Idol = 8, Totem = 9, Sigil = 10, Relic = 11 },
    AuctionHouseSortOrder = { Price = 0 },
  }

  ---@param item number|string an item ID or item string
  local function LookupItemInfo(item)
    if type(item) == "string" then
      return itemInfo[item] or itemInfo[tonumber(item:match("^item:(%d+)"))]
    end
    return itemInfo[item]
  end

  C_Item = {
    GetItemInfo = function(item)
      local info = LookupItemInfo(item)
      if info then
        return unpack(info)
      end
    end,
    GetItemInfoInstant = function(itemID)
      if itemClasses[itemID] then
        return itemID, "", "", itemEquipLocs[itemID] or "", 0, itemClasses[itemID], itemSubClasses[itemID] or 0
      end
    end,
    GetItemClassInfo = function(classID)
      return itemClassNames[classID]
    end,
    GetItemSubClassInfo = function(classID, subClassID)
      return itemSubClassNames[classID] and itemSubClassNames[classID][subClassID]
    end,
    GetItemStats = function(link)
      if LookupItemInfo(link) then
        return itemStats[link] or itemStats[tonumber(link:match("^item:(%d+)"))] or {}
      end
    end,
    GetItemQualityColor = function(quality)
      return unpack(qualityColors[quality] or { 1, 1, 1 })
    end,
    IsItemDataCachedByID = function(itemID)
      return itemInfo[itemID] ~= nil
    end,
    -- Icons are known without loading the item; a test item's icon is its ID plus 1000.
    GetItemIconByID = function(itemID)
      return itemID + 1000
    end,
    RequestLoadItemDataByID = function(itemID)
      requestedItemIDs[#requestedItemIDs + 1] = itemID
    end,
    -- Counts every place the shopping list asks about: bags, bank, reagent bank, and account bank.
    GetItemCount = function(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
      assert(includeBank and not includeUses and includeReagentBank and includeAccountBank, "counts every bank")
      return ownedItems[itemID] or 0
    end,
  }

  GameTooltip = {
    SetOwner = function(self, owner, anchor)
      self.owner = owner
      self.anchor = anchor
    end,
    IsOwned = function(self, owner)
      return self.owner == owner
    end,
    SetHyperlink = function(self, link)
      self.hyperlink = link
    end,
    AddLine = function(_, text)
      tooltipLines[#tooltipLines + 1] = text
    end,
    AddDoubleLine = function(_, left, right)
      tooltipDoubleLines[#tooltipDoubleLines + 1] = { left, right }
    end,
    Show = function() end,
    Hide = function()
      tooltipHideCalls = tooltipHideCalls + 1
      GameTooltip.owner = nil
      GameTooltip.anchor = nil
    end,
  }

  -- Like Blizzard's handler with the default bindings: Shift-clicking an item links it in chat.
  local heldModifier
  local chatLinks = {}
  function IsModifierKeyDown()
    return heldModifier ~= nil
  end
  function IsShiftKeyDown()
    return heldModifier == "SHIFT"
  end

  -- Each context menu opened, as its owner and the entries its generator added; Pick runs one.
  local contextMenus = {}
  MenuUtil = {
    CreateContextMenu = function(owner, generator)
      local menu = { owner = owner, entries = {} }
      function menu:CreateButton(label, callback)
        local entry = { label = label, Pick = callback }
        self.entries[#self.entries + 1] = entry
        return entry
      end
      generator(owner, menu)
      contextMenus[#contextMenus + 1] = menu
      return menu
    end,
  }

  -- Each dialog shown, by name, with its text filled in as the game does; Accept runs its OnAccept
  -- with the data it was shown with.
  local shownDialogs = {}
  YES, NO, CANCEL = "Yes", "No", "Cancel"
  -- An atlas drawn in text, as the game marks it up.
  function CreateAtlasMarkup(atlas, width, height)
    return ("|A:%s:%d:%d|a"):format(atlas, height, width)
  end
  -- The game's clock, in seconds; nothing here waits on it.
  function GetTime()
    return 0
  end
  StaticPopupDialogs = {}
  function StaticPopup_Show(name, text1, text2, data)
    local dialog = StaticPopupDialogs[name]
    shownDialogs[#shownDialogs + 1] = {
      name = name,
      text = dialog.text:format(text1, text2),
      Accept = function()
        dialog.OnAccept({}, data)
      end,
    }
  end
  function HandleModifiedItemClick(link)
    if link and heldModifier == "SHIFT" then
      chatLinks[#chatLinks + 1] = link
      return true
    end
    return false
  end

  AuctionHouseFrame = {
    BuyTab = {},
    SellTab = {},
    AuctionsTab = {},
  }
  AuctionHouseFrame.Tabs = {
    AuctionHouseFrame.BuyTab,
    AuctionHouseFrame.SellTab,
    AuctionHouseFrame.AuctionsTab,
  }

  function AuctionHouseFrame:IsShown()
    return auctionHouseShown
  end

  function AuctionHouseFrame:SetDisplayMode() end

  function AuctionHouseFrame:SetTitle(title)
    windowTitle = title
  end

  local databaseStatus = {
    latestScan = 123,
    latestQuickScan = 123,
    recentScanCount = 2,
  }

  local scanStatus = {
    phase = "idle",
  }
  local cancelCalls = 0
  local lastScanOutcome
  local atNeutralAuctionHouse = false

  local opportunityResult = {
    totalCount = 4,
    pricedCount = 2,
    profitableCount = 2,
    items = {
      {
        itemID = 200,
        outputQuantity = 1,
        recipeKey = "item-200",
        saleMethod = "auction",
        craftCost = 90,
        profit = 5,
        craftCostIsUncertain = false,
        materials = {
          [201] = { itemID = 201, name = "Iron Bar", quantity = 2, price = 45, source = "auction" },
        },
        sources = {
          { characterName = "Main", professionName = "Blacksmithing", recipeKey = "item-200" },
        },
        reasons = { "limited scans" },
        isUncertain = true,
      },
      {
        itemID = 100,
        outputQuantity = 2,
        recipeKey = "shared",
        saleMethod = "auction",
        craftCost = 80,
        profit = 110,
        perCraft = { saleProceeds = 380, craftCost = 160, profit = 220 },
        materials = {
          [101] = { itemID = 101, name = "Herb", quantity = 1.5, price = 40, source = "auction" },
          [102] = { itemID = 102, name = "Empty Vial", quantity = 0.5, price = 40, source = "vendor" },
        },
        buyoutCraftCost = 70,
        buyoutSaleMethod = "auction",
        buyoutProfit = 101,
        buyoutMaterials = {
          [101] = { itemID = 101, name = "Herb", quantity = 1.5, price = 30, source = "auction" },
          [102] = { itemID = 102, name = "Empty Vial", quantity = 0.5, price = 40, source = "vendor" },
        },
        sources = {
          { characterName = "Alt", professionName = "Alchemy", recipeKey = "shared" },
          { characterName = "Main", professionName = "Alchemy", recipeKey = "shared" },
        },
        reasons = {},
        isUncertain = false,
      },
    },
  }

  -- The price database the Database tab reads: stored scans, latest buyouts, and market values,
  -- with each item's daily prices for its details.
  local databaseItems = {}
  local latestBuyouts = {}
  local dailyValues = {}
  local marketValues = {}
  -- Units listed by key, and region-wide sales by item ID as { averagePrice, saleRate }.
  local listed = {}
  local sales = {}
  -- Crafting costs at Market Value and at Buyout prices, and the recipes each Buyout cost was
  -- asked to use.
  local craftingCosts = {}
  local scanCraftingCosts = {}
  local scanCostRecipeKeys = {}
  -- The recipes your characters know by the item they make, matching the default opportunities:
  -- a Flask craft makes two from three Herbs and an Empty Vial, and the craft of item 200 uses two
  -- Iron Bars.
  local recipes = {
    [100] = {
      {
        recipeKey = "shared",
        outputItemID = 100,
        outputQuantity = 2,
        reagents = {
          { itemID = 101, quantity = 3, name = "Herb" },
          { itemID = 102, quantity = 1, name = "Empty Vial" },
        },
      },
    },
    [200] = {
      {
        recipeKey = "item-200",
        outputItemID = 200,
        outputQuantity = 1,
        reagents = { { itemID = 201, quantity = 2, name = "Iron Bar" } },
      },
    },
  }
  -- Who knows each recipe, by the item it makes.
  local recipeSources = {}
  -- The make-or-buy choices behind each craft's costs, by item ID, and what each was asked for.
  local craftingChoices = {}
  local refreshedChoices = {}
  local choiceRequests = {}
  -- Vendor prices of materials, beside the Buyouts in latestBuyouts.
  local vendorPrices = {}

  local ns = {
    Crafting = {
      GetCostForItemID = function(itemID)
        return craftingCosts[itemID]
      end,
      GetScanCostForItemID = function(itemID, recipeKeys)
        scanCostRecipeKeys[itemID] = recipeKeys or "any"
        return scanCraftingCosts[itemID]
      end,
      -- With refreshed prices, the choices those prices make cheapest.
      GetChoices = function(itemID, recipeKey, atBuyout, unitPrice)
        choiceRequests[#choiceRequests + 1] =
          { itemID = itemID, recipeKey = recipeKey, atBuyout = atBuyout, unitPrice = unitPrice }
        if unitPrice then
          return refreshedChoices[itemID]
        end
        return craftingChoices[itemID]
      end,
      -- Like the real lookup: the vendor when it's cheaper than the Buyout.
      GetBuyoutPurchasePrice = function(itemID)
        local buyout, vendor = latestBuyouts[tostring(itemID)], vendorPrices[itemID]
        if vendor and (buyout == nil or vendor < buyout) then
          return { value = vendor, source = "vendor" }
        end
        return buyout and { value = buyout, source = "auction" } or nil
      end,
    },
    Database = {
      IsIgnoredItem = function(itemID)
        return select(3, C_Item.GetItemInfo(itemID)) == 0
      end,
      GetStatus = function()
        return databaseStatus
      end,
      GetItemKeys = function()
        local keys = {}
        for dbKey in pairs(databaseItems) do
          keys[#keys + 1] = dbKey
        end
        table.sort(keys)
        return keys
      end,
      Get = function(dbKey)
        local itemID = tonumber(dbKey) or tonumber(dbKey:match("^equip:(%d+):"))
        if select(3, C_Item.GetItemInfo(itemID)) ~= 0 then
          return databaseItems[dbKey]
        end
      end,
      GetLatestBuyout = function(dbKey)
        return latestBuyouts[dbKey]
      end,
      GetDailyValues = function(dbKey)
        return dailyValues[dbKey] or {}
      end,
      GetLastSeen = function(dbKey)
        return databaseItems[dbKey] and databaseItems[dbKey].latest
      end,
      GetListed = function(dbKey)
        return listed[dbKey]
      end,
      -- Rows pass the history Get returned, so its key is the one that holds it.
      GetListedIn = function(history)
        for dbKey, item in pairs(databaseItems) do
          if item == history then
            return listed[dbKey]
          end
        end
      end,
      GetFirstDay = function()
        return 0
      end,
      GetSales = function(dbKey)
        return unpack(sales[tonumber(dbKey)] or {})
      end,
      HasSales = function()
        return next(sales) ~= nil
      end,
    },
    RollingMarketValue = {
      Get = function(dbKeys)
        return marketValues[dbKeys[1]]
      end,
    },
    Opportunities = {
      AUCTION_HOUSE_CUT_RATE = 0.05,
      HandleItemInfoReceived = function(itemID, success)
        local wasPending = pendingSaleItemIDs[itemID]
        pendingSaleItemIDs[itemID] = nil
        return wasPending and success or false
      end,
      Get = function()
        opportunityCalls = opportunityCalls + 1
        return opportunityResult
      end,
    },
    RecipeBook = {
      GetProfessionNames = function()
        return { "Alchemy", "Blacksmithing" }
      end,
      GetCharacterNames = function()
        return { "Alt", "Main" }
      end,
      GetRecipes = function(itemID)
        return recipes[itemID] or {}
      end,
      GetSources = function(itemID)
        return recipeSources[itemID] or {}
      end,
    },
    Realm = {
      GetName = function()
        return "Test Realm"
      end,
      GetCharacterName = function()
        return "Main"
      end,
    },
    Scan = {
      GetStatus = function()
        return scanStatus
      end,
      Start = function()
        scanCalls = scanCalls + 1
      end,
      StartQuick = function()
        quickScanCalls = quickScanCalls + 1
      end,
      Cancel = function()
        cancelCalls = cancelCalls + 1
      end,
      GetLastOutcome = function(kind)
        return kind ~= "quick" and lastScanOutcome or nil
      end,
      IsAtNeutralAuctionHouse = function()
        return atNeutralAuctionHouse
      end,
    },
  }

  strmatch = string.match
  strlower = string.lower
  function strtrim(value)
    return value:match("^%s*(.-)%s*$")
  end
  WOW_PROJECT_CAMELOT = 18
  WOW_PROJECT_ID = WOW_PROJECT_CAMELOT
  WOW_PROJECT_MAINLINE = 1
  assert(loadfile("libs/LibAHTab/LibStub/LibStub.lua"), "loads LibStub")()
  assert(loadfile("libs/LibAHTab/LibAHTab.lua"), "loads LibAHTab")()
  assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
  assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
  ns.Config.Init()
  ns.Config.OpenOptionsPanel = function()
    settingsCalls = settingsCalls + 1
  end
  assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
  assert(loadfile("src/ItemTable.lua"), "loads ItemTable.lua")("Arbitrage", ns)
  assert(loadfile("src/PriceChart.lua"), "loads PriceChart.lua")("Arbitrage", ns)
  assert(loadfile("src/ItemDetails.lua"), "loads ItemDetails.lua")("Arbitrage", ns)
  assert(loadfile("src/OpportunityTable.lua"), "loads OpportunityTable.lua")("Arbitrage", ns)
  assert(loadfile("src/OpportunityPanel.lua"), "loads OpportunityPanel.lua")("Arbitrage", ns)
  assert(loadfile("src/Keys.lua"), "loads Keys.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabaseIndex.lua"), "loads DatabaseIndex.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabaseFilters.lua"), "loads DatabaseFilters.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabasePanel.lua"), "loads DatabasePanel.lua")("Arbitrage", ns)
  assert(loadfile("src/ShoppingList.lua"), "loads ShoppingList.lua")("Arbitrage", ns)
  assert(loadfile("src/ShoppingSearch.lua"), "loads ShoppingSearch.lua")("Arbitrage", ns)
  assert(loadfile("src/ShoppingPurchase.lua"), "loads ShoppingPurchase.lua")("Arbitrage", ns)
  assert(loadfile("src/ShoppingPanel.lua"), "loads ShoppingPanel.lua")("Arbitrage", ns)
  assert(loadfile("src/Window.lua"), "loads Window.lua")("Arbitrage", ns)
  ARBITRAGE_SHOPPING = nil
  ns.ShoppingList.Init()
  ns.ShoppingList.Register()
  ns.OpportunityPanel.Register()
  ns.ShoppingSearch.Register()
  ns.ShoppingPurchase.Register()
  ns.ShoppingPanel.Register()

  local function IsDescendantOf(region, ancestor)
    local current = region and region.parent
    while current do
      if current == ancestor then
        return true
      end
      current = current.parent
    end
    return false
  end

  -- The item details panel beside a tab has its own insets and scroll bar, which aren't the tab's.
  local function IsInsideDetails(region, panel)
    local current = region.parent
    while current and current ~= panel do
      if current.template == "PortraitFrameTemplate" then
        return true
      end
      current = current.parent
    end
    return false
  end

  local function FindComponents(targetPanel)
    local panel = targetPanel
    if not panel then
      for _, frame in ipairs(createdFrames) do
        if frame.name == "ArbitrageAuctionHouseFrame" then
          panel = frame
          break
        end
      end
    end

    local components = { panel = panel, headers = {} }
    for _, frame in ipairs(createdFrames) do
      if frame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
        components.tab = frame
      elseif frame.template == "PanelTopTabButtonTemplate" and frame.parent == panel then
        components.viewTabs = components.viewTabs or {}
        components.viewTabs[#components.viewTabs + 1] = frame
      elseif
        panel
        and not components.content
        and frame.parent == panel
        and frame.frameType == "Frame"
        and frame.template == nil
        and frame.layoutType == nil
      then
        -- The Opportunities panel's holder for every control and its table, made before the
        -- Auction House tab's shopping list.
        components.content = frame
      end
    end

    -- Controls belong to the Opportunities content, or to the panel when it has none.
    local root = components.content or panel
    for _, frame in ipairs(createdFrames) do
      if root and IsDescendantOf(frame, root) and not IsInsideDetails(frame, root) then
        if frame.layoutType == "InsetFrameTemplate" then
          components.tableBackground = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text and frame.text:find("^Full Scan", 1, false) then
          components.scanButton = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Quick Scan" then
          components.quickScanButton = frame
        elseif frame.template == "WowStyle1FilterDropdownTemplate" then
          components.filterDropdown = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Settings" then
          components.settingsButton = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text == "?" then
          components.glossaryButton = frame
        elseif frame.template == "ColumnDisplayButtonShortTemplate" then
          components.headers[frame.text] = frame
        elseif frame.template == "WowScrollBoxList" then
          components.scrollBox = frame
        elseif frame.template == "MinimalScrollBar" then
          components.scrollBar = frame
        elseif frame.template == "SearchBoxTemplate" then
          components.searchBox = frame
        end
      end
    end
    return components
  end

  -- The standalone window's tab contents, in tab order.
  local function GetWindowContents()
    local contents = {}
    for _, frame in ipairs(createdFrames) do
      if frame.parent == _G.ArbitrageWindow and frame.frameType == "Frame" and frame.template == nil then
        contents[#contents + 1] = frame
      end
    end
    return contents
  end

  local COIN_LETTERS = { Gold = "g", Silver = "s", Copper = "c" }

  -- Reads a table money string with its coin icons as letters: "1g 05s 07c".
  local function PlainMoney(text)
    return (text:gsub("|TInterface\\MoneyFrame\\UI%-(%a+)Icon:12:12:2:0|t", COIN_LETTERS))
  end

  local function RunTimers()
    local queued = { unpack(timers) }
    for index = #timers, 1, -1 do
      timers[index] = nil
    end
    for _, callback in ipairs(queued) do
      callback()
    end
  end

  return {
    ns = ns,
    createdFrames = createdFrames,
    createdFontStrings = createdFontStrings,
    createdTextures = createdTextures,
    createdLines = createdLines,
    requestedItemIDs = requestedItemIDs,
    tooltipLines = tooltipLines,
    tooltipDoubleLines = tooltipDoubleLines,
    chatLinks = chatLinks,
    -- The modifier key held during later clicks, such as "SHIFT", or nil for plain clicks.
    SetHeldModifier = function(modifier)
      heldModifier = modifier
    end,
    pendingSaleItemIDs = pendingSaleItemIDs,
    timers = timers,
    RunTimers = RunTimers,
    PlainMoney = PlainMoney,
    -- Runs frame after frame, letting delays pass once nothing runs sooner, until no more work is
    -- scheduled; returns the number of frames.
    RunAllTimers = function()
      local frames = 0
      while #timers > 0 or #delayedTimers > 0 do
        if #timers == 0 then
          for index, callback in ipairs(delayedTimers) do
            timers[index] = callback
          end
          delayedTimers = {}
        end
        frames = frames + 1
        assert(frames < 1000, "background work finishes")
        RunTimers()
      end
      return frames
    end,
    SetProfileStep = function(milliseconds)
      profileStep = milliseconds
    end,
    itemInfo = itemInfo,
    itemClasses = itemClasses,
    itemSubClasses = itemSubClasses,
    itemEquipLocs = itemEquipLocs,
    itemStats = itemStats,
    databaseItems = databaseItems,
    latestBuyouts = latestBuyouts,
    dailyValues = dailyValues,
    marketValues = marketValues,
    listed = listed,
    sales = sales,
    craftingCosts = craftingCosts,
    scanCraftingCosts = scanCraftingCosts,
    scanCostRecipeKeys = scanCostRecipeKeys,
    recipes = recipes,
    recipeSources = recipeSources,
    craftingChoices = craftingChoices,
    refreshedChoices = refreshedChoices,
    choiceRequests = choiceRequests,
    vendorPrices = vendorPrices,
    ownedItems = ownedItems,
    contextMenus = contextMenus,
    shownDialogs = shownDialogs,
    commodityListings = commodityListings,
    sentSearches = sentSearches,
    chatMessages = chatMessages,
    itemAuctions = itemAuctions,
    nonCommodities = nonCommodities,
    purchaseCalls = purchaseCalls,
    SetMoney = function(copper)
      money = copper
    end,
    SetAuctionHouseReady = function(ready)
      auctionHouseReady = ready
    end,
    playedSounds = playedSounds,
    GetWindowContents = GetWindowContents,
    databaseStatus = databaseStatus,
    auctionHouseFrame = AuctionHouseFrame,
    FireEvent = function(eventName, ...)
      if eventName == "AUCTION_HOUSE_SHOW" then
        auctionHouseShown = true
      elseif eventName == "AUCTION_HOUSE_CLOSED" then
        auctionHouseShown = false
      end
      for _, frame in ipairs(eventFrames) do
        if frame.registeredEvents[eventName] and frame.scripts.OnEvent then
          frame.scripts.OnEvent(frame, eventName, ...)
        end
      end
    end,
    FindComponents = FindComponents,
    SetOpportunityResult = function(result)
      opportunityResult = result
    end,
    SetScanStatus = function(status)
      scanStatus = status
    end,
    SetLastScanOutcome = function(outcome)
      lastScanOutcome = outcome
    end,
    SetAtNeutralAuctionHouse = function(atNeutral)
      atNeutralAuctionHouse = atNeutral
    end,
    GetCancelCalls = function()
      return cancelCalls
    end,
    SetCurrentTime = function(value)
      currentTime = value
    end,
    GetOpportunityCalls = function()
      return opportunityCalls
    end,
    GetTooltipHideCalls = function()
      return tooltipHideCalls
    end,
    GetWindowTitle = function()
      return windowTitle
    end,
    GetScanCalls = function()
      return scanCalls
    end,
    GetQuickScanCalls = function()
      return quickScanCalls
    end,
    GetSettingsCalls = function()
      return settingsCalls
    end,
  }
end

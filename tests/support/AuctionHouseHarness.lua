return function()
  local eventFrames = {}
  local createdFrames = {}
  local createdFontStrings = {}
  local windowTitle
  local auctionHouseShown = false
  local scanCalls = 0
  local settingsCalls = 0
  local requestedItemIDs = {}
  local opportunityCalls = 0
  local currentTime = 200
  local tooltipHideCalls = 0
  local tooltipLines = {}
  local tooltipDoubleLines = {}
  local pendingSaleItemIDs = {}
  local timers = {}

  C_Timer = {
    After = function(seconds, callback)
      assert(seconds == 0, "batches price refreshes until the next frame")
      timers[#timers + 1] = callback
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

    function region:SetTextColor(...)
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

    function region:SetTexCoord(...)
      self.texCoord = { ... }
    end

    function region:SetHitRectInsets() end

    function region:SetAtlas(atlas, useAtlasSize)
      self.atlas = atlas
      self.useAtlasSize = useAtlasSize
    end

    function region:SetBlendMode(blendMode)
      self.blendMode = blendMode
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
      function texture:SetTexture(value)
        self.texture = value
      end
      function texture:SetColorTexture(...) end
      return texture
    end

    return region
  end

  UIParent = NewRegion()
  UISpecialFrames = {}

  function CreateFrame(frameType, name, parent, template)
    local frame = NewRegion(parent, template)
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
    elseif template == "PanelTabButtonTemplate" then
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
        local function NewMenu(label)
          local menu = { label = label, entries = {} }
          local function AddItem(_, itemLabel, isSelected, onSelect, data)
            local item = {
              label = itemLabel,
              value = data,
              IsSelected = function()
                return isSelected(data)
              end,
              Pick = function()
                onSelect(data)
                frame:ValidateResetState()
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
            local submenu = NewMenu(buttonLabel)
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
        local root = NewMenu()
        self.menuGenerator(self, root)
        self:ValidateResetState()
        return root
      end
    end

    return frame
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

  SOUNDKIT = { IG_CHARACTER_INFO_TAB = 841 }
  local playedSounds = {}
  function PlaySound(soundKitID)
    playedSounds[#playedSounds + 1] = soundKitID
  end

  BreakUpLargeNumbers = tostring

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
    RequestLoadItemDataByID = function(itemID)
      requestedItemIDs[#requestedItemIDs + 1] = itemID
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
        saleMethod = "auction",
        saleProceeds = 95,
        auctionSaleProceeds = 95,
        vendorSaleProceeds = 80,
        craftCost = 90,
        profit = 5,
        roi = 0.055,
        marketIsUncertain = true,
        craftCostIsUncertain = false,
        minimumCraftCostIsUncertain = false,
        sources = {
          { characterName = "Main", professionName = "Blacksmithing", recipeKey = "item-200" },
        },
        reasons = { "limited scans" },
        isUncertain = true,
      },
      {
        itemID = 100,
        outputQuantity = 2,
        saleMethod = "auction",
        saleProceeds = 190,
        auctionSaleProceeds = 190,
        vendorSaleProceeds = 70,
        craftCost = 80,
        profit = 110,
        roi = 1.375,
        minimumCraftCost = 60,
        minimumProfit = 130,
        sources = {
          { characterName = "Alt", professionName = "Alchemy", recipeKey = "shared" },
          { characterName = "Main", professionName = "Alchemy", recipeKey = "shared" },
        },
        reasons = {},
        isUncertain = false,
      },
    },
  }

  -- The price database the Database tab reads: stored scans, latest buyouts, and market values.
  local databaseItems = {}
  local latestBuyouts = {}
  local marketValues = {}
  local craftingCosts = {}

  local ns = {
    Crafting = {
      GetCostForItemID = function(itemID)
        return craftingCosts[itemID]
      end,
    },
    Database = {
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
        return databaseItems[dbKey]
      end,
      GetLatestBuyout = function(dbKey)
        return latestBuyouts[dbKey]
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
    },
    Realm = {
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
      Cancel = function()
        cancelCalls = cancelCalls + 1
      end,
      GetLastOutcome = function()
        return lastScanOutcome
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
  assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
  ns.Config.Init()
  ns.Config.OpenOptionsPanel = function()
    settingsCalls = settingsCalls + 1
  end
  assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
  assert(loadfile("src/ItemTable.lua"), "loads ItemTable.lua")("Arbitrage", ns)
  assert(loadfile("src/OpportunityTable.lua"), "loads OpportunityTable.lua")("Arbitrage", ns)
  assert(loadfile("src/OpportunityPanel.lua"), "loads OpportunityPanel.lua")("Arbitrage", ns)
  assert(loadfile("src/Keys.lua"), "loads Keys.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabaseIndex.lua"), "loads DatabaseIndex.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabaseFilters.lua"), "loads DatabaseFilters.lua")("Arbitrage", ns)
  assert(loadfile("src/DatabasePanel.lua"), "loads DatabasePanel.lua")("Arbitrage", ns)
  assert(loadfile("src/Window.lua"), "loads Window.lua")("Arbitrage", ns)
  ns.OpportunityPanel.Register()

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
      elseif
        panel
        and frame.parent == panel
        and frame.frameType == "Frame"
        and frame.template == nil
        and frame.layoutType == nil
      then
        -- The Opportunities panel's holder for every control and its table.
        components.content = frame
      elseif panel and IsDescendantOf(frame, panel) then
        if frame.layoutType == "InsetFrameTemplate" then
          components.tableBackground = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text and frame.text:find("^Full Scan", 1, false) then
          components.scanButton = frame
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
    -- Runs frame after frame until no more work is scheduled; returns the number of frames.
    RunAllTimers = function()
      local frames = 0
      while #timers > 0 do
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
    marketValues = marketValues,
    craftingCosts = craftingCosts,
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
    GetSettingsCalls = function()
      return settingsCalls
    end,
  }
end

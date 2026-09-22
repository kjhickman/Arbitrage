return function()
  local onEvent
  local events = {}
  local createdFrames = {}
  local createdFontStrings = {}
  local resizedTab
  local selectedDisplayMode
  local windowTitle
  local scanCalls = 0
  local settingsCalls = 0
  local requestedItemIDs = {}
  local opportunityCalls = 0
  local currentTime = 200
  local tooltipHideCalls = 0
  local tooltipLines = {}

  local function NewRegion(parent, template)
    local region = {
      parent = parent,
      template = template,
      points = {},
      scripts = {},
    }

    function region:SetScript(scriptName, callback)
      self.scripts[scriptName] = callback
    end

    function region:SetPoint(...)
      self.points[#self.points + 1] = { ... }
    end

    function region:ClearAllPoints()
      self.points = {}
    end

    function region:SetSize(width, height)
      self.width = width
      self.height = height
    end

    function region:SetWidth(width)
      self.width = width
    end

    function region:SetText(text)
      self.text = text
    end

    function region:SetTextColor(red, green, blue)
      self.textColor = { red, green, blue }
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
      self.shown = shown
    end

    function region:SetTexCoord(...)
      self.texCoord = { ... }
    end

    function region:SetHitRectInsets(...)
      self.hitRectInsets = { ... }
    end

    function region:SetAtlas(atlas)
      self.atlas = atlas
    end

    function region:Hide()
      self.shown = false
    end

    function region:Show()
      self.shown = true
      if self.scripts.OnShow then
        self.scripts.OnShow(self)
      end
    end

    function region:Click()
      if self.scripts.OnClick then
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
      return texture
    end

    return region
  end

  function CreateFrame(frameType, name, parent, template)
    local frame = NewRegion(parent, template)
    frame.frameType = frameType
    frame.name = name
    createdFrames[#createdFrames + 1] = frame

    function frame:IsObjectType(objectType)
      return objectType == "Frame" or objectType == frameType
    end

    if parent == nil then
      function frame:RegisterEvent(eventName)
        events[eventName] = true
      end
      function frame:SetScript(_, callback)
        onEvent = callback
      end
    elseif template == "AuctionHouseFrameDisplayModeTabTemplate" then
      frame.scripts.OnClick = function(self)
        self.parent:SetDisplayMode(self.displayMode)
      end
    end

    if template == "AuctionHouseTableHeaderStringTemplate" then
      frame.Arrow = NewRegion(frame)
    elseif template == "AuctionHouseItemListLineTemplate" then
      frame.HighlightTexture = NewRegion(frame)
      frame.normalTexture = NewRegion(frame)
      frame.scripts.OnClick = function()
        error("native Auction House rows require an AuctionHouseItemList parent")
      end
      function frame:GetNormalTexture()
        return self.normalTexture
      end
      function frame:GetElementData()
        return self.elementData
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
            row = CreateFrame("Button", nil, self, self.view.template)
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
    elseif template == "AuctionHouseBackgroundTemplate" then
      frame.Background = NewRegion(frame)
      frame.NineSlice = NewRegion(frame)
    end

    return frame
  end

  function CreateScrollBoxListLinearView()
    local view = {}
    function view:SetElementInitializer(template, initializer)
      self.template = template
      self.initializer = initializer
    end
    return view
  end

  function CreateDataProvider(elements)
    return { elements = elements }
  end

  ScrollBoxConstants = {
    RetainScrollPosition = true,
    DiscardScrollPosition = false,
  }

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

  function PanelTemplates_TabResize(tab, padding, absoluteSize, minimumWidth)
    resizedTab = {
      tab = tab,
      padding = padding,
      absoluteSize = absoluteSize,
      minimumWidth = minimumWidth,
    }
  end

  function hooksecurefunc(target, methodName, callback)
    local original = target[methodName]
    target[methodName] = function(...)
      original(...)
      callback(...)
    end
  end

  function date(format, timestamp)
    assert(format == "%Y-%m-%d %H:%M" and timestamp == 123, "formats the latest scan timestamp")
    return "2026-09-21 10:15"
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

  C_Item = {
    GetItemInfo = function(itemID)
      if itemInfo[itemID] then
        return unpack(itemInfo[itemID])
      end
    end,
    RequestLoadItemDataByID = function(itemID)
      requestedItemIDs[#requestedItemIDs + 1] = itemID
    end,
  }

  GameTooltip = {
    SetOwner = function(self, owner)
      self.owner = owner
    end,
    IsOwned = function(self, owner)
      return self.owner == owner
    end,
    SetHyperlink = function() end,
    AddLine = function(_, text)
      tooltipLines[#tooltipLines + 1] = text
    end,
    AddDoubleLine = function() end,
    Show = function() end,
    Hide = function()
      tooltipHideCalls = tooltipHideCalls + 1
      GameTooltip.owner = nil
    end,
  }

  AuctionHouseFrame = {
    BuyTab = {},
    SellTab = {},
    AuctionsTab = {},
    tabsForDisplayMode = {},
  }
  AuctionHouseFrame.Tabs = {
    AuctionHouseFrame.BuyTab,
    AuctionHouseFrame.SellTab,
    AuctionHouseFrame.AuctionsTab,
  }

  function AuctionHouseFrame:SetDisplayMode(displayMode)
    selectedDisplayMode = displayMode
  end

  function AuctionHouseFrame:SetTitle(title)
    windowTitle = title
  end

  local databaseStatus = {
    latestScan = 123,
    recentScanCount = 2,
  }

  local opportunityResult = {
    totalCount = 4,
    pricedCount = 2,
    items = {
      {
        itemID = 200,
        outputQuantity = 1,
        saleProceeds = 95,
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
        saleProceeds = 190,
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

  local ns = {
    Database = {
      GetStatus = function()
        return databaseStatus
      end,
    },
    Opportunities = {
      Get = function()
        opportunityCalls = opportunityCalls + 1
        return opportunityResult
      end,
    },
    Scan = {
      Start = function()
        scanCalls = scanCalls + 1
      end,
    },
    Config = {
      OpenOptionsPanel = function()
        settingsCalls = settingsCalls + 1
      end,
    },
  }

  strmatch = string.match
  WOW_PROJECT_ID = 1
  WOW_PROJECT_MAINLINE = 1
  assert(loadfile("libs/LibAHTab/LibStub/LibStub.lua"), "loads LibStub")()
  assert(loadfile("libs/LibAHTab/LibAHTab.lua"), "loads LibAHTab")()
  assert(loadfile("src/OpportunityTable.lua"), "loads OpportunityTable.lua")("Arbitrage", ns)
  assert(loadfile("src/AuctionHouse.lua"), "loads AuctionHouse.lua")("Arbitrage", ns)
  ns.AuctionHouse.Register()

  local function FindComponents()
    local components = { headers = {} }
    for _, frame in ipairs(createdFrames) do
      if frame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
        components.tab = frame
      elseif frame.name == "ArbitrageAuctionHouseFrame" then
        components.panel = frame
      elseif frame.template == "AuctionHouseBackgroundTemplate" then
        components.tableBackground = frame
      elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Full Scan" then
        components.scanButton = frame
      elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Settings" then
        components.settingsButton = frame
      elseif frame.template == "AuctionHouseTableHeaderStringTemplate" then
        components.headers[frame.text] = frame
      elseif frame.template == "WowScrollBoxList" then
        components.scrollBox = frame
      elseif frame.template == "MinimalScrollBar" then
        components.scrollBar = frame
      end
    end
    return components
  end

  return {
    ns = ns,
    events = events,
    createdFrames = createdFrames,
    createdFontStrings = createdFontStrings,
    requestedItemIDs = requestedItemIDs,
    tooltipLines = tooltipLines,
    itemInfo = itemInfo,
    databaseStatus = databaseStatus,
    auctionHouseFrame = AuctionHouseFrame,
    FireEvent = function(...)
      onEvent(nil, ...)
    end,
    FindComponents = FindComponents,
    SetOpportunityResult = function(result)
      opportunityResult = result
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
    GetSelectedDisplayMode = function()
      return selectedDisplayMode
    end,
    GetWindowTitle = function()
      return windowTitle
    end,
    GetResizedTab = function()
      return resizedTab
    end,
    GetScanCalls = function()
      return scanCalls
    end,
    GetSettingsCalls = function()
      return settingsCalls
    end,
  }
end

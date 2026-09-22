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
    frame.height = 20
    frame.HighlightTexture = NewRegion(frame)
    frame.HighlightTexture:SetAtlas("auctionhouse-ui-row-highlight")
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

assert(loadfile("src/AuctionHouse.lua"), "loads AuctionHouse.lua")("Arbitrage", ns)
ns.AuctionHouse.Register()
assert(events.AUCTION_HOUSE_SHOW, "waits for the load-on-demand Auction House UI")

onEvent(nil, "AUCTION_HOUSE_SHOW")

local tab
local panel
local tableBackground
local scanButton
local settingsButton
local scrollBox
local scrollBar
local headers = {}
for _, frame in ipairs(createdFrames) do
  if frame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
    tab = frame
  elseif frame.name == "ArbitrageAuctionHouseFrame" then
    panel = frame
  elseif frame.template == "AuctionHouseBackgroundTemplate" then
    tableBackground = frame
  elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Full Scan" then
    scanButton = frame
  elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Settings" then
    settingsButton = frame
  elseif frame.template == "AuctionHouseTableHeaderStringTemplate" then
    headers[frame.text] = frame
  elseif frame.template == "WowScrollBoxList" then
    scrollBox = frame
  elseif frame.template == "MinimalScrollBar" then
    scrollBar = frame
  end
end

assert(tab and tab.parent.parent == AuctionHouseFrame, "creates an independently parented Auction House tab")
assert(tab.text == "Arbitrage", "labels the tab")
assert(
  tab.points[1][2] == AuctionHouseFrame.AuctionsTab and tab.points[1][4] == 3,
  "leaves space after the Auctions tab"
)
assert(resizedTab and resizedTab.tab == tab, "sizes the dynamic tab like Blizzard tabs")
assert(
  #AuctionHouseFrame.Tabs == 3 and next(AuctionHouseFrame.tabsForDisplayMode) == nil,
  "does not taint Blizzard's native tab registration"
)
assert(panel and panel.shown == false, "creates a hidden Arbitrage panel")
assert(tableBackground and tableBackground.parent == panel, "creates a native Auction House table background")
assert(
  tableBackground.Background.atlas == "auctionhouse-background-index",
  "uses the native Auction House list artwork"
)
assert(
  tableBackground.NineSlice.points[1][1] == "TOPLEFT"
    and tableBackground.NineSlice.points[1][3] == -19
    and tableBackground.NineSlice.points[2][1] == "BOTTOMRIGHT"
    and tableBackground.NineSlice.points[2][2] == -22
    and tableBackground.Background.points[2][1] == "BOTTOMRIGHT"
    and tableBackground.Background.points[2][2] == -25,
  "places the native inset below the headers and outside the scrollbar"
)
assert(scanButton and scanButton.parent == panel and scanButton.text == "Full Scan", "creates the full scan button")
assert(scanButton.width == 132 and scanButton.height == 22, "sizes full scan like the Buy tab search button")
assert(
  scanButton.points[1][1] == "TOPRIGHT"
    and scanButton.points[1][2] == AuctionHouseFrame
    and scanButton.points[1][3] == "TOPRIGHT"
    and scanButton.points[1][4] == -12
    and scanButton.points[1][5] == -38,
  "places full scan where the Buy tab places Search"
)
assert(
  settingsButton and settingsButton.parent == panel and settingsButton.text == "Settings",
  "creates the settings button"
)
assert(
  settingsButton.points[1][1] == "RIGHT"
    and settingsButton.points[1][2] == scanButton
    and settingsButton.points[1][3] == "LEFT"
    and settingsButton.points[1][4] == -10,
  "places settings immediately left of full scan"
)
assert(scrollBox and scrollBox.parent == tableBackground, "creates a native Auction House scroll box")
assert(scrollBar and scrollBar.parent == tableBackground, "creates the Forever Auction House scrollbar")
assert(scrollBox.scrollBar == scrollBar, "connects the opportunity list to its scrollbar")
assert(
  scrollBox.view and scrollBox.view.template == "AuctionHouseItemListLineTemplate",
  "uses the native Auction House row template"
)
assert(
  headers["ITEM / CRAFTER"]
    and headers["NET SALE"]
    and headers["CRAFT COST"]
    and headers["MIN COST"]
    and headers["EST. PROFIT"]
    and headers["BEST PROFIT"]
    and headers.ROI,
  "creates an Auction House-style header for every table column"
)
for _, header in pairs(headers) do
  assert(type(header.scripts.OnClick) == "function", "makes every table column sortable")
end

tab:Click()
assert(type(selectedDisplayMode) == "table" and #selectedDisplayMode == 0, "hides native Auction House content")
assert(tab.selected and panel.shown, "selects the Arbitrage tab and panel")
assert(windowTitle == "Arbitrage", "updates the Auction House title")

local opportunityRowCount = 0
local opportunityRows = {}
for _, createdFrame in ipairs(createdFrames) do
  if createdFrame.parent == scrollBox and createdFrame.template == "AuctionHouseItemListLineTemplate" then
    opportunityRowCount = opportunityRowCount + 1
    opportunityRows[#opportunityRows + 1] = createdFrame
  end
end
assert(opportunityRowCount >= 2, "creates compact rows for visible opportunities")
assert(opportunityRows[1].scripts.OnClick == nil, "removes the incompatible native row click handler")
assert(opportunityRows[1].height == 20, "matches the native Auction House row height")
assert(opportunityRows[1].icon.width == 14 and opportunityRows[1].icon.height == 14, "matches native item icon sizing")
assert(
  opportunityRows[1].iconBorder.atlas == "auctionhouse-itemicon-small-border"
    and opportunityRows[1].iconBorder.width == 16
    and opportunityRows[1].iconBorder.height == 16,
  "uses the native Auction House item icon border"
)
assert(
  opportunityRows[1].normalTexture.atlas == "auctionhouse-rowstripe-2"
    and opportunityRows[2].normalTexture.atlas == "auctionhouse-rowstripe-1",
  "alternates native Auction House row stripes"
)

local heading
local summaryText
local uncertaintyText
local itemName
local sourceText
local marketText
local costText
local minimumCostText
local profitText
local minimumProfitText
local roiText
local missingValueCount = 0
for _, fontString in ipairs(createdFontStrings) do
  if fontString.text == "Craft Opportunities" then
    heading = fontString
  elseif fontString.text and fontString.text:find("4 known crafts", 1, true) then
    summaryText = fontString
  elseif fontString.text == "Yellow values are uncertain; more market data is needed." then
    uncertaintyText = fontString
  elseif fontString.text == "Flask (x2)" then
    itemName = fontString
  elseif fontString.text == "Alchemy - Alt, Main" then
    sourceText = fontString
  elseif fontString.text == "190c" then
    marketText = fontString
  elseif fontString.text == "80c" then
    costText = fontString
  elseif fontString.text == "60c" then
    minimumCostText = fontString
  elseif fontString.text == "+110c" then
    profitText = fontString
  elseif fontString.text == "+130c" then
    minimumProfitText = fontString
  elseif fontString.text == "138%" then
    roiText = fontString
  elseif fontString.text == "—" then
    missingValueCount = missingValueCount + 1
  end
end
assert(heading, "labels the opportunities page")
assert(
  summaryText.text == "4 known crafts | 2 profitable | Last scan: 2026-09-21 10:15 | 2 scans / 14 days",
  "shows compact recipe and scan status"
)
assert(summaryText.points[2][1] == "TOPRIGHT", "keeps the compact summary at its top anchor")
assert(uncertaintyText and uncertaintyText.textColor[2] == 0.82, "explains the yellow uncertainty color")
assert(itemName and sourceText, "shows the product, output quantity, profession, and crafters")
assert(not itemName.wordWrap and itemName.maxLines == 1, "keeps item names within one row")
assert(not sourceText.wordWrap and sourceText.maxLines == 1, "keeps long crafter lists within one row")
assert(
  marketText and costText and minimumCostText and profitText and minimumProfitText and roiText,
  "shows sale, both costs, both profits, and ROI in separate cells"
)
assert(missingValueCount >= 2, "shows missing minimum values explicitly")
assert(
  opportunityRows[1].HighlightTexture.atlas == "auctionhouse-ui-row-highlight",
  "uses the Auction House row highlight"
)
assert(headers["EST. PROFIT"].Arrow.shown, "marks estimated profit as the default sort")
assert(opportunityRows[1]:GetElementData().itemID == 100, "sorts estimated profit descending by default")
assert(
  opportunityRows[2].market.textColor[2] == 0.82
    and opportunityRows[2].profit.textColor[2] == 0.82
    and opportunityRows[2].roi.textColor[2] == 0.82
    and opportunityRows[2].roi.text == "6%",
  "colors uncertain market-derived values and ROI yellow"
)
assert(opportunityRows[2].cost.textColor[2] == 1, "keeps reliable values white in an otherwise uncertain row")
assert(requestedItemIDs[1] == 200, "requests missing item display data")

opportunityRows[1].scripts.OnEnter(opportunityRows[1])
assert(tooltipLines[#tooltipLines] == "Crafted by: Alchemy - Alt, Main", "shows the complete crafter list on hover")
opportunityRows[1].scripts.OnLeave(opportunityRows[1])

itemInfo[200] = { "Widget", "item:200", 1, 1, 1, "", "", 20, "", 2000 }
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 200, true)
assert(opportunityCalls == 1, "rerenders without recalculating when requested item data loads")
local loadedName
for _, fontString in ipairs(createdFontStrings) do
  if fontString.text == "Widget" then
    loadedName = fontString
  end
end
assert(loadedName, "refreshes rows when requested item data loads")

onEvent(nil, "GET_ITEM_INFO_RECEIVED", 999, true)
assert(opportunityCalls == 1, "ignores unrelated item data events")

itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
local sortableItems = {
  {
    itemID = 3,
    outputQuantity = 1,
    saleProceeds = 40,
    craftCost = 10,
    minimumCraftCost = 5,
    profit = 30,
    minimumProfit = 35,
    roi = 3,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
  {
    itemID = 1,
    outputQuantity = 1,
    saleProceeds = 30,
    craftCost = 20,
    minimumCraftCost = 15,
    profit = 10,
    minimumProfit = 15,
    roi = 0.5,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
  {
    itemID = 2,
    outputQuantity = 1,
    saleProceeds = 50,
    craftCost = 40,
    profit = 5,
    roi = 0.125,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
}
opportunityResult = { totalCount = 3, pricedCount = 3, items = sortableItems }
ns.AuctionHouse.Refresh()

local function AssertColumnSort(label, firstDefault, firstReversed)
  headers[label]:Click()
  assert(opportunityRows[1]:GetElementData().itemID == firstDefault, label .. " uses its default sort direction")
  assert(headers[label].Arrow.shown, label .. " shows its active sort arrow")
  headers[label]:Click()
  assert(opportunityRows[1]:GetElementData().itemID == firstReversed, label .. " reverses on a second click")
end

AssertColumnSort("ITEM / CRAFTER", 1, 3)
AssertColumnSort("NET SALE", 2, 1)
AssertColumnSort("CRAFT COST", 2, 3)
AssertColumnSort("MIN COST", 1, 3)
AssertColumnSort("EST. PROFIT", 3, 2)
AssertColumnSort("BEST PROFIT", 3, 1)
AssertColumnSort("ROI", 3, 2)

itemInfo[1][1] = "Zulu"
itemInfo[2] = nil
headers["ITEM / CRAFTER"]:Click()
assert(opportunityRows[1]:GetElementData().itemID == 3, "sorts known item names ahead of unresolved names")
itemInfo[2] = { "Alpha", "item:2", 1, 1, 1, "", "", 20, "", 2 }
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 2, true)
assert(opportunityRows[1]:GetElementData().itemID == 2, "reapplies item sorting when a requested name loads")
headers["EST. PROFIT"]:Click()

local scrollingItems = {}
for itemID = 1, 17 do
  scrollingItems[itemID] = {
    itemID = itemID,
    outputQuantity = 1,
    saleProceeds = 100,
    craftCost = 50,
    profit = 50,
    roi = 1,
    sources = {},
    reasons = {},
    isUncertain = false,
  }
end
scrollingItems[17].profit = -1
scrollingItems[17].minimumProfit = 1
opportunityResult = { totalCount = 17, pricedCount = 17, items = scrollingItems }
ns.AuctionHouse.Refresh()
opportunityRows[1].scripts.OnEnter(opportunityRows[1])
local hideCallsBeforeScroll = tooltipHideCalls
scrollBox:SetScrollOffset(1)
assert(opportunityRows[1]:GetElementData().itemID == 2, "scrolls through ranked opportunities")
assert(
  scrollBox.frames[16].profit.text == "-1c",
  "formats a bottom-row estimated loss without passing it to the coin formatter"
)
assert(tooltipHideCalls == hideCallsBeforeScroll + 1, "hides a stale row tooltip when scrolling")
itemInfo[2] = { "Loaded Item", "item:2", 1, 1, 1, "", "", 20, "", 2000 }
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 2, true)
assert(opportunityRows[1]:GetElementData().itemID == 2, "preserves the scroll position after item data loads")

local itemFourRequestCount = 0
for _, requestedItemID in ipairs(requestedItemIDs) do
  if requestedItemID == 4 then
    itemFourRequestCount = itemFourRequestCount + 1
  end
end
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 4, false)
ns.AuctionHouse.Refresh()
local itemFourRetryCount = 0
for _, requestedItemID in ipairs(requestedItemIDs) do
  if requestedItemID == 4 then
    itemFourRetryCount = itemFourRetryCount + 1
  end
end
assert(itemFourRetryCount == itemFourRequestCount + 1, "retries item display data after a failed load")

scanButton:Click()
assert(scanCalls == 1, "starts a full scan from the panel")
settingsButton:Click()
assert(settingsCalls == 1, "opens Arbitrage settings from the panel")

AuctionHouseFrame:SetDisplayMode({ "BuyFrame" })
assert(not tab.selected and not panel.shown, "returns to native Auction House tabs")

opportunityRows[1].scripts.OnEnter(opportunityRows[1])
local hideCallsBeforeRefresh = tooltipHideCalls
opportunityResult = { totalCount = 0, pricedCount = 0, items = {} }
ns.AuctionHouse.Refresh()
assert(tooltipHideCalls == hideCallsBeforeRefresh + 1, "hides its tooltip before replacing ranked results")
local emptyText
for _, fontString in ipairs(createdFontStrings) do
  if fontString.text and fontString.text:find("No known recipes", 1, true) then
    emptyText = fontString
  end
end
assert(emptyText, "explains how to populate an empty recipe book")
assert(emptyText.points[2][1] == "TOPRIGHT", "keeps empty-state guidance at its top anchor")

opportunityResult = { totalCount = 4, pricedCount = 0, items = {} }
databaseStatus.latestScan = nil
ns.AuctionHouse.Refresh()
assert(
  emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
  "prompts for a scan when known recipes have no market data"
)

databaseStatus.latestScan = 123
ns.AuctionHouse.Refresh()
assert(
  emptyText.text == "No known crafts have complete output and material prices." and emptyText.shown,
  "explains when scanned recipes still cannot be priced"
)

opportunityResult = { totalCount = 4, pricedCount = 4, items = {} }
ns.AuctionHouse.Refresh()
assert(
  emptyText.text == "No known crafts are currently profitable." and emptyText.shown,
  "explains when all priced crafts are unprofitable"
)

currentTime = 123 + 15 * 24 * 60 * 60
ns.AuctionHouse.Refresh()
assert(
  emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
  "prompts for a scan when the last scan has expired"
)

local createdCount = #createdFrames
onEvent(nil, "AUCTION_HOUSE_SHOW")
assert(#createdFrames == createdCount, "creates the tab only once")

local displayModeTabCount = 0
for _, createdFrame in ipairs(createdFrames) do
  if createdFrame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
    displayModeTabCount = displayModeTabCount + 1
  end
end

local libraryTab
LibStub = function(libraryName, silent)
  assert(libraryName == "LibAHTab-1-0" and silent, "requests the shared Auction House tab library")
  return {
    CreateTab = function(_, id, attachedFrame, displayText, tabHeader)
      libraryTab = {
        id = id,
        attachedFrame = attachedFrame,
        displayText = displayText,
        tabHeader = tabHeader,
      }
    end,
  }
end

assert(loadfile("src/AuctionHouse.lua"), "reloads AuctionHouse.lua with LibAHTab")("Arbitrage", ns)
ns.AuctionHouse.Register()
onEvent(nil, "AUCTION_HOUSE_SHOW")

assert(
  libraryTab
    and libraryTab.id == "Arbitrage"
    and libraryTab.displayText == "Arbitrage"
    and libraryTab.tabHeader == "Arbitrage",
  "coordinates the tab through an available LibAHTab"
)
assert(libraryTab.attachedFrame.name == "ArbitrageAuctionHouseFrame", "attaches the Arbitrage panel to LibAHTab")

local updatedDisplayModeTabCount = 0
for _, createdFrame in ipairs(createdFrames) do
  if createdFrame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
    updatedDisplayModeTabCount = updatedDisplayModeTabCount + 1
  end
end
assert(updatedDisplayModeTabCount == displayModeTabCount, "does not create a conflicting standalone tab")

local onEvent
local events = {}
local createdFrames = {}
local createdFontStrings = {}
local resizedTab
local selectedDisplayMode
local windowTitle
local scanCalls = 0

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

  function region:SetSize(width, height)
    self.width = width
    self.height = height
  end

  function region:SetText(text)
    self.text = text
  end

  function region:SetJustifyH(justify)
    self.justifyH = justify
  end

  function region:SetJustifyV(justify)
    self.justifyV = justify
  end

  function region:SetSpacing(spacing)
    self.spacing = spacing
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

  return frame
end

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
  itemCount = 7,
  latestScan = 123,
  recentScanCount = 2,
}

local config = {
  showTooltips = true,
  showCraftingCost = false,
  showMinimumCraftCost = true,
}

local ns = {
  Config = {
    Get = function(key)
      return config[key]
    end,
  },
  Database = {
    CountVendorPrices = function()
      return 3
    end,
    GetStatus = function()
      return databaseStatus
    end,
  },
  RecipeBook = {
    GetStatus = function()
      return { recipeCount = 4, characterCount = 2 }
    end,
  },
  Scan = {
    Start = function()
      scanCalls = scanCalls + 1
    end,
  },
}

assert(loadfile("src/AuctionHouse.lua"), "loads AuctionHouse.lua")("Arbitrage", ns)
ns.AuctionHouse.Register()
assert(events.AUCTION_HOUSE_SHOW, "waits for the load-on-demand Auction House UI")

onEvent(nil, "AUCTION_HOUSE_SHOW")

local tab
local panel
local scanButton
for _, frame in ipairs(createdFrames) do
  if frame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
    tab = frame
  elseif frame.template == "InsetFrameTemplate" then
    panel = frame
  elseif frame.template == "UIPanelButtonTemplate" then
    scanButton = frame
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
assert(scanButton and scanButton.parent == panel and scanButton.text == "Full Scan", "creates the full scan button")

tab:Click()
assert(type(selectedDisplayMode) == "table" and #selectedDisplayMode == 0, "hides native Auction House content")
assert(tab.selected and panel.shown, "selects the Arbitrage tab and panel")
assert(windowTitle == "Arbitrage", "updates the Auction House title")

local statusText
for _, fontString in ipairs(createdFontStrings) do
  if fontString.text and fontString.text:find("Stored items:", 1, true) then
    statusText = fontString
  end
end
assert(statusText, "renders status text")
assert(statusText.text == table.concat({
  "Stored items: 7",
  "Known vendor prices: 3",
  "Known recipes: 4 across 2 characters",
  "Tooltips: enabled",
  "Crafting cost: disabled",
  "Minimum craft cost: enabled",
  "Latest scan: 2026-09-21 10:15",
  "Scans in last 14 days: 2",
}, "\n"), "shows the slash-command status values")

scanButton:Click()
assert(scanCalls == 1, "starts a full scan from the panel")

AuctionHouseFrame:SetDisplayMode({ "BuyFrame" })
assert(not tab.selected and not panel.shown, "returns to native Auction House tabs")

databaseStatus.itemCount = 9
ns.AuctionHouse.Refresh()
assert(statusText.text:find("Stored items: 9", 1, true), "refreshes visible status values")

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
assert(libraryTab.attachedFrame.template == "InsetFrameTemplate", "attaches the Arbitrage panel to LibAHTab")

local updatedDisplayModeTabCount = 0
for _, createdFrame in ipairs(createdFrames) do
  if createdFrame.template == "AuctionHouseFrameDisplayModeTabTemplate" then
    updatedDisplayModeTabCount = updatedDisplayModeTabCount + 1
  end
end
assert(updatedDisplayModeTabCount == displayModeTabCount, "does not create a conflicting standalone tab")

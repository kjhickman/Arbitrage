local shiftDown = false
local hooks = {}
local hookCount = 0
local itemPostCall
local itemPostCallType
local lines = {}
local primaryData
local processingInfo

local function Color()
  return {
    WrapTextInColorCode = function(_, value)
      return value
    end,
  }
end

WHITE_FONT_COLOR = Color()
NORMAL_FONT_COLOR = Color()
LIGHTBLUE_FONT_COLOR = Color()
UNKNOWN = "Unknown"
LE_ITEM_BIND_NONE = 0
LE_ITEM_BIND_ON_EQUIP = 2
LE_ITEM_BIND_ON_USE = 3
Enum = {
  ItemBind = { None = 0, OnEquip = 2, OnUse = 3 },
  TooltipDataType = { Item = 0 },
}

function IsShiftKeyDown()
  return shiftDown
end

function hooksecurefunc(target, method, callback)
  assert(target[method], "only hooks available tooltip methods")
  hooks[method] = callback
  hookCount = hookCount + 1
end

TooltipDataProcessor = {
  AddTooltipPostCall = function(tooltipType, callback)
    itemPostCallType = tooltipType
    itemPostCall = callback
  end,
}

TooltipUtil = {
  GetDisplayedItem = function(tooltip)
    local data = tooltip:GetPrimaryTooltipData()
    return nil, data and data.displayedLink
  end,
}

local function Method() end

GameTooltip = {
  SetAuctionItem = Method,
  SetTradeSkillItem = Method,
  SetCraftItem = Method,
  AddLine = function(_, text)
    lines[#lines + 1] = { text }
  end,
  AddDoubleLine = function(_, left, right)
    lines[#lines + 1] = { left, right }
  end,
  GetPrimaryTooltipData = function()
    return primaryData
  end,
  GetProcessingTooltipInfo = function()
    return processingInfo
  end,
  GetPrimaryTooltipInfo = function()
    return processingInfo
  end,
  RebuildFromTooltipInfo = function(self)
    lines = {}
    itemPostCall(self, primaryData)
  end,
}
ItemRefTooltip = {}

local materialNames = {
  [201] = "API Name",
}

C_Item = {
  GetItemInfo = function(item)
    if type(item) == "number" then
      return materialNames[item]
    end

    return "Item", item, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, LE_ITEM_BIND_NONE
  end,
  GetItemLinkByGUID = function()
    return "item:100"
  end,
  DoesItemExist = function()
    return true
  end,
  GetStackCount = function()
    return 5
  end,
}

ItemLocation = {
  CreateFromBagAndSlot = function(_, bag, slot)
    return { bag = bag, slot = slot }
  end,
}

function GetAuctionItemInfo()
  return nil, nil, 4
end

function GetTradeSkillReagentInfo()
  return nil, nil, 3
end

function GetTradeSkillNumMade()
  return 2
end

function GetCraftReagentInfo()
  return nil, nil, 3
end

function GetCraftNumMade()
  return 2
end

local marketResult = {
  value = 12345,
  latestAgeDays = 0,
  dayCount = 3,
  scanCount = 4,
  reasons = {},
  isUncertain = false,
}
local craftingResult
local ns = {
  Config = {
    Get = function()
      return true
    end,
  },
  Keys = {
    FromLink = function()
      return { "100" }
    end,
  },
  RollingMarketValue = {
    Get = function()
      return marketResult
    end,
  },
  Crafting = {
    GetCost = function()
      return craftingResult
    end,
    GetMinimumCost = function() end,
  },
}
assert(loadfile("src/Tooltip.lua"), "loads Tooltip.lua")("Arbitrage", ns)

ns.Tooltip.AddMarketValue(GameTooltip, "item:100", 2)
assert(lines[1][1] == "Market Value", "shows a per-item market value without Shift")

shiftDown = true
lines = {}
ns.Tooltip.AddMarketValue(GameTooltip, "item:100", 2)
assert(lines[1][1] == "Market Value x2", "shows a stack market value with Shift")
assert(lines[2][1] == "MP data", "shows market confidence details with Shift")

craftingResult = {
  cost = 100,
  isUncertain = false,
  reasons = {},
  leaves = {
    [201] = { itemID = 201, name = "Ignored Leaf Name", quantity = 1, price = 10, source = "auction" },
    [202] = { itemID = 202, name = "Leaf Name", quantity = 1, price = 20, source = "vendor" },
    [203] = { itemID = 203, quantity = 1, price = 30, source = "auction" },
  },
}
lines = {}
ns.Tooltip.AddCraftingCost(GameTooltip, "item:100", 1)
assert(lines[3][1]:find("API Name", 1, true), "prefers the API material name")
assert(lines[4][1]:find("Item #203", 1, true), "falls back to an item-ID placeholder")
assert(lines[5][1]:find("Leaf Name", 1, true), "falls back to the captured material name")
craftingResult = nil

ns.Tooltip.Register()
assert(itemPostCallType == Enum.TooltipDataType.Item, "registers the item tooltip post-call")
assert(type(itemPostCall) == "function", "registers a tooltip callback")
assert(hookCount == 3, "keeps only legacy stack-context hooks")
assert(hooks.SetAuctionItem and hooks.SetTradeSkillItem and hooks.SetCraftItem, "hooks the legacy item setters")

shiftDown = false
primaryData = { type = Enum.TooltipDataType.Item, hyperlink = "item:100" }
processingInfo = { getterName = "GetHyperlink", getterArgs = { "item:100" } }
lines = {}
itemPostCall(GameTooltip, primaryData)
assert(lines[1][1] == "Market Value", "renders through the item tooltip post-call")

lines = {}
itemPostCall(GameTooltip, primaryData)
assert(lines[1][1] == "Market Value", "renders again after an asynchronous rebuild")

lines = {}
itemPostCall(GameTooltip, { type = Enum.TooltipDataType.Item, hyperlink = "item:100" })
assert(#lines == 0, "ignores appended item data")

shiftDown = true
primaryData = { type = Enum.TooltipDataType.Item, hyperlink = "item:100" }
processingInfo = { getterName = "GetBagItem", getterArgs = { 0, 1 } }
lines = {}
itemPostCall(GameTooltip, primaryData)
assert(lines[1][1] == "Market Value x5", "gets modern stack context from the tooltip info")

processingInfo = { tooltipData = primaryData }
lines = {}
itemPostCall(GameTooltip, primaryData)
hooks.SetAuctionItem(GameTooltip, "list", 1)
assert(lines[1][1] == "Market Value x4", "rebuilds a legacy tooltip with its stack context")

lines = {}
itemPostCall(GameTooltip, primaryData)
assert(lines[1][1] == "Market Value x4", "preserves legacy stack context across asynchronous rebuilds")

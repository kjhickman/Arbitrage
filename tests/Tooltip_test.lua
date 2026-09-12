local shiftDown = false
local hooks = {}
local hookCount = 0
local tooltipScripts = {}
local timers = {}
local lines = {}
local currentItemLink = "item:100"
local currentOwner = {}

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
Enum = { ItemBind = { None = 0, OnEquip = 2, OnUse = 3 } }

function IsShiftKeyDown()
  return shiftDown
end

function hooksecurefunc(target, method, callback)
  assert(target[method], "only hooks available tooltip methods")
  hooks[method] = callback
  hookCount = hookCount + 1
end

C_Timer = {
  After = function(delay, callback)
    assert(delay == 0, "defers tooltip rendering by one tick")
    timers[#timers + 1] = callback
  end,
}

local function RunTimer()
  local callback = table.remove(timers, 1)
  assert(callback, "has a deferred tooltip callback")
  callback()
end

local function Method() end

local function HookScript(self, eventName, callback)
  assert(eventName == "OnTooltipSetItem", "uses the Classic item tooltip lifecycle")
  tooltipScripts[self] = callback
end

GameTooltip = {
  SetBagItem = Method,
  SetBuybackItem = Method,
  SetMerchantItem = Method,
  SetInventoryItem = Method,
  SetGuildBankItem = Method,
  SetLootItem = Method,
  SetLootRollItem = Method,
  SetQuestItem = Method,
  SetSendMailItem = Method,
  SetInboxItem = Method,
  SetTradePlayerItem = Method,
  SetTradeTargetItem = Method,
  SetAuctionItem = Method,
  SetTradeSkillItem = Method,
  SetCraftItem = Method,
  HookScript = HookScript,
  AddLine = function(_, text)
    lines[#lines + 1] = { text }
  end,
  AddDoubleLine = function(_, left, right)
    lines[#lines + 1] = { left, right }
  end,
  GetItem = function()
    return "Item", currentItemLink
  end,
  GetOwner = function()
    return currentOwner
  end,
  IsShown = function()
    return true
  end,
  Show = function() end,
}
ItemRefTooltip = {
  HookScript = HookScript,
}

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
  DoesItemExist = function()
    return true
  end,
  GetItemLink = function()
    return currentItemLink
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
assert(tooltipScripts[GameTooltip], "registers the GameTooltip item lifecycle")
assert(tooltipScripts[ItemRefTooltip], "registers the ItemRefTooltip item lifecycle")
assert(hookCount == 15, "keeps only stack-context setter hooks")
assert(hooks.SetBagItem and hooks.SetAuctionItem and hooks.SetCraftItem, "registers representative stack hooks")
assert(hooks.SetHyperlink == nil and hooks.SetItemByID == nil, "does not render through generic setter hooks")

shiftDown = false
lines = {}
tooltipScripts[GameTooltip](GameTooltip)
assert(#lines == 0, "waits for setter stack context before rendering")
RunTimer()
assert(lines[1][1] == "Market Value", "renders through the Classic item tooltip lifecycle")

lines = {}
tooltipScripts[GameTooltip](GameTooltip)
RunTimer()
assert(lines[1][1] == "Market Value", "renders again after an asynchronous rebuild")

shiftDown = true
lines = {}
tooltipScripts[GameTooltip](GameTooltip)
hooks.SetBagItem(GameTooltip, 0, 1)
RunTimer()
assert(lines[1][1] == "Market Value x5", "uses stack context captured after the lifecycle callback")

lines = {}
tooltipScripts[GameTooltip](GameTooltip)
RunTimer()
assert(lines[1][1] == "Market Value x5", "preserves stack context across asynchronous rebuilds")

currentOwner = {}
lines = {}
tooltipScripts[GameTooltip](GameTooltip)
RunTimer()
assert(lines[1][1] == "Market Value", "does not reuse stack context for a different tooltip owner")

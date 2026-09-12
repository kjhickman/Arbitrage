local shiftDown = false
local hooks = {}

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
Enum = { ItemBind = { None = 0, OnEquip = 2, OnUse = 3 } }

function IsShiftKeyDown()
  return shiftDown
end

function hooksecurefunc(target, method, callback)
  assert(target[method], "only hooks available tooltip methods")
  hooks[#hooks + 1] = callback
end

local function Method() end
GameTooltip = {
  SetHyperlink = Method,
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
  SetItemByID = Method,
}
ItemRefTooltip = { SetHyperlink = Method }

local materialNames = {
  [201] = "API Name",
}
C_Item = {
  GetItemInfo = function(item)
    if type(item) == "number" then
      return materialNames[item]
    end

    return "Item", 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, LE_ITEM_BIND_NONE
  end,
}

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

local lines = {}
local tooltip = {
  AddLine = function(_, text)
    lines[#lines + 1] = { text }
  end,
  AddDoubleLine = function(_, left, right)
    lines[#lines + 1] = { left, right }
  end,
}

ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
assert(lines[1][1] == "Market Value", "shows a per-item market value without Shift")

shiftDown = true
lines = {}
ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
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
ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
assert(lines[3][1]:find("API Name", 1, true), "prefers the API material name")
assert(lines[4][1]:find("Item #203", 1, true), "falls back to an item-ID placeholder")
assert(lines[5][1]:find("Leaf Name", 1, true), "falls back to the captured material name")

ns.Tooltip.Register()
assert(#hooks == 15, "registers the supported tooltip entry points")

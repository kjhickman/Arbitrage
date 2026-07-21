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

C_Item = {
  GetItemInfo = function()
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
  Crafting = { GetCost = function() end, GetMinimumCost = function() end },
}
assert(loadfile("Tooltip.lua"), "loads Tooltip.lua")("Arbitrage", ns)

local lines = {}
local tooltip = {
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

ns.Tooltip.Register()
assert(#hooks == 15, "registers the supported tooltip entry points")

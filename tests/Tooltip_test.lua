local shiftDown = false
local tooltipPostCall
local registeredTooltipType
local lastKeyLink

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
Enum = {
  ItemBind = {
    None = 0,
    OnEquip = 2,
    OnUse = 3,
  },
  TooltipDataType = {
    Item = 0,
  },
}

function IsShiftKeyDown()
  return shiftDown
end

TooltipDataProcessor = {
  AddTooltipPostCall = function(tooltipType, callback)
    registeredTooltipType = tooltipType
    tooltipPostCall = callback
  end,
}

TooltipUtil = {
  GetDisplayedItem = function(tooltip)
    return "Item", tooltip.displayedLink, tooltip.displayedItemID
  end,
}

local materialNames = {
  [201] = "API Name",
}
local itemLocations = {
  ["Item-1"] = { count = 5 },
}

C_Item = {
  GetItemInfo = function(item)
    if type(item) == "number" then
      local name = materialNames[item]
      if item == 100 then
        name = "Item 100"
      end
      if name then
        return name, "item:" .. item, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, Enum.ItemBind.None
      end
      return nil
    end

    return "Item", item, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, Enum.ItemBind.None
  end,
  GetItemInfoInstant = function(itemLink)
    return tonumber(itemLink:match("item:(%d+)"))
  end,
  GetItemLocation = function(itemGUID)
    return itemLocations[itemGUID]
  end,
  GetStackCount = function(itemLocation)
    return itemLocation.count
  end,
}

C_CurrencyInfo = {
  GetCoinTextureString = function(value, height)
    assert(height == 12, "uses compact coin icons")
    return "money:" .. value
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
    FromLink = function(itemLink)
      lastKeyLink = itemLink
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

local function NewTooltip()
  local lines = {}
  local tooltip = {
    forbidden = false,
    AddLine = function(_, text)
      lines[#lines + 1] = { text }
    end,
    AddDoubleLine = function(_, left, right)
      lines[#lines + 1] = { left, right }
    end,
    IsForbidden = function(self)
      return self.forbidden
    end,
    GetPrimaryTooltipData = function(self)
      return self.primaryData
    end,
  }
  return tooltip, lines
end

local tooltip, lines = NewTooltip()
ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
assert(lines[1][1] == "Market Value", "shows a per-item market value without Shift")

shiftDown = true
tooltip, lines = NewTooltip()
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
tooltip, lines = NewTooltip()
ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
assert(lines[3][1]:find("API Name", 1, true), "prefers the API material name")
assert(lines[4][1]:find("Item #203", 1, true), "falls back to an item-ID placeholder")
assert(lines[5][1]:find("Leaf Name", 1, true), "falls back to the captured material name")

craftingResult = nil
ns.Tooltip.Register()
assert(registeredTooltipType == Enum.TooltipDataType.Item, "registers one modern item tooltip post-call")
assert(type(tooltipPostCall) == "function", "registers a tooltip callback")

tooltip, lines = NewTooltip()
local tooltipData = { id = 100, hyperlink = "item:100", guid = "Item-1" }
tooltip.primaryData = tooltipData
tooltip.displayedLink = "item:100"
tooltip.displayedItemID = 100
tooltipPostCall(tooltip, tooltipData)
assert(lines[1][1] == "Market Value x5", "uses the item location stack count")
assert(lastKeyLink == "item:100", "uses the displayed item hyperlink")

tooltip, lines = NewTooltip()
tooltip.primaryData = { id = 100 }
tooltip.displayedLink = "item:200"
tooltip.displayedItemID = 200
tooltipPostCall(tooltip, { id = 200, hyperlink = "item:200" })
assert(#lines == 0, "ignores appended non-primary item data")

tooltip, lines = NewTooltip()
tooltip.forbidden = true
tooltip.primaryData = { id = 100 }
tooltipPostCall(tooltip, tooltip.primaryData)
assert(#lines == 0, "does not modify forbidden tooltips")

tooltip, lines = NewTooltip()
tooltipData = { id = 100 }
tooltip.primaryData = tooltipData
tooltip.displayedLink = "item:999"
tooltip.displayedItemID = 999
tooltipPostCall(tooltip, tooltipData)
assert(lastKeyLink == "item:100", "uses the primary item when an embedded product link differs")

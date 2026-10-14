local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Tooltip", function()
  local environment
  local ns
  local shiftDown
  local tooltipPostCall
  local registeredTooltipType
  local lastKeyLink
  local marketResult
  local craftingResult
  local minimumCraftingResult
  local sellPrices
  local settings

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    shiftDown = false
    tooltipPostCall = nil
    registeredTooltipType = nil
    lastKeyLink = nil
    craftingResult = nil
    minimumCraftingResult = nil

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

    local itemLocationMixin = {
      HasAnyLocation = function(self)
        return self.bagID ~= nil and self.slotIndex ~= nil
      end,
    }

    local itemLocations = {
      ["Item-1"] = setmetatable({ bagID = 0, slotIndex = 1, count = 5 }, { __index = itemLocationMixin }),
      ["Item-Sold"] = setmetatable({}, { __index = itemLocationMixin }),
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
      DoesItemExist = function(itemLocation)
        assert(itemLocation:HasAnyLocation(), "DoesItemExist rejects locations without inventory coordinates")
        return itemLocation.count ~= nil
      end,
      GetStackCount = function(itemLocation)
        assert(itemLocation:HasAnyLocation(), "only reads item locations with inventory coordinates")
        return itemLocation.count
      end,
    }

    C_CurrencyInfo = {
      GetCoinTextureString = function(value, height)
        assert(height == 12, "uses compact coin icons")
        return "money:" .. value
      end,
    }

    marketResult = {
      value = 12345,
      latestAgeDays = 0,
      dayCount = 3,
      scanCount = 4,
      reasons = {},
      isUncertain = false,
    }
    sellPrices = {}
    settings = {
      showTooltips = true,
      showMarketValue = true,
      showCraftingCost = true,
      showMinimumCraftCost = true,
      tooltipDetails = "shift",
    }
    ns = {
      Vendor = {
        GetSellPrice = function(itemID)
          return sellPrices[itemID]
        end,
      },
      Config = {
        Get = function(key)
          return settings[key]
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
        GetCostForItemID = function(itemID)
          assert(itemID == 100, "resolves the crafting item ID in the tooltip")
          return craftingResult
        end,
        GetMinimumCostForItemID = function()
          return minimumCraftingResult
        end,
      },
    }
    assert(loadfile("src/Tooltip.lua"), "loads Tooltip.lua")("Arbitrage", ns)
  end)

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

  it("shows per-item market value without Shift", function()
    setfenv(1, environment)
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(lines[1][1] == "Market Value", "shows a per-item market value without Shift")
  end)

  it("hides market value independently of other tooltip prices", function()
    setfenv(1, environment)
    settings.showMarketValue = false
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(#lines == 0, "hides Market Value independently")
  end)

  it("shows stack market value and confidence details with Shift", function()
    setfenv(1, environment)
    shiftDown = true
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(lines[1][1] == "Market Value x2", "shows a stack market value with Shift")
    assert(lines[2][1] == "MP data", "shows market confidence details with Shift")
  end)

  it("keeps compact market value to one line even with Shift", function()
    setfenv(1, environment)
    shiftDown = true
    settings.tooltipDetails = "compact"
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(#lines == 1 and lines[1][1] == "Market Value x2", "keeps Compact Market Value to one line")
  end)

  it("always shows market confidence details when configured", function()
    setfenv(1, environment)
    settings.tooltipDetails = "always"
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(lines[1][1] == "Market Value" and lines[2][1] == "MP data", "always shows Market Value details")
  end)

  describe("crafting details", function()
    before_each(function()
      setfenv(1, environment)
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
      settings.tooltipDetails = "shift"
      shiftDown = true
    end)

    it("prefers API material names and falls back to captured names or item IDs", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(lines[3][1]:find("API Name", 1, true), "prefers the API material name")
      assert(lines[4][1]:find("Item #203", 1, true), "falls back to an item-ID placeholder")
      assert(lines[5][1]:find("Leaf Name", 1, true), "falls back to the captured material name")
    end)

    it("keeps compact crafting costs to one line even with Shift", function()
      setfenv(1, environment)
      settings.tooltipDetails = "compact"
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 1, "keeps Compact Crafting Cost to one line")
    end)

    it("always shows the material breakdown and uncertain crafting details when configured", function()
      setfenv(1, environment)
      settings.tooltipDetails = "always"
      shiftDown = false
      craftingResult.isUncertain = true
      craftingResult.reasons = { "stale" }
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 6, "always shows the crafting material breakdown and confidence details")
      assert(lines[6][1] == "Crafting Cost data", "labels the always-visible crafting confidence details")
    end)
  end)

  describe("item tooltip callbacks", function()
    before_each(function()
      setfenv(1, environment)
      shiftDown = true
      ns.Tooltip.Register()
    end)

    it("registers a modern item tooltip post-call", function()
      setfenv(1, environment)
      assert(registeredTooltipType == Enum.TooltipDataType.Item, "registers one modern item tooltip post-call")
      assert(type(tooltipPostCall) == "function", "registers a tooltip callback")
    end)

    it("uses the inventory stack count and displayed hyperlink", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      local tooltipData = { id = 100, hyperlink = "item:100", guid = "Item-1" }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = "item:100"
      tooltip.displayedItemID = 100
      tooltipPostCall(tooltip, tooltipData)
      assert(lines[1][1] == "Market Value x5", "uses the item location stack count")
      assert(lastKeyLink == "item:100", "uses the displayed item hyperlink")
    end)

    it("ignores item locations without inventory coordinates", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      local tooltipData = { id = 100, hyperlink = "item:100", guid = "Item-Sold" }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = "item:100"
      tooltip.displayedItemID = 100
      tooltipPostCall(tooltip, tooltipData)
      assert(lines[1][1] == "Market Value", "ignores an item location without inventory coordinates")
    end)

    it("ignores appended non-primary item data", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      tooltip.primaryData = { id = 100 }
      tooltip.displayedLink = "item:200"
      tooltip.displayedItemID = 200
      tooltipPostCall(tooltip, { id = 200, hyperlink = "item:200" })
      assert(#lines == 0, "ignores appended non-primary item data")
    end)

    it("does not modify forbidden tooltips", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      tooltip.forbidden = true
      tooltip.primaryData = { id = 100 }
      tooltipPostCall(tooltip, tooltip.primaryData)
      assert(#lines == 0, "does not modify forbidden tooltips")
    end)

    it("uses the primary item when an embedded product link differs", function()
      setfenv(1, environment)
      local tooltip = NewTooltip()
      local tooltipData = { id = 100 }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = "item:999"
      tooltip.displayedItemID = 999
      tooltipPostCall(tooltip, tooltipData)
      assert(lastKeyLink == "item:100", "uses the primary item when an embedded product link differs")
    end)
  end)

  describe("vendor profit", function()
    before_each(function()
      setfenv(1, environment)
      settings.tooltipDetails = "compact"
      craftingResult = { cost = 100, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
      minimumCraftingResult = { cost = 80, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
      sellPrices[100] = 120
    end)

    it("shows per-item profit using rolling and latest-scan material costs", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 3)
      assert(
        lines[3][1] == "Vendor Profit" and lines[3][2] == "+money:20",
        "shows vendor profit per item without Shift"
      )
      assert(
        lines[4][1] == "Best-case Vendor Profit" and lines[4][2] == "+money:40",
        "shows vendor profit using latest-scan material costs"
      )
    end)

    it("scales rolling and best-case vendor profit by the stack with Shift", function()
      setfenv(1, environment)
      shiftDown = true
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 3)
      assert(lines[3][1] == "Vendor Profit x3" and lines[3][2] == "+money:60", "shows stack vendor profit with Shift")
      assert(lines[4][2] == "+money:120", "scales best-case vendor profit by the displayed stack")
    end)

    it("formats rolling vendor losses and best-case gains separately", function()
      setfenv(1, environment)
      sellPrices[100] = 50
      minimumCraftingResult.cost = 40
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(
        lines[3][2] == "-money:50" and lines[4][2] == "+money:10",
        "formats vendor losses and best-case gains separately"
      )
    end)

    it("does not show vendor profit for nonsellable crafts", function()
      setfenv(1, environment)
      sellPrices[100] = 0
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 2, "does not show vendor profit for nonsellable crafts")
    end)

    it("leaves vendor profit unknown when the vendor price is missing", function()
      setfenv(1, environment)
      sellPrices[100] = nil
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 2, "does not assume missing vendor prices are zero")
    end)

    it("ties each vendor profit line to its crafting-cost visibility setting", function()
      setfenv(1, environment)
      settings.showCraftingCost = false
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(
        #lines == 2 and lines[2][1] == "Best-case Vendor Profit",
        "ties vendor profit visibility to its crafting-cost setting"
      )
      settings.showMinimumCraftCost = false
      tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 0, "hides vendor profit when both crafting-cost settings are disabled")
    end)

    it("does not invent vendor profit when material costs are unknown", function()
      setfenv(1, environment)
      settings.showMinimumCraftCost = false
      craftingResult = { isUnknown = true }
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(
        #lines == 1 and lines[1][2] == "Unknown  ",
        "does not invent vendor profit when material costs are unknown"
      )
    end)

    it("respects the global tooltip setting for vendor profit", function()
      setfenv(1, environment)
      settings.showMinimumCraftCost = false
      craftingResult = { isUnknown = true }
      settings.showTooltips = false
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 0, "respects the global tooltip setting for vendor profit")
    end)
  end)
end)

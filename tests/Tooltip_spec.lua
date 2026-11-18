local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Tooltip", function()
  local NOW = 1000000
  local environment
  local ns
  local shiftDown
  local tooltipPostCall
  local registeredTooltipType
  local marketResult
  local marketResultsByLink
  local craftingResult
  local minimumCraftingResult
  local settings

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    shiftDown = false
    tooltipPostCall = nil
    registeredTooltipType = nil
    marketResultsByLink = {}
    craftingResult = nil
    minimumCraftingResult = nil

    local function Color(prefix)
      return {
        WrapTextInColorCode = function(_, value)
          return prefix .. value
        end,
      }
    end

    WHITE_FONT_COLOR = Color("")
    -- Uncertain prices are yellow, so mark them apart from white text.
    NORMAL_FONT_COLOR = Color("yellow:")
    LIGHTBLUE_FONT_COLOR = Color("")
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

    function time()
      return NOW
    end

    marketResult = {
      value = 12345,
      latest = NOW - 3 * 60 * 60,
      dayCount = 3,
      scanCount = 4,
      reasons = {},
      isUncertain = false,
    }
    settings = {
      showMarketValue = true,
      showCraftingCost = true,
      showMinimumCraftCost = true,
      showCraftProfit = false,
      tooltipDetails = "shift",
    }
    ns = {
      Opportunities = {
        AUCTION_HOUSE_CUT_RATE = 0.05,
      },
      Config = {
        Get = function(key)
          return settings[key]
        end,
      },
      Keys = {
        FromLink = function(itemLink)
          return { itemLink }
        end,
      },
      RollingMarketValue = {
        Get = function(keys)
          return marketResultsByLink[keys[1]] or marketResult
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
    assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
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
    assert.are.same({ "Market Value data", "3 days, 4 scans, latest 3 hours ago" }, lines[2])
  end)

  it("never shows market confidence details when set to Never, even with Shift", function()
    setfenv(1, environment)
    shiftDown = true
    settings.tooltipDetails = "compact"
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(#lines == 1 and lines[1][1] == "Market Value x2", "keeps Market Value to one line")
  end)

  it("always shows market confidence details when configured", function()
    setfenv(1, environment)
    settings.tooltipDetails = "always"
    local tooltip, lines = NewTooltip()
    ns.Tooltip.AddMarketValue(tooltip, "item:100", 2)
    assert(lines[1][1] == "Market Value" and lines[2][1] == "Market Value data", "always shows Market Value details")
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

    it("heads each materials list with the item count and the cost it makes up", function()
      setfenv(1, environment)
      minimumCraftingResult = {
        cost = 80,
        isUncertain = false,
        reasons = {},
        leaves = { [201] = { itemID = 201, quantity = 1, price = 80, source = "auction" } },
      }
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ "Materials for one item (Craft Cost):" }, lines[3])
      assert.are.same({ "Materials for one item (Buyout Cost):" }, lines[7])

      tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 3)
      assert.are.same({ "Materials for 3 items (Craft Cost):" }, lines[3])
      assert.are.same({ "  API Name x3 (Auction House)", "money:30" }, lines[4])
      assert.are.same({ "Materials for 3 items (Buyout Cost):" }, lines[7])
    end)

    it("never shows the material breakdown when set to Never, even with Shift", function()
      setfenv(1, environment)
      settings.tooltipDetails = "compact"
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert(#lines == 1, "keeps Craft Cost to one line")
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
      assert(lines[6][1] == "Craft Cost data", "labels the always-visible crafting confidence details")
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
      local variantLink = "item:100::::::::1:1485"
      marketResultsByLink[variantLink] =
        { value = 7, latest = NOW, dayCount = 1, scanCount = 1, reasons = {}, isUncertain = false }
      local tooltip, lines = NewTooltip()
      local tooltipData = { id = 100, hyperlink = "item:100", guid = "Item-1" }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = variantLink
      tooltip.displayedItemID = 100
      tooltipPostCall(tooltip, tooltipData)
      assert.are.same({ "Market Value x5", "money:35" }, lines[1])
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
      marketResultsByLink["item:999"] =
        { value = 9, latest = NOW, dayCount = 1, scanCount = 1, reasons = {}, isUncertain = false }
      local tooltip, lines = NewTooltip()
      local tooltipData = { id = 100 }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = "item:999"
      tooltip.displayedItemID = 999
      tooltipPostCall(tooltip, tooltipData)
      assert.are.same({ "Market Value", "money:12345" }, lines[1])
    end)
  end)

  describe("craft profit", function()
    before_each(function()
      setfenv(1, environment)
      settings.tooltipDetails = "compact"
      settings.showCraftProfit = true
      marketResult.value = 200
      craftingResult = { cost = 100, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
      minimumCraftingResult = { cost = 80, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
    end)

    it("shows Market Value after the Auction House cut minus Craft Cost per item", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 3)
      assert.are.same({
        { "Craft Cost", "money:100" },
        { "Buyout Cost", "money:80" },
        { "Craft Profit", "+money:90" },
      }, lines)
    end)

    it("scales Craft Profit by the stack with Shift", function()
      setfenv(1, environment)
      shiftDown = true
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 3)
      assert.are.same({ "Craft Profit x3", "+money:270" }, lines[3])
    end)

    it("signs a loss", function()
      setfenv(1, environment)
      marketResult.value = 100
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ "Craft Profit", "-money:5" }, lines[3])
    end)

    it("turns yellow when the Market Value or the Craft Cost is uncertain", function()
      setfenv(1, environment)
      marketResult.isUncertain = true
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ "Craft Profit", "+yellow:money:90" }, lines[3])

      marketResult.isUncertain = false
      craftingResult.isUncertain = true
      tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ "Craft Profit", "+yellow:money:90" }, lines[3])
    end)

    it("needs both a Market Value and a known Craft Cost", function()
      setfenv(1, environment)
      marketResult = nil
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.equal(2, #lines)

      marketResult = { value = 200, latest = NOW, dayCount = 3, scanCount = 4, reasons = {}, isUncertain = false }
      craftingResult = { isUnknown = true }
      tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ { "Craft Cost", "Unknown  " }, { "Buyout Cost", "money:80" } }, lines)
    end)

    it("is left off items that cannot be auctioned", function()
      setfenv(1, environment)
      C_Item.GetItemInfo = function(item)
        return "Item", item, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 1
      end
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.equal(2, #lines)
    end)

    it("controls the two cost lines and Craft Profit independently", function()
      setfenv(1, environment)
      local priceLines = {
        { "showCraftingCost", "Craft Cost", "money:100" },
        { "showMinimumCraftCost", "Buyout Cost", "money:80" },
        { "showCraftProfit", "Craft Profit", "+money:90" },
      }
      for combination = 0, 7 do
        local expected = {}
        for index, priceLine in ipairs(priceLines) do
          local enabled = math.floor(combination / 2 ^ (index - 1)) % 2 == 1
          settings[priceLine[1]] = enabled
          if enabled then
            expected[#expected + 1] = { priceLine[2], priceLine[3] }
          end
        end
        local tooltip, lines = NewTooltip()
        ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
        assert.are.same(expected, lines, "respects independent visibility for combination " .. combination)
      end
    end)

    it("hides the crafting breakdown when only Craft Profit is shown, even with details", function()
      setfenv(1, environment)
      settings.showCraftingCost = false
      settings.showMinimumCraftCost = false
      settings.tooltipDetails = "always"
      craftingResult.isUncertain = true
      craftingResult.reasons = { "stale" }
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ { "Craft Profit", "+yellow:money:90" } }, lines)
    end)

    it("skips pricing what neither a cost line nor Craft Profit shows", function()
      setfenv(1, environment)
      settings.showCraftingCost = false
      settings.showCraftProfit = false
      ns.Crafting.GetCostForItemID = function()
        error("must not calculate hidden rolling prices")
      end
      ns.RollingMarketValue.Get = function()
        error("must not look up a Market Value for a hidden Craft Profit")
      end
      local tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.same({ { "Buyout Cost", "money:80" } }, lines)

      settings.showMinimumCraftCost = false
      ns.Crafting.GetMinimumCostForItemID = function()
        error("must not calculate hidden best-case prices")
      end
      tooltip, lines = NewTooltip()
      ns.Tooltip.AddCraftingCost(tooltip, "item:100", 1)
      assert.are.equal(0, #lines)
    end)
  end)
end)

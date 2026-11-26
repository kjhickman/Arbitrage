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
  local recipeIDsByOutput
  local previews
  local recipeCosts
  local pricedRecipeKeys
  local buyouts
  local lastSeen
  local listed
  local sales
  local vendorPrices

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    shiftDown = false
    tooltipPostCall = nil
    registeredTooltipType = nil
    marketResultsByLink = {}
    craftingResult = nil
    minimumCraftingResult = nil
    recipeIDsByOutput = {}
    previews = {}
    recipeCosts = {}
    buyouts = {}
    lastSeen = {}
    listed = {}
    sales = {}
    vendorPrices = {}

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
      ["Item-2"] = setmetatable({ bagID = 0, slotIndex = 2, count = 2 }, { __index = itemLocationMixin }),
      ["Item-3"] = setmetatable({ bagID = 0, slotIndex = 3, count = 3 }, { __index = itemLocationMixin }),
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
      showBuyout = true,
      showCraftingCost = true,
      showMinimumCraftCost = true,
      showCraftProfit = false,
      tooltipDetails = "shift",
    }
    ns = {
      Vendor = {
        GetSellPrice = function(itemID)
          return vendorPrices[itemID]
        end,
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
      Database = {
        IsIgnoredItem = function()
          return false
        end,
        GetLatestBuyout = function(dbKey)
          return buyouts[dbKey]
        end,
        GetLastSeen = function(dbKey)
          return lastSeen[dbKey]
        end,
        GetListed = function(dbKey)
          return listed[dbKey]
        end,
        GetSales = function(dbKey)
          return unpack(sales[dbKey] or {})
        end,
      },
      RollingMarketValue = {
        Get = function(keys)
          return marketResultsByLink[keys[1]] or marketResult
        end,
      },
      Crafting = {
        GetCostForItemID = function(itemID)
          return itemID == 100 and craftingResult or nil
        end,
        GetScanCostForItemID = function(itemID)
          return itemID == 100 and minimumCraftingResult or nil
        end,
        GetRecipeCosts = function(recipes)
          pricedRecipeKeys = {}
          for _, recipe in ipairs(recipes) do
            pricedRecipeKeys[#pricedRecipeKeys + 1] = recipe.recipeKey
          end
          return unpack(recipeCosts)
        end,
      },
      RecipeBook = {
        GetRecipeIDs = function(itemID)
          return recipeIDsByOutput[itemID] or {}
        end,
      },
      RecipeParser = {
        Preview = function(recipeID)
          return previews[recipeID]
        end,
      },
    }
    assert(loadfile("src/Terminology.lua"), "loads Terminology.lua")("Arbitrage", ns)
    assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
    assert(loadfile("src/ItemTable.lua"), "loads ItemTable.lua")("Arbitrage", ns)
    assert(loadfile("src/Opportunities.lua"), "loads Opportunities.lua")("Arbitrage", ns)
    assert(loadfile("src/Tooltip.lua"), "loads Tooltip.lua")("Arbitrage", ns)
    ns.Tooltip.Register()
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
      GetOwner = function(self)
        return self.owner
      end,
    }
    return tooltip, lines
  end

  local function ShowItem(itemLink, guid)
    local tooltip, lines = NewTooltip()
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    local tooltipData = { id = itemID, hyperlink = itemLink, guid = guid }
    tooltip.primaryData = tooltipData
    tooltip.displayedLink = itemLink
    tooltip.displayedItemID = itemID
    tooltipPostCall(tooltip, tooltipData)
    return lines
  end

  it("shows per-item market value without Shift", function()
    setfenv(1, environment)
    local lines = ShowItem("item:100", "Item-2")
    assert.are.same({ { "Typical", "money:12345" } }, lines)
  end)

  it("hides market value independently of other tooltip prices", function()
    setfenv(1, environment)
    settings.showMarketValue = false
    assert.are.same({}, ShowItem("item:100", "Item-2"))
  end)

  it("shows when a scan last listed the item only with pricing details", function()
    setfenv(1, environment)
    settings.showMarketValue = false
    ns.Keys.FromLink = function(itemLink)
      return itemLink == "item:300" and { "equip:300:12720", "300" } or { itemLink }
    end
    lastSeen["item:100"] = NOW - 3 * 60 * 60
    lastSeen["300"] = NOW - 60
    assert.are.same({}, ShowItem("item:100"), "hides it without Shift")

    shiftDown = true
    assert.are.same({ { "Last scan", "3 hours ago" } }, ShowItem("item:100"))
    assert.are.same({ { "Last scan", "1 minute ago" } }, ShowItem("item:300"), "falls back to any gear variant's scan")
    assert.are.same({}, ShowItem("item:400"), "skips items no scan listed")

    settings.tooltipDetails = "compact"
    assert.are.same({}, ShowItem("item:100"), "never shows it when set to Never")

    settings.tooltipDetails = "always"
    shiftDown = false
    settings.showBuyout = false
    assert.are.same({}, ShowItem("item:100"), "has nothing to date without Typical or Current")
    settings.showBuyout = true
    assert.are.same({ { "Last scan", "3 hours ago" } }, ShowItem("item:100"), "always shows it when configured")
  end)

  it("shows the item's own Current, as a stack with Shift, and nothing when it wasn't listed", function()
    setfenv(1, environment)
    settings.showMarketValue = false
    ns.Keys.FromLink = function(itemLink)
      return itemLink == "item:300" and { "equip:300:12720", "300" } or { itemLink }
    end
    buyouts["item:100"] = 450
    buyouts["300"] = 20
    assert.are.same({ { "Current", "money:450" } }, ShowItem("item:100", "Item-2"))
    assert.are.same({}, ShowItem("item:300"), "never shows another gear variant's Current")

    shiftDown = true
    assert.are.same({ { "Current x2", "money:900" } }, ShowItem("item:100", "Item-2"))

    settings.showBuyout = false
    assert.are.same({}, ShowItem("item:100", "Item-2"), "hides Current independently")
  end)

  it("shows units listed only when set to, for the item's own variant, and nothing when none were", function()
    setfenv(1, environment)
    settings.showMarketValue = false
    ns.Keys.FromLink = function(itemLink)
      return itemLink == "item:300" and { "equip:300:12720", "300" } or { itemLink }
    end
    listed["item:100"] = 12795
    listed["300"] = 4
    assert.are.same({}, ShowItem("item:100"), "hides it unless set to show it")

    settings.showListed = true
    assert.are.same({ { "Listed", "12,795" } }, ShowItem("item:100", "Item-2"))
    assert.are.same({}, ShowItem("item:300"), "never shows another gear variant's units")
    assert.are.same({}, ShowItem("item:400"))
  end)

  describe("region sales", function()
    before_each(function()
      setfenv(1, environment)
      settings.showMarketValue = false
      settings.showSaleRate = true
      sales["item:100"] = { 2400, 0.887 }
    end)

    it("shows Sale Rate alone when the other figures are off", function()
      setfenv(1, environment)
      assert.are.same({ { "Sale Rate", "89%" } }, ShowItem("item:100", "Item-2"))
    end)

    it("shows each figure by its own setting, Average Sale Price as a stack with Shift", function()
      setfenv(1, environment)
      settings.showAverageSalePrice = true
      assert.are.same(
        { { "Sale Rate", "89%" }, { "Average Sale Price", "money:2400" } },
        ShowItem("item:100", "Item-2")
      )

      shiftDown = true
      settings.showSaleRate = false
      assert.are.same({ { "Average Sale Price x2", "money:4800" } }, ShowItem("item:100", "Item-2"))
    end)

    it("leaves out what TradeSkillMaster doesn't know, and items without sales", function()
      setfenv(1, environment)
      settings.showAverageSalePrice = true
      sales["item:100"] = { 0, 0.004 }
      assert.are.same({ { "Sale Rate", "<1%" } }, ShowItem("item:100"))
      assert.are.same({}, ShowItem("item:400"))
    end)

    it("never shows a gear variant its item ID's sales, which blend every enchant", function()
      setfenv(1, environment)
      ns.Keys.FromLink = function()
        return { "equip:300:12720", "300" }
      end
      sales["300"] = { 52000, 0.2 }
      assert.are.same({}, ShowItem("item:300"))
    end)

    it("is left off items that cannot be auctioned", function()
      setfenv(1, environment)
      local GetItemInfo = C_Item.GetItemInfo
      C_Item.GetItemInfo = function(item)
        local info = { GetItemInfo(item) }
        info[14] = 1
        return unpack(info, 1, 14)
      end
      assert.are.same({}, ShowItem("item:100"))
    end)
  end)

  describe("crafting details", function()
    before_each(function()
      setfenv(1, environment)
      settings.showMarketValue = false
      settings.showBuyout = false
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
      local lines = ShowItem("item:100")
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
      local lines = ShowItem("item:100")
      assert.are.same({ "Materials for one item (Typical Craft Cost):" }, lines[3])
      assert.are.same({ "Materials for one item (Current Craft Cost):" }, lines[7])

      lines = ShowItem("item:100", "Item-3")
      assert.are.same({ "Materials for 3 items (Typical Craft Cost):" }, lines[3])
      assert.are.same({ "  API Name x3 (Auction House)", "money:30" }, lines[4])
      assert.are.same({ "Materials for 3 items (Current Craft Cost):" }, lines[7])
    end)

    it("never shows the material breakdown when set to Never, even with Shift", function()
      setfenv(1, environment)
      settings.tooltipDetails = "compact"
      local lines = ShowItem("item:100")
      assert(#lines == 1, "keeps Typical Craft Cost to one line")
    end)

    it("always shows the material breakdown and uncertain crafting details when configured", function()
      setfenv(1, environment)
      settings.tooltipDetails = "always"
      shiftDown = false
      craftingResult.isUncertain = true
      craftingResult.reasons = { "stale" }
      local lines = ShowItem("item:100")
      assert(#lines == 6, "always shows the crafting material breakdown and confidence details")
      assert(lines[6][1] == "Typical Craft Cost data", "labels the always-visible crafting confidence details")
    end)
  end)

  describe("item tooltip callbacks", function()
    before_each(function()
      setfenv(1, environment)
      shiftDown = true
    end)

    it("registers a modern item tooltip post-call", function()
      setfenv(1, environment)
      assert(registeredTooltipType == Enum.TooltipDataType.Item, "registers one modern item tooltip post-call")
    end)

    it("adds no lines to grey item tooltips even if prices and details are enabled", function()
      setfenv(1, environment)
      ns.Database.IsIgnoredItem = function(item)
        return item == 100
      end
      lastSeen["item:100"], buyouts["item:100"] = NOW - 60, 450
      local tooltip, lines = NewTooltip()
      tooltip.displayedLink = "item:100"
      tooltipPostCall(tooltip, { id = 100 })
      assert.are.same({}, lines)
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
      assert.are.same({ { "Typical x5", "money:35" } }, lines)
    end)

    it("puts the last scan above the prices and the Current under Typical", function()
      setfenv(1, environment)
      shiftDown = true
      lastSeen["item:100"] = NOW - 60
      buyouts["item:100"] = 450
      local lines = ShowItem("item:100")
      assert.are.same(
        { { "Last scan", "1 minute ago" }, { "Typical", "money:12345" }, { "Current", "money:450" } },
        lines
      )
    end)

    it("ignores item locations without inventory coordinates", function()
      setfenv(1, environment)
      local lines = ShowItem("item:100", "Item-Sold")
      assert(lines[1][1] == "Typical", "ignores an item location without inventory coordinates")
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

    it("leaves pricing out of tooltips owned by tables that price their own rows", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      local tooltipData = { id = 100, hyperlink = "item:100" }
      tooltip.primaryData = tooltipData
      tooltip.displayedLink = "item:100"
      tooltip.displayedItemID = 100
      tooltip.owner = { arbitrageReplacesItemPricing = true }
      tooltipPostCall(tooltip, tooltipData)
      assert.are.equal(0, #lines)

      tooltip.owner = {}
      tooltipPostCall(tooltip, tooltipData)
      assert.are.equal("Typical", lines[1][1])
    end)

    it("does not modify forbidden tooltips", function()
      setfenv(1, environment)
      local tooltip, lines = NewTooltip()
      tooltip.forbidden = true
      tooltip.primaryData = { id = 100 }
      tooltipPostCall(tooltip, tooltip.primaryData)
      assert(#lines == 0, "does not modify forbidden tooltips")
    end)

    describe("on recipe items", function()
      local function ShowRecipe()
        local tooltip, lines = NewTooltip()
        local tooltipData = { id = 100 }
        tooltip.primaryData = tooltipData
        tooltip.displayedLink = "item:999"
        tooltip.displayedItemID = 999
        tooltipPostCall(tooltip, tooltipData)
        return lines
      end

      local function Cost(cost)
        return { cost = cost, outputQuantity = 1, isUncertain = false, reasons = {}, leaves = {} }
      end

      before_each(function()
        setfenv(1, environment)
        settings.tooltipDetails = "compact"
        settings.showCraftProfit = true
        marketResultsByLink["item:999"] =
          { value = 200, latest = NOW, dayCount = 3, scanCount = 4, reasons = {}, isUncertain = false }
        recipeIDsByOutput[999] = { 5, 6, 7 }
        previews[5] = { { recipeKey = "five:a" }, { recipeKey = "five:b" } }
        previews[6] = { { recipeKey = "six" } }
        recipeCosts = { Cost(120), Cost(90) }
      end)

      it("prices the taught item with every recipe that makes it, learned or not", function()
        setfenv(1, environment)
        assert.are.same({
          { "Typical", "money:12345" },
          { "Typical Craft Cost", "money:120" },
          { "Current Craft Cost", "money:90" },
          -- The taught item's Typical price of 200 after the 5% cut, less its Typical Craft Cost.
          { "Typical Profit", "+money:70" },
        }, ShowRecipe())
        assert.are.same({ "five:a", "five:b", "six" }, pricedRecipeKeys)
      end)

      it("adds nothing for an item no character has seen a recipe for", function()
        setfenv(1, environment)
        recipeIDsByOutput[999] = nil
        assert.are.same({ { "Typical", "money:12345" } }, ShowRecipe())
      end)

      it("follows the same settings as other crafting lines", function()
        setfenv(1, environment)
        settings.showMinimumCraftCost = false
        settings.showCraftingCost = false
        assert.are.same({ { "Typical", "money:12345" }, { "Typical Profit", "+money:70" } }, ShowRecipe())

        settings.showCraftProfit = false
        ns.RecipeParser.Preview = function()
          error("must not price recipes for hidden lines")
        end
        assert.are.same({ { "Typical", "money:12345" } }, ShowRecipe())
      end)
    end)
  end)

  describe("craft profit", function()
    before_each(function()
      setfenv(1, environment)
      settings.showMarketValue = false
      settings.showBuyout = false
      settings.tooltipDetails = "compact"
      settings.showCraftProfit = true
      marketResult.value = 200
      craftingResult = { cost = 100, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
      minimumCraftingResult = { cost = 80, outputQuantity = 2, isUncertain = false, reasons = {}, leaves = {} }
    end)

    it("shows Typical Profit per item without Shift and scales by the stack with Shift", function()
      setfenv(1, environment)
      assert.are.same({
        { "Typical Craft Cost", "money:100" },
        { "Current Craft Cost", "money:80" },
        { "Typical Profit", "+money:90" },
      }, ShowItem("item:100", "Item-3"))

      shiftDown = true
      assert.are.same({ "Typical Profit x3", "+money:270" }, ShowItem("item:100", "Item-3")[3])
    end)

    it("signs a loss", function()
      setfenv(1, environment)
      marketResult.value = 100
      assert.are.same({ "Typical Profit", "-money:5" }, ShowItem("item:100")[3])
    end)

    it("sells to a vendor when that pays more than the Typical price after the cut", function()
      setfenv(1, environment)
      -- The Typical price of 200 nets 190 after the cut, so a vendor's 150 loses and its 250 wins.
      vendorPrices[100] = 150
      assert.are.same({ "Typical Profit", "+money:90" }, ShowItem("item:100")[3])

      vendorPrices[100] = 250
      assert.are.same({ "Typical Profit", "+money:150" }, ShowItem("item:100")[3])

      shiftDown = true
      assert.are.same({ "Typical Profit x3", "+money:450" }, ShowItem("item:100", "Item-3")[3])
    end)

    it("shows a vendor's profit on items that cannot be auctioned", function()
      setfenv(1, environment)
      C_Item.GetItemInfo = function(item)
        return "Item", item, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 1
      end
      vendorPrices[100] = 250
      assert.are.same({ "Typical Profit", "+money:150" }, ShowItem("item:100")[3])
    end)

    it("stays white when a vendor's fixed price beats an uncertain Typical price", function()
      setfenv(1, environment)
      marketResult.isUncertain = true
      vendorPrices[100] = 250
      assert.are.same({ "Typical Profit", "+money:150" }, ShowItem("item:100")[3])
    end)

    it("turns yellow when the Typical or the Typical Craft Cost is uncertain", function()
      setfenv(1, environment)
      marketResult.isUncertain = true
      assert.are.same({ "Typical Profit", "+yellow:money:90" }, ShowItem("item:100")[3])

      marketResult.isUncertain = false
      craftingResult.isUncertain = true
      assert.are.same({ "Typical Profit", "+yellow:money:90" }, ShowItem("item:100")[3])
    end)

    it("needs a Typical or vendor price and a known Typical Craft Cost", function()
      setfenv(1, environment)
      marketResult = nil
      assert.are.equal(2, #ShowItem("item:100"))

      marketResult = { value = 200, latest = NOW, dayCount = 3, scanCount = 4, reasons = {}, isUncertain = false }
      craftingResult = { isUnknown = true }
      assert.are.same(
        { { "Typical Craft Cost", "Unknown  " }, { "Current Craft Cost", "money:80" } },
        ShowItem("item:100")
      )
    end)

    it("is left off items that can be neither auctioned nor sold to a vendor", function()
      setfenv(1, environment)
      C_Item.GetItemInfo = function(item)
        return "Item", item, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 1
      end
      assert.are.equal(2, #ShowItem("item:100"))
    end)

    it("controls the two cost lines and Typical Profit independently", function()
      setfenv(1, environment)
      local priceLines = {
        { "showCraftingCost", "Typical Craft Cost", "money:100" },
        { "showMinimumCraftCost", "Current Craft Cost", "money:80" },
        { "showCraftProfit", "Typical Profit", "+money:90" },
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
        assert.are.same(
          expected,
          ShowItem("item:100"),
          "respects independent visibility for combination " .. combination
        )
      end
    end)

    it("hides the crafting breakdown when only Typical Profit is shown, even with details", function()
      setfenv(1, environment)
      settings.showCraftingCost = false
      settings.showMinimumCraftCost = false
      settings.tooltipDetails = "always"
      craftingResult.isUncertain = true
      craftingResult.reasons = { "stale" }
      assert.are.same({ { "Typical Profit", "+yellow:money:90" } }, ShowItem("item:100"))
    end)

    it("skips pricing what neither a cost line nor Typical Profit shows", function()
      setfenv(1, environment)
      settings.showCraftingCost = false
      settings.showCraftProfit = false
      ns.Crafting.GetCostForItemID = function()
        error("must not calculate hidden rolling prices")
      end
      ns.RollingMarketValue.Get = function()
        error("must not look up a Typical for a hidden Typical Profit")
      end
      assert.are.same({ { "Current Craft Cost", "money:80" } }, ShowItem("item:100"))

      settings.showMinimumCraftCost = false
      ns.Crafting.GetScanCostForItemID = function()
        error("must not calculate hidden best-case prices")
      end
      assert.are.equal(0, #ShowItem("item:100"))
    end)
  end)
end)

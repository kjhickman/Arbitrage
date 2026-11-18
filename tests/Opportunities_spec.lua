local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Opportunities", function()
  local environment
  local ns, sellPrices, requestedItemIDs, settings, currentCharacter
  local outputs, marketValues, typicalCosts, minimumCosts

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    sellPrices = {}
    requestedItemIDs = {}
    C_Item = {
      RequestLoadItemDataByID = function(itemID)
        requestedItemIDs[#requestedItemIDs + 1] = itemID
      end,
    }
    settings = {
      includeBestCaseOnly = true,
      showUncertainOpportunities = true,
      minimumProfit = 1,
      craftingWindowMinimumProfit = 1,
      opportunityProfession = "",
      opportunityCrafter = "",
      opportunitySaleMethod = "",
    }
    currentCharacter = "Main"
    outputs = {
      {
        outputItemID = 100,
        sources = {
          { characterName = "Alt", professionName = "Alchemy", recipeKey = "shared" },
          { characterName = "Main", professionName = "Alchemy", recipeKey = "alternative" },
          { characterName = "Main", professionName = "Alchemy", recipeKey = "shared" },
        },
      },
      {
        outputItemID = 200,
        sources = {
          { characterName = "Main", professionName = "Blacksmithing", recipeKey = "item-200" },
        },
      },
      {
        outputItemID = 250,
        sources = {
          { characterName = "Main", professionName = "Tailoring", recipeKey = "item-250" },
        },
      },
      {
        outputItemID = 260,
        sources = {
          { characterName = "Main", professionName = "Tailoring", recipeKey = "item-260" },
        },
      },
      { outputItemID = 300, sources = {} },
      { outputItemID = 400, sources = {} },
    }
    marketValues = {
      [100] = { value = 10000, isUncertain = false, reasons = {} },
      [200] = { value = 10000, isUncertain = true, reasons = { "limited scans" } },
      [250] = { value = 10000, isUncertain = false, reasons = {} },
      [260] = { value = 10000, isUncertain = false, reasons = {} },
      [400] = { value = 10000, isUncertain = false, reasons = {} },
    }
    typicalCosts = {
      [100] = {
        cost = 4000,
        outputQuantity = 2,
        recipeKey = "shared",
        isUncertain = false,
        reasons = {},
      },
      [200] = {
        cost = 11000,
        outputQuantity = 1,
        recipeKey = "item-200",
        isUncertain = true,
        reasons = { "stale", "limited scans" },
      },
      [250] = {
        cost = 10000,
        outputQuantity = 1,
        recipeKey = "item-250",
        isUncertain = false,
        reasons = {},
      },
      [260] = {
        cost = 9500,
        outputQuantity = 1,
        recipeKey = "item-260",
        isUncertain = false,
        reasons = {},
      },
      [400] = { isUnknown = true },
    }
    minimumCosts = {
      [100] = {
        cost = 3000,
        outputQuantity = 2,
        recipeKey = "shared",
        isUncertain = false,
        reasons = {},
      },
      [200] = {
        cost = 9000,
        outputQuantity = 1,
        recipeKey = "item-200",
        isUncertain = false,
        reasons = {},
      },
    }
    ns = {
      Vendor = {
        GetSellPrice = function(itemID)
          return sellPrices[itemID]
        end,
      },
      Config = {
        CURRENT_CHARACTER = "@current",
        Get = function(key)
          return settings[key]
        end,
      },
      Realm = {
        GetCharacterName = function()
          return currentCharacter
        end,
      },
      Crafting = {
        GetCostForItemID = function(itemID)
          return typicalCosts[itemID]
        end,
        -- A Buyout Cost exists only for the recipe it was planned with.
        GetMinimumCostForItemID = function(itemID, recipeKey)
          local plan = minimumCosts[itemID]
          if plan and plan.recipeKey == recipeKey then
            return plan
          end
        end,
        GetRecipeCosts = function(recipe)
          return typicalCosts[recipe.outputItemID], minimumCosts[recipe.outputItemID]
        end,
      },
      Database = {},
      RecipeBook = {
        GetCraftableOutputs = function()
          return outputs
        end,
      },
      RollingMarketValue = {
        Get = function(keys)
          return marketValues[tonumber(keys[1])]
        end,
      },
    }
    assert(loadfile("src/Opportunities.lua"), "loads Opportunities.lua")("Arbitrage", ns)
  end)

  it("counts known, priced, and profitable outputs before visibility filters", function()
    setfenv(1, environment)
    local result = ns.Opportunities.Get()
    assert(result.totalCount == 6 and result.pricedCount == 4, "counts known and fully priced craftable outputs")
    assert(result.profitableCount == 2, "counts profitable outputs before visibility filters")
    assert(#result.items == 2, "omits crafts without a positive Profit or Buyout Profit")
  end)

  local function ItemIDs(result)
    local itemIDs = {}
    for index, opportunity in ipairs(result.items) do
      itemIDs[index] = opportunity.itemID
    end
    return itemIDs
  end

  it("shows only crafts one crafter makes with the chosen profession, keeping the counts", function()
    setfenv(1, environment)
    settings.opportunityProfession = "Blacksmithing"
    local result = ns.Opportunities.Get()
    assert.are.same({ 200 }, ItemIDs(result))
    assert.are.equal(2, result.profitableCount)

    settings.opportunityProfession = ""
    settings.opportunityCrafter = "Alt"
    assert.are.same({ 100 }, ItemIDs(ns.Opportunities.Get()))

    settings.opportunityProfession = "Blacksmithing"
    assert.are.same({}, ItemIDs(ns.Opportunities.Get()))

    settings.opportunityCrafter = "Main"
    assert.are.same({ 200 }, ItemIDs(ns.Opportunities.Get()))
  end)

  it("follows the logged-in character for the current-character crafter filter", function()
    setfenv(1, environment)
    settings.opportunityCrafter = "@current"
    currentCharacter = "Alt"
    assert.are.same({ 100 }, ItemIDs(ns.Opportunities.Get()))

    currentCharacter = "Main"
    assert.are.same({ 100, 200 }, ItemIDs(ns.Opportunities.Get()))
  end)

  it("shows only crafts whose better sale is the chosen sale method, keeping the counts", function()
    setfenv(1, environment)
    sellPrices[200] = 20000
    settings.opportunitySaleMethod = "vendor"
    local result = ns.Opportunities.Get()
    assert.are.same({ 200 }, ItemIDs(result))
    assert.are.equal(2, result.profitableCount)

    settings.opportunitySaleMethod = "auction"
    assert.are.same({ 100 }, ItemIDs(ns.Opportunities.Get()))
  end)

  it("reports reliable per-item auction profits, per-craft totals, and sources for the selected recipe", function()
    setfenv(1, environment)
    local result = ns.Opportunities.Get()
    local opportunitiesByItemID = {}
    for _, opportunity in ipairs(result.items) do
      opportunitiesByItemID[opportunity.itemID] = opportunity
    end

    local first = opportunitiesByItemID[100]
    assert(first.outputQuantity == 2, "reports the selected recipe output quantity")
    assert(first.saleProceeds == 9500, "deducts the faction Auction House cut from per-item proceeds")
    assert(first.saleMethod == "auction" and first.auctionSaleProceeds == 9500, "identifies Auction House proceeds")
    assert(first.craftCost == 4000 and first.profit == 5500, "calculates typical cost and profit per item")
    assert(first.roi == 1.375, "calculates return on crafting cost")
    assert(
      first.minimumCraftCost == 3000 and first.minimumProfit == 6500,
      "calculates the latest-scan Buyout Cost for the selected rolling recipe"
    )
    assert.are.same({
      saleProceeds = 19000,
      craftCost = 8000,
      profit = 11000,
      minimumCraftCost = 6000,
      minimumProfit = 13000,
    }, first.perCraft)
    assert(#first.sources == 2, "keeps only crafters who know the selected recipe")
    assert(first.sources[1].characterName == "Alt" and first.sources[2].characterName == "Main", "keeps source order")
    assert(not first.isUncertain and #first.reasons == 0, "keeps reliable opportunities unmarked")
    assert(
      not first.marketIsUncertain and not first.craftCostIsUncertain and not first.minimumCraftCostIsUncertain,
      "marks each reliable value source"
    )
  end)

  it("keeps and marks buyout-only crafts and deduplicates their uncertainty reasons", function()
    setfenv(1, environment)
    local result = ns.Opportunities.Get()
    local opportunitiesByItemID = {}
    for _, opportunity in ipairs(result.items) do
      opportunitiesByItemID[opportunity.itemID] = opportunity
    end

    local second = opportunitiesByItemID[200]
    assert(
      second.itemID == 200 and second.profit == -1500 and second.minimumProfit == 500,
      "keeps crafts that are profitable only at latest minimum prices"
    )
    assert.is_true(second.isBuyoutOnly, "marks crafts listed only for their Buyout Profit")
    assert.is_false(opportunitiesByItemID[100].isBuyoutOnly, "leaves crafts whose Profit qualifies unmarked")
    assert(second.isUncertain, "combines output and crafting uncertainty")
    assert(
      table.concat(second.reasons, ",") == "limited scans,stale",
      "deduplicates uncertainty reasons in a stable order"
    )
    assert(
      second.marketIsUncertain and second.craftCostIsUncertain and not second.minimumCraftCostIsUncertain,
      "reports uncertainty for each value source"
    )
  end)

  it("hides buyout-only opportunities without changing the profitable count", function()
    setfenv(1, environment)
    settings.includeBestCaseOnly = false
    local result = ns.Opportunities.Get()
    assert(
      result.pricedCount == 4 and result.profitableCount == 2 and #result.items == 1,
      "can hide opportunities profitable only at Buyout Cost without changing the profitable count"
    )
    assert(result.items[1].itemID == 100, "keeps opportunities with positive estimated profit")
  end)

  it("lists every priced craft when the profit filter is off, marking none as buyout-only", function()
    setfenv(1, environment)
    settings.minimumProfit = 0
    local result = ns.Opportunities.Get()
    assert(
      result.pricedCount == 4 and result.profitableCount == 2 and #result.items == 4,
      "lists unprofitable crafts without changing the profitable count"
    )
    for _, opportunity in ipairs(result.items) do
      assert.is_false(opportunity.isBuyoutOnly)
    end
  end)

  it("hides crafts that do not clear the minimum profit", function()
    setfenv(1, environment)
    settings.minimumProfit = 5000
    local result = ns.Opportunities.Get()
    assert(#result.items == 1 and result.items[1].itemID == 100, "keeps only crafts clearing the threshold")

    settings.minimumProfit = 20000
    result = ns.Opportunities.Get()
    assert(#result.items == 0 and result.profitableCount == 2, "can hide every craft without hiding the count")
  end)

  it("ignores the crafting-window threshold when filtering Auction House opportunities", function()
    setfenv(1, environment)
    settings.minimumProfit = 5000
    settings.craftingWindowMinimumProfit = 1000000
    local result = ns.Opportunities.Get()
    assert.are.equal(1, #result.items)
    assert.are.equal(100, result.items[1].itemID)

    settings.craftingWindowMinimumProfit = 0
    assert.same(result.items, ns.Opportunities.Get().items)
    settings.minimumProfit = 20000
    assert.are.equal(0, #ns.Opportunities.Get().items)
  end)

  it("measures the minimum profit against Buyout Profit when buyout-only crafts are included", function()
    setfenv(1, environment)
    settings.minimumProfit = 500
    assert(#ns.Opportunities.Get().items == 2, "keeps a craft whose Buyout Profit clears the threshold")

    settings.includeBestCaseOnly = false
    assert(#ns.Opportunities.Get().items == 1, "drops it again when buyout-only crafts are excluded")
  end)

  it("hides uncertain opportunities without changing the profitable count", function()
    setfenv(1, environment)
    settings.showUncertainOpportunities = false
    local result = ns.Opportunities.Get()
    assert(
      result.pricedCount == 4 and result.profitableCount == 2 and #result.items == 1,
      "can hide uncertain opportunities without changing the profitable count"
    )
    assert(result.items[1].itemID == 100, "keeps reliable opportunities")
  end)

  it("uses exact costs for finite ROI and rounded costs when switching to higher vendor proceeds", function()
    setfenv(1, environment)
    outputs = { { outputItemID = 500, sources = {} } }
    marketValues[500] = { value = 100, isUncertain = false, reasons = {} }
    typicalCosts[500] = {
      cost = 0.04,
      outputQuantity = 1,
      recipeKey = "batch-reagent",
      isUncertain = false,
      reasons = {},
    }
    local result = ns.Opportunities.Get()
    assert(result.items[1].roi < math.huge, "calculates finite ROI from an unrounded positive craft cost")

    sellPrices[500] = 120
    result = ns.Opportunities.Get()
    local vendor = result.items[1]
    assert(vendor.saleMethod == "vendor" and vendor.saleProceeds == 120, "selects higher vendor proceeds")
    assert(vendor.vendorSaleProceeds == 120 and vendor.auctionSaleProceeds == 95, "retains both sale alternatives")
    assert(vendor.profit == 120, "subtracts the rounded craft cost from vendor proceeds")
  end)

  it("prices individual recipes without profitability or uncertainty filters", function()
    setfenv(1, environment)
    settings.includeBestCaseOnly = false
    settings.showUncertainOpportunities = false
    local recipe = { outputItemID = 200, recipeKey = "item-200" }
    local opportunity = assert(ns.Opportunities.GetForRecipe(recipe))
    assert.are.equal(-1500, opportunity.profit)
    assert.are.equal(500, opportunity.minimumProfit)
    assert.is_false(opportunity.isBuyoutOnly)
    assert.is_true(opportunity.isUncertain)
    assert.same({}, opportunity.sources)
    assert.is_nil(ns.Opportunities.GetForRecipe({ outputItemID = 400, recipeKey = "unknown" }))
  end)

  it("does not substitute a cheaper recipe or its batch size in an individual estimate", function()
    setfenv(1, environment)
    local recipes = {
      {
        recipeKey = "shared",
        outputQuantity = 2,
        reagents = { { itemID = 700, quantity = 1 } },
      },
      {
        outputItemID = 100,
        recipeKey = "alternative",
        outputQuantity = 1,
        reagents = { { itemID = 800, quantity = 1 } },
      },
    }
    ns.RecipeBook.GetRecipes = function(itemID)
      return itemID == 100 and { recipes[1] } or {}
    end
    ns.Database.GetVendorPrice = function() end
    ns.Database.GetLatestBuyout = function(itemID)
      return ({ [700] = 4000, [800] = 9000 })[itemID]
    end
    marketValues[700] = { value = 10000 }
    marketValues[800] = { value = 10000 }
    sellPrices[100] = 0
    assert(loadfile("src/CraftingPlanner.lua"))("Arbitrage", ns)
    assert(loadfile("src/Crafting.lua"))("Arbitrage", ns)

    local opportunity = assert(ns.Opportunities.GetForRecipe(recipes[2]))
    assert.are.equal(1, opportunity.outputQuantity)
    assert.are.equal(10000, opportunity.craftCost)
    assert.are.equal(-500, opportunity.profit)
    assert.are.equal(500, opportunity.minimumProfit)
    assert.are.same({ itemID = 800, quantity = 1, price = 10000, source = "auction" }, opportunity.materials[800])
    local cheapest = ns.Opportunities.Get().items[1]
    assert.are.equal(4500, cheapest.profit)
    assert.are.equal(0.5, cheapest.materials[700].quantity, "keeps the materials for one item")
  end)

  it("rounds per-item and per-craft totals once from exact values", function()
    setfenv(1, environment)
    outputs = { { outputItemID = 900, sources = {} } }
    marketValues[900] = { value = 15, isUncertain = false, reasons = {} }
    -- One reagent costing 7 copper makes 200 items.
    typicalCosts[900] = { cost = 0.035, outputQuantity = 200, isUncertain = false, reasons = {} }
    local opportunity = ns.Opportunities.Get().items[1]
    assert.are.equal(14, opportunity.saleProceeds)
    assert.are.equal(0, opportunity.craftCost)
    assert.are.equal(14, opportunity.profit)
    assert.are.equal(2850, opportunity.perCraft.saleProceeds)
    assert.are.equal(7, opportunity.perCraft.craftCost)
    assert.are.equal(2843, opportunity.perCraft.profit)
  end)

  it("prices the best recipe the chosen crafter knows when another crafter knows a cheaper one", function()
    setfenv(1, environment)
    outputs = {
      {
        outputItemID = 700,
        sources = {
          { characterName = "Alt", professionName = "Tailoring", recipeKey = "cheap" },
          { characterName = "Main", professionName = "Leatherworking", recipeKey = "dear" },
        },
      },
    }
    local recipes = {
      { outputItemID = 700, recipeKey = "cheap", outputQuantity = 1, reagents = { { itemID = 701, quantity = 1 } } },
      { outputItemID = 700, recipeKey = "dear", outputQuantity = 1, reagents = { { itemID = 702, quantity = 1 } } },
    }
    ns.RecipeBook.GetRecipes = function(itemID)
      return itemID == 700 and recipes or {}
    end
    ns.Database.GetVendorPrice = function() end
    ns.Database.GetLatestBuyout = function() end
    marketValues[700] = { value = 10000, isUncertain = false, reasons = {} }
    marketValues[701] = { value = 1000 }
    marketValues[702] = { value = 5000 }
    assert(loadfile("src/CraftingPlanner.lua"))("Arbitrage", ns)
    assert(loadfile("src/Crafting.lua"))("Arbitrage", ns)

    local function OnlyItem()
      local result = ns.Opportunities.Get()
      assert.are.equal(1, #result.items)
      local crafters = {}
      for index, source in ipairs(result.items[1].sources) do
        crafters[index] = source.characterName
      end
      return result.items[1], crafters
    end

    local opportunity, crafters = OnlyItem()
    assert.are.equal(1000, opportunity.craftCost)
    assert.are.same({ "Alt" }, crafters)

    settings.opportunityCrafter = "Main"
    opportunity, crafters = OnlyItem()
    assert.are.equal(5000, opportunity.craftCost)
    assert.are.equal(4500, opportunity.profit)
    assert.are.same({ "Main" }, crafters)

    settings.opportunityCrafter = ""
    settings.opportunityProfession = "Leatherworking"
    assert.are.equal(5000, OnlyItem().craftCost)
  end)

  describe("vendor opportunities", function()
    before_each(function()
      setfenv(1, environment)
      outputs = { { outputItemID = 600, sources = {} } }
      typicalCosts[600] = { cost = 40, outputQuantity = 2, isUncertain = false, reasons = {} }
      minimumCosts[600] = { cost = 30, outputQuantity = 2, isUncertain = false, reasons = {} }
      sellPrices[600] = 50
    end)

    it("prices each crafted item without market data or any Auction House cut", function()
      setfenv(1, environment)
      local result = ns.Opportunities.Get()
      local vendor = result.items[1]
      assert(result.pricedCount == 1 and result.profitableCount == 1, "prices vendor crafts without an output AH price")
      assert(vendor.saleProceeds == 50 and vendor.profit == 10, "evaluates one crafted item without an AH cut")
      assert(vendor.minimumCraftCost == 30 and vendor.minimumProfit == 20, "reuses latest-scan costs for vendor profit")
      assert(
        vendor.perCraft.saleProceeds == 100 and vendor.perCraft.profit == 20 and vendor.perCraft.minimumProfit == 40,
        "totals the full crafted quantity"
      )
      assert(
        vendor.auctionSaleProceeds == nil and not vendor.isUncertain,
        "does not require output market data for vendors"
      )
    end)

    it("ignores unused output-market uncertainty but propagates and filters material uncertainty", function()
      setfenv(1, environment)
      marketValues[600] = { value = 51, isUncertain = true, reasons = { "stale output" } }
      settings.showUncertainOpportunities = false
      local vendor = ns.Opportunities.Get().items[1]
      assert(vendor.saleMethod == "vendor" and not vendor.marketIsUncertain, "ignores unused output-market uncertainty")
      assert(
        vendor.auctionIsUncertain and table.concat(vendor.auctionReasons, ",") == "stale output",
        "preserves market confidence for the alternative AH estimate"
      )
      assert(#vendor.reasons == 0, "keeps vendor opportunities visible when only the AH output price is uncertain")
      typicalCosts[600].isUncertain = true
      typicalCosts[600].reasons = { "stale materials" }
      assert(#ns.Opportunities.Get().items == 0, "still filters vendor crafts with uncertain material costs")
      settings.showUncertainOpportunities = true
      vendor = ns.Opportunities.Get().items[1]
      assert(table.concat(vendor.reasons, ",") == "stale materials", "propagates only relevant vendor uncertainty")
    end)

    it("switches to higher auction proceeds but prefers fixed vendor proceeds on ties", function()
      setfenv(1, environment)
      ns.Opportunities.Get()
      marketValues[600] = { value = 100, isUncertain = false, reasons = {} }
      local auction = ns.Opportunities.Get().items[1]
      assert(
        auction.saleMethod == "auction" and auction.saleProceeds == 95,
        "keeps AH sales when net proceeds are higher"
      )
      assert(auction.vendorSaleProceeds == 50, "retains vendor proceeds when AH sales are selected")
      marketValues[600] = { value = 100, isUncertain = true, reasons = { "limited scans" } }
      sellPrices[600] = 95
      local vendor = ns.Opportunities.Get().items[1]
      assert(
        vendor.saleMethod == "vendor" and not vendor.isUncertain,
        "prefers fixed vendor proceeds when net values tie"
      )
    end)

    it("does not price nonsellable items as vendor opportunities", function()
      setfenv(1, environment)
      sellPrices[600] = 0
      minimumCosts[600] = nil
      local result = ns.Opportunities.Get()
      assert(result.pricedCount == 0 and #result.items == 0, "does not price nonsellable items as vendor opportunities")
    end)

    it("deduplicates pending item-data requests, retries failures, and clears completed requests", function()
      setfenv(1, environment)
      sellPrices[600] = nil
      minimumCosts[600] = nil
      local result = ns.Opportunities.Get()
      assert(
        result.pricedCount == 0 and requestedItemIDs[1] == 600,
        "requests uncached sell prices for otherwise priced crafts"
      )
      ns.Opportunities.Get()
      assert(#requestedItemIDs == 1, "does not repeat pending item-data requests")
      assert(not ns.Opportunities.HandleItemInfoReceived(999, true), "ignores unrelated item-data events")
      assert(
        not ns.Opportunities.HandleItemInfoReceived(600, false),
        "does not refresh immediately after a failed request"
      )
      ns.Opportunities.Get()
      assert(#requestedItemIDs == 2, "retries failed price requests on the next evaluation")
      sellPrices[600] = 50
      assert(
        ns.Opportunities.HandleItemInfoReceived(600, true),
        "requests reevaluation when a pending sell price loads"
      )
      assert(ns.Opportunities.Get().items[1].profit == 10, "finds a vendor opportunity after item data arrives")
      assert(not ns.Opportunities.HandleItemInfoReceived(600, true), "clears completed price requests")
    end)
  end)
end)

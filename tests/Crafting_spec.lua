local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Crafting", function()
  local environment
  local ns, recipes, prices, GetRecipes, GetPrice

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ns = {}
    recipes = {
      [100] = {
        { outputQuantity = 1, reagents = { { itemID = 200, quantity = 2, name = "Ingot" } } },
      },
      [200] = {
        { outputQuantity = 1, reagents = { { itemID = 300, quantity = 1, name = "Ore" } } },
      },
      [400] = {
        { outputQuantity = 1, reagents = { { itemID = 500, quantity = 1, name = "Cycle B" } } },
      },
      [500] = {
        { outputQuantity = 1, reagents = { { itemID = 400, quantity = 1, name = "Cycle A" } } },
      },
      [600] = {
        {
          recipeKey = "expensive",
          outputQuantity = 1,
          reagents = { { itemID = 700, quantity = 1, name = "Expensive" } },
        },
        { recipeKey = "cheap", outputQuantity = 2, reagents = { { itemID = 800, quantity = 2, name = "Cheap" } } },
      },
      [1000] = {
        {
          outputQuantity = 1,
          reagents = {
            { itemID = 1100, quantity = 1, name = "First Branch" },
            { itemID = 1200, quantity = 1, name = "Second Branch" },
          },
        },
      },
      [1100] = {
        { outputQuantity = 1, reagents = { { itemID = 1300, quantity = 1, name = "Cycle" } } },
        { outputQuantity = 1, reagents = { { itemID = 1400, quantity = 1, name = "Fallback" } } },
      },
      [1200] = {
        { outputQuantity = 1, reagents = { { itemID = 1300, quantity = 1, name = "Cycle" } } },
      },
      [1300] = {
        { outputQuantity = 1, reagents = { { itemID = 1100, quantity = 1, name = "First Branch" } } },
      },
    }
    prices = {
      [200] = 10,
      [300] = 3,
      [400] = 8,
      [700] = 10,
      [800] = { value = 3, isUncertain = true, reasons = { "stale" } },
      [1400] = 1,
    }
    GetRecipes = function(itemID)
      return recipes[itemID] or {}
    end
    GetPrice = function(itemID)
      return prices[itemID]
    end
    ns.RecipeBook = { GetRecipes = GetRecipes }
    ns.Database = {
      GetLatestBuyout = function(itemID)
        return ({ ["200"] = 10, ["300"] = 3, ["700"] = 4, ["800"] = 1 })[tostring(itemID)]
      end,
      GetVendorPrice = function(itemID)
        return itemID == 300 and 2 or nil
      end,
    }
    ns.RollingMarketValue = {
      Get = function()
        return nil
      end,
    }
    assert(loadfile("src/CraftingPlanner.lua"), "loads CraftingPlanner.lua")("Arbitrage", ns)
    assert(loadfile("src/Crafting.lua"), "loads Crafting.lua")("Arbitrage", ns)
  end)

  it("breaks equal-cost recipe ties by key regardless of input order", function()
    setfenv(1, environment)
    local tiedRecipes = {
      { recipeKey = "z-single", outputQuantity = 1, reagents = { { itemID = 710, quantity = 1 } } },
      { recipeKey = "a-batch", outputQuantity = 2, reagents = { { itemID = 810, quantity = 2 } } },
    }
    prices[710] = 4
    prices[810] = 4

    local tiedPlan = assert(ns.CraftingPlanner.Calculate(650, function(itemID)
      return itemID == 650 and tiedRecipes or {}
    end, GetPrice))
    assert(tiedPlan.recipeKey == "a-batch", "breaks equal-cost recipe ties by recipe key")

    tiedRecipes[1], tiedRecipes[2] = tiedRecipes[2], tiedRecipes[1]
    tiedPlan = assert(ns.CraftingPlanner.Calculate(650, function(itemID)
      return itemID == 650 and tiedRecipes or {}
    end, GetPrice))
    assert(tiedPlan.recipeKey == "a-batch", "selects the same equal-cost recipe regardless of input order")
  end)

  it("switches from crafting to buying intermediates when reagent prices rise", function()
    setfenv(1, environment)
    local plan = assert(ns.CraftingPlanner.Calculate(100, GetRecipes, GetPrice))
    assert(plan.cost == 6, "crafts ingots when ore is cheaper")
    assert(plan.leaves[300].quantity == 2, "aggregates purchased ore")
    assert(plan.leaves[200] == nil, "does not buy crafted ingots")

    prices[300] = 12
    plan = assert(ns.CraftingPlanner.Calculate(100, GetRecipes, GetPrice))
    assert(plan.cost == 20, "buys ingots when ore is more expensive")
    assert(plan.leaves[200].quantity == 2, "aggregates purchased ingots")
  end)

  it("records which craftable materials a plan makes and which it buys only when asked", function()
    setfenv(1, environment)
    recipes[100][1].recipeKey = "forge"
    recipes[200][1].recipeKey = "smelt"
    recipes[900] = { { recipeKey = "top", outputQuantity = 1, reagents = { { itemID = 100, quantity = 1 } } } }

    assert.is_nil(assert(ns.CraftingPlanner.Calculate(900, GetRecipes, GetPrice)).choices)
    local plan = assert(ns.CraftingPlanner.Calculate(900, GetRecipes, GetPrice, true))
    -- Ore has no recipe, so only what could be either made or bought has a choice.
    assert.are.same({ [100] = "forge", [200] = "smelt" }, plan.choices)

    prices[300] = 12
    plan = assert(ns.CraftingPlanner.Calculate(900, GetRecipes, GetPrice, true))
    assert.are.same({ [100] = "forge", [200] = false }, plan.choices)

    -- A material bought outright keeps no choices from the recipe it passed over.
    prices[100] = 1
    plan = assert(ns.CraftingPlanner.Calculate(900, GetRecipes, GetPrice, true))
    assert.are.same({ [100] = false }, plan.choices)
  end)

  it("reports the choices behind a recipe's costs at Buyout prices or Market Value", function()
    setfenv(1, environment)
    recipes[100][1].recipeKey = "forge"
    recipes[200][1].recipeKey = "smelt"
    -- At Buyout prices ingots cost more than the ore to smelt them; at Market Value they cost less.
    ns.RollingMarketValue.Get = function(keys)
      return ({ ["200"] = 1, ["300"] = 3 })[keys[1]]
    end
    ns.Database.GetVendorPrice = function()
      return nil
    end

    assert.are.same({ [200] = "smelt" }, ns.Crafting.GetChoices(100, "forge", true))
    assert.are.same({ [200] = false }, ns.Crafting.GetChoices(100, "forge", false))
    assert.is_nil(ns.Crafting.GetChoices(100, "missing", true))
  end)

  it("buys a material from a vendor only when it's cheaper than the Buyout", function()
    setfenv(1, environment)
    assert.are.same({ value = 2, source = "vendor" }, ns.Crafting.GetBuyoutPurchasePrice(300))
    assert.are.same({ value = 10, source = "auction" }, ns.Crafting.GetBuyoutPurchasePrice(200))
    assert.is_nil(ns.Crafting.GetBuyoutPurchasePrice(999))
  end)

  it("breaks craft cycles with a market purchase", function()
    setfenv(1, environment)
    local plan = assert(ns.CraftingPlanner.Calculate(400, GetRecipes, GetPrice))
    assert(plan.cost == 8, "uses a market quote to break a craft cycle")
    assert(plan.leaves[400].quantity == 1, "records the cycle-breaking purchase")
  end)

  it("chooses the cheapest recipe per output and propagates its price uncertainty", function()
    setfenv(1, environment)
    local plan = assert(ns.CraftingPlanner.Calculate(600, GetRecipes, GetPrice))
    assert(plan.cost == 3, "chooses the cheapest alternative recipe per output item")
    assert(plan.leaves[800].quantity == 1, "normalizes materials by the guaranteed output")
    assert(plan.recipeKey == "cheap" and plan.outputQuantity == 2, "identifies the selected root recipe and its output")
    assert(plan.isUncertain, "propagates market-price uncertainty")
    assert(plan.reasons[1] == "stale", "keeps market-price uncertainty reasons")
  end)

  it("does not reuse cycle-context results across branches", function()
    setfenv(1, environment)
    local plan = assert(ns.CraftingPlanner.Calculate(1000, GetRecipes, GetPrice))
    assert(plan.cost == 2, "does not reuse a cycle-context result in another branch")
  end)

  it("has no cost for an item no recipe makes, and an unknown one when its recipes can't be priced", function()
    setfenv(1, environment)
    assert.is_nil(ns.Crafting.GetCostForItemID(300))
    -- Nothing prices the cycle's materials, and no recipe of 600's is the one asked for.
    assert.are.same({ isUnknown = true }, ns.Crafting.GetCostForItemID(400))
    assert.are.same({ isUnknown = true }, ns.Crafting.GetCostForItemID(600, { missing = true }))
  end)

  it("prices a specific root recipe for a comparable best case", function()
    setfenv(1, environment)
    local plan = assert(ns.Crafting.GetScanCostForItemID(600, { expensive = true }))
    assert(
      plan.cost == 4 and plan.recipeKey == "expensive",
      "can price a specific root recipe for a comparable best case"
    )
  end)

  it("restricts rolling costs to the recipe shown instead of a cheaper alternative", function()
    setfenv(1, environment)
    ns.RollingMarketValue.Get = function(keys)
      return prices[tonumber(keys[1])]
    end

    local recipe = recipes[600][1]
    recipe.outputItemID = 600
    local plan, minimumPlan = ns.Crafting.GetRecipeCosts({ recipe })
    assert.are.equal("expensive", plan.recipeKey)
    assert.are.equal(10, plan.cost)
    assert.are.equal(1, plan.outputQuantity)
    assert.are.equal(4, minimumPlan.cost)
    recipes[600] = {}
    plan, minimumPlan = ns.Crafting.GetRecipeCosts({ recipe })
    assert.are.equal(10, plan.cost)
    assert.are.equal(4, minimumPlan.cost)
  end)

  it("reprices minimum and rolling craft paths as vendor and auction quotes change", function()
    setfenv(1, environment)
    local plan = assert(ns.Crafting.GetScanCostForItemID(100))
    assert(plan.cost == 4, "uses a cheaper vendor price in the minimum craft path")
    assert(plan.leaves[300].source == "vendor", "records vendor as the purchase source")

    ns.Database.GetVendorPrice = function(itemID)
      return itemID == 300 and 4 or nil
    end
    plan = assert(ns.Crafting.GetScanCostForItemID(100))
    assert(plan.cost == 6, "uses the Auction House when it is cheaper than the vendor")
    assert(plan.leaves[300].source == "auction", "records the Auction House as the purchase source")

    ns.Database.GetVendorPrice = function(itemID)
      return itemID == 300 and 3 or nil
    end
    plan = assert(ns.Crafting.GetScanCostForItemID(100))
    assert(plan.leaves[300].source == "auction", "uses the Auction House when its price ties the vendor")

    ns.RollingMarketValue.Get = function(keys)
      return ({
        ["200"] = { value = 10, isUncertain = true, reasons = { "stale" } },
        ["300"] = { value = 3, isUncertain = true, reasons = { "stale" } },
      })[keys[1]]
    end
    ns.Database.GetVendorPrice = function(itemID)
      return itemID == 300 and 2 or nil
    end
    plan = assert(ns.Crafting.GetCostForItemID(100))
    assert(plan.cost == 4, "uses a cheaper vendor price in the rolling craft path")
    assert(not plan.isUncertain, "does not inherit uncertainty from a rejected Auction House quote")
  end)
end)

local ns = {}
assert(loadfile("src/CraftingPlanner.lua"), "loads CraftingPlanner.lua")("Arbitrage", ns)
assert(loadfile("src/Crafting.lua"), "loads Crafting.lua")("Arbitrage", ns)
assert(ns.Crafting.Calculate == ns.CraftingPlanner.Calculate, "keeps the planner compatibility entry point")

local recipes = {
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
    { recipeKey = "expensive", outputQuantity = 1, reagents = { { itemID = 700, quantity = 1, name = "Expensive" } } },
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

local prices = {
  [200] = 10,
  [300] = 3,
  [400] = 8,
  [700] = 10,
  [800] = { value = 3, isUncertain = true, reasons = { "stale" } },
  [1400] = 1,
}
local function GetRecipes(itemID)
  return recipes[itemID] or {}
end
local function GetPrice(itemID)
  return prices[itemID]
end

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

local plan = assert(ns.CraftingPlanner.Calculate(100, GetRecipes, GetPrice))
assert(plan.cost == 6, "crafts ingots when ore is cheaper")
assert(plan.leaves[300].quantity == 2, "aggregates purchased ore")
assert(plan.leaves[200] == nil, "does not buy crafted ingots")

prices[300] = 12
plan = assert(ns.CraftingPlanner.Calculate(100, GetRecipes, GetPrice))
assert(plan.cost == 20, "buys ingots when ore is more expensive")
assert(plan.leaves[200].quantity == 2, "aggregates purchased ingots")

plan = assert(ns.CraftingPlanner.Calculate(400, GetRecipes, GetPrice))
assert(plan.cost == 8, "uses a market quote to break a craft cycle")
assert(plan.leaves[400].quantity == 1, "records the cycle-breaking purchase")

plan = assert(ns.CraftingPlanner.Calculate(600, GetRecipes, GetPrice))
assert(plan.cost == 3, "chooses the cheapest alternative recipe per output item")
assert(plan.leaves[800].quantity == 1, "normalizes materials by the guaranteed output")
assert(plan.recipeKey == "cheap" and plan.outputQuantity == 2, "identifies the selected root recipe and its output")
assert(plan.isUncertain, "propagates market-price uncertainty")
assert(plan.reasons[1] == "stale", "keeps market-price uncertainty reasons")

plan = assert(ns.CraftingPlanner.Calculate(1000, GetRecipes, GetPrice))
assert(plan.cost == 2, "does not reuse a cycle-context result in another branch")

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

plan = assert(ns.Crafting.GetMinimumCostForItemID(100))
assert(plan.cost == 4, "uses a cheaper vendor price in the minimum craft path")
assert(plan.leaves[300].source == "vendor", "records vendor as the purchase source")

plan = assert(ns.Crafting.GetMinimumCostForItemID(600, "expensive"))
assert(plan.cost == 4 and plan.recipeKey == "expensive", "can price a specific root recipe for a comparable best case")

ns.Database.GetVendorPrice = function(itemID)
  return itemID == 300 and 4 or nil
end
plan = assert(ns.Crafting.GetMinimumCostForItemID(100))
assert(plan.cost == 6, "uses the Auction House when it is cheaper than the vendor")
assert(plan.leaves[300].source == "auction", "records the Auction House as the purchase source")

ns.Database.GetVendorPrice = function(itemID)
  return itemID == 300 and 3 or nil
end
plan = assert(ns.Crafting.GetMinimumCostForItemID(100))
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

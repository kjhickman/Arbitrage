local ns = {}
assert(loadfile("Crafting.lua"), "loads Crafting.lua")("Arbitrage", ns)

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
    { outputQuantity = 1, reagents = { { itemID = 700, quantity = 1, name = "Expensive" } } },
    { outputQuantity = 2, reagents = { { itemID = 800, quantity = 2, name = "Cheap" } } },
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

local plan = assert(ns.Crafting.Calculate(100, GetRecipes, GetPrice))
assert(plan.cost == 6, "crafts ingots when ore is cheaper")
assert(plan.leaves[300].quantity == 2, "aggregates purchased ore")
assert(plan.leaves[200] == nil, "does not buy crafted ingots")

prices[300] = 12
plan = assert(ns.Crafting.Calculate(100, GetRecipes, GetPrice))
assert(plan.cost == 20, "buys ingots when ore is more expensive")
assert(plan.leaves[200].quantity == 2, "aggregates purchased ingots")

plan = assert(ns.Crafting.Calculate(400, GetRecipes, GetPrice))
assert(plan.cost == 8, "uses a market quote to break a craft cycle")
assert(plan.leaves[400].quantity == 1, "records the cycle-breaking purchase")

plan = assert(ns.Crafting.Calculate(600, GetRecipes, GetPrice))
assert(plan.cost == 3, "chooses the cheapest alternative recipe per output item")
assert(plan.leaves[800].quantity == 1, "normalizes materials by the guaranteed output")
assert(plan.isUncertain, "propagates market-price uncertainty")
assert(plan.reasons[1] == "stale", "keeps market-price uncertainty reasons")

plan = assert(ns.Crafting.Calculate(1000, GetRecipes, GetPrice))
assert(plan.cost == 2, "does not reuse a cycle-context result in another branch")

C_Item = {
  GetItemInfoInstant = function()
    return 100
  end,
}
ns.RecipeBook = { GetRecipes = GetRecipes }
ns.Database = {
  GetRollingMarketValue = function()
    return nil
  end,
  GetLatestBuyout = function(keys)
    return ({ ["200"] = 10, ["300"] = 3 })[keys[1]]
  end,
  GetVendorPrice = function(itemID)
    return itemID == 300 and 2 or nil
  end,
}

plan = assert(ns.Crafting.GetMinimumCost("item:100"))
assert(plan.value == 4, "uses a cheaper vendor price in the minimum craft path")
assert(plan.leaves[300].source == "vendor", "records vendor as the purchase source")

ns.Database.GetVendorPrice = function(itemID)
  return itemID == 300 and 4 or nil
end
plan = assert(ns.Crafting.GetMinimumCost("item:100"))
assert(plan.value == 6, "uses the Auction House when it is cheaper than the vendor")
assert(plan.leaves[300].source == "auction", "records the Auction House as the purchase source")

ns.Database.GetVendorPrice = function(itemID)
  return itemID == 300 and 3 or nil
end
plan = assert(ns.Crafting.GetMinimumCost("item:100"))
assert(plan.leaves[300].source == "auction", "uses the Auction House when its price ties the vendor")

ns.Database.GetRollingMarketValue = function(keys)
  return ({
    ["200"] = { value = 10, isUncertain = true, reasons = { "stale" } },
    ["300"] = { value = 3, isUncertain = true, reasons = { "stale" } },
  })[keys[1]]
end
ns.Database.GetVendorPrice = function(itemID)
  return itemID == 300 and 2 or nil
end
plan = assert(ns.Crafting.GetCost("item:100"))
assert(plan.value == 4, "uses a cheaper vendor price in the rolling craft path")
assert(not plan.isUncertain, "does not inherit uncertainty from a rejected Auction House quote")

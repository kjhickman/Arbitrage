local market = "Alliance"
local requestedMinimumRecipeKeys = {}

local outputs = {
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
  { outputItemID = 300, sources = {} },
  { outputItemID = 400, sources = {} },
}

local marketValues = {
  [100] = { value = 10000, isUncertain = false, reasons = {} },
  [200] = { value = 10000, isUncertain = true, reasons = { "limited scans" } },
  [400] = { value = 10000, isUncertain = false, reasons = {} },
}

local typicalCosts = {
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
  [400] = { isUnknown = true },
}

local minimumCosts = {
  [100] = {
    cost = 3000,
    outputQuantity = 2,
    recipeKey = "shared",
    isUncertain = false,
    reasons = {},
  },
}

local ns = {
  Crafting = {
    GetCostForItemID = function(itemID)
      return typicalCosts[itemID]
    end,
    GetMinimumCostForItemID = function(itemID, recipeKey)
      requestedMinimumRecipeKeys[itemID] = recipeKey
      return minimumCosts[itemID]
    end,
  },
  Database = {
    GetMarket = function()
      return market
    end,
  },
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

local result = ns.Opportunities.Get()
assert(result.totalCount == 4 and #result.items == 2, "counts known and fully priced craftable outputs")

local first = result.items[1]
assert(first.itemID == 100 and first.outputQuantity == 2, "sorts by estimated profit per craft")
assert(first.saleProceeds == 19000, "deducts the faction Auction House cut from per-craft proceeds")
assert(first.craftCost == 8000 and first.profit == 11000, "calculates typical cost and profit per craft")
assert(first.roi == 1.375, "calculates return on crafting cost")
assert(first.minimumCraftCost == 6000 and first.minimumProfit == 13000, "calculates latest-scan best case")
assert(
  requestedMinimumRecipeKeys[100] == "shared" and requestedMinimumRecipeKeys[200] == "item-200",
  "prices each best case using its selected rolling recipe"
)
assert(#first.sources == 2, "keeps only crafters who know the selected recipe")
assert(first.sources[1].characterName == "Alt" and first.sources[2].characterName == "Main", "keeps source order")
assert(not first.isUncertain and #first.reasons == 0, "keeps reliable opportunities unmarked")

local second = result.items[2]
assert(second.itemID == 200 and second.profit == -1500, "keeps lower and unprofitable opportunities in the ranking")
assert(second.isUncertain, "combines output and crafting uncertainty")
assert(table.concat(second.reasons, ",") == "limited scans,stale", "deduplicates uncertainty reasons in a stable order")
assert(second.minimumCraftCost == nil and second.minimumProfit == nil, "allows missing best-case prices")

market = "Neutral"
result = ns.Opportunities.Get()
assert(result.items[1].saleProceeds == 17000 and result.items[1].profit == 9000, "uses the neutral Auction House cut")

market = "Alliance"
outputs = { { outputItemID = 500, sources = {} } }
marketValues[500] = { value = 100, isUncertain = false, reasons = {} }
typicalCosts[500] = {
  cost = 0.04,
  outputQuantity = 1,
  recipeKey = "batch-reagent",
  isUncertain = false,
  reasons = {},
}
result = ns.Opportunities.Get()
assert(result.items[1].roi < math.huge, "calculates finite ROI from an unrounded positive craft cost")

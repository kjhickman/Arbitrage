local market = "Alliance"
local requestedMinimumRecipeKeys = {}
local sellPrices = {}
local requestedItemIDs = {}
C_Item = {
  RequestLoadItemDataByID = function(itemID)
    requestedItemIDs[#requestedItemIDs + 1] = itemID
  end,
}
local settings = {
  includeBestCaseOnly = true,
  showUncertainOpportunities = true,
}

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

local marketValues = {
  [100] = { value = 10000, isUncertain = false, reasons = {} },
  [200] = { value = 10000, isUncertain = true, reasons = { "limited scans" } },
  [250] = { value = 10000, isUncertain = false, reasons = {} },
  [260] = { value = 10000, isUncertain = false, reasons = {} },
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

local minimumCosts = {
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

local ns = {
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
assert(result.totalCount == 6 and result.pricedCount == 4, "counts known and fully priced craftable outputs")
assert(result.profitableCount == 2, "counts profitable outputs before visibility filters")
assert(#result.items == 2, "omits crafts without a positive estimated or best-case profit")

local opportunitiesByItemID = {}
for _, opportunity in ipairs(result.items) do
  opportunitiesByItemID[opportunity.itemID] = opportunity
end

local first = opportunitiesByItemID[100]
assert(first.outputQuantity == 2, "reports the selected recipe output quantity")
assert(first.saleProceeds == 19000, "deducts the faction Auction House cut from per-craft proceeds")
assert(first.saleMethod == "auction" and first.auctionSaleProceeds == 19000, "identifies Auction House proceeds")
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
assert(
  not first.marketIsUncertain and not first.craftCostIsUncertain and not first.minimumCraftCostIsUncertain,
  "marks each reliable value source"
)

local second = opportunitiesByItemID[200]
assert(
  second.itemID == 200 and second.profit == -1500 and second.minimumProfit == 500,
  "keeps crafts that are profitable only at latest minimum prices"
)
assert(second.isUncertain, "combines output and crafting uncertainty")
assert(table.concat(second.reasons, ",") == "limited scans,stale", "deduplicates uncertainty reasons in a stable order")
assert(
  second.marketIsUncertain and second.craftCostIsUncertain and not second.minimumCraftCostIsUncertain,
  "reports uncertainty for each value source"
)

settings.includeBestCaseOnly = false
result = ns.Opportunities.Get()
assert(
  result.pricedCount == 4 and result.profitableCount == 2 and #result.items == 1,
  "can hide opportunities profitable only at Best Cost without changing the profitable count"
)
assert(result.items[1].itemID == 100, "keeps opportunities with positive estimated profit")

settings.includeBestCaseOnly = true
settings.showUncertainOpportunities = false
result = ns.Opportunities.Get()
assert(
  result.pricedCount == 4 and result.profitableCount == 2 and #result.items == 1,
  "can hide uncertain opportunities without changing the profitable count"
)
assert(result.items[1].itemID == 100, "keeps reliable opportunities")

settings.showUncertainOpportunities = true
market = "Neutral"
result = ns.Opportunities.Get()
opportunitiesByItemID = {}
for _, opportunity in ipairs(result.items) do
  opportunitiesByItemID[opportunity.itemID] = opportunity
end
assert(
  opportunitiesByItemID[100].saleProceeds == 17000 and opportunitiesByItemID[100].profit == 9000,
  "uses the neutral Auction House cut"
)

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

sellPrices[500] = 120
result = ns.Opportunities.Get()
local vendor = result.items[1]
assert(vendor.saleMethod == "vendor" and vendor.saleProceeds == 120, "selects higher vendor proceeds")
assert(vendor.vendorSaleProceeds == 120 and vendor.auctionSaleProceeds == 95, "retains both sale alternatives")
assert(vendor.profit == 120, "subtracts the rounded craft cost from vendor proceeds")

outputs = { { outputItemID = 600, sources = {} } }
typicalCosts[600] = { cost = 40, outputQuantity = 2, isUncertain = false, reasons = {} }
minimumCosts[600] = { cost = 30, outputQuantity = 2, isUncertain = false, reasons = {} }
sellPrices[600] = 50
result = ns.Opportunities.Get()
vendor = result.items[1]
assert(result.pricedCount == 1 and result.profitableCount == 1, "prices vendor crafts without an output AH price")
assert(vendor.saleProceeds == 100 and vendor.profit == 20, "evaluates the full crafted quantity without an AH cut")
assert(vendor.minimumCraftCost == 60 and vendor.minimumProfit == 40, "reuses latest-scan costs for vendor profit")
assert(vendor.auctionSaleProceeds == nil and not vendor.isUncertain, "does not require output market data for vendors")
market = "Neutral"
assert(ns.Opportunities.Get().items[1].saleProceeds == 100, "never applies the neutral AH cut to vendor sales")
market = "Alliance"

marketValues[600] = { value = 51, isUncertain = true, reasons = { "stale output" } }
settings.showUncertainOpportunities = false
vendor = ns.Opportunities.Get().items[1]
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
typicalCosts[600].isUncertain = false
typicalCosts[600].reasons = {}

marketValues[600] = { value = 100, isUncertain = false, reasons = {} }
local auction = ns.Opportunities.Get().items[1]
assert(auction.saleMethod == "auction" and auction.saleProceeds == 190, "keeps AH sales when net proceeds are higher")
assert(auction.vendorSaleProceeds == 100, "retains vendor proceeds when AH sales are selected")
marketValues[600] = { value = 100, isUncertain = true, reasons = { "limited scans" } }
sellPrices[600] = 95
vendor = ns.Opportunities.Get().items[1]
assert(vendor.saleMethod == "vendor" and not vendor.isUncertain, "prefers fixed vendor proceeds when net values tie")

marketValues[600] = nil
sellPrices[600] = 35
vendor = ns.Opportunities.Get().items[1]
assert(vendor.profit == -10 and vendor.minimumProfit == 10, "includes vendor crafts profitable only at Best Cost")
settings.includeBestCaseOnly = false
result = ns.Opportunities.Get()
assert(result.profitableCount == 1 and #result.items == 0, "applies the best-case-only filter to vendor opportunities")
settings.includeBestCaseOnly = true
sellPrices[600] = 40
minimumCosts[600] = nil
result = ns.Opportunities.Get()
assert(result.pricedCount == 1 and result.profitableCount == 0, "excludes break-even vendor crafts")
sellPrices[600] = 0
result = ns.Opportunities.Get()
assert(result.pricedCount == 0 and #result.items == 0, "does not price nonsellable items as vendor opportunities")

sellPrices[600] = nil
requestedItemIDs = {}
result = ns.Opportunities.Get()
assert(
  result.pricedCount == 0 and requestedItemIDs[1] == 600,
  "requests uncached sell prices for otherwise priced crafts"
)
ns.Opportunities.Get()
assert(#requestedItemIDs == 1, "does not repeat pending item-data requests")
assert(not ns.Opportunities.HandleItemInfoReceived(999, true), "ignores unrelated item-data events")
assert(not ns.Opportunities.HandleItemInfoReceived(600, false), "does not refresh immediately after a failed request")
ns.Opportunities.Get()
assert(#requestedItemIDs == 2, "retries failed price requests on the next evaluation")
sellPrices[600] = 50
assert(ns.Opportunities.HandleItemInfoReceived(600, true), "requests reevaluation when a pending sell price loads")
assert(ns.Opportunities.Get().items[1].profit == 20, "finds a vendor opportunity after item data arrives")
assert(not ns.Opportunities.HandleItemInfoReceived(600, true), "clears completed price requests")

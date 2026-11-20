local _, ns = ...

ns.Opportunities = {}

---@alias ArbitrageOpportunityMode "typical"|"scan"|"sellLater"

---@class ArbitrageCraftTotals
---@field saleProceeds number
---@field craftCost number
---@field profit number

-- Sales, costs and profits are copper per crafted item; perCraft holds the same totals for one
-- craft of outputQuantity items.
---@class ArbitrageCraftOpportunity : ArbitrageItemTableItem
---@field mode ArbitrageOpportunityMode
---@field itemID number
---@field outputQuantity number
---@field saleMethod "auction"|"vendor"
---@field saleProceeds number
---@field auctionSaleProceeds number?
---@field auctionIsUncertain boolean
---@field auctionReasons string[]?
---@field vendorSaleProceeds number?
---@field craftCost number
---@field profit number
---@field roi number
---@field minimumProfit number?
---@field scanSaleProceeds number?
---@field scanSaleMethod ("auction"|"vendor")?
---@field scanProfit number?
---@field breakEvenListing number? gross Auction House asking price per item
---@field perCraft ArbitrageCraftTotals
---@field materials table<number, ArbitrageCraftingLeaf> what to buy for one item at Craft Cost
---@field marketIsUncertain boolean
---@field craftCostIsUncertain boolean
---@field sources ArbitrageRecipeSource[]
---@field reasons string[]
---@field isUncertain boolean

---@class ArbitrageOpportunityResult
---@field totalCount number
---@field pricedCount number
---@field profitableCount number
---@field items ArbitrageCraftOpportunity[]

-- The faction Auction House cut, shared with every other place that prices an Auction House sale;
-- neutral Auction Houses are not supported.
ns.Opportunities.AUCTION_HOUSE_CUT_RATE = 0.05
local requestedItems = {}

---@param value number
---@return number
local function Round(value)
  return math.floor(value + 0.5)
end

---@param reasons string[]
---@param additions string[]?
local function AddReasons(reasons, additions)
  for _, addition in ipairs(additions or {}) do
    local found = false
    for _, reason in ipairs(reasons) do
      if reason == addition then
        found = true
        break
      end
    end
    if not found then
      reasons[#reasons + 1] = addition
    end
  end
end

-- Each total is rounded once from exact per-item values, so a craft's totals do not multiply
-- the rounding of a single item by its output quantity.
---@param sale number exact proceeds from selling one item
---@param cost number exact Craft Cost of one item
---@param quantity number
---@return ArbitrageCraftTotals
local function GetTotals(sale, cost, quantity)
  local saleProceeds = math.floor(sale * quantity)
  local craftCost = Round(cost * quantity)
  return {
    saleProceeds = saleProceeds,
    craftCost = craftCost,
    profit = saleProceeds - craftCost,
  }
end

---@param sources ArbitrageRecipeSource[]
---@param recipeKey string?
---@return ArbitrageRecipeSource[]
local function GetRecipeSources(sources, recipeKey)
  local selected = {}
  for _, source in ipairs(sources) do
    if recipeKey == nil or source.recipeKey == recipeKey then
      selected[#selected + 1] = source
    end
  end
  return selected
end

---@param auctionSale number? exact net proceeds
---@param vendorSale number?
---@return number?, "auction"|"vendor"
local function BestSale(auctionSale, vendorSale)
  if vendorSale and (auctionSale == nil or vendorSale >= math.floor(auctionSale)) then
    return vendorSale, "vendor"
  end
  return auctionSale, "auction"
end

---@param output ArbitrageCraftableOutput
---@param mode ArbitrageOpportunityMode
---@param recipe ArbitrageStoredRecipe?
---@param recipeKeys table<string, true>? without a recipe, the recipes to choose from; nil for any
---@return ArbitrageCraftOpportunity?
local function BuildOpportunity(output, mode, recipe, recipeKeys)
  local itemID = output.outputItemID
  local craftingPlan
  local minimumPlan
  if recipe then
    craftingPlan, minimumPlan = ns.Crafting.GetRecipeCosts({ recipe })
  elseif mode ~= "typical" then
    craftingPlan = ns.Crafting.GetScanCostForItemID(itemID, recipeKeys)
  else
    craftingPlan = ns.Crafting.GetCostForItemID(itemID, recipeKeys)
  end
  if craftingPlan == nil or craftingPlan.isUnknown or type(craftingPlan.outputQuantity) ~= "number" then
    return nil
  end

  ---@cast craftingPlan ArbitrageCraftingPlan
  local outputQuantity = craftingPlan.outputQuantity
  local marketValue = mode ~= "scan" and ns.RollingMarketValue.Get({ tostring(itemID) }) or nil
  local scanBuyout = mode ~= "typical" and ns.Database.GetLatestBuyout(itemID) or nil
  local netRate = 1 - ns.Opportunities.AUCTION_HOUSE_CUT_RATE
  local scanAuctionSale = scanBuyout and scanBuyout * netRate
  local auctionSale
  if mode == "scan" then
    auctionSale = scanAuctionSale
  elseif marketValue then
    auctionSale = marketValue.value * netRate
  end
  local auctionSaleProceeds = auctionSale and math.floor(auctionSale)
  local sellPrice = ns.Vendor.GetSellPrice(itemID)
  if sellPrice == nil and not requestedItems[itemID] then
    requestedItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local vendorSaleProceeds = sellPrice and sellPrice > 0 and sellPrice or nil
  local sale, saleMethod = BestSale(auctionSale, vendorSaleProceeds)
  if sale == nil then
    return nil
  end

  local reasons = {}
  local marketIsUncertain = false
  if saleMethod == "auction" and marketValue then
    AddReasons(reasons, marketValue.reasons)
    marketIsUncertain = marketValue.isUncertain
  end
  AddReasons(reasons, craftingPlan.reasons)

  local minimumCost
  if minimumPlan and not minimumPlan.isUnknown then
    ---@cast minimumPlan ArbitrageCraftingPlan
    minimumCost = minimumPlan.cost
  end

  local perItem = GetTotals(sale, craftingPlan.cost, 1)
  local scanSaleProceeds, scanSaleMethod
  if mode == "sellLater" then
    local scanSale, method = BestSale(scanAuctionSale, vendorSaleProceeds)
    if scanSale then
      scanSaleProceeds = math.floor(scanSale)
      scanSaleMethod = method
    end
  end

  return {
    mode = mode,
    itemID = itemID,
    outputQuantity = outputQuantity,
    saleMethod = saleMethod,
    saleProceeds = perItem.saleProceeds,
    auctionSaleProceeds = auctionSaleProceeds,
    auctionIsUncertain = marketValue ~= nil and marketValue.isUncertain,
    auctionReasons = marketValue and marketValue.reasons,
    vendorSaleProceeds = vendorSaleProceeds,
    craftCost = perItem.craftCost,
    profit = perItem.profit,
    roi = (sale - craftingPlan.cost) / craftingPlan.cost,
    minimumProfit = minimumCost and perItem.saleProceeds - Round(minimumCost),
    scanSaleProceeds = scanSaleProceeds,
    scanSaleMethod = scanSaleMethod,
    scanProfit = scanSaleProceeds and scanSaleProceeds - perItem.craftCost,
    breakEvenListing = mode ~= "typical" and (saleMethod == "auction" or scanSaleMethod == "auction") and math.ceil(
      math.ceil(craftingPlan.cost) / netRate
    ) or nil,
    perCraft = GetTotals(sale, craftingPlan.cost, outputQuantity),
    materials = craftingPlan.leaves,
    marketIsUncertain = marketIsUncertain,
    craftCostIsUncertain = craftingPlan.isUncertain,
    sources = GetRecipeSources(output.sources, craftingPlan.recipeKey),
    reasons = reasons,
    isUncertain = #reasons > 0,
  }
end

---@param itemID number
---@param success boolean
---@return boolean
function ns.Opportunities.HandleItemInfoReceived(itemID, success)
  if not requestedItems[itemID] then
    return false
  end
  requestedItems[itemID] = nil
  return success
end

-- The profession and crafter must both belong to the same source.
---@param source ArbitrageRecipeSource
---@param profession string empty for any
---@param crafter string empty for any
---@return boolean
local function MatchesSource(source, profession, crafter)
  return (profession == "" or source.professionName == profession)
    and (crafter == "" or source.characterName == crafter)
end

---@param sources ArbitrageRecipeSource[]
---@param profession string empty for any
---@param crafter string empty for any
---@return ArbitrageRecipeSource[]
local function GetMatchingSources(sources, profession, crafter)
  local matching = {}
  for _, source in ipairs(sources) do
    if MatchesSource(source, profession, crafter) then
      matching[#matching + 1] = source
    end
  end
  return matching
end

-- The cheapest recipe overall can belong to another character, so this prices the best one the
-- chosen crafter or profession knows instead; nil when none of them makes the item.
---@param output ArbitrageCraftableOutput
---@param mode ArbitrageOpportunityMode
---@param profession string
---@param crafter string
---@return ArbitrageCraftOpportunity?
local function BuildEligibleOpportunity(output, mode, profession, crafter)
  local sources = GetMatchingSources(output.sources, profession, crafter)
  local recipeKeys
  for _, source in ipairs(sources) do
    recipeKeys = recipeKeys or {}
    recipeKeys[source.recipeKey] = true
  end
  return recipeKeys
    and BuildOpportunity({ outputItemID = output.outputItemID, sources = sources }, mode, nil, recipeKeys)
end

---@param mode ArbitrageOpportunityMode?
---@return ArbitrageOpportunityResult
function ns.Opportunities.Get(mode)
  mode = mode or "typical"
  local outputs = ns.RecipeBook.GetCraftableOutputs()
  local showUncertain = ns.Config.Get("showUncertainOpportunities")
  local profession = ns.Config.Get("opportunityProfession")
  local crafter = ns.Config.Get("opportunityCrafter")
  if crafter == ns.Config.CURRENT_CHARACTER then
    crafter = ns.Realm.GetCharacterName() or ""
  end
  local saleMethod = ns.Config.Get("opportunitySaleMethod")
  local minimumProfit = ns.Config.Get("minimumProfit")
  local items = {}
  local pricedCount = 0
  local profitableCount = 0

  for _, output in ipairs(outputs) do
    local opportunity = BuildOpportunity(output, mode)
    if opportunity then
      pricedCount = pricedCount + 1
      if opportunity.profit > 0 then
        profitableCount = profitableCount + 1
      end
      if profession ~= "" or crafter ~= "" then
        local matching = GetMatchingSources(opportunity.sources, profession, crafter)
        if #matching == 0 then
          opportunity = BuildEligibleOpportunity(output, mode, profession, crafter)
        else
          opportunity.sources = matching
        end
      end
      if
        opportunity
        and (showUncertain or not opportunity.isUncertain)
        and (saleMethod == "" or opportunity.saleMethod == saleMethod)
        and (minimumProfit <= 0 or opportunity.profit >= minimumProfit)
      then
        items[#items + 1] = opportunity
      end
    end
  end

  return {
    totalCount = #outputs,
    pricedCount = pricedCount,
    profitableCount = profitableCount,
    items = items,
  }
end

---@param recipe ArbitrageStoredRecipe
---@return ArbitrageCraftOpportunity?
function ns.Opportunities.GetForRecipe(recipe)
  return BuildOpportunity({ outputItemID = recipe.outputItemID, sources = {} }, "typical", recipe)
end

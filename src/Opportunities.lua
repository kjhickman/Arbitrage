local _, ns = ...

ns.Opportunities = {}

---@class ArbitrageCraftTotals
---@field saleProceeds number
---@field craftCost number
---@field profit number
---@field minimumCraftCost number?
---@field minimumProfit number?

-- Sales, costs and profits are copper per crafted item; perCraft holds the same totals for one
-- craft of outputQuantity items.
---@class ArbitrageCraftOpportunity : ArbitrageItemTableItem
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
---@field minimumCraftCost number?
---@field minimumProfit number?
---@field perCraft ArbitrageCraftTotals
---@field materials table<number, ArbitrageCraftingLeaf> what to buy for one item at Craft Cost
---@field marketIsUncertain boolean
---@field craftCostIsUncertain boolean
---@field minimumCraftCostIsUncertain boolean
---@field sources ArbitrageRecipeSource[]
---@field reasons string[]
---@field isUncertain boolean
---@field isBuyoutOnly boolean listed only because its Buyout Profit meets the minimum profit

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
---@param minimumCost number? exact Buyout Cost of one item
---@param quantity number
---@return ArbitrageCraftTotals
local function GetTotals(sale, cost, minimumCost, quantity)
  local saleProceeds = math.floor(sale * quantity)
  local craftCost = Round(cost * quantity)
  local minimumCraftCost = minimumCost and Round(minimumCost * quantity)
  return {
    saleProceeds = saleProceeds,
    craftCost = craftCost,
    profit = saleProceeds - craftCost,
    minimumCraftCost = minimumCraftCost,
    minimumProfit = minimumCraftCost and saleProceeds - minimumCraftCost,
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

---@param output ArbitrageCraftableOutput
---@param recipe ArbitrageStoredRecipe?
---@param recipeKeys table<string, true>? without a recipe, the recipes to choose from; nil for any
---@return ArbitrageCraftOpportunity?
local function BuildOpportunity(output, recipe, recipeKeys)
  local itemID = output.outputItemID
  local craftingPlan
  local minimumPlan
  if recipe then
    craftingPlan, minimumPlan = ns.Crafting.GetRecipeCosts(recipe)
  else
    craftingPlan = ns.Crafting.GetCostForItemID(itemID, recipeKeys)
  end
  if craftingPlan == nil or craftingPlan.isUnknown or type(craftingPlan.outputQuantity) ~= "number" then
    return nil
  end

  ---@cast craftingPlan ArbitrageCraftingPlan
  local outputQuantity = craftingPlan.outputQuantity
  local marketValue = ns.RollingMarketValue.Get({ tostring(itemID) })
  local auctionSale = marketValue and marketValue.value * (1 - ns.Opportunities.AUCTION_HOUSE_CUT_RATE)
  local auctionSaleProceeds = auctionSale and math.floor(auctionSale)
  local sellPrice = ns.Vendor.GetSellPrice(itemID)
  if sellPrice == nil and not requestedItems[itemID] then
    requestedItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local vendorSaleProceeds = sellPrice and sellPrice > 0 and sellPrice or nil
  local saleMethod = "auction"
  local sale = auctionSale
  if vendorSaleProceeds and (auctionSaleProceeds == nil or vendorSaleProceeds >= auctionSaleProceeds) then
    saleMethod = "vendor"
    sale = vendorSaleProceeds
  end
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
  local minimumCraftCostIsUncertain = false
  if not recipe then
    minimumPlan = ns.Crafting.GetMinimumCostForItemID(itemID, craftingPlan.recipeKey)
  end
  if minimumPlan and not minimumPlan.isUnknown then
    ---@cast minimumPlan ArbitrageCraftingPlan
    minimumCost = minimumPlan.cost
    minimumCraftCostIsUncertain = minimumPlan.isUncertain
  end

  local perItem = GetTotals(sale, craftingPlan.cost, minimumCost, 1)
  return {
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
    minimumCraftCost = perItem.minimumCraftCost,
    minimumProfit = perItem.minimumProfit,
    perCraft = GetTotals(sale, craftingPlan.cost, minimumCost, outputQuantity),
    materials = craftingPlan.leaves,
    marketIsUncertain = marketIsUncertain,
    craftCostIsUncertain = craftingPlan.isUncertain,
    minimumCraftCostIsUncertain = minimumCraftCostIsUncertain,
    sources = GetRecipeSources(output.sources, craftingPlan.recipeKey),
    reasons = reasons,
    isUncertain = #reasons > 0,
    isBuyoutOnly = false,
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

-- A minimum of zero lists every priced craft, regardless of its profit.
---@param opportunity ArbitrageCraftOpportunity
---@return boolean meetsMinimum
---@return boolean buyoutOnly only its Buyout Profit meets the minimum
local function MeetsProfitFilter(opportunity)
  local minimum = ns.Config.Get("minimumProfit")
  if minimum <= 0 or opportunity.profit >= minimum then
    return true, false
  end

  local buyoutOnly = ns.Config.Get("includeBestCaseOnly")
    and opportunity.minimumProfit ~= nil
    and opportunity.minimumProfit >= minimum
  return buyoutOnly, buyoutOnly
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

---@param opportunity ArbitrageCraftOpportunity
---@param profession string empty for any
---@param crafter string empty for any
---@return boolean
local function MeetsCrafterFilter(opportunity, profession, crafter)
  if profession == "" and crafter == "" then
    return true
  end

  for _, source in ipairs(opportunity.sources) do
    if MatchesSource(source, profession, crafter) then
      return true
    end
  end
  return false
end

-- The cheapest recipe overall can belong to another character, so this prices the best one the
-- chosen crafter or profession knows instead; nil when none of them makes the item.
---@param output ArbitrageCraftableOutput
---@param profession string
---@param crafter string
---@return ArbitrageCraftOpportunity?
local function BuildEligibleOpportunity(output, profession, crafter)
  local recipeKeys
  for _, source in ipairs(output.sources) do
    if MatchesSource(source, profession, crafter) then
      recipeKeys = recipeKeys or {}
      recipeKeys[source.recipeKey] = true
    end
  end
  return recipeKeys and BuildOpportunity(output, nil, recipeKeys)
end

---@return ArbitrageOpportunityResult
function ns.Opportunities.Get()
  local outputs = ns.RecipeBook.GetCraftableOutputs()
  local showUncertain = ns.Config.Get("showUncertainOpportunities")
  local profession = ns.Config.Get("opportunityProfession")
  local crafter = ns.Config.Get("opportunityCrafter")
  if crafter == ns.Config.CURRENT_CHARACTER then
    crafter = ns.Realm.GetCharacterName() or ""
  end
  local saleMethod = ns.Config.Get("opportunitySaleMethod")
  local items = {}
  local pricedCount = 0
  local profitableCount = 0

  for _, output in ipairs(outputs) do
    local opportunity = BuildOpportunity(output)
    if opportunity then
      pricedCount = pricedCount + 1
      local estimatedIsProfitable = opportunity.profit > 0
      local bestCaseIsProfitable = opportunity.minimumProfit and opportunity.minimumProfit > 0
      if estimatedIsProfitable or bestCaseIsProfitable then
        profitableCount = profitableCount + 1
      end
      if not MeetsCrafterFilter(opportunity, profession, crafter) then
        opportunity = BuildEligibleOpportunity(output, profession, crafter)
      end
      if
        opportunity
        and (showUncertain or not opportunity.isUncertain)
        and (saleMethod == "" or opportunity.saleMethod == saleMethod)
      then
        local meetsMinimum, buyoutOnly = MeetsProfitFilter(opportunity)
        if meetsMinimum then
          opportunity.isBuyoutOnly = buyoutOnly
          items[#items + 1] = opportunity
        end
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
  return BuildOpportunity({ outputItemID = recipe.outputItemID, sources = {} }, recipe)
end

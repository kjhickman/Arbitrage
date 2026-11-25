local _, ns = ...

ns.Opportunities = {}

---@class ArbitrageCraftTotals
---@field saleProceeds number
---@field craftCost number
---@field profit number

-- Every craft is priced twice: at Market Value, and at Buyout prices, the cheapest listings in the
-- latest scan. Costs and profits are copper per crafted item; perCraft holds the Market Value totals
-- for one craft of outputQuantity items. A profit is nil when one of its prices is missing, but
-- every listed craft has at least one.
---@class ArbitrageCraftOpportunity : ArbitrageItemTableItem
---@field itemID number
---@field outputQuantity number
---@field recipeKey string? the recipe both costs use
---@field sources ArbitrageRecipeSource[]
---@field craftCost number?
---@field craftCostIsUncertain boolean
---@field materials table<number, ArbitrageCraftingLeaf>? what to buy for one item at Craft Cost
---@field saleMethod ("auction"|"vendor")? the better sale at Market Value
---@field profit number?
---@field perCraft ArbitrageCraftTotals?
---@field reasons string[] why Profit is uncertain
---@field isUncertain boolean
---@field buyoutCraftCost number?
---@field buyoutMaterials table<number, ArbitrageCraftingLeaf>? what to buy for one item at Buyout Craft Cost
---@field buyoutSaleMethod ("auction"|"vendor")? the better sale at the item's Buyout
---@field buyoutProfit number?
---@field profitMissesFilters boolean? listed only for its Buyout Profit
---@field buyoutProfitMissesFilters boolean? listed only for its Profit
---@field saleRate number? the share of the item's auctions that sell across the region, from TradeSkillMaster
---@field marketValue number? the item's Market Value, before the AH cut
---@field marketValueIsUncertain boolean
---@field buyout number? the item's Buyout, before the AH cut
---@field roi number? Profit as a share of Craft Cost
---@field buyoutRoi number? Buyout Profit as a share of Buyout Craft Cost
---@field isUnlearned boolean? no character knows a recipe for it, so its sources are who could learn one

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
---@param cost number exact cost to make one item
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
function ns.Opportunities.BestSale(auctionSale, vendorSale)
  if vendorSale and (auctionSale == nil or vendorSale >= math.floor(auctionSale)) then
    return vendorSale, "vendor"
  end
  return auctionSale, "auction"
end

---@param plan ArbitrageCraftingCostResult?
---@return ArbitrageCraftingPlan?
local function Usable(plan)
  if plan and not plan.isUnknown and type(plan.outputQuantity) == "number" then
    ---@cast plan ArbitrageCraftingPlan
    return plan
  end
  return nil
end

---@param output ArbitrageCraftableOutput
---@param recipes ArbitrageStoredRecipe[]? priced instead of the recipe book's, which still make the materials
---@param recipeKeys table<string, true>? without recipes, the recipe book's to choose from; nil for any
---@param unlearned boolean? no character has learned the recipes; the output's sources could
---@return ArbitrageCraftOpportunity?
local function BuildOpportunity(output, recipes, recipeKeys, unlearned)
  local itemID = output.outputItemID
  if ns.Database.IsIgnoredItem(itemID) then
    return nil
  end
  local marketValue = ns.RollingMarketValue.Get({ tostring(itemID) })
  local buyout = ns.Database.GetLatestBuyout(itemID)
  -- Profession windows also list recipes nobody can learn, such as the other faction's or retired
  -- ones. Their items rarely reach the Auction House, so an unlearned craft needs a price there.
  if unlearned and marketValue == nil and buyout == nil then
    return nil
  end

  local costPlan, buyoutCost
  if recipes then
    costPlan, buyoutCost = ns.Crafting.GetRecipeCosts(recipes)
  else
    costPlan = ns.Crafting.GetCostForItemID(itemID, recipeKeys)
  end
  costPlan = Usable(costPlan)

  local sellPrice = ns.Vendor.GetSellPrice(itemID)
  local vendorSale = sellPrice and sellPrice > 0 and sellPrice or nil
  local netRate = 1 - ns.Opportunities.AUCTION_HOUSE_CUT_RATE
  local auctionSale = marketValue and marketValue.value * netRate
  local sale, saleMethod = ns.Opportunities.BestSale(auctionSale, vendorSale)
  local buyoutSale, buyoutSaleMethod = ns.Opportunities.BestSale(buyout and buyout * netRate, vendorSale)

  -- Profit needs a sale as well as a cost. When it has both, Buyout Craft Cost uses the same recipe,
  -- so the crafters listed make the item at either price; otherwise it picks its own cheapest.
  local plan = sale and costPlan or nil
  local buyoutPlan
  if recipes then
    buyoutPlan = Usable(buyoutCost)
  else
    local buyoutKeys = plan and plan.recipeKey and { [plan.recipeKey] = true } or recipeKeys
    buyoutPlan = Usable(ns.Crafting.GetScanCostForItemID(itemID, buyoutKeys))
  end
  if sellPrice == nil and (costPlan or buyoutPlan) and not requestedItems[itemID] then
    requestedItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local anyPlan = plan or buyoutPlan
  if not plan and not (buyoutPlan and buyoutSale) then
    return nil
  end
  ---@cast anyPlan ArbitrageCraftingPlan

  ---@type ArbitrageCraftOpportunity
  local _, saleRate = ns.Database.GetSales(itemID)
  local opportunity = {
    itemID = itemID,
    outputQuantity = anyPlan.outputQuantity,
    recipeKey = anyPlan.recipeKey,
    sources = GetRecipeSources(output.sources, anyPlan.recipeKey),
    craftCost = plan and Round(plan.cost),
    craftCostIsUncertain = plan ~= nil and plan.isUncertain,
    materials = plan and plan.leaves,
    reasons = {},
    isUncertain = false,
    buyoutCraftCost = buyoutPlan and Round(buyoutPlan.cost),
    buyoutMaterials = buyoutPlan and buyoutPlan.leaves,
    saleRate = saleRate,
    marketValue = marketValue and marketValue.value,
    marketValueIsUncertain = marketValue ~= nil and marketValue.isUncertain == true,
    buyout = buyout,
    isUnlearned = unlearned,
  }

  if plan and sale then
    if saleMethod == "auction" and marketValue then
      AddReasons(opportunity.reasons, marketValue.reasons)
    end
    AddReasons(opportunity.reasons, plan.reasons)
    opportunity.isUncertain = #opportunity.reasons > 0
    opportunity.saleMethod = saleMethod
    opportunity.profit = GetTotals(sale, plan.cost, 1).profit
    opportunity.perCraft = GetTotals(sale, plan.cost, plan.outputQuantity)
    -- Of the costs and profits the table shows, so it reads as their ratio.
    if opportunity.craftCost > 0 then
      opportunity.roi = opportunity.profit / opportunity.craftCost
    end
  end

  if buyoutPlan and buyoutSale then
    opportunity.buyoutSaleMethod = buyoutSaleMethod
    opportunity.buyoutProfit = GetTotals(buyoutSale, buyoutPlan.cost, 1).profit
    if opportunity.buyoutCraftCost > 0 then
      opportunity.buyoutRoi = opportunity.buyoutProfit / opportunity.buyoutCraftCost
    end
  end

  return opportunity
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

-- The cheapest recipe overall can belong to another character, so this prices the best one the
-- chosen crafter or profession has instead; nil when none of them makes the item.
---@param output ArbitrageCraftableOutput
---@param profession string empty for any
---@param crafter string empty for any
---@param unlearned boolean the output's sources could learn its recipes rather than know them
---@return ArbitrageCraftOpportunity?
local function BuildEligibleOpportunity(output, profession, crafter, unlearned)
  local sources = {}
  local recipeKeys = {}
  for _, source in ipairs(output.sources) do
    if MatchesSource(source, profession, crafter) then
      sources[#sources + 1] = source
      recipeKeys[source.recipeKey] = true
    end
  end
  if #sources == 0 then
    return nil
  end

  local eligible = { outputItemID = output.outputItemID, sources = sources }
  if not unlearned then
    return BuildOpportunity(eligible, nil, recipeKeys)
  end
  local recipes = {}
  for _, recipe in ipairs(ns.RecipeBook.GetUnlearnedRecipes(output.outputItemID)) do
    if recipeKeys[recipe.recipeKey] then
      recipes[#recipes + 1] = recipe
    end
  end
  return #recipes > 0 and BuildOpportunity(eligible, recipes, nil, true) or nil
end

-- A craft is listed when either profit passes every filter and each profit with a minimum does, so
-- a minimum is only met by a profit the other filters keep. A profit that misses is grayed in the table.
-- Known crafts are ones any character knows a recipe for; unlearned ones are those none do yet.
---@return ArbitrageOpportunityResult
function ns.Opportunities.Get()
  local recipesFilter = ns.Config.Get("opportunityRecipes")
  local showUncertain = ns.Config.Get("showUncertainOpportunities")
  local profession = ns.Config.Get("opportunityProfession")
  local crafter = ns.Config.Get("opportunityCrafter")
  if crafter == ns.Config.CURRENT_CHARACTER then
    crafter = ns.Realm.GetCharacterName() or ""
  end
  local saleMethod = ns.Config.Get("opportunitySaleMethod")
  local minimumTypicalProfit = ns.Config.Get("minimumTypicalProfit")
  local minimumCurrentProfit = ns.Config.Get("minimumCurrentProfit")
  local items = {}
  local totalCount = 0
  local pricedCount = 0
  local profitableCount = 0

  ---@param profit number?
  ---@param isUncertain boolean
  ---@param method ("auction"|"vendor")?
  ---@param minimum number zero for none
  ---@return boolean
  local function Qualifies(profit, isUncertain, method, minimum)
    return profit ~= nil
      and (showUncertain or not isUncertain)
      and (saleMethod == "" or method == saleMethod)
      and (minimum <= 0 or profit >= minimum)
  end

  ---@param output ArbitrageCraftableOutput
  ---@param unlearned boolean
  local function Consider(output, unlearned)
    totalCount = totalCount + 1
    local opportunity
    if unlearned then
      opportunity = BuildEligibleOpportunity(output, "", "", true)
    else
      opportunity = BuildOpportunity(output)
    end
    if not opportunity then
      return
    end
    pricedCount = pricedCount + 1
    if (opportunity.profit or 0) > 0 or (opportunity.buyoutProfit or 0) > 0 then
      profitableCount = profitableCount + 1
    end
    if profession ~= "" or crafter ~= "" then
      opportunity = BuildEligibleOpportunity(output, profession, crafter, unlearned)
    end
    if opportunity then
      local profitQualifies =
        Qualifies(opportunity.profit, opportunity.isUncertain, opportunity.saleMethod, minimumTypicalProfit)
      -- Buyout prices are plain listings, so Buyout Profit is never uncertain.
      local buyoutQualifies =
        Qualifies(opportunity.buyoutProfit, false, opportunity.buyoutSaleMethod, minimumCurrentProfit)
      if
        (profitQualifies or buyoutQualifies)
        and (profitQualifies or minimumTypicalProfit <= 0)
        and (buyoutQualifies or minimumCurrentProfit <= 0)
      then
        opportunity.profitMissesFilters = opportunity.profit ~= nil and not profitQualifies
        opportunity.buyoutProfitMissesFilters = opportunity.buyoutProfit ~= nil and not buyoutQualifies
        items[#items + 1] = opportunity
      end
    end
  end

  if recipesFilter ~= "unlearned" then
    for _, output in ipairs(ns.RecipeBook.GetCraftableOutputs()) do
      Consider(output, false)
    end
  end
  if recipesFilter == "all" or recipesFilter == "unlearned" then
    for _, output in ipairs(ns.RecipeBook.GetLearnableOutputs()) do
      Consider(output, true)
    end
  end

  return {
    totalCount = totalCount,
    pricedCount = pricedCount,
    profitableCount = profitableCount,
    items = items,
  }
end

-- Prices one recipe for the profession, trainer, and What's Training windows, which need its Profit.
---@param recipe ArbitrageStoredRecipe
---@return ArbitrageCraftOpportunity?
function ns.Opportunities.GetForRecipe(recipe)
  local opportunity = BuildOpportunity({ outputItemID = recipe.outputItemID, sources = {} }, { recipe })
  return opportunity and opportunity.profit and opportunity or nil
end

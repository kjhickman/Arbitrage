local _, ns = ...

ns.Opportunities = {}

---@class ArbitrageCraftOpportunity
---@field itemID number
---@field outputQuantity number
---@field saleProceeds number
---@field craftCost number
---@field profit number
---@field roi number
---@field minimumCraftCost number?
---@field minimumProfit number?
---@field marketIsUncertain boolean
---@field craftCostIsUncertain boolean
---@field minimumCraftCostIsUncertain boolean
---@field sources ArbitrageRecipeSource[]
---@field reasons string[]
---@field isUncertain boolean

---@class ArbitrageOpportunityResult
---@field totalCount number
---@field pricedCount number
---@field items ArbitrageCraftOpportunity[]

local FACTION_CUT_RATE = 0.05
local NEUTRAL_CUT_RATE = 0.15

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

---@param value number
---@param outputQuantity number
---@param cutRate number
---@return number
local function GetSaleProceeds(value, outputQuantity, cutRate)
  return math.floor(value * outputQuantity * (1 - cutRate))
end

---@param output ArbitrageCraftableOutput
---@param cutRate number
---@return ArbitrageCraftOpportunity?
local function BuildOpportunity(output, cutRate)
  local itemID = output.outputItemID
  local marketValue = ns.RollingMarketValue.Get({ tostring(itemID) })
  local craftingPlan = ns.Crafting.GetCostForItemID(itemID)
  if
    marketValue == nil
    or craftingPlan == nil
    or craftingPlan.isUnknown
    or type(craftingPlan.outputQuantity) ~= "number"
  then
    return nil
  end

  ---@cast craftingPlan ArbitrageCraftingPlan
  local outputQuantity = craftingPlan.outputQuantity
  local saleProceeds = GetSaleProceeds(marketValue.value, outputQuantity, cutRate)
  local exactCraftCost = craftingPlan.cost * outputQuantity
  local craftCost = Round(exactCraftCost)
  local profit = saleProceeds - craftCost
  local reasons = {}
  AddReasons(reasons, marketValue.reasons)
  AddReasons(reasons, craftingPlan.reasons)

  local minimumCraftCost
  local minimumProfit
  local minimumCraftCostIsUncertain = false
  local minimumPlan = ns.Crafting.GetMinimumCostForItemID(itemID, craftingPlan.recipeKey)
  if minimumPlan and not minimumPlan.isUnknown then
    ---@cast minimumPlan ArbitrageCraftingPlan
    minimumCraftCost = Round(minimumPlan.cost * outputQuantity)
    minimumProfit = saleProceeds - minimumCraftCost
    minimumCraftCostIsUncertain = minimumPlan.isUncertain
  end

  return {
    itemID = itemID,
    outputQuantity = outputQuantity,
    saleProceeds = saleProceeds,
    craftCost = craftCost,
    profit = profit,
    roi = (saleProceeds - exactCraftCost) / exactCraftCost,
    minimumCraftCost = minimumCraftCost,
    minimumProfit = minimumProfit,
    marketIsUncertain = marketValue.isUncertain,
    craftCostIsUncertain = craftingPlan.isUncertain,
    minimumCraftCostIsUncertain = minimumCraftCostIsUncertain,
    sources = GetRecipeSources(output.sources, craftingPlan.recipeKey),
    reasons = reasons,
    isUncertain = #reasons > 0,
  }
end

---@return ArbitrageOpportunityResult
function ns.Opportunities.Get()
  local outputs = ns.RecipeBook.GetCraftableOutputs()
  local cutRate = ns.Database.GetMarket() == "Neutral" and NEUTRAL_CUT_RATE or FACTION_CUT_RATE
  local items = {}
  local pricedCount = 0

  for _, output in ipairs(outputs) do
    local opportunity = BuildOpportunity(output, cutRate)
    if opportunity then
      pricedCount = pricedCount + 1
      if opportunity.profit > 0 or (opportunity.minimumProfit and opportunity.minimumProfit > 0) then
        items[#items + 1] = opportunity
      end
    end
  end

  return {
    totalCount = #outputs,
    pricedCount = pricedCount,
    items = items,
  }
end

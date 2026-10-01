local _, ns = ...

ns.Opportunities = {}

---@class ArbitrageCraftOpportunity
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
---@field marketIsUncertain boolean
---@field craftCostIsUncertain boolean
---@field minimumCraftCostIsUncertain boolean
---@field sources ArbitrageRecipeSource[]
---@field reasons string[]
---@field isUncertain boolean

---@class ArbitrageOpportunityResult
---@field totalCount number
---@field pricedCount number
---@field profitableCount number
---@field items ArbitrageCraftOpportunity[]

local FACTION_CUT_RATE = 0.05
local NEUTRAL_CUT_RATE = 0.15
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
---@param cutRate number
---@return ArbitrageCraftOpportunity?
local function BuildOpportunity(output, cutRate)
  local itemID = output.outputItemID
  local craftingPlan = ns.Crafting.GetCostForItemID(itemID)
  if craftingPlan == nil or craftingPlan.isUnknown or type(craftingPlan.outputQuantity) ~= "number" then
    return nil
  end

  ---@cast craftingPlan ArbitrageCraftingPlan
  local outputQuantity = craftingPlan.outputQuantity
  local marketValue = ns.RollingMarketValue.Get({ tostring(itemID) })
  local auctionSaleProceeds = marketValue and math.floor(marketValue.value * outputQuantity * (1 - cutRate))
  local sellPrice = ns.Vendor.GetSellPrice(itemID)
  if sellPrice == nil and not requestedItems[itemID] then
    requestedItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local vendorSaleProceeds = sellPrice and sellPrice > 0 and sellPrice * outputQuantity or nil
  local saleMethod = "auction"
  local saleProceeds = auctionSaleProceeds
  if vendorSaleProceeds and (saleProceeds == nil or vendorSaleProceeds >= saleProceeds) then
    saleMethod = "vendor"
    saleProceeds = vendorSaleProceeds
  end
  if saleProceeds == nil then
    return nil
  end

  local exactCraftCost = craftingPlan.cost * outputQuantity
  local craftCost = Round(exactCraftCost)
  local profit = saleProceeds - craftCost
  local reasons = {}
  local marketIsUncertain = false
  if saleMethod == "auction" and marketValue then
    AddReasons(reasons, marketValue.reasons)
    marketIsUncertain = marketValue.isUncertain
  end
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
    saleMethod = saleMethod,
    saleProceeds = saleProceeds,
    auctionSaleProceeds = auctionSaleProceeds,
    auctionIsUncertain = marketValue ~= nil and marketValue.isUncertain,
    auctionReasons = marketValue and marketValue.reasons,
    vendorSaleProceeds = vendorSaleProceeds,
    craftCost = craftCost,
    profit = profit,
    roi = (saleProceeds - exactCraftCost) / exactCraftCost,
    minimumCraftCost = minimumCraftCost,
    minimumProfit = minimumProfit,
    marketIsUncertain = marketIsUncertain,
    craftCostIsUncertain = craftingPlan.isUncertain,
    minimumCraftCostIsUncertain = minimumCraftCostIsUncertain,
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

---@return ArbitrageOpportunityResult
function ns.Opportunities.Get()
  local outputs = ns.RecipeBook.GetCraftableOutputs()
  local cutRate = ns.Database.GetMarket() == "Neutral" and NEUTRAL_CUT_RATE or FACTION_CUT_RATE
  local includeBestCaseOnly = ns.Config.Get("includeBestCaseOnly")
  local showUncertain = ns.Config.Get("showUncertainOpportunities")
  local items = {}
  local pricedCount = 0
  local profitableCount = 0

  for _, output in ipairs(outputs) do
    local opportunity = BuildOpportunity(output, cutRate)
    if opportunity then
      pricedCount = pricedCount + 1
      local estimatedIsProfitable = opportunity.profit > 0
      local bestCaseIsProfitable = opportunity.minimumProfit and opportunity.minimumProfit > 0
      if estimatedIsProfitable or bestCaseIsProfitable then
        profitableCount = profitableCount + 1
      end
      local isVisible = estimatedIsProfitable or (includeBestCaseOnly and bestCaseIsProfitable)
      if isVisible and (showUncertain or not opportunity.isUncertain) then
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

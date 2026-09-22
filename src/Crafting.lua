local _, ns = ...

ns.Crafting = {}

---@alias ArbitragePurchaseSource "auction"|"vendor"

---@class ArbitragePriceInfo
---@field value number
---@field source ArbitragePurchaseSource?
---@field isUncertain boolean?
---@field reasons string[]?

---@class ArbitrageCraftingLeaf
---@field itemID number
---@field name string?
---@field quantity number
---@field price number
---@field source ArbitragePurchaseSource

---@class ArbitrageCraftingPlan
---@field cost number
---@field leaves table<number, ArbitrageCraftingLeaf>
---@field reasons string[]
---@field isUncertain boolean
---@field recipeKey string?
---@field outputQuantity number?

---@class ArbitrageUnknownCraftingCost
---@field isUnknown true

---@alias ArbitrageCraftingCostResult ArbitrageCraftingPlan|ArbitrageUnknownCraftingCost

---@param reasons string[]
---@param reason string
local function AddReason(reasons, reason)
  for _, existing in ipairs(reasons) do
    if existing == reason then
      return
    end
  end
  reasons[#reasons + 1] = reason
end

---@param target ArbitrageCraftingPlan
---@param source ArbitrageCraftingPlan
---@param multiplier number
local function AddPlan(target, source, multiplier)
  target.cost = target.cost + source.cost * multiplier
  target.isUncertain = target.isUncertain or source.isUncertain

  for _, reason in ipairs(source.reasons) do
    AddReason(target.reasons, reason)
  end

  for itemID, leaf in pairs(source.leaves) do
    local targetLeaf = target.leaves[itemID]
    if targetLeaf == nil then
      targetLeaf = {
        itemID = leaf.itemID,
        name = leaf.name,
        quantity = 0,
        price = leaf.price,
        source = leaf.source,
      }
      target.leaves[itemID] = targetLeaf
    end
    targetLeaf.quantity = targetLeaf.quantity + leaf.quantity * multiplier
  end
end

---@param itemID number
---@param name string?
---@param priceInfo ArbitragePriceInfo
---@return ArbitrageCraftingPlan
local function CreatePurchasePlan(itemID, name, priceInfo)
  local reasons = {}
  for _, reason in ipairs(priceInfo.reasons or {}) do
    AddReason(reasons, reason)
  end

  return {
    cost = priceInfo.value,
    leaves = {
      [itemID] = {
        itemID = itemID,
        name = name,
        quantity = 1,
        price = priceInfo.value,
        source = priceInfo.source or "auction",
      },
    },
    reasons = reasons,
    isUncertain = priceInfo.isUncertain or false,
  }
end

---@param priceInfo number|ArbitragePriceInfo|nil
---@return ArbitragePriceInfo?
local function NormalizePrice(priceInfo)
  if type(priceInfo) == "number" then
    return { value = priceInfo }
  end
  return priceInfo
end

---@param itemID number
---@param recipeLookup fun(itemID: number): ArbitrageCraftingRecipe[]
---@param priceLookup fun(itemID: number): number|ArbitragePriceInfo|nil
---@return ArbitrageCraftingPlan?
function ns.Crafting.Calculate(itemID, recipeLookup, priceLookup)
  -- ponytail: recompute per branch; cache only with a cycle-safe graph solver.
  ---@type table<number, boolean>
  local visiting = {}

  local function CalculateCraft(craftItemID)
    if visiting[craftItemID] then
      return nil
    end

    visiting[craftItemID] = true
    local best
    for _, recipe in ipairs(recipeLookup(craftItemID)) do
      local outputQuantity = recipe.outputQuantity
      if outputQuantity > 0 then
        ---@type ArbitrageCraftingPlan
        local plan = {
          cost = 0,
          leaves = {},
          reasons = {},
          isUncertain = false,
          recipeKey = recipe.recipeKey,
          outputQuantity = outputQuantity,
        }
        local valid = true

        for _, reagent in ipairs(recipe.reagents) do
          local priceInfo = NormalizePrice(priceLookup(reagent.itemID))
          local crafted = CalculateCraft(reagent.itemID)
          local acquired

          if priceInfo and crafted then
            if crafted.cost < priceInfo.value then
              acquired = crafted
            else
              acquired = CreatePurchasePlan(reagent.itemID, reagent.name, priceInfo)
            end
          elseif priceInfo then
            acquired = CreatePurchasePlan(reagent.itemID, reagent.name, priceInfo)
          else
            acquired = crafted
          end

          if acquired == nil then
            valid = false
            break
          end

          AddPlan(plan, acquired, reagent.quantity / outputQuantity)
        end

        if
          valid
          and (
            best == nil
            or plan.cost < best.cost
            or (plan.cost == best.cost and (plan.recipeKey or "") < (best.recipeKey or ""))
          )
        then
          best = plan
        end
      end
    end
    visiting[craftItemID] = nil
    return best
  end

  return CalculateCraft(itemID)
end

---@param itemID number
---@param auctionPriceLookup fun(itemID: number): number|ArbitragePriceInfo|nil
---@return ArbitragePriceInfo?
local function GetPurchasePrice(itemID, auctionPriceLookup)
  local auctionPrice = NormalizePrice(auctionPriceLookup(itemID))
  local vendorPrice = ns.Database.GetVendorPrice(itemID)

  if vendorPrice and (auctionPrice == nil or vendorPrice < auctionPrice.value) then
    return { value = vendorPrice, source = "vendor" }
  end

  return auctionPrice
end

---@param itemID number
---@param auctionPriceLookup fun(itemID: number): number|ArbitragePriceInfo|nil
---@param recipeKey string?
---@return ArbitrageCraftingCostResult?
local function CalculateCost(itemID, auctionPriceLookup, recipeKey)
  local function GetRecipes(craftItemID)
    local recipes = ns.RecipeBook.GetRecipes(craftItemID)
    if craftItemID ~= itemID or recipeKey == nil then
      return recipes
    end

    for _, recipe in ipairs(recipes) do
      if recipe.recipeKey == recipeKey then
        return { recipe }
      end
    end
    return {}
  end

  local plan = ns.Crafting.Calculate(itemID, GetRecipes, function(reagentItemID)
    return GetPurchasePrice(reagentItemID, auctionPriceLookup)
  end)
  if plan == nil then
    if #ns.RecipeBook.GetRecipes(itemID) > 0 then
      return { isUnknown = true }
    end
    return nil
  end

  return plan
end

---@param itemID number
---@return ArbitrageCraftingCostResult?
function ns.Crafting.GetCostForItemID(itemID)
  return CalculateCost(itemID, function(reagentItemID)
    return ns.RollingMarketValue.Get({ tostring(reagentItemID) })
  end)
end

---@param itemID number
---@param recipeKey string?
---@return ArbitrageCraftingCostResult?
function ns.Crafting.GetMinimumCostForItemID(itemID, recipeKey)
  return CalculateCost(itemID, function(reagentItemID)
    return ns.Database.GetLatestBuyout(reagentItemID)
  end, recipeKey)
end

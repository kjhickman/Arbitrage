local _, ns = ...

ns.Crafting = {}
ns.Crafting.Calculate = ns.CraftingPlanner.Calculate

---@param priceInfo number|ArbitragePriceInfo|nil
---@return ArbitragePriceInfo?
local function NormalizePrice(priceInfo)
  if type(priceInfo) == "number" then
    return { value = priceInfo }
  end
  return priceInfo
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

  local plan = ns.CraftingPlanner.Calculate(itemID, GetRecipes, function(reagentItemID)
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

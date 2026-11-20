local _, ns = ...

ns.Crafting = {}

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
---@param recipeKeys table<string, true>? the recipes the item itself may use; nil for any
---@param rootRecipe ArbitrageStoredRecipe?
---@return ArbitrageCraftingCostResult?
local function CalculateCost(itemID, auctionPriceLookup, recipeKeys, rootRecipe)
  local function GetRecipes(craftItemID)
    if craftItemID == itemID and rootRecipe then
      return { rootRecipe }
    end
    local recipes = ns.RecipeBook.GetRecipes(craftItemID)
    if craftItemID ~= itemID or recipeKeys == nil then
      return recipes
    end

    local allowed = {}
    for _, recipe in ipairs(recipes) do
      if recipeKeys[recipe.recipeKey] then
        allowed[#allowed + 1] = recipe
      end
    end
    return allowed
  end

  local plan = ns.CraftingPlanner.Calculate(itemID, GetRecipes, function(reagentItemID)
    return GetPurchasePrice(reagentItemID, auctionPriceLookup)
  end)
  if plan == nil then
    if rootRecipe or #ns.RecipeBook.GetRecipes(itemID) > 0 then
      return { isUnknown = true }
    end
    return nil
  end

  return plan
end

---@param itemID number
---@param recipeKeys table<string, true>? limits the item's own recipe to these; nil for the cheapest of all
---@return ArbitrageCraftingCostResult?
function ns.Crafting.GetCostForItemID(itemID, recipeKeys)
  return CalculateCost(itemID, function(reagentItemID)
    return ns.RollingMarketValue.Get({ tostring(reagentItemID) })
  end, recipeKeys)
end

---@param itemID number
---@param recipeKeys table<string, true>? limits the item's own recipe to these; nil for the cheapest of all
---@return ArbitrageCraftingCostResult?
function ns.Crafting.GetScanCostForItemID(itemID, recipeKeys)
  return CalculateCost(itemID, function(reagentItemID)
    return ns.Database.GetLatestBuyout(reagentItemID)
  end, recipeKeys)
end

---@param recipe ArbitrageStoredRecipe
---@return ArbitrageCraftingCostResult?, ArbitrageCraftingCostResult?
function ns.Crafting.GetRecipeCosts(recipe)
  local cost = CalculateCost(recipe.outputItemID, function(reagentItemID)
    return ns.RollingMarketValue.Get({ tostring(reagentItemID) })
  end, nil, recipe)
  local minimumCost = CalculateCost(recipe.outputItemID, function(reagentItemID)
    return ns.Database.GetLatestBuyout(reagentItemID)
  end, nil, recipe)
  return cost, minimumCost
end

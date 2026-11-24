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
---@param rootRecipes ArbitrageStoredRecipe[]? the item's own recipes, used instead of the recipe book's
---@param trackChoices boolean? records which craftable materials the plan makes and which it buys
---@return ArbitrageCraftingCostResult?
local function CalculateCost(itemID, auctionPriceLookup, recipeKeys, rootRecipes, trackChoices)
  -- The Database tab asks about every stored item, and almost none of them have a recipe.
  if rootRecipes == nil and #ns.RecipeBook.GetRecipes(itemID) == 0 then
    return nil
  end

  local function GetRecipes(craftItemID)
    if craftItemID == itemID and rootRecipes then
      return rootRecipes
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
  end, trackChoices)
  if plan == nil then
    return { isUnknown = true }
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

-- Where Buyout Craft Cost buys a material: the vendor when it sells it for less than the Auction
-- House's cheapest listing, otherwise the Auction House. Nil when neither has a price.
---@param itemID number
---@return ArbitragePriceInfo?
function ns.Crafting.GetBuyoutPurchasePrice(itemID)
  local price = GetPurchasePrice(itemID, ns.Database.GetLatestBuyout)
  if price and price.source == nil then
    return { value = price.value, source = "auction" }
  end
  return price
end

-- The make-or-buy choices behind the recipe's Buyout Craft Cost, or its Craft Cost when atBuyout is
-- false: each craftable material's recipe key when the cheapest way makes it, or false when it buys
-- it. At Buyout prices, unitPrice can price a material instead, as a refresh of its listings does.
-- Nil when the recipe can't be priced that way.
---@param itemID number
---@param recipeKey string
---@param atBuyout boolean
---@param unitPrice (fun(itemID: number): number?)? at Buyout prices, a price to use before the Buyout
---@return table<number, string|false>?
function ns.Crafting.GetChoices(itemID, recipeKey, atBuyout, unitPrice)
  local lookup
  if atBuyout and unitPrice then
    lookup = function(reagentItemID)
      return unitPrice(reagentItemID) or ns.Database.GetLatestBuyout(reagentItemID)
    end
  elseif atBuyout then
    lookup = ns.Database.GetLatestBuyout
  else
    lookup = function(reagentItemID)
      return ns.RollingMarketValue.Get({ tostring(reagentItemID) })
    end
  end
  local plan = CalculateCost(itemID, lookup, { [recipeKey] = true }, nil, true)
  if plan == nil or plan.isUnknown then
    return nil
  end
  ---@cast plan ArbitrageCraftingPlan
  return plan.choices
end

-- Each cost comes from the cheapest of the recipes, which all make the same item.
---@param recipes ArbitrageStoredRecipe[]
---@return ArbitrageCraftingCostResult?, ArbitrageCraftingCostResult?
function ns.Crafting.GetRecipeCosts(recipes)
  local itemID = recipes[1].outputItemID
  local cost = CalculateCost(itemID, function(reagentItemID)
    return ns.RollingMarketValue.Get({ tostring(reagentItemID) })
  end, nil, recipes)
  local minimumCost = CalculateCost(itemID, function(reagentItemID)
    return ns.Database.GetLatestBuyout(reagentItemID)
  end, nil, recipes)
  return cost, minimumCost
end

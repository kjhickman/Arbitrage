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
---@return ArbitragePriceInfo?
local function MarketValue(itemID)
  return ns.RollingMarketValue.Get({ tostring(itemID) })
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
  return CalculateCost(itemID, MarketValue, recipeKeys)
end

---@param itemID number
---@param recipeKeys table<string, true>? limits the item's own recipe to these; nil for the cheapest of all
---@return ArbitrageCraftingCostResult?
function ns.Crafting.GetScanCostForItemID(itemID, recipeKeys)
  return CalculateCost(itemID, ns.Database.GetLatestBuyout, recipeKeys)
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

---@param unitPrice (fun(itemID: number): number?)? a price to use before the Buyout
---@return fun(itemID: number): number|ArbitragePriceInfo|nil
local function BuyoutLookup(unitPrice)
  if unitPrice then
    return function(reagentItemID)
      return unitPrice(reagentItemID) or ns.Database.GetLatestBuyout(reagentItemID)
    end
  end
  return ns.Database.GetLatestBuyout
end

-- The make-or-buy choices behind the recipe's Buyout Craft Cost, or its Craft Cost when atBuyout is
-- false: each craftable material's recipe key when the cheapest way makes it, or false when it buys
-- it. At Buyout prices, unitPrice can price a material instead, as a refresh of its listings does.
-- The recipe can be one no character has learned yet; its materials are still only made with
-- recipes they know. Nil without a recipe, or when the recipe can't be priced that way.
---@param recipe ArbitrageStoredRecipe?
---@param atBuyout boolean
---@param unitPrice (fun(itemID: number): number?)? at Buyout prices, a price to use before the Buyout
---@return table<number, string|false>?
function ns.Crafting.GetChoices(recipe, atBuyout, unitPrice)
  if recipe == nil then
    return nil
  end
  local lookup = atBuyout and BuyoutLookup(unitPrice) or MarketValue
  local plan = CalculateCost(recipe.outputItemID, lookup, nil, { recipe }, true)
  if plan == nil or plan.isUnknown then
    return nil
  end
  ---@cast plan ArbitrageCraftingPlan
  return plan.choices
end

-- Whether to make or buy the item itself at Buyout prices, or at unitPrice where it has one: its
-- cheapest recipe's key with the choices beneath that recipe, or false to buy it. As with a
-- material, it's made only when that costs less. Nil when no character knows a recipe for it.
---@param itemID number
---@param unitPrice (fun(itemID: number): number?)? a price to use before the Buyout
---@return table<number, string|false>?
function ns.Crafting.GetItemChoices(itemID, unitPrice)
  local lookup = BuyoutLookup(unitPrice)
  local plan = CalculateCost(itemID, lookup, nil, nil, true)
  if plan == nil then
    return nil
  end
  local price = GetPurchasePrice(itemID, lookup)
  if plan.isUnknown or (price and price.value <= plan.cost) then
    return { [itemID] = false }
  end
  ---@cast plan ArbitrageCraftingPlan
  local choices = plan.choices or {}
  choices[itemID] = plan.recipeKey
  return choices
end

-- Each cost comes from the cheapest of the recipes, which all make the same item.
---@param recipes ArbitrageStoredRecipe[]
---@return ArbitrageCraftingCostResult?, ArbitrageCraftingCostResult?
function ns.Crafting.GetRecipeCosts(recipes)
  local itemID = recipes[1].outputItemID
  local cost = CalculateCost(itemID, MarketValue, nil, recipes)
  local minimumCost = CalculateCost(itemID, ns.Database.GetLatestBuyout, nil, recipes)
  return cost, minimumCost
end

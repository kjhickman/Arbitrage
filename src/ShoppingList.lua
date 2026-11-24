local _, ns = ...

ns.ShoppingList = {}

---@class ArbitrageShoppingCraft
---@field itemID number
---@field recipeKey string
---@field count number crafts, not items

-- One realm's list. A craftable material's choice is the recipe key to make it with, or false to
-- buy it; a material without one is bought.
---@class ArbitrageShoppingRealm
---@field crafts ArbitrageShoppingCraft[] in the order they were added
---@field choices table<number, string|false>

---@class ArbitrageShoppingMaterial
---@field itemID number
---@field name string
---@field depth number 0 for a craft's own materials, one more under each material made for them
---@field need number every unit the list's crafts use, before what you have
---@field have number in your bags and banks
---@field kind "buy"|"make"
---@field crafts number? made: crafts still to make after what you have
---@field outputQuantity number? made: items each craft makes
---@field toBuy number? bought: need minus have, never below zero
---@field unitPrice number? bought: the Buyout, or the vendor's price when lower
---@field source ArbitragePurchaseSource? bought, when it has a price
---@field cost number? bought: toBuy at unitPrice

---@class ArbitrageShoppingMaterials
---@field rows ArbitrageShoppingMaterial[]
---@field cost number what the materials still to buy cost at their prices
---@field unpricedCount number materials still to buy without a price

local VERSION = 1
local MAX_COUNT = 999

---@type ArbitrageShoppingRealm
local list = { crafts = {}, choices = {} }
---@type fun()[]
local listeners = {}

local function Changed()
  for _, listener in ipairs(listeners) do
    listener()
  end
end

---@param value any
---@return boolean
local function IsCount(value)
  return type(value) == "number" and value >= 1 and value == math.floor(value)
end

---@param itemID number
---@return number? index, ArbitrageShoppingCraft? craft
local function FindCraft(itemID)
  for index, craft in ipairs(list.crafts) do
    if craft.itemID == itemID then
      return index, craft
    end
  end
end

-- The recipe a character on this realm still knows, or nil once they've all forgotten it.
---@param itemID number
---@param recipeKey string
---@return ArbitrageStoredRecipe?
function ns.ShoppingList.GetRecipe(itemID, recipeKey)
  for _, recipe in ipairs(ns.RecipeBook.GetRecipes(itemID)) do
    if recipe.recipeKey == recipeKey and recipe.outputQuantity > 0 then
      return recipe
    end
  end
end

-- The recipe the list makes a material with, or nil when it buys the material.
---@param itemID number
---@return ArbitrageStoredRecipe?
local function MakeRecipe(itemID)
  local recipeKey = list.choices[itemID]
  return type(recipeKey) == "string" and ns.ShoppingList.GetRecipe(itemID, recipeKey) or nil
end

-- Drops the choices of materials no craft on the list uses any more, so a later craft makes its own.
local function PruneChoices()
  local used = {}
  local function Visit(itemID)
    if used[itemID] then
      return
    end
    used[itemID] = true
    local recipe = MakeRecipe(itemID)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      Visit(reagent.itemID)
    end
  end
  for _, craft in ipairs(list.crafts) do
    local recipe = ns.ShoppingList.GetRecipe(craft.itemID, craft.recipeKey)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      Visit(reagent.itemID)
    end
  end
  for itemID in pairs(list.choices) do
    if not used[itemID] then
      list.choices[itemID] = nil
    end
  end
end

function ns.ShoppingList.Init()
  if type(ARBITRAGE_SHOPPING) ~= "table" or ARBITRAGE_SHOPPING.__version ~= VERSION then
    ARBITRAGE_SHOPPING = { __version = VERSION }
  end

  local realmKey = ns.Realm.GetName()
  local realm = rawget(ARBITRAGE_SHOPPING, realmKey)
  if type(realm) ~= "table" or type(realm.crafts) ~= "table" or type(realm.choices) ~= "table" then
    realm = { crafts = {}, choices = {} }
    ARBITRAGE_SHOPPING[realmKey] = realm
  end
  ---@cast realm ArbitrageShoppingRealm
  local crafts = {}
  for _, craft in ipairs(realm.crafts) do
    if
      type(craft) == "table"
      and IsCount(craft.itemID)
      and type(craft.recipeKey) == "string"
      and IsCount(craft.count)
    then
      crafts[#crafts + 1] = craft
    end
  end
  realm.crafts = crafts
  list = realm
end

---@param callback fun() called after every change to the list
function ns.ShoppingList.OnChange(callback)
  listeners[#listeners + 1] = callback
end

-- Adds crafts of the opportunity's recipe, or more of a craft already on the list. Its materials
-- follow the make-or-buy choices behind the costs the details show: at Buyout prices when it has
-- them. A material another craft already uses keeps the list's choice.
---@param opportunity ArbitrageCraftOpportunity
---@param count number
---@return boolean added false when the opportunity names no recipe
function ns.ShoppingList.Add(opportunity, count)
  local recipeKey = opportunity.recipeKey
  if not recipeKey or not IsCount(count) then
    return false
  end

  local _, craft = FindCraft(opportunity.itemID)
  if craft then
    craft.count = math.min(craft.count + count, MAX_COUNT)
  else
    craft = { itemID = opportunity.itemID, recipeKey = recipeKey, count = math.min(count, MAX_COUNT) }
    list.crafts[#list.crafts + 1] = craft
  end

  local choices = ns.Crafting.GetChoices(craft.itemID, craft.recipeKey, opportunity.buyoutMaterials ~= nil)
  for materialID, choice in pairs(choices or {}) do
    if list.choices[materialID] == nil then
      list.choices[materialID] = choice
    end
  end
  Changed()
  return true
end

-- A count below one removes the craft.
---@param itemID number
---@param count number
function ns.ShoppingList.SetCount(itemID, count)
  local index, craft = FindCraft(itemID)
  if not index or not craft then
    return
  end
  if count < 1 then
    table.remove(list.crafts, index)
    PruneChoices()
  else
    craft.count = math.min(math.floor(count), MAX_COUNT)
  end
  Changed()
end

---@param itemID number
function ns.ShoppingList.Remove(itemID)
  ns.ShoppingList.SetCount(itemID, 0)
end

function ns.ShoppingList.Clear()
  list.crafts = {}
  list.choices = {}
  Changed()
end

-- The crafts in the order they were added. Callers must not change them.
---@return ArbitrageShoppingCraft[]
function ns.ShoppingList.GetCrafts()
  return list.crafts
end

---@param itemID number
---@return number crafts of the item on the list
function ns.ShoppingList.GetCount(itemID)
  local _, craft = FindCraft(itemID)
  return craft and craft.count or 0
end

---@return number
function ns.ShoppingList.GetCraftCount()
  return #list.crafts
end

---@param itemID number
---@return number
local function CountOwned(itemID)
  return C_Item.GetItemCount(itemID, true, false, true, true) or 0
end

-- Everything the list's crafts use, made into whole crafts: a material needing three from a recipe
-- that makes two is crafted twice. What you already have of a made material counts before any is
-- made from its own materials. Each material is listed once, under the first material still to be
-- made from it, and materials nothing needs any more are left out.
---@return ArbitrageShoppingMaterials
function ns.ShoppingList.GetMaterials()
  ---@type table<number, number>
  local demand = {}
  ---@type table<number, string>
  local names = {}
  ---@type table<number, number>
  local owned = {}
  ---@type ArbitrageRecipeReagent[]
  local topReagents = {}

  ---@param reagent ArbitrageRecipeReagent
  local function Name(reagent)
    if not names[reagent.itemID] then
      names[reagent.itemID] = C_Item.GetItemInfo(reagent.itemID) or reagent.name or ("Item #" .. reagent.itemID)
    end
    return names[reagent.itemID]
  end

  ---@param itemID number
  local function Have(itemID)
    if not owned[itemID] then
      owned[itemID] = CountOwned(itemID)
    end
    return owned[itemID]
  end

  local seenTop = {}
  for _, craft in ipairs(list.crafts) do
    local recipe = ns.ShoppingList.GetRecipe(craft.itemID, craft.recipeKey)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      demand[reagent.itemID] = (demand[reagent.itemID] or 0) + reagent.quantity * craft.count
      Name(reagent)
      if not seenTop[reagent.itemID] then
        seenTop[reagent.itemID] = true
        topReagents[#topReagents + 1] = reagent
      end
    end
  end

  -- Each made material after every material made from it, so it knows its full demand before
  -- passing its own on. A material whose recipe would need something already being made for it is
  -- bought instead, which ends the loop.
  ---@type table<number, ArbitrageStoredRecipe>
  local recipes = {}
  local visited, inProgress, finished = {}, {}, {}
  local function Visit(itemID)
    if visited[itemID] then
      return
    end
    visited[itemID] = true
    local recipe = MakeRecipe(itemID)
    if recipe then
      inProgress[itemID] = true
      for _, reagent in ipairs(recipe.reagents) do
        Name(reagent)
        if inProgress[reagent.itemID] then
          recipe = nil
          break
        end
        Visit(reagent.itemID)
      end
      inProgress[itemID] = nil
    end
    recipes[itemID] = recipe
    finished[#finished + 1] = itemID
  end
  for _, reagent in ipairs(topReagents) do
    Visit(reagent.itemID)
  end

  ---@type table<number, number>
  local craftsToMake = {}
  for index = #finished, 1, -1 do
    local itemID = finished[index]
    local recipe = recipes[itemID]
    if recipe then
      local short = math.max(0, (demand[itemID] or 0) - Have(itemID))
      local crafts = math.ceil(short / recipe.outputQuantity)
      craftsToMake[itemID] = crafts
      for _, reagent in ipairs(recipe.reagents) do
        demand[reagent.itemID] = (demand[reagent.itemID] or 0) + reagent.quantity * crafts
      end
    end
  end

  ---@param reagents ArbitrageRecipeReagent[]
  ---@return ArbitrageRecipeReagent[]
  local function ByName(reagents)
    local sorted = {}
    for index, reagent in ipairs(reagents) do
      sorted[index] = reagent
    end
    table.sort(sorted, function(left, right)
      local leftName, rightName = names[left.itemID], names[right.itemID]
      if leftName ~= rightName then
        return leftName < rightName
      end
      return left.itemID < right.itemID
    end)
    return sorted
  end

  ---@type ArbitrageShoppingMaterials
  local result = { rows = {}, cost = 0, unpricedCount = 0 }
  local placed = {}
  local function Place(itemID, depth)
    local need = demand[itemID] or 0
    if placed[itemID] or need <= 0 then
      return
    end
    placed[itemID] = true

    local have = Have(itemID)
    ---@type ArbitrageShoppingMaterial
    local row = { itemID = itemID, name = names[itemID], depth = depth, need = need, have = have, kind = "buy" }
    result.rows[#result.rows + 1] = row
    local recipe = recipes[itemID]
    if recipe then
      row.kind = "make"
      row.crafts = craftsToMake[itemID]
      row.outputQuantity = recipe.outputQuantity
      -- Nothing is made from what you already have, so other crafts' materials don't go under it.
      if row.crafts > 0 then
        for _, reagent in ipairs(ByName(recipe.reagents)) do
          Place(reagent.itemID, depth + 1)
        end
      end
      return
    end

    row.toBuy = math.max(0, need - have)
    local price = ns.Crafting.GetBuyoutPurchasePrice(itemID)
    if price then
      row.unitPrice = price.value
      row.source = price.source
      row.cost = math.floor(price.value * row.toBuy + 0.5)
      result.cost = result.cost + row.cost
    elseif row.toBuy > 0 then
      result.unpricedCount = result.unpricedCount + 1
    end
  end
  for _, reagent in ipairs(ByName(topReagents)) do
    Place(reagent.itemID, 0)
  end
  return result
end

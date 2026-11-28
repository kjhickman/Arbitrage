local _, ns = ...

ns.ShoppingList = {}

---@class ArbitrageShoppingCraft
---@field itemID number
---@field recipeKey string
---@field count number crafts, not items

-- An item wanted for itself, made or bought as the list chooses, rather than crafts of one recipe.
---@class ArbitrageShoppingItem
---@field itemID number
---@field count number items, not crafts

-- One realm's list. A craftable material's choice is the recipe key to make it with, or false to
-- buy it; a material without one is bought. Items share the choices, as the list's own materials.
---@class ArbitrageShoppingRealm
---@field crafts ArbitrageShoppingCraft[] in the order they were added
---@field items ArbitrageShoppingItem[] in the order they were added
---@field choices table<number, string|false>
---@field mail table<string, table<number, number>> by character, what it bought and hasn't yet collected from its mailbox

---@class ArbitrageShoppingMaterial
---@field itemID number
---@field name string
---@field depth number 0 for a craft's own materials, one more under each material made for them
---@field need number every unit the list's crafts use, before what you have
---@field have number in your bags and banks, and bought and waiting in your mailbox
---@field inMail number? of have, bought and waiting in your mailbox
---@field kind "buy"|"make"
---@field canMake boolean a character knows a recipe for it, so it can be made or bought
---@field crafts number? made: crafts still to make after what you have
---@field outputQuantity number? made: items each craft makes
---@field toBuy number? bought: need minus have, never below zero
---@field unitPrice number? bought: the Buyout, or the vendor's price when lower; refreshed, the average a unit costs
---@field source ArbitragePurchaseSource? bought, when it has a price
---@field cost number? bought: toBuy at unitPrice, or refreshed, what the cheapest listings of toBuy cost
---@field listed number? refreshed: units listed, not counting your own
---@field refreshedAt number? refreshed: when its listings were searched

---@class ArbitrageShoppingMaterials
---@field rows ArbitrageShoppingMaterial[]
---@field cost number what the materials still to buy cost at their prices
---@field unpricedCount number materials still to buy without a price
---@field shortCount number refreshed materials with fewer listed than are still to buy

-- What some of a material costs made or bought. Nil where it has no price.
---@class ArbitrageMakeOrBuy
---@field recipeKey string? the recipe making it uses
---@field makeTotal number? copper to make them, in whole crafts, its own materials made or bought as the list would
---@field makeRefreshed boolean every Auction House price behind makeTotal came from a refresh
---@field buyTotal number? copper to buy them
---@field buyRefreshed boolean buyTotal came from a refresh, or a vendor
---@field buySource ArbitragePurchaseSource?

local VERSION = 1
local MAX_COUNT = 999

---@type ArbitrageShoppingRealm
local list = { crafts = {}, items = {}, choices = {}, mail = {} }
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

---@generic T : ArbitrageShoppingCraft|ArbitrageShoppingItem
---@param entries T[]
---@param itemID number
---@return number? index, T? entry
local function Find(entries, itemID)
  for index, entry in ipairs(entries) do
    if entry.itemID == itemID then
      return index, entry
    end
  end
end

---@param recipes ArbitrageStoredRecipe[]
---@param recipeKey string
---@return ArbitrageStoredRecipe?
local function WithKey(recipes, recipeKey)
  for _, recipe in ipairs(recipes) do
    if recipe.recipeKey == recipeKey and recipe.outputQuantity > 0 then
      return recipe
    end
  end
end

-- The recipe a character on this realm still knows, or nil once they've all forgotten it.
---@param itemID number
---@param recipeKey string
---@return ArbitrageStoredRecipe?
function ns.ShoppingList.GetRecipe(itemID, recipeKey)
  return WithKey(ns.RecipeBook.GetRecipes(itemID), recipeKey)
end

-- A craft's recipe: one a character knows, or else one a character could still learn, which the
-- list plans the craft with but never makes a material with. Nil once neither is so.
---@param craft ArbitrageShoppingCraft
---@return ArbitrageStoredRecipe? recipe, boolean unlearned
function ns.ShoppingList.GetCraftRecipe(craft)
  local recipe = ns.ShoppingList.GetRecipe(craft.itemID, craft.recipeKey)
  if recipe then
    return recipe, false
  end
  recipe = WithKey(ns.RecipeBook.GetUnlearnedRecipes(craft.itemID), craft.recipeKey)
  return recipe, recipe ~= nil
end

-- The recipe the list makes a material with, or nil when it buys the material.
---@param itemID number
---@return ArbitrageStoredRecipe?
local function MakeRecipe(itemID)
  local recipeKey = list.choices[itemID]
  return type(recipeKey) == "string" and ns.ShoppingList.GetRecipe(itemID, recipeKey) or nil
end

-- The recipe that makes the item for least at Buyout prices, or, when none can be priced, the first
-- by key. Nil when no character knows one.
---@param itemID number
---@return string?
local function CheapestRecipeKey(itemID)
  local plan = ns.Crafting.GetScanCostForItemID(itemID)
  if plan and not plan.isUnknown and plan.recipeKey then
    return plan.recipeKey
  end
  local first
  for _, recipe in ipairs(ns.RecipeBook.GetRecipes(itemID)) do
    if recipe.outputQuantity > 0 and (first == nil or recipe.recipeKey < first) then
      first = recipe.recipeKey
    end
  end
  return first
end

-- Drops the choices of materials nothing on the list uses any more, so a later craft makes its own.
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
    local recipe = ns.ShoppingList.GetCraftRecipe(craft)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      Visit(reagent.itemID)
    end
  end
  for _, item in ipairs(list.items) do
    Visit(item.itemID)
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
  -- Lists saved before items could be added have none.
  local wanted = {}
  for _, item in ipairs(type(realm.items) == "table" and realm.items or {}) do
    if type(item) == "table" and IsCount(item.itemID) and IsCount(item.count) then
      wanted[#wanted + 1] = item
    end
  end
  realm.items = wanted
  local mail = {}
  for character, items in pairs(type(realm.mail) == "table" and realm.mail or {}) do
    if type(character) == "string" and type(items) == "table" then
      mail[character] = {}
      for itemID, quantity in pairs(items) do
        if IsCount(itemID) and IsCount(quantity) then
          mail[character][itemID] = quantity
        end
      end
    end
  end
  realm.mail = mail
  list = realm
end

-- What the current character bought and hasn't collected from its mailbox, by item.
---@param create boolean? makes the character's table when it has none
---@return table<number, number>?
local function MailOf(create)
  local character = ns.Realm.GetCharacterName()
  if not character then
    return nil
  end
  if not list.mail[character] and create then
    list.mail[character] = {}
  end
  return list.mail[character]
end

---@param itemID number
---@return number
local function BagCount(itemID)
  return C_Item.GetItemCount(itemID, true, false, true, true) or 0
end

---@param itemID number
---@return number bought and waiting in the current character's mailbox
function ns.ShoppingList.GetInMail(itemID)
  local pending = MailOf()
  return pending and pending[itemID] or 0
end

local mailboxOpen = false
-- When the mailbox last closed. Items taken just before reach the bags just after.
local mailboxClosedAt = -math.huge
-- Bag and bank counts of what's waiting in the mail, as last seen.
---@type table<number, number>
local bagCounts = {}

-- Auction House purchases arrive by mail, which bags and banks don't count, so the list counts what
-- you buy until you collect it.
---@param itemID number
---@param quantity number
function ns.ShoppingList.RecordPurchase(itemID, quantity)
  local pending = MailOf(true)
  if not pending or not IsCount(quantity) then
    return
  end
  pending[itemID] = (pending[itemID] or 0) + quantity
  bagCounts[itemID] = bagCounts[itemID] or BagCount(itemID)
  Changed()
end

-- What reaches your bags while the mailbox is open comes off what's waiting in it. Anything gained
-- elsewhere, such as by crafting, only moves the count it's measured from.
local function NoteBags()
  local pending = MailOf()
  if not pending then
    return
  end
  local changed = false
  local atMailbox = mailboxOpen or GetTime() - mailboxClosedAt < 1
  for itemID, quantity in pairs(pending) do
    local owned = BagCount(itemID)
    local gained = owned - (bagCounts[itemID] or owned)
    if atMailbox and gained > 0 then
      local left = quantity - math.min(gained, quantity)
      pending[itemID] = left > 0 and left or nil
      changed = true
    end
    bagCounts[itemID] = owned
  end
  if changed then
    Changed()
  end
end

-- Follows the mailbox and your bags.
function ns.ShoppingList.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("MAIL_SHOW")
  frame:RegisterEvent("MAIL_CLOSED")
  frame:RegisterEvent("BAG_UPDATE_DELAYED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "MAIL_SHOW" then
      mailboxOpen = true
      bagCounts = {}
      NoteBags()
    elseif eventName == "MAIL_CLOSED" then
      mailboxOpen, mailboxClosedAt = false, GetTime()
    else
      NoteBags()
    end
  end)
end

-- Takes the choices for materials the list has none for yet.
---@param choices table<number, string|false>?
local function FillChoices(choices)
  for materialID, choice in pairs(choices or {}) do
    if list.choices[materialID] == nil then
      list.choices[materialID] = choice
    end
  end
end

---@param callback fun() called after every change to the list
function ns.ShoppingList.OnChange(callback)
  listeners[#listeners + 1] = callback
end

-- Adds crafts of the opportunity's recipe, or more of a craft already on the list. Its materials
-- follow the make-or-buy choices behind the costs the details show: at Buyout prices when it has
-- them. A material another craft already uses keeps the list's choice. The recipe can be one no
-- character has learned yet.
---@param opportunity ArbitrageCraftOpportunity
---@param count number
---@return boolean added false when the opportunity names no recipe
function ns.ShoppingList.Add(opportunity, count)
  local recipeKey = opportunity.recipeKey
  if not recipeKey or not IsCount(count) then
    return false
  end

  local _, craft = Find(list.crafts, opportunity.itemID)
  if craft then
    craft.count = math.min(craft.count + count, MAX_COUNT)
  else
    craft = { itemID = opportunity.itemID, recipeKey = recipeKey, count = math.min(count, MAX_COUNT) }
    list.crafts[#list.crafts + 1] = craft
  end

  local recipe = ns.ShoppingList.GetCraftRecipe(craft)
  FillChoices(ns.Crafting.GetChoices(recipe, opportunity.buyoutMaterials ~= nil))
  Changed()
  return true
end

-- Adds some of an item, or more of one already on the list. One a character can craft is made or
-- bought as costs least at Buyout prices, unless the list already chose for it; any other is bought.
---@param itemID number
---@param count number items, not crafts
---@return boolean added
function ns.ShoppingList.AddItem(itemID, count)
  if not IsCount(itemID) or not IsCount(count) then
    return false
  end

  local _, item = Find(list.items, itemID)
  if item then
    item.count = math.min(item.count + count, MAX_COUNT)
  else
    list.items[#list.items + 1] = { itemID = itemID, count = math.min(count, MAX_COUNT) }
  end

  if list.choices[itemID] == nil then
    FillChoices(ns.Crafting.GetItemChoices(itemID))
  end
  Changed()
  return true
end

-- Makes a material instead of buying it, or buys it instead of making it, for every craft on the
-- list. Making it uses the recipe that costs least at Buyout prices, and the materials beneath it
-- the list has no choice for yet are made or bought as cost least. Buying it keeps those choices, so
-- making it again restores them.
---@param itemID number
---@param make boolean
function ns.ShoppingList.SetMake(itemID, make)
  if not make then
    if list.choices[itemID] == false then
      return
    end
    list.choices[itemID] = false
  else
    if MakeRecipe(itemID) then
      return
    end
    local recipeKey = CheapestRecipeKey(itemID)
    if not recipeKey then
      return
    end
    list.choices[itemID] = recipeKey
    FillChoices(ns.Crafting.GetChoices(MakeRecipe(itemID), true))
  end
  Changed()
end

---@alias ArbitrageQuoteLookup fun(itemID: number, quantity: number): ArbitrageSearchQuote?

-- What buying some of a material costs: at a vendor, at what a refresh found listed, or at its
-- Buyout, with any a refresh found too few of at the Buyout. Also whether it's a refreshed or vendor
-- price, and where it's bought.
---@param itemID number
---@param quantity number
---@param quote ArbitrageQuoteLookup?
---@return number? total, boolean refreshed, ArbitragePurchaseSource? source
local function BuyTotal(itemID, quantity, quote)
  local price = ns.Crafting.GetBuyoutPurchasePrice(itemID)
  if price and price.source == "vendor" then
    return price.value * quantity, true, "vendor"
  end
  local searched = quote and quote(itemID, quantity)
  if searched and searched.listed >= quantity then
    return searched.cost, true, "auction"
  elseif searched and price then
    return searched.cost + price.value * (quantity - searched.listed), false, "auction"
  elseif price then
    return price.value * quantity, false, "auction"
  end
  return nil, false, nil
end

-- What making some of a material with the recipe costs: whole crafts of it, each of its materials
-- made or bought as the list would, or as fallback chooses for any the list has no choice for yet.
---@param recipe ArbitrageStoredRecipe
---@param quantity number
---@param quote ArbitrageQuoteLookup?
---@param fallback table<number, string|false>
---@param making table<number, true> the materials being made for it, which aren't made again
---@return number? total, boolean refreshed
local function MakeTotal(recipe, quantity, quote, fallback, making)
  local crafts = math.ceil(quantity / recipe.outputQuantity)
  local total, refreshed = 0, true
  for _, reagent in ipairs(recipe.reagents) do
    local amount = reagent.quantity * crafts
    local choice = list.choices[reagent.itemID]
    if choice == nil then
      choice = fallback[reagent.itemID]
    end
    local made = type(choice) == "string"
      and not making[reagent.itemID]
      and ns.ShoppingList.GetRecipe(reagent.itemID, choice)
    local cost, fresh
    if made then
      making[reagent.itemID] = true
      cost, fresh = MakeTotal(made, amount, quote, fallback, making)
      making[reagent.itemID] = nil
    else
      cost, fresh = BuyTotal(reagent.itemID, amount, quote)
    end
    if not cost then
      return nil, false
    end
    total, refreshed = total + cost, refreshed and fresh
  end
  return total, refreshed
end

-- What making and buying some of a material cost, at refreshed prices where quote has them: made with
-- the recipe the list makes it with, or would if switched to making it.
---@param itemID number
---@param quantity number
---@param quote ArbitrageQuoteLookup?
---@return ArbitrageMakeOrBuy
function ns.ShoppingList.CompareMakeAndBuy(itemID, quantity, quote)
  local recipe = MakeRecipe(itemID)
  local recipeKey = recipe and recipe.recipeKey or CheapestRecipeKey(itemID)
  recipe = recipe or (recipeKey and ns.ShoppingList.GetRecipe(itemID, recipeKey))
  ---@type ArbitrageMakeOrBuy
  local comparison = { recipeKey = recipeKey, makeRefreshed = false, buyRefreshed = false }
  if recipe then
    -- Switching to making it fills in the choices beneath it the same way.
    local fallback = ns.Crafting.GetChoices(recipe, true) or {}
    local total, refreshed = MakeTotal(recipe, quantity, quote, fallback, { [itemID] = true })
    if total then
      comparison.makeTotal, comparison.makeRefreshed = math.floor(total + 0.5), refreshed
    end
  end
  local total, refreshed, source = BuyTotal(itemID, quantity, quote)
  if total then
    comparison.buyTotal, comparison.buyRefreshed = math.floor(total + 0.5), refreshed
    comparison.buySource = source
  end
  return comparison
end

-- A count below one removes the entry.
---@param entries ArbitrageShoppingCraft[]|ArbitrageShoppingItem[]
---@param itemID number
---@param count number
local function SetEntryCount(entries, itemID, count)
  local index, entry = Find(entries, itemID)
  if not index or not entry then
    return
  end
  if count < 1 then
    table.remove(entries, index)
    PruneChoices()
  else
    entry.count = math.min(math.floor(count), MAX_COUNT)
  end
  Changed()
end

-- A count below one removes the craft.
---@param itemID number
---@param count number crafts
function ns.ShoppingList.SetCount(itemID, count)
  SetEntryCount(list.crafts, itemID, count)
end

-- A count below one removes the item.
---@param itemID number
---@param count number items
function ns.ShoppingList.SetItemCount(itemID, count)
  SetEntryCount(list.items, itemID, count)
end

function ns.ShoppingList.Clear()
  list.crafts = {}
  list.items = {}
  list.choices = {}
  Changed()
end

-- The crafts in the order they were added. Callers must not change them.
---@return ArbitrageShoppingCraft[]
function ns.ShoppingList.GetCrafts()
  return list.crafts
end

-- The items in the order they were added. Callers must not change them.
---@return ArbitrageShoppingItem[]
function ns.ShoppingList.GetItems()
  return list.items
end

---@param itemID number
---@return number crafts of the item on the list
function ns.ShoppingList.GetCount(itemID)
  local _, craft = Find(list.crafts, itemID)
  return craft and craft.count or 0
end

---@param itemID number
---@return number of the item on the list for itself, not counting crafts of it
function ns.ShoppingList.GetItemCount(itemID)
  local _, item = Find(list.items, itemID)
  return item and item.count or 0
end

-- Each material after every material that could be made from it, with the recipes it can be made by
-- here: a recipe that would need something already being made for it is left out, which ends the
-- loop.
---@param itemIDs number[]
---@param recipesFor fun(itemID: number): ArbitrageStoredRecipe[]
---@return number[] ordered, table<number, ArbitrageStoredRecipe[]> usable
local function Order(itemIDs, recipesFor)
  local ordered, usable, inProgress = {}, {}, {}
  local function Visit(itemID)
    if usable[itemID] then
      return
    end
    usable[itemID] = {}
    inProgress[itemID] = true
    for _, recipe in ipairs(recipesFor(itemID)) do
      local loops = recipe.outputQuantity <= 0
      for _, reagent in ipairs(recipe.reagents) do
        loops = loops or inProgress[reagent.itemID] == true
      end
      if not loops then
        table.insert(usable[itemID], recipe)
        for _, reagent in ipairs(recipe.reagents) do
          Visit(reagent.itemID)
        end
      end
    end
    inProgress[itemID] = nil
    ordered[#ordered + 1] = itemID
  end
  for _, itemID in ipairs(itemIDs) do
    Visit(itemID)
  end
  return ordered, usable
end

---@param itemID number
---@return number
local function CountOwned(itemID)
  return BagCount(itemID) + ns.ShoppingList.GetInMail(itemID)
end

-- Everything the list's crafts use, and its items, made into whole crafts: a material needing three
-- from a recipe that makes two is crafted twice. What you already have of a made material counts
-- before any is made from its own materials. Each material is listed once, under the first material
-- still to be made from it, and materials nothing needs any more are left out. Items are listed
-- with the crafts' own materials, adding to their need. A material bought at the Auction House
-- costs what quote says its listings do, when it has a quote.
---@param quote (fun(itemID: number, quantity: number): ArbitrageSearchQuote?)?
---@return ArbitrageShoppingMaterials
function ns.ShoppingList.GetMaterials(quote)
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

  local seenTop, topIDs = {}, {}
  ---@param reagent ArbitrageRecipeReagent|ArbitrageShoppingItem
  ---@param quantity number
  local function AddTop(reagent, quantity)
    demand[reagent.itemID] = (demand[reagent.itemID] or 0) + quantity
    Name(reagent)
    if not seenTop[reagent.itemID] then
      seenTop[reagent.itemID] = true
      topReagents[#topReagents + 1] = reagent
      topIDs[#topIDs + 1] = reagent.itemID
    end
  end
  for _, craft in ipairs(list.crafts) do
    local recipe = ns.ShoppingList.GetCraftRecipe(craft)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      AddTop(reagent, reagent.quantity * craft.count)
    end
  end
  for _, item in ipairs(list.items) do
    AddTop(item, item.count)
  end

  -- Each made material after every material made from it, so it knows its full demand before
  -- passing its own on. A material whose recipe would loop is bought instead.
  local finished, usable = Order(topIDs, function(itemID)
    return { MakeRecipe(itemID) }
  end)
  ---@type table<number, ArbitrageStoredRecipe>
  local recipes = {}
  for _, itemID in ipairs(finished) do
    recipes[itemID] = usable[itemID][1]
    for _, reagent in ipairs(recipes[itemID] and recipes[itemID].reagents or {}) do
      Name(reagent)
    end
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
    local sorted = { unpack(reagents) }
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
  local result = { rows = {}, cost = 0, unpricedCount = 0, shortCount = 0 }
  local placed = {}
  local function Place(itemID, depth)
    local need = demand[itemID] or 0
    if placed[itemID] or need <= 0 then
      return
    end
    placed[itemID] = true

    local have = Have(itemID)
    local recipe = recipes[itemID]
    ---@type ArbitrageShoppingMaterial
    local row = {
      itemID = itemID,
      name = names[itemID],
      depth = depth,
      need = need,
      have = have,
      kind = "buy",
      canMake = recipe ~= nil or #ns.RecipeBook.GetRecipes(itemID) > 0,
    }
    local inMail = ns.ShoppingList.GetInMail(itemID)
    if inMail > 0 then
      row.inMail = inMail
    end
    result.rows[#result.rows + 1] = row
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
    local searched = quote
      and row.toBuy > 0
      and (price == nil or price.source == "auction")
      and quote(itemID, row.toBuy)
    if searched then
      row.source = "auction"
      row.cost = searched.cost
      row.listed = searched.listed
      row.refreshedAt = searched.at
      if searched.listed > 0 then
        row.unitPrice = searched.cost / math.min(row.toBuy, searched.listed)
      end
      result.cost = result.cost + row.cost
      if searched.listed < row.toBuy then
        result.shortCount = result.shortCount + 1
      end
    elseif price then
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

-- What a refresh searches: every material the crafts and items could need however each is made or
-- bought, by any recipe a character knows. Each is searched for the most the list could need of it:
-- what it'd need with everything above it made, by whichever recipe needs most, less what you have.
-- Materials a vendor sells for less than the Auction House aren't searched.
---@return ArbitrageSearchRequest[]
function ns.ShoppingList.GetSearchList()
  ---@type table<number, number>
  local demand = {}
  local owned = {}
  local function Have(itemID)
    if not owned[itemID] then
      owned[itemID] = CountOwned(itemID)
    end
    return owned[itemID]
  end

  local top = {}
  for _, craft in ipairs(list.crafts) do
    local recipe = ns.ShoppingList.GetCraftRecipe(craft)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      demand[reagent.itemID] = (demand[reagent.itemID] or 0) + reagent.quantity * craft.count
      top[#top + 1] = reagent.itemID
    end
  end
  for _, item in ipairs(list.items) do
    demand[item.itemID] = (demand[item.itemID] or 0) + item.count
    top[#top + 1] = item.itemID
  end

  local finished, recipesOf = Order(top, ns.RecipeBook.GetRecipes)

  for index = #finished, 1, -1 do
    local itemID = finished[index]
    local short = math.max(0, (demand[itemID] or 0) - Have(itemID))
    local most = {}
    for _, recipe in ipairs(recipesOf[itemID]) do
      local crafts = math.ceil(short / recipe.outputQuantity)
      for _, reagent in ipairs(recipe.reagents) do
        most[reagent.itemID] = math.max(most[reagent.itemID] or 0, reagent.quantity * crafts)
      end
    end
    for reagentID, quantity in pairs(most) do
      demand[reagentID] = (demand[reagentID] or 0) + quantity
    end
  end

  ---@type ArbitrageSearchRequest[]
  local requests = {}
  for _, itemID in ipairs(finished) do
    local short = (demand[itemID] or 0) - Have(itemID)
    local price = ns.Crafting.GetBuyoutPurchasePrice(itemID)
    if short > 0 and not (price and price.source == "vendor") then
      requests[#requests + 1] = { itemID = itemID, quantity = short }
    end
  end
  table.sort(requests, function(left, right)
    return left.itemID < right.itemID
  end)
  return requests
end

-- After a refresh: makes or buys every material, and every item, as costs least at the prices
-- unitPrice gives, and the Buyouts of anything it doesn't, as Buyout Craft Cost chooses. A material
-- more than one craft or item uses follows the first, crafts before items.
---@param unitPrice fun(itemID: number): number?
function ns.ShoppingList.ChooseCheapest(unitPrice)
  local decided, changed = {}, false
  ---@param choices table<number, string|false>?
  local function Decide(choices)
    for materialID, choice in pairs(choices or {}) do
      if not decided[materialID] then
        decided[materialID] = true
        if list.choices[materialID] ~= choice then
          list.choices[materialID] = choice
          changed = true
        end
      end
    end
  end
  for _, craft in ipairs(list.crafts) do
    local recipe = ns.ShoppingList.GetCraftRecipe(craft)
    Decide(ns.Crafting.GetChoices(recipe, true, unitPrice))
  end
  for _, item in ipairs(list.items) do
    Decide(ns.Crafting.GetItemChoices(item.itemID, unitPrice))
  end
  if changed then
    Changed()
  end
end

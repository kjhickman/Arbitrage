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
---@field mail table<string, table<number, number>>? by character, what it bought and hasn't yet collected from its mailbox

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
  list.mail = list.mail or {}
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
-- Marks the latest closing of the mailbox, so a later opening keeps it open.
local mailboxToken
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
  for itemID, quantity in pairs(pending) do
    local owned = BagCount(itemID)
    local gained = owned - (bagCounts[itemID] or owned)
    if mailboxOpen and gained > 0 then
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

-- Follows the mailbox and your bags. Items taken just before the mailbox closes reach the bags just
-- after, so it counts as open a moment longer.
function ns.ShoppingList.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("MAIL_SHOW")
  frame:RegisterEvent("MAIL_CLOSED")
  frame:RegisterEvent("BAG_UPDATE_DELAYED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "MAIL_SHOW" then
      mailboxOpen, mailboxToken = true, nil
      bagCounts = {}
      NoteBags()
    elseif eventName == "MAIL_CLOSED" then
      local token = {}
      mailboxToken = token
      C_Timer.After(1, function()
        if mailboxToken == token then
          mailboxOpen = false
        end
      end)
    else
      NoteBags()
    end
  end)
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
    for materialID, choice in pairs(ns.Crafting.GetChoices(itemID, recipeKey, true) or {}) do
      if list.choices[materialID] == nil then
        list.choices[materialID] = choice
      end
    end
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
    local fallback = ns.Crafting.GetChoices(itemID, recipe.recipeKey, true) or {}
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
  return BagCount(itemID) + ns.ShoppingList.GetInMail(itemID)
end

-- Everything the list's crafts use, made into whole crafts: a material needing three from a recipe
-- that makes two is crafted twice. What you already have of a made material counts before any is
-- made from its own materials. Each material is listed once, under the first material still to be
-- made from it, and materials nothing needs any more are left out. A material bought at the
-- Auction House costs what quote says its listings do, when it has a quote.
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

-- What a refresh searches: every material the crafts could need however each is made or bought, by
-- any recipe a character knows. Each is searched for the most the crafts could need of it: what
-- they'd need with everything above it made, by whichever recipe needs most, less what you have.
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
    local recipe = ns.ShoppingList.GetRecipe(craft.itemID, craft.recipeKey)
    for _, reagent in ipairs(recipe and recipe.reagents or {}) do
      demand[reagent.itemID] = (demand[reagent.itemID] or 0) + reagent.quantity * craft.count
      top[#top + 1] = reagent.itemID
    end
  end

  -- Each material after every material that could be made from it. A recipe that would need
  -- something already being made for it is left out, which ends the loop.
  ---@type table<number, ArbitrageStoredRecipe[]>
  local recipesOf = {}
  local visited, inProgress, finished = {}, {}, {}
  local function Visit(itemID)
    if visited[itemID] then
      return
    end
    visited[itemID] = true
    inProgress[itemID] = true
    local usable = {}
    for _, recipe in ipairs(ns.RecipeBook.GetRecipes(itemID)) do
      local loops = recipe.outputQuantity <= 0
      for _, reagent in ipairs(recipe.reagents) do
        loops = loops or inProgress[reagent.itemID] == true
      end
      if not loops then
        usable[#usable + 1] = recipe
        for _, reagent in ipairs(recipe.reagents) do
          Visit(reagent.itemID)
        end
      end
    end
    inProgress[itemID] = nil
    recipesOf[itemID] = usable
    finished[#finished + 1] = itemID
  end
  for _, itemID in ipairs(top) do
    Visit(itemID)
  end

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

-- After a refresh: makes or buys every material as costs least at the prices unitPrice gives, and the
-- Buyouts of anything it doesn't, as Buyout Craft Cost chooses. A material more than one craft uses
-- follows the first.
---@param unitPrice fun(itemID: number): number?
function ns.ShoppingList.ChooseCheapest(unitPrice)
  local decided, changed = {}, false
  for _, craft in ipairs(list.crafts) do
    for materialID, choice in pairs(ns.Crafting.GetChoices(craft.itemID, craft.recipeKey, true, unitPrice) or {}) do
      if not decided[materialID] then
        decided[materialID] = true
        if list.choices[materialID] ~= choice then
          list.choices[materialID] = choice
          changed = true
        end
      end
    end
  end
  if changed then
    Changed()
  end
end

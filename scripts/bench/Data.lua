-- The benchmark's data: picking the market saved data plays on, a synthetic database shaped like a
-- real one for when there is no saved data, and the auctions a scan of that market would see.
local Hash = require("Client").Hash

local Data = {}

local DAY = 24 * 60 * 60
-- A fixed clock for synthetic data, so it ages the same way every run.
local SYNTHETIC_NOW = 1795448000
-- The most listings a stackable item has; tuned so a real market's keys make as many auctions as
-- its Auction House had.
local MOST_STACK_LISTINGS = 200
-- An auction is kept as its item's index times this, plus which of the item's listings it is.
local LISTINGS_PER_ITEM = 1024

---@param key string
---@return number? itemID, number? variant
local function ParseKey(key)
  local itemID, variant = key:match("^equip:(%d+):(%-?%d+)$")
  if itemID then
    return tonumber(itemID), tonumber(variant)
  end
  return tonumber(key)
end
Data.ParseKey = ParseKey

---@param set table
---@return any[]
local function SortedKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

-- The faction market of the saved database most recently played, as the game would log into it.
---@return string realm, string faction, number region, table market
function Data.ChooseMarket()
  local best
  for realmName, realm in pairs(ARBITRAGE_DATABASE.realms) do
    for faction, market in pairs(realm.markets) do
      local played = market.meta.lastPlayed or market.meta.lastScan or 0
      if faction ~= "Unknown" and (not best or played > best.played) then
        best = { realm = realmName, faction = faction, region = realm.region or 1, market = market, played = played }
      end
    end
  end
  assert(best, "the saved database has no faction market")
  return best.realm, best.faction, best.region, best.market
end

-- When the benchmark's session happens: half an hour after the newest scan or login it knows of,
-- so the full-scan cooldown has passed.
---@param market table
---@param realm string
---@param faction string
---@return number
function Data.SessionTime(market, realm, faction)
  local newest =
    math.max(market.meta.lastPlayed or 0, market.meta.lastScan or 0, ARBITRAGE_DATABASE.meta.lastReplicateScan or 0)
  local import = ARBITRAGE_IMPORT and ARBITRAGE_IMPORT.realms and ARBITRAGE_IMPORT.realms[realm]
  local synced = import and import.markets and import.markets[faction]
  if synced and synced.meta and synced.meta.lastScan then
    newest = math.max(newest, synced.meta.lastScan)
  end
  return newest + 1800
end

-- Every item ID the market's own and synced prices name, and the ones that come in random
-- enchants, which the client treats as gear.
---@param market table
---@param realm string
---@param faction string
---@return number[] items, table<number, true> gear
function Data.Items(market, realm, faction)
  local seen, gear = {}, {}
  local function Add(keys)
    for key in pairs(keys or {}) do
      local itemID, variant = ParseKey(key)
      if itemID then
        seen[itemID] = true
        if variant then
          gear[itemID] = true
        end
      end
    end
  end
  Add(market.items)
  local import = ARBITRAGE_IMPORT and ARBITRAGE_IMPORT.realms and ARBITRAGE_IMPORT.realms[realm]
  local synced = import and import.markets and import.markets[faction]
  Add(synced and synced.items)
  return SortedKeys(seen), gear
end

-- The auctions behind the market's latest Buyouts: one or two per random enchant, a few of other
-- gear, and of each stackable item from one to a couple of hundred, most having few, plus a grey
-- listing of each known grey item. Sized like a busy Auction House: a real one's 25,800 priced
-- keys came from 196,806 auctions. Kept as one number per auction and made up when asked for, so
-- they take little of the heap the benchmark measures.
---@param market table
---@param greyItems table<number, true>
---@return { count: number, Get: fun(index: number): number, number?, number, number }
function Data.Auctions(market, greyItems)
  local keys = SortedKeys(market.latestBuyouts)
  local gearWithVariants = {}
  for _, key in ipairs(keys) do
    local itemID, variant = ParseKey(key)
    if variant then
      gearWithVariants[itemID] = true
    end
  end

  local itemIDs, variants, prices, stackable = {}, {}, {}, {}
  local auctions = {}
  local function AddItem(itemID, variant, price, stacks, count)
    local index = #itemIDs + 1
    itemIDs[index], variants[index], prices[index], stackable[index] = itemID, variant or false, price, stacks
    for listing = 0, count - 1 do
      auctions[#auctions + 1] = index * LISTINGS_PER_ITEM + listing
    end
  end

  for index, key in ipairs(keys) do
    local itemID, variant = ParseKey(key)
    local price = market.latestBuyouts[key]
    if itemID and type(price) == "number" and price > 0 then
      local roll = Hash(index * 5 + 1)
      if variant then
        AddItem(itemID, variant, price, false, 1 + math.floor(roll * 2))
      elseif not gearWithVariants[itemID] then
        -- Gear sells one at a time; anything else stacks and has more sellers.
        local stacks = Hash(itemID * 7 + 1) >= 0.12
        AddItem(
          itemID,
          nil,
          price,
          stacks,
          stacks and 1 + math.floor(roll ^ 4 * MOST_STACK_LISTINGS) or 1 + math.floor(roll * 3)
        )
      end
    end
  end
  for _, itemID in ipairs(SortedKeys(greyItems)) do
    AddItem(itemID, nil, 50, true, 1)
  end

  return {
    count = #auctions,
    Get = function(index)
      local packed = auctions[index + 1]
      local item = math.floor(packed / LISTINGS_PER_ITEM)
      local listing = packed % LISTINGS_PER_ITEM
      local quantity = stackable[item] and 1 + math.floor(Hash(index * 7 + 3) * 20) or 1
      -- The first listing is the item's Buyout; the rest cost up to 60% more.
      local unitPrice = prices[item] * (listing == 0 and 1 or 1 + 0.6 * Hash(index * 13 + 1))
      return itemIDs[item], variants[item] or nil, quantity, math.floor(unitPrice * quantity) + 1
    end,
  }
end

-- What a Quick Scan's browse query returns: each listed item's cheapest unit price, greys left
-- out as Arbitrage's query asks.
---@param auctions { count: number, Get: fun(index: number): number, number?, number, number }
---@param greyItems table<number, true>
---@return table[]
function Data.BrowseResults(auctions, greyItems)
  local minPrices, quantities = {}, {}
  for index = 0, auctions.count - 1 do
    local itemID, _, quantity, buyout = auctions.Get(index)
    if not greyItems[itemID] then
      local unitPrice = math.ceil(buyout / quantity)
      minPrices[itemID] = math.min(minPrices[itemID] or unitPrice, unitPrice)
      quantities[itemID] = (quantities[itemID] or 0) + quantity
    end
  end
  local results = {}
  for _, itemID in ipairs(SortedKeys(minPrices)) do
    results[#results + 1] = {
      itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
      totalQuantity = quantities[itemID],
      minPrice = minPrices[itemID],
    }
  end
  return results
end

-- Synthetic data ---------------------------------------------------------------------------------

-- Roughly one player's saved data: 7,000 items, 1,600 of them gear in about 24 random enchants
-- each, scanned 15 times over a week, with a month of synced prices and 150 recipes across two
-- characters.
---@return string realm, string faction
function Data.Synthesize()
  local realmName, faction = "PvP", "Horde"
  local lastScan = SYNTHETIC_NOW - 3600
  local today = math.floor(SYNTHETIC_NOW / DAY)

  -- Items and their keys.
  local plain, gear = {}, {}
  for index = 1, 7072 do
    local itemID = 1000 + index * 19
    if index % 9 < 2 then
      gear[#gear + 1] = itemID
    else
      plain[#plain + 1] = itemID
    end
  end
  local keys, basePrices = {}, {}
  for _, itemID in ipairs(plain) do
    local key = tostring(itemID)
    keys[#keys + 1] = key
    basePrices[key] = math.floor(10 ^ (1.3 + Hash(itemID * 11) * 5.2))
  end
  for _, itemID in ipairs(gear) do
    local key = tostring(itemID)
    keys[#keys + 1] = key
    local price = math.floor(10 ^ (3 + Hash(itemID * 11) * 4))
    basePrices[key] = price
    for number = 1, 1 + math.floor(Hash(itemID * 3 + 1) ^ 1.2 * 50) do
      local variant = Hash(itemID + number) < 0.5 and -(3 + number) or 12700 + number
      local variantKey = "equip:" .. itemID .. ":" .. variant
      keys[#keys + 1] = variantKey
      basePrices[variantKey] = math.floor(price * (0.8 + 0.6 * Hash(itemID * 5 + number)))
    end
  end

  -- The account's 15 full scans; the first four predate random enchants.
  local scanTimes = {}
  for scan = 1, 15 do
    scanTimes[scan] = lastScan - (15 - scan) * 11 * 3600
  end
  local items, latestBuyouts = {}, {}
  for index, key in ipairs(keys) do
    local isVariant = key:find("^equip:") ~= nil
    local scans = {}
    for scan, at in ipairs(scanTimes) do
      local listed = isVariant and scan > 4 and Hash(index * 31 + scan) < 0.5
        or not isVariant and Hash(index * 31 + scan) < 0.85
      if listed then
        scans[at] = math.floor(basePrices[key] * (0.85 + 0.3 * Hash(index * 17 + scan)))
      end
    end
    if next(scans) then
      items[key] = { scans = scans }
      if scans[lastScan] then
        latestBuyouts[key] = math.floor(scans[lastScan] * 0.92)
      end
    end
  end

  local vendorPrices = {}
  for index = 1, #plain, 31 do
    vendorPrices[tostring(plain[index])] = 5 + plain[index] % 400
  end

  ARBITRAGE_DATABASE = {
    __version = 2,
    meta = { lastReplicateScan = lastScan },
    realms = {
      [realmName] = {
        region = 1,
        markets = {
          [faction] = {
            meta = { lastScan = lastScan, lastPlayed = lastScan + 60 },
            items = items,
            latestBuyouts = latestBuyouts,
          },
        },
        vendorPrices = { [faction] = vendorPrices },
      },
    },
  }

  -- Synced prices: the account's scans and hourly TradeSkillMaster snapshots, as day totals, and
  -- a few thousand items only TradeSkillMaster lists.
  local syncedScans = {}
  for _, at in ipairs(scanTimes) do
    syncedScans[#syncedScans + 1] = at
  end
  for hour = 1, 68 do
    syncedScans[#syncedScans + 1] = lastScan - hour * 3 * 3600 - 1800
  end
  table.sort(syncedScans)
  for index = 1, 4202 do
    local key = tostring(300000 + index * 7)
    keys[#keys + 1] = key
    basePrices[key] = math.floor(10 ^ (1.3 + Hash(index * 23) * 5))
  end
  local syncedItems, itemBuyouts, variantBuyouts, legacyBuyouts = {}, {}, {}, {}
  for index, key in ipairs(keys) do
    local days = {}
    local dayCount = 1 + math.floor(Hash(index * 43) ^ 0.8 * 9)
    for offset = 0, dayCount - 1 do
      local count = 1 + math.floor(Hash(index * 47 + offset) * 8)
      local value = math.floor(basePrices[key] * (0.85 + 0.3 * Hash(index * 53 + offset)))
      days[today - offset] = value * count * 1024 + count
    end
    syncedItems[key] = { latest = lastScan - math.floor(Hash(index * 59) * 3) * DAY, days = days }
    local buyout = latestBuyouts[key]
    if buyout then
      legacyBuyouts[key] = buyout
      if key:find("^equip:") then
        variantBuyouts[key] = buyout
      else
        itemBuyouts[key] = buyout
      end
    end
  end

  ARBITRAGE_IMPORT = {
    __version = 3,
    meta = {},
    realms = {
      [realmName] = {
        region = 1,
        markets = {
          [faction] = {
            meta = { lastScan = lastScan },
            scans = syncedScans,
            items = syncedItems,
            latestBuyouts = legacyBuyouts,
            buyouts = {
              items = { at = lastScan, prices = itemBuyouts },
              variants = { at = lastScan, prices = variantBuyouts },
            },
          },
        },
        vendorPrices = { [faction] = vendorPrices },
      },
    },
  }

  -- Recipes: each makes an item from up to four cheaper ones, some of them crafted too.
  local function Recipe(number)
    local outputItemID = plain[1 + (number * 37) % #plain]
    local reagents, parts = {}, { "recipe", tostring(2000 + number), tostring(outputItemID) }
    for slot = 1, 1 + math.floor(Hash(number * 61) * 4) do
      local source = Hash(number * 67 + slot) < 0.2 and 1 + ((number + slot) * 37) % #plain
        or 1 + (number * 101 + slot * 13) % #plain
      local reagent = { itemID = plain[source], quantity = 1 + math.floor(Hash(number * 71 + slot) * 5) }
      if reagent.itemID ~= outputItemID then
        reagents[#reagents + 1] = reagent
      end
    end
    table.sort(reagents, function(left, right)
      return left.itemID < right.itemID
    end)
    for _, reagent in ipairs(reagents) do
      parts[#parts + 1] = reagent.itemID .. "x" .. reagent.quantity
    end
    local recipe = {
      recipeKey = table.concat(parts, ":"),
      outputItemID = outputItemID,
      outputQuantity = Hash(number * 73) < 0.2 and 4 or 1,
      reagents = reagents,
    }
    if Hash(number * 79) < 0.3 then
      recipe.skillUp = { points = 1, difficulty = "medium" }
    end
    return recipe
  end

  local function Profession(first, last)
    local recipes = {}
    for number = first, last do
      local recipe = Recipe(number)
      recipes[recipe.recipeKey] = recipe
    end
    return { recipes = recipes, unlearned = {}, updatedAt = lastScan - DAY, unsupportedCount = 0 }
  end

  ARBITRAGE_RECIPES = {
    __version = 1,
    [realmName] = {
      characters = {
        Main = {
          professions = {
            Alchemy = Profession(1, 40),
            Blacksmithing = Profession(41, 90),
            Cooking = Profession(91, 110),
          },
        },
        Alt = { professions = { Tailoring = Profession(111, 150), Cooking = Profession(91, 105) } },
      },
    },
  }

  local greyItems = {}
  for index = 1, 617 do
    greyItems[500000 + index * 3] = true
  end
  ARBITRAGE_GREY_ITEMS = greyItems
  ARBITRAGE_QUICK_BUYOUTS = { ["1:" .. realmName .. ":" .. faction] = { at = lastScan - 7200 } }
  ARBITRAGE_CONFIG = {}
  return realmName, faction
end

return Data

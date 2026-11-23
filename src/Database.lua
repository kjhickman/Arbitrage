local _, ns = ...

ns.Database = {}

-- A scan's values as parallel lists: the items it saw, then each value it recorded for them, 0
-- for none. A value it didn't record at all, such as a quick scan's market value, is left out.
---@class ArbitrageScanColumns
---@field keys string[]
---@field marketValues number[]?
---@field buyouts number[]?
---@field quantities number[]? units listed
---@field auctions number[]? auctions listed

-- A saved scan: its kind, and its columns as text, in pieces of up to ITEMS_PER_PIECE items. A
-- piece's first line lists its keys, and each line after names a value and lists it for each key:
-- "2589,4306\nmarketValues=1234,70\nbuyouts=1200,65".
---@class ArbitrageSavedScan
---@field kind "full"|"quick"
---@field [integer] string

---@class ArbitrageDatabaseMeta
---@field lastScan number?
---@field lastPlayed number?

---@class ArbitrageMarketDatabase
---@field meta ArbitrageDatabaseMeta
---@field scans table<number, ArbitrageSavedScan>

-- An item's history: when a scan last saw it, then each day it was seen, oldest first, as the day
-- number, floor(timestamp / DAY), followed by that day's values, each its scans' total and count
-- packed into one number (see Pack), or 0 when no scan that day recorded it. Older days stay in
-- the list until it is rebuilt, so readers check the window.
---@alias ArbitrageItemHistory number[]

-- An item's averages across one UTC day's scans, each nil when no scan that day recorded it.
---@class ArbitrageDailyValue
---@field day number day number, floor(timestamp / DAY)
---@field value number? Market Value, copper
---@field count number? scans with a Market Value
---@field buyout number? lowest Buyout, copper
---@field buyoutCount number? scans with a Buyout
---@field quantity number? units listed

-- One scan's Buyouts for the kind of item it saw, and when it ran. An item of that kind missing
-- from the list wasn't listed.
---@class ArbitrageBuyoutList
---@field at number
---@field prices table<string, number>

-- Where Buyouts can come from. A full scan sees every item, by item ID and by random-enchant
-- variant. The synced item list, from the newest scan the Companion has, sees item IDs except
-- random-enchant gear, which TradeSkillMaster leaves out; the synced variant list, from the newest
-- full scan, has that gear by variant and, when it's the older list, by item ID.
---@class ArbitrageBuyoutSources
---@field own ArbitrageBuyoutList? the account's latest full scan
---@field items ArbitrageBuyoutList? synced, by item ID
---@field variants ArbitrageBuyoutList? synced, random-enchant gear
---@field quick ArbitrageBuyoutList? the account's latest quick scan, while newer than its full scan

---@class ArbitrageViewMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field buyouts ArbitrageBuyoutSources
---@field scans table<number, true> every full scan and TradeSkillMaster snapshot of the last thirty days
---@field latestQuickScan number?

-- A market of the Companion's import: its items' histories, and the scans they hold.
---@class ArbitrageImportMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field buyouts { items: any, variants: any }?
---@field scans number[] full scans and TradeSkillMaster snapshots
---@field quickScans number[]

---@class ArbitrageRealmDatabase
---@field region number?
---@field markets table<string, ArbitrageMarketDatabase>
---@field vendorPrices table<string, table<string, number>>

---@class ArbitrageDatabaseRootMeta
---@field lastReplicateScan number?

---@class ArbitrageDatabaseRoot
---@field __version number
---@field meta ArbitrageDatabaseRootMeta
---@field realms table<string, ArbitrageRealmDatabase>

---@class ArbitrageDatabaseStatus
---@field itemCount number
---@field latestScan number?
---@field latestQuickScan number?
---@field recentScanCount number

local VERSION = 3
-- Before version 3, each item kept its market values by scan time, and the latest full scan's
-- Buyouts were kept apart.
local ITEM_VERSION = 2
-- The Companion's import moved to version 4 when each item's history became one list.
local IMPORT_VERSION = 4
local DAY = 24 * 60 * 60
local HOUR = 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30
-- Quick scans are kept for the market value window, the newest of each hour, and at most this many.
local MOST_QUICK_SCANS = 48
-- A day's scans add up as total * SCANS_PER_DAY + count, so one addition records a scan. Exact while
-- a day holds under 1024 scans of an item and its prices sum below 2^43 copper (880 million gold).
local SCANS_PER_DAY = 1024
-- A saved scan is written a piece at a time, so a full scan's save pauses between pieces.
local ITEMS_PER_PIECE = 20000
-- The values a scan can record, in the order an item's history lists them after each day.
local COLUMNS = { "marketValues", "buyouts", "quantities", "auctions" }
local IS_COLUMN = {}
for _, name in ipairs(COLUMNS) do
  IS_COLUMN[name] = true
end
local BUYOUTS_ONLY = { buyouts = true }
-- Where an item's history keeps things: its last scan, its first day, how far apart days are, and
-- each value's place after its day.
ns.Database.History = {
  latest = 1,
  firstDay = 2,
  stride = 5,
  marketValue = 1,
  buyout = 2,
  quantity = 3,
  auctions = 4,
}
local STRIDE = ns.Database.History.stride
local function Noop() end

-- The own* tables are the account's saved scans, the only data the companion uploads. The view,
-- db, merges the player's faction market with the synced import and is what every read sees; it
-- is never saved.
---@type ArbitrageDatabaseRoot!
local ownRoot
---@type ArbitrageRealmDatabase!
local ownRealm
---@type ArbitrageMarketDatabase!
local ownMarket
---@type table<string, number>!
local ownVendorPrices
---@type ArbitrageViewMarket!
local db
---@type table<string, number>!
local vendorPrices
-- Region-wide sales by item ID as the import holds them: average sale price, sale rate, and units
-- sold a day, which isn't shown.
---@type table<number, number[]>
local sales = {}
-- Each kind of item takes its Buyouts from the newest source that sees it; see ChooseBuyoutSources.
---@type ArbitrageBuyoutList?
local itemSource
---@type ArbitrageBuyoutList?
local randomEnchantItemSource
---@type ArbitrageBuyoutList?
local variantSource
-- Grey items by ID, kept across sessions since an item's quality never changes, so their old and
-- synced prices are dropped before the client loads them. Kept outside ARBITRAGE_DATABASE, which
-- the Companion reads strictly; it reads this list to leave greys out of the import.
---@type table<number, true>
local greyItems = {}

---@param root any
---@param version number
---@return boolean
local function IsValidRoot(root, version)
  return type(root) == "table"
    and root.__version == version
    and type(root.meta) == "table"
    and type(root.realms) == "table"
end

---@param value any
---@return table
local function AsTable(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

-- Drops anything but a price from a synced Buyout list. The list is used where it is rather than
-- copied, since each holds tens of thousands of prices.
---@param buyouts any
---@return table<string, number>
local function CleanBuyouts(buyouts)
  local prices = AsTable(buyouts)
  for key, value in pairs(prices) do
    if type(value) ~= "number" then
      prices[key] = nil
    end
  end
  return prices
end

---@param timestamp number
---@return number
local function ScanDay(timestamp)
  return math.floor(timestamp / DAY)
end

-- Every value a scan records is a whole number of copper or units.
---@param value number
---@return number
local function Pack(value)
  if value > 0 then
    return value * SCANS_PER_DAY + 1
  end
  return 0
end

-- A day's summed value and its number of scans.
---@param packed number
---@return number total, number count
function ns.Database.UnpackDay(packed)
  local count = packed % SCANS_PER_DAY
  return (packed - count) / SCANS_PER_DAY, count
end

---@param key string
---@return number?
local function ItemIDOf(key)
  return tonumber(key) or tonumber(key:match("^equip:(%d+):"))
end

---@param key string
---@return boolean
local function IsGreyKey(key)
  local itemID = ItemIDOf(key)
  return itemID ~= nil and greyItems[itemID] == true
end

-- Adds a scan's values for an item to a day other than its newest, or makes the item. A new day goes
-- in order, and the list is rebuilt to fit it exactly, as a list grows to the next power of two
-- otherwise.
---@param items table<string, ArbitrageItemHistory>
---@param dbKey string
---@param history ArbitrageItemHistory?
---@param at number
---@param day number
---@param firstDay number days before it only move when the item was last seen
---@param marketValue number
---@param buyout number
---@param quantity number
---@param auctions number
local function AddToDay(items, dbKey, history, at, day, firstDay, marketValue, buyout, quantity, auctions)
  if not history then
    if day >= firstDay then
      items[dbKey] = { at, day, Pack(marketValue), Pack(buyout), Pack(quantity), Pack(auctions) }
    else
      items[dbKey] = { at }
    end
    return
  end
  if at > history[1] then
    history[1] = at
  end
  if day < firstDay then
    return
  end

  local count = #history
  local index = count - STRIDE + 1
  while index >= 2 and history[index] > day do
    index = index - STRIDE
  end
  if index >= 2 and history[index] == day then
    if marketValue > 0 then
      history[index + 1] = history[index + 1] + Pack(marketValue)
    end
    if buyout > 0 then
      history[index + 2] = history[index + 2] + Pack(buyout)
    end
    if quantity > 0 then
      history[index + 3] = history[index + 3] + Pack(quantity)
    end
    if auctions > 0 then
      history[index + 4] = history[index + 4] + Pack(auctions)
    end
    return
  end

  -- unpack's missing values past the end still count, so the new list has room for the day.
  local insertAt = math.max(index, 2 - STRIDE) + STRIDE
  history = { unpack(history, 1, count + STRIDE) }
  items[dbKey] = history
  for position = count, insertAt, -1 do
    history[position + STRIDE] = history[position]
  end
  history[insertAt] = day
  history[insertAt + 1] = Pack(marketValue)
  history[insertAt + 2] = Pack(buyout)
  history[insertAt + 3] = Pack(quantity)
  history[insertAt + 4] = Pack(auctions)
end

-- Adds every item of a scan's columns to the history. A login without the Companion adds every
-- saved scan, so the usual case, adding to an item's newest day, is written out here.
---@param items table<string, ArbitrageItemHistory>
---@param columns ArbitrageScanColumns
---@param at number
---@param firstDay number
local function AddColumns(items, columns, at, firstDay)
  local day = ScanDay(at)
  local inWindow = day >= firstDay
  local keys = columns.keys
  local marketValues, buyouts = columns.marketValues, columns.buyouts
  local quantities, auctions = columns.quantities, columns.auctions
  for index = 1, #keys do
    local marketValue = marketValues and marketValues[index] or 0
    local buyout = buyouts and buyouts[index] or 0
    local quantity = quantities and quantities[index] or 0
    local auctionCount = auctions and auctions[index] or 0
    if marketValue > 0 or buyout > 0 or quantity > 0 or auctionCount > 0 then
      local key = keys[index]
      local history = items[key]
      local count = history and #history or 0
      if inWindow and count > 1 and history[count - 4] == day then
        if at > history[1] then
          history[1] = at
        end
        if marketValue > 0 then
          history[count - 3] = history[count - 3] + marketValue * SCANS_PER_DAY + 1
        end
        if buyout > 0 then
          history[count - 2] = history[count - 2] + buyout * SCANS_PER_DAY + 1
        end
        if quantity > 0 then
          history[count - 1] = history[count - 1] + quantity * SCANS_PER_DAY + 1
        end
        if auctionCount > 0 then
          history[count] = history[count] + auctionCount * SCANS_PER_DAY + 1
        end
      else
        AddToDay(items, key, history, at, day, firstDay, marketValue, buyout, quantity, auctionCount)
      end
    end
  end
end

-- Adds the Buyouts a scan's columns hold to prices, by key.
---@param prices table<string, number>
---@param columns ArbitrageScanColumns
---@param checkpoint fun()?
---@return table<string, number> prices
local function AddBuyouts(prices, columns, checkpoint)
  local keys, buyouts = columns.keys, columns.buyouts
  if buyouts then
    for index = 1, #keys do
      local price = buyouts[index]
      if price > 0 then
        prices[keys[index]] = price
      end
      if checkpoint then
        checkpoint()
      end
    end
  end
  return prices
end

-- Writes columns as text, from the first item to the last.
---@param columns ArbitrageScanColumns
---@param first number
---@param last number
---@return string
local function PieceOf(columns, first, last)
  local lines = { table.concat(columns.keys, ",", first, last) }
  for _, name in ipairs(COLUMNS) do
    local values = columns[name]
    if values then
      lines[#lines + 1] = name .. "=" .. table.concat(values, ",", first, last)
    end
  end
  return table.concat(lines, "\n")
end

-- Saves a scan's columns as text, which the game loads as a few strings rather than a table per
-- item, a few hundred kilobytes for a full scan.
---@param kind "full"|"quick"
---@param columns ArbitrageScanColumns
---@param checkpoint fun()?
---@return ArbitrageSavedScan
local function WriteScan(kind, columns, checkpoint)
  local saved = { kind = kind }
  local count = #columns.keys
  for first = 1, count, ITEMS_PER_PIECE do
    saved[#saved + 1] = PieceOf(columns, first, math.min(first + ITEMS_PER_PIECE - 1, count))
    if checkpoint then
      checkpoint()
    end
  end
  return saved
end

local find, sub, gmatch = string.find, string.sub, string.gmatch

-- Reads one piece of a saved scan back: its keys, and the values `wanted` names, or all of them. A
-- piece whose values don't line up with its keys is skipped, and a value this version doesn't know
-- is left out. Values are whole numbers, so anything else breaks the count.
---@param text string
---@param wanted table<string, true>?
---@return ArbitrageScanColumns?
local function ReadPiece(text, wanted)
  local length = #text
  local lineEnd = find(text, "\n", 1, true) or length + 1
  local keys, count = {}, 0
  for key in gmatch(sub(text, 1, lineEnd - 1), "[^,]+") do
    count = count + 1
    keys[count] = key
  end
  local columns = { keys = keys }
  local start = lineEnd + 1
  while start <= length do
    lineEnd = find(text, "\n", start, true) or length + 1
    local equals = find(text, "=", start, true)
    if not equals or equals > lineEnd then
      return nil
    end
    local name = sub(text, start, equals - 1)
    if IS_COLUMN[name] and (wanted == nil or wanted[name]) then
      local values, index = {}, 0
      -- Arithmetic converts a matched number faster than tonumber.
      for value in gmatch(sub(text, equals + 1, lineEnd - 1), "%d+") do
        index = index + 1
        values[index] = value + 0
      end
      if index ~= count then
        return nil
      end
      columns[name] = values
    end
    start = lineEnd + 1
  end
  return columns
end

-- Reads a saved scan's columns back a piece at a time.
---@param saved ArbitrageSavedScan
---@param wanted table<string, true>?
---@param each fun(columns: ArbitrageScanColumns)
local function ReadScan(saved, wanted, each)
  for index = 1, #saved do
    local piece = saved[index]
    local columns = type(piece) == "string" and ReadPiece(piece, wanted)
    if columns then
      each(columns)
    end
  end
end

---@param saved any
---@return boolean
local function IsSavedScan(saved)
  return type(saved) == "table" and (saved.kind == "full" or saved.kind == "quick")
end

---@param market ArbitrageMarketDatabase
---@param kind "full"|"quick"
---@return number? at, ArbitrageSavedScan? saved
local function NewestSavedScan(market, kind)
  local newest
  for at, saved in pairs(market.scans) do
    if saved.kind == kind and (newest == nil or at > newest) then
      newest = at
    end
  end
  return newest, newest and market.scans[newest]
end

-- Version 2 to 3 ----------------------------------------------------------------------------------

-- Turns a version 2 market's item-by-item market values into a saved scan per time, its latest
-- Buyouts on its last scan, leaving out grey items.
---@param market any
---@return ArbitrageMarketDatabase
local function MigrateMarket(market)
  market = AsTable(market)
  local meta = AsTable(market.meta)
  ---@type table<number, ArbitrageScanColumns>
  local byTime = {}
  local function ColumnsAt(at)
    local columns = byTime[at]
    if not columns then
      columns = { keys = {}, marketValues = {} }
      byTime[at] = columns
    end
    return columns
  end

  for dbKey, item in pairs(AsTable(market.items)) do
    if type(dbKey) == "string" and not IsGreyKey(dbKey) then
      for scanKey, copper in pairs(AsTable(AsTable(item).scans)) do
        local at = tonumber(scanKey)
        if at and type(copper) == "number" then
          local columns = ColumnsAt(at)
          local index = #columns.keys + 1
          columns.keys[index], columns.marketValues[index] = dbKey, copper
        end
      end
    end
  end

  local lastScan = meta.lastScan
  if type(lastScan) == "number" and next(AsTable(market.latestBuyouts)) then
    local columns = ColumnsAt(lastScan)
    local indexOf, buyouts = {}, {}
    for index, key in ipairs(columns.keys) do
      indexOf[key], buyouts[index] = index, 0
    end
    for key, price in pairs(market.latestBuyouts) do
      if type(key) == "string" and type(price) == "number" and not IsGreyKey(key) then
        local index = indexOf[key]
        if not index then
          index = #columns.keys + 1
          columns.keys[index], columns.marketValues[index] = key, 0
        end
        buyouts[index] = price
      end
    end
    columns.buyouts = buyouts
  end

  local scans = {}
  for at, columns in pairs(byTime) do
    scans[at] = WriteScan("full", columns)
  end
  return { meta = { lastPlayed = type(meta.lastPlayed) == "number" and meta.lastPlayed or nil }, scans = scans }
end

---@param root table a valid version 2 root
local function Migrate(root)
  for _, realm in pairs(root.realms) do
    if type(realm) == "table" then
      local markets = {}
      for faction, market in pairs(AsTable(realm.markets)) do
        markets[faction] = MigrateMarket(market)
      end
      realm.markets = markets
      for _, prices in pairs(AsTable(realm.vendorPrices)) do
        if type(prices) == "table" then
          for itemID in pairs(prices) do
            if greyItems[tonumber(itemID)] then
              prices[itemID] = nil
            end
          end
        end
      end
    end
  end
  root.__version = VERSION
end

-- The view -----------------------------------------------------------------------------------------

---@param at any
---@param prices table<string, number>
---@return ArbitrageBuyoutList?
local function BuyoutList(at, prices)
  if type(at) == "number" then
    return { at = at, prices = prices }
  end
  return nil
end

-- The import's synced Buyout lists.
---@param market ArbitrageImportMarket
---@return ArbitrageBuyoutList? items, ArbitrageBuyoutList? variants
local function ReadSyncedBuyouts(market)
  local buyouts = AsTable(market.buyouts)
  local items, variants = AsTable(buyouts.items), AsTable(buyouts.variants)
  return BuyoutList(items.at, CleanBuyouts(items.prices)), BuyoutList(variants.at, CleanBuyouts(variants.prices))
end

---@param times any
---@return table<number, true> set, number? newest
local function TimeSet(times)
  local set, newest = {}, nil
  for _, at in ipairs(AsTable(times)) do
    if type(at) == "number" then
      set[at] = true
      newest = math.max(newest or at, at)
    end
  end
  return set, newest
end

-- Joins the account's saved scans to the import's histories. The import already holds the scans
-- the Companion synced, so only the account's scans it does not list are added.
---@param saved ArbitrageMarketDatabase
---@param imported ArbitrageImportMarket
---@return ArbitrageViewMarket
local function MergeMarket(saved, imported)
  local importedScans = TimeSet(imported.scans)
  local importedQuickScans, latestQuickScan = TimeSet(imported.quickScans)
  local syncedItems, syncedVariants = ReadSyncedBuyouts(imported)

  local lastScan = AsTable(imported.meta).lastScan
  lastScan = type(lastScan) == "number" and lastScan or nil
  local ownTimes = {}
  for at, scan in pairs(saved.scans) do
    if type(at) == "number" and IsSavedScan(scan) then
      ownTimes[#ownTimes + 1] = at
      if scan.kind == "full" and (lastScan == nil or at > lastScan) then
        lastScan = at
      end
    end
  end
  table.sort(ownTimes)

  -- Scans count toward Last Seen for thirty days before the last scan, and toward the history's
  -- days only within the market value window.
  local cutoff = lastScan and lastScan - PRUNE_DAYS * DAY or -math.huge
  local firstDay = ScanDay(time() - WINDOW_DAYS * DAY)
  local scans = {}
  for at in pairs(importedScans) do
    if at >= cutoff then
      scans[at] = true
    end
  end

  -- The view takes over the import's lists, which are not read again.
  local items = AsTable(imported.items)
  for dbKey, history in pairs(items) do
    if type(history) ~= "table" or type(history[1]) ~= "number" or history[1] < cutoff then
      items[dbKey] = nil
    end
  end

  ns.Profile.Stage("Login", "Own scans")
  local newestFull, newestQuick = NewestSavedScan(saved, "full"), NewestSavedScan(saved, "quick")
  local own, quick
  for _, at in ipairs(ownTimes) do
    local scan = saved.scans[at]
    local isFull = scan.kind == "full"
    if isFull and at >= cutoff then
      scans[at] = true
    elseif not isFull then
      latestQuickScan = math.max(latestQuickScan or at, at)
    end
    local isImported
    if isFull then
      isImported = importedScans[at] == true
    else
      isImported = importedQuickScans[at] == true
    end
    local isNewest = at == (isFull and newestFull or newestQuick)
    local adds = at >= cutoff and not isImported
    if adds or isNewest then
      local prices = isNewest and {}
      -- Every read hides grey items, so the view doesn't check each key for them.
      ReadScan(scan, not adds and BUYOUTS_ONLY or nil, function(columns)
        if adds then
          AddColumns(items, columns, at, firstDay)
        end
        if prices then
          AddBuyouts(prices, columns)
        end
      end)
      if isNewest and isFull then
        own = { at = at, prices = prices }
      elseif isNewest then
        quick = { at = at, prices = prices }
      end
    end
  end
  return {
    meta = { lastScan = lastScan },
    items = items,
    buyouts = {
      own = own,
      items = syncedItems,
      variants = syncedVariants,
      quick = quick and (own == nil or quick.at > own.at) and quick or nil,
    },
    scans = scans,
    latestQuickScan = latestQuickScan,
  }
end

---@param left any
---@param right any
---@return table<string, table<string, number>>
local function MergeVendorPrices(left, right)
  local factions = {}

  local function ingest(source)
    for faction, prices in pairs(AsTable(source)) do
      if type(prices) == "table" then
        local dest = factions[faction]
        if not dest then
          dest = {}
          factions[faction] = dest
        end
        for itemId, copper in pairs(prices) do
          if type(copper) == "number" and copper > 0 then
            copper = math.ceil(copper)
            local existing = dest[itemId]
            if existing == nil or copper < existing then
              dest[itemId] = copper
            end
          end
        end
      end
    end
  end

  ingest(left)
  ingest(right)

  for faction, prices in pairs(factions) do
    if next(prices) == nil then
      factions[faction] = nil
    end
  end

  return factions
end

-- The import's market for one faction, its realm's vendor prices, and the region's sales.
-- Imports from older Companions are ignored until the Companion updates.
---@param realmName string
---@param faction string
---@param region number
---@return ArbitrageImportMarket? market, table? vendorPrices, table? sales
local function ReadImport(realmName, faction, region)
  local import = ARBITRAGE_IMPORT
  if not IsValidRoot(import, IMPORT_VERSION) then
    return nil, nil, nil
  end
  local realm = AsTable(import.realms[realmName])
  local market = AsTable(realm.markets)[faction]
  local regionSales = AsTable(AsTable(import.regions)[region]).items
  return type(market) == "table" and market or nil, realm.vendorPrices, regionSales
end

---@param root ArbitrageDatabaseRoot
---@param name string
---@return ArbitrageRealmDatabase
local function EnsureRealm(root, name)
  local realm = rawget(root.realms, name)
  if type(realm) ~= "table" or type(realm.markets) ~= "table" or type(realm.vendorPrices) ~= "table" then
    realm = { markets = {}, vendorPrices = {} }
    root.realms[name] = realm
  end
  ---@cast realm ArbitrageRealmDatabase
  return realm
end

---@param realm ArbitrageRealmDatabase
---@param name string
---@return ArbitrageMarketDatabase
local function EnsureMarket(realm, name)
  local market = realm.markets[name]
  if type(market) ~= "table" or type(market.meta) ~= "table" or type(market.scans) ~= "table" then
    market = { meta = {}, scans = {} }
    realm.markets[name] = market
  end
  ---@cast market ArbitrageMarketDatabase
  return market
end

---@param realm ArbitrageRealmDatabase
---@param faction string
---@return table<string, number>
local function EnsureVendorPrices(realm, faction)
  if type(realm.vendorPrices[faction]) ~= "table" then
    realm.vendorPrices[faction] = {}
  end
  return realm.vendorPrices[faction]
end

---@param ... ArbitrageBuyoutList?
---@return ArbitrageBuyoutList?
local function Newest(...)
  local newest
  for index = 1, select("#", ...) do
    local list = select(index, ...)
    -- Earlier sources win ties: the account's own scan and its synced copy are the same scan.
    if list and (newest == nil or list.at > newest.at) then
      newest = list
    end
  end
  return newest
end

-- Picks, for each kind of item, the newest source that sees it. Quick scans see item IDs, and
-- synced lists see only their own kind, so random-enchant gear keeps a full scan's prices when
-- TradeSkillMaster, which leaves that gear out, is newer.
local function ChooseBuyoutSources()
  local sources = db.buyouts
  itemSource = Newest(sources.own, sources.quick, sources.items)
  randomEnchantItemSource = Newest(sources.own, sources.quick, sources.variants)
  variantSource = Newest(sources.own, sources.variants)
end

---@param key string
---@return ArbitrageBuyoutList?
local function BuyoutSourceFor(key)
  if not tonumber(key) then
    return variantSource
  end
  -- The synced variant list holds random-enchant gear's item IDs only when the item list couldn't.
  local variants = db.buyouts.variants
  if variants and variants.prices[key] then
    return randomEnchantItemSource
  end
  return itemSource
end

function ns.Database.Init()
  ARBITRAGE_GREY_ITEMS = AsTable(ARBITRAGE_GREY_ITEMS)
  greyItems = ARBITRAGE_GREY_ITEMS

  if IsValidRoot(ARBITRAGE_DATABASE, ITEM_VERSION) then
    ns.Profile.Stage("Login", "Migrating")
    Migrate(ARBITRAGE_DATABASE)
    ns.Profile.Stage("Login", "Database")
  elseif not IsValidRoot(ARBITRAGE_DATABASE, VERSION) then
    ARBITRAGE_DATABASE = { __version = VERSION, meta = {}, realms = {} }
  end
  ---@cast ARBITRAGE_DATABASE ArbitrageDatabaseRoot
  ownRoot = ARBITRAGE_DATABASE

  local realm = ns.Realm.GetName()
  ownRealm = EnsureRealm(ownRoot, realm)
  ownRealm.region = GetCurrentRegion()
  ownRealm.vendorPrices = MergeVendorPrices(ownRealm.vendorPrices, nil)

  -- Every read and scan uses the player's faction market for the whole session, so only it is
  -- merged with the import; neutral Auction Houses are not supported.
  local faction = UnitFactionGroup("player")
  if faction ~= "Alliance" and faction ~= "Horde" then
    faction = "Unknown"
  end
  ownMarket = EnsureMarket(ownRealm, faction)
  for at, scan in pairs(ownMarket.scans) do
    if type(at) ~= "number" or not IsSavedScan(scan) then
      ownMarket.scans[at] = nil
    end
  end

  local imported, importedVendorPrices, importedSales = ReadImport(realm, faction, ownRealm.region)
  db = MergeMarket(ownMarket, imported or { meta = {}, items = {}, scans = {}, quickScans = {} })
  ns.Profile.Stage("Login", "Database")
  local mergedVendorPrices = MergeVendorPrices(
    { [faction] = ownRealm.vendorPrices[faction] },
    { [faction] = AsTable(importedVendorPrices)[faction] }
  )
  vendorPrices = mergedVendorPrices[faction] or {}
  sales = AsTable(importedSales)
  -- The view keeps what it needs, so the rest of the loaded import can be collected.
  _G.ARBITRAGE_IMPORT = nil

  if faction ~= "Unknown" then
    ownMarket.meta.lastPlayed = time()
  end
  ChooseBuyoutSources()

  ownVendorPrices = EnsureVendorPrices(ownRealm, faction)
end

---@param timestamp number
function ns.Database.RecordReplicateScan(timestamp)
  ownRoot.meta.lastReplicateScan = timestamp
end

---@return number?
function ns.Database.GetLastReplicateScan()
  return ownRoot.meta.lastReplicateScan
end

-- Drops the view's items not seen since the cutoff, pausing between items. They were stale before
-- this scan, so a tooltip reading the view partway through sees no half-applied scan.
---@param cutoff number
---@param checkpoint fun()
local function PruneView(cutoff, checkpoint)
  for dbKey, history in pairs(db.items) do
    if history[1] < cutoff then
      db.items[dbKey] = nil
    end
    checkpoint()
  end
  for at in pairs(db.scans) do
    if at < cutoff then
      db.scans[at] = nil
    end
  end
end

-- The scan is written as text a piece at a time, then the saved scans take it whole in one frame
-- and the view in the next, so nothing reads either half applied: not the Companion, should the
-- game save partway through, nor a tooltip.
---@param columns ArbitrageScanColumns
---@param timestamp number
---@param checkpoint fun()?
---@return number count items with a market value
function ns.Database.SaveScan(columns, timestamp, checkpoint)
  checkpoint = checkpoint or Noop
  local cutoff = timestamp - PRUNE_DAYS * DAY
  for at, scan in pairs(ownMarket.scans) do
    if scan.kind == "full" and at < cutoff then
      ownMarket.scans[at] = nil
    end
  end
  PruneView(cutoff, checkpoint)
  checkpoint()

  ns.Profile.Stage("Full Scan", "Writing the scan")
  local saved = WriteScan("full", columns, checkpoint)
  local prices = AddBuyouts({}, columns, checkpoint)
  ownMarket.scans[timestamp] = saved
  checkpoint()

  ns.Profile.Stage("Full Scan", "Updating prices")
  local firstDay = ScanDay(time() - WINDOW_DAYS * DAY)
  AddColumns(db.items, columns, timestamp, firstDay)
  db.scans[timestamp] = true
  db.meta.lastScan = timestamp
  db.buyouts.own = { at = timestamp, prices = prices }
  -- An older quick scan can't win any more, so its Buyouts go; when it ran is kept.
  if db.buyouts.quick and db.buyouts.quick.at <= timestamp then
    db.buyouts.quick = nil
  end
  ChooseBuyoutSources()

  local count = 0
  local marketValues = columns.marketValues or {}
  for index = 1, #columns.keys do
    if (marketValues[index] or 0) > 0 then
      count = count + 1
    end
  end
  return count
end

-- Keeps the account's quick scans from the market value window before `now`, the newest of each
-- hour, and no more than MOST_QUICK_SCANS of those.
---@param now number
local function PruneQuickScans(now)
  local cutoff = now - WINDOW_DAYS * DAY
  local times, newestByHour = {}, {}
  for at, scan in pairs(ownMarket.scans) do
    if scan.kind == "quick" then
      local hour = math.floor(at / HOUR)
      if at < cutoff then
        ownMarket.scans[at] = nil
      elseif newestByHour[hour] == nil or at > newestByHour[hour] then
        newestByHour[hour] = at
      end
    end
  end
  for at, scan in pairs(ownMarket.scans) do
    if scan.kind == "quick" then
      if newestByHour[math.floor(at / HOUR)] == at then
        times[#times + 1] = at
      else
        ownMarket.scans[at] = nil
      end
    end
  end
  table.sort(times)
  for index = 1, #times - MOST_QUICK_SCANS do
    ownMarket.scans[times[index]] = nil
  end
end

-- A quick scan reads the browse list: each item ID's lowest Buyout and units listed. It is saved,
-- then the view takes it whole, perhaps a frame later.
---@param buyouts table<string, number>
---@param quantities table<string, number>
---@param timestamp number when the last browse page arrived
---@param checkpoint fun()?
---@return boolean saved
function ns.Database.SaveQuickScan(buyouts, quantities, timestamp, checkpoint)
  local ownAt = db.buyouts.own and db.buyouts.own.at or 0
  if timestamp <= ownAt or (db.latestQuickScan and timestamp < db.latestQuickScan) then
    return false
  end

  local columns = { keys = {}, buyouts = {}, quantities = {} }
  for key, price in pairs(buyouts) do
    local index = #columns.keys + 1
    columns.keys[index], columns.buyouts[index], columns.quantities[index] = key, price, quantities[key] or 0
  end
  ownMarket.scans[timestamp] = WriteScan("quick", columns)
  PruneQuickScans(timestamp)
  if checkpoint then
    checkpoint()
  end

  AddColumns(db.items, columns, timestamp, ScanDay(time() - WINDOW_DAYS * DAY))
  db.buyouts.quick = { at = timestamp, prices = buyouts }
  db.latestQuickScan = timestamp
  ChooseBuyoutSources()
  return true
end

-- Whether each item the client has loaded is grey. Quality never changes, and every price
-- lookup checks it, so the client is asked once per item rather than on every lookup.
---@type table<number|string, boolean>
local isIgnoredByItem = {}

-- Scans see every listed item's quality, so they record the grey ones without loading them.
---@param itemID number
function ns.Database.RecordGreyItem(itemID)
  greyItems[itemID] = true
end

-- Historical and synced prices do not carry quality. Check the client without requesting
-- thousands of uncached items at once; the Database tab already loads them in batches.
---@param item number|string item ID or link
---@return boolean
function ns.Database.IsIgnoredItem(item)
  if greyItems[item] then
    return true
  end
  local isIgnored = isIgnoredByItem[item]
  if isIgnored == nil and C_Item.IsItemDataCachedByID(item) then
    local quality = select(3, C_Item.GetItemInfo(item))
    if quality then
      isIgnored = quality == Enum.ItemQuality.Poor
      isIgnoredByItem[item] = isIgnored
      if isIgnored and type(item) == "number" then
        greyItems[item] = true
      end
    end
  end
  return isIgnored == true
end

---@param key string
---@return boolean
local function IsIgnoredKey(key)
  local itemID = ItemIDOf(key)
  return itemID ~= nil and ns.Database.IsIgnoredItem(itemID)
end

---@param dbKey string|number
---@return ArbitrageItemHistory?
function ns.Database.Get(dbKey)
  local key = tostring(dbKey)
  local item = db.items[key]
  if item and not IsIgnoredKey(key) then
    return item
  end
end

---@return string[]
function ns.Database.GetItemKeys()
  local keys = {}
  for dbKey in pairs(db.items) do
    keys[#keys + 1] = dbKey
  end
  return keys
end

---@param dbKey string|number
---@return number?
function ns.Database.GetLatestBuyout(dbKey)
  local key = tostring(dbKey)
  local source = BuyoutSourceFor(key)
  local price = source and source.prices[key]
  if price and not IsIgnoredKey(key) then
    return price
  end
end

-- When a scan last listed the item: its history's newest scan, or the scan behind its Buyout.
---@param dbKey string|number
---@return number?
function ns.Database.GetLastSeen(dbKey)
  local key = tostring(dbKey)
  local history = db.items[key]
  local lastSeen = history and history[1]
  local source = BuyoutSourceFor(key)
  local buyoutAt = source and source.prices[key] and source.at
  if buyoutAt and (lastSeen == nil or buyoutAt > lastSeen) then
    return buyoutAt
  end
  return lastSeen
end

-- A day's average and its number of scans, rounded to whole copper or units, or nil without scans.
---@param packed number
---@return number? average, number? count
local function AverageOf(packed)
  if packed > 0 then
    local total, count = ns.Database.UnpackDay(packed)
    return math.floor(total / count + 0.5), count
  end
end

-- Each day's averages in the window, oldest first. Days age out of the window during a session, so
-- they are checked here as Market Value checks them.
---@param dbKey string|number
---@return ArbitrageDailyValue[]
function ns.Database.GetDailyValues(dbKey)
  local values = {}
  local history = ns.Database.Get(dbKey)
  if history == nil then
    return values
  end

  local firstDay = ScanDay(time() - WINDOW_DAYS * DAY)
  for index = 2, #history, STRIDE do
    local day = history[index]
    if day >= firstDay then
      local value, count = AverageOf(history[index + 1])
      local buyout, buyoutCount = AverageOf(history[index + 2])
      values[#values + 1] = {
        day = day,
        value = value,
        count = count,
        buyout = buyout,
        buyoutCount = buyoutCount,
        quantity = (AverageOf(history[index + 3])),
      }
    end
  end
  return values
end

-- How many units were listed on an average scan of the newest day in the window whose scans counted
-- them. Takes the history Get returned, for the Database tab, which already holds it for every row.
---@param history ArbitrageItemHistory
---@param firstDay number the window's first day
---@return number? units
function ns.Database.GetListedIn(history, firstDay)
  for index = #history - STRIDE + 1, 2, -STRIDE do
    if history[index] < firstDay then
      return nil
    end
    local units = AverageOf(history[index + 3])
    if units then
      return units
    end
  end
end

-- The window's first day, for GetListedIn.
---@return number
function ns.Database.GetFirstDay()
  return ScanDay(time() - WINDOW_DAYS * DAY)
end

---@param dbKey string|number
---@return number? units
function ns.Database.GetListed(dbKey)
  local history = ns.Database.Get(dbKey)
  if history then
    return ns.Database.GetListedIn(history, ns.Database.GetFirstDay())
  end
end

-- How an item sells across the region, from TradeSkillMaster through the Companion: its average
-- sale price and the share of its auctions that sell. Random-enchant gear has none: a variant's key
-- isn't an item ID, and the server leaves out the item IDs of gear that rolls random enchants, whose
-- figures blend every enchant.
---@param dbKey string|number
---@return number? averagePrice, number? saleRate
function ns.Database.GetSales(dbKey)
  local sale = sales[tonumber(dbKey)]
  if type(sale) == "table" then
    return sale[1], sale[2]
  end
end

-- Whether the Companion brought any region-wide sales, so they're worth a column.
---@return boolean
function ns.Database.HasSales()
  return next(sales) ~= nil
end

---@param itemID number
---@param unitPrice number
function ns.Database.RecordVendorPrice(itemID, unitPrice)
  if
    type(itemID) ~= "number"
    or not (itemID > 0 and itemID < math.huge)
    or type(unitPrice) ~= "number"
    or not (unitPrice > 0 and unitPrice < math.huge)
  then
    return
  end
  local key = tostring(itemID)
  ownVendorPrices[key] = math.min(ownVendorPrices[key] or unitPrice, unitPrice)
  vendorPrices[key] = math.min(vendorPrices[key] or unitPrice, unitPrice)
end

---@param itemID number
---@return number?
function ns.Database.GetVendorPrice(itemID)
  return vendorPrices[tostring(itemID)]
end

---@return number
function ns.Database.CountVendorPrices()
  local count = 0
  for _ in pairs(vendorPrices) do
    count = count + 1
  end
  return count
end

---@return ArbitrageDatabaseStatus
function ns.Database.GetStatus()
  local cutoff = time() - WINDOW_DAYS * DAY
  local latestScan = db.meta.lastScan
  local recentScanCount = 0
  for timestamp in pairs(db.scans) do
    latestScan = math.max(latestScan or 0, timestamp)
    if timestamp >= cutoff then
      recentScanCount = recentScanCount + 1
    end
  end

  local itemCount = 0
  for _ in pairs(db.items) do
    itemCount = itemCount + 1
  end

  return {
    itemCount = itemCount,
    latestScan = latestScan,
    latestQuickScan = db.latestQuickScan,
    recentScanCount = recentScanCount,
  }
end

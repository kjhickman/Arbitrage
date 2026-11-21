local _, ns = ...

ns.Database = {}

---@class ArbitrageDatabaseMeta
---@field lastScan number?
---@field lastPlayed number?

---@class ArbitrageDatabaseItem
---@field scans table<number|string, number>

---@class ArbitrageMarketDatabase
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageDatabaseItem>
---@field latestBuyouts table<string, number>

-- What the lookup copy keeps of an item: each UTC day's scans packed into one number (see
-- AddToDay) for the market value window, and the newest scan of the last thirty days.
---@class ArbitrageItemHistory
---@field days table<number, number> packed scans by day number, floor(timestamp / DAY)
---@field latest number

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

---@class ArbitrageViewMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field buyouts ArbitrageBuyoutSources
---@field scans table<number, true> every scan time of the last thirty days

-- A market of the companion's import: its items already as day totals, and the scans they hold.
-- Companions from before the Buyout lists leave out buyouts and have only latestBuyouts.
---@class ArbitrageImportMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field latestBuyouts table<string, number>
---@field buyouts { items: any, variants: any }?
---@field scans number[]

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

-- A full scan replaces a quick scan's Buyouts but keeps when the quick scan ran.
---@class ArbitrageQuickBuyoutSnapshot
---@field at number
---@field buyouts table<string, number>?

-- On the next database version migration, purge confirmed Poor-quality items from saved and
-- synced price data (including suffix keys, Buyouts, and vendor prices). Keep unknown quality.
local VERSION = 2
-- The companion's import moved to version 3 when it began holding day totals instead of scans.
local DAILY_IMPORT_VERSION = 3
local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30
-- A day's scans add up as total * SCANS_PER_DAY + count, so one addition records a scan. Exact while
-- a day holds under 1024 scans of an item and its prices sum below 2^43 copper (880 million gold).
local SCANS_PER_DAY = 1024
local function Noop() end

-- The own* tables are the account's saved scans, the only data the companion uploads. The view
-- merges them with the synced import and is what every read sees; it is never saved.
---@type ArbitrageDatabaseRoot!
local ownRoot
---@type ArbitrageRealmDatabase!
local ownRealm
---@type ArbitrageMarketDatabase!
local ownMarket
---@type table<string, number>!
local ownVendorPrices
---@type { markets: table<string, ArbitrageViewMarket>, vendorPrices: table<string, table<string, number>> }!
local viewRealm
---@type ArbitrageViewMarket!
local db
---@type table<string, number>!
local vendorPrices
-- Whether the companion's import was loaded, and when the companion synced it. Companions from
-- before the sync time was recorded leave it out.
local importLoaded = false
---@type number?
local importSyncedAt
-- Kept outside ARBITRAGE_DATABASE: the Companion uploads only full scans.
---@type string
local quickMarketKey
---@type ArbitrageBuyoutList?
local quickBuyouts
---@type number?
local latestQuickScan
-- Each kind of item takes its Buyouts from the newest source that sees it; see ChooseBuyoutSources.
---@type ArbitrageBuyoutList?
local itemSource
---@type ArbitrageBuyoutList?
local randomEnchantItemSource
---@type ArbitrageBuyoutList?
local variantSource

---@param root any
---@param version number
---@return boolean
local function IsValidRoot(root, version)
  return type(root) == "table"
    and root.__version == version
    and type(root.meta) == "table"
    and type(root.realms) == "table"
end

---@param import any
---@return boolean
local function IsValidImport(import)
  return IsValidRoot(import, VERSION) or IsValidRoot(import, DAILY_IMPORT_VERSION)
end

---@param value any
---@return table
local function AsTable(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

---@param buyouts any
---@return table<string, number>
local function CopyBuyouts(buyouts)
  local copy = {}
  for key, value in pairs(AsTable(buyouts)) do
    if type(value) == "number" then
      copy[key] = value
    end
  end
  return copy
end

---@param timestamp number
---@return number
local function ScanDay(timestamp)
  return math.floor(timestamp / DAY)
end

---@param days table<number, number>
---@param day number
---@param copper number
local function AddToDay(days, day, copper)
  days[day] = (days[day] or 0) + math.floor(copper + 0.5) * SCANS_PER_DAY + 1
end

-- A day's summed price and its number of scans.
---@param packed number
---@return number total, number count
function ns.Database.UnpackDay(packed)
  local count = packed % SCANS_PER_DAY
  return (packed - count) / SCANS_PER_DAY, count
end

-- Records a scan of an item, adding to its day only from firstDay on.
---@param items table<string, ArbitrageItemHistory>
---@param dbKey string
---@param at number
---@param copper number
---@param firstDay number
local function AddScan(items, dbKey, at, copper, firstDay)
  local history = items[dbKey]
  if history then
    history.latest = math.max(history.latest, at)
  else
    history = { days = {}, latest = at }
    items[dbKey] = history
  end
  local day = ScanDay(at)
  if day >= firstDay then
    AddToDay(history.days, day, copper)
  end
end

-- Companions before the daily import wrote every scan, so such a market is added up here.
---@param market table
---@return ArbitrageImportMarket
local function AddUpImportScans(market)
  local items, scans, seen = {}, {}, {}
  for dbKey, item in pairs(AsTable(market.items)) do
    for key, copper in pairs(AsTable(AsTable(item).scans)) do
      local at = tonumber(key)
      if at and type(copper) == "number" and copper > 0 then
        AddScan(items, dbKey, at, copper, -math.huge)
        if not seen[at] then
          seen[at] = true
          scans[#scans + 1] = at
        end
      end
    end
  end
  return { meta = market.meta, items = items, latestBuyouts = market.latestBuyouts, scans = scans }
end

---@param at any
---@param prices table<string, number>
---@return ArbitrageBuyoutList?
local function BuyoutList(at, prices)
  if type(at) == "number" then
    return { at = at, prices = prices }
  end
  return nil
end

---@param prices table<string, number>
---@param variants boolean
---@return table<string, number>
local function KeysOfKind(prices, variants)
  local kind = {}
  for dbKey, copper in pairs(prices) do
    if (tonumber(dbKey) == nil) == variants then
      kind[dbKey] = copper
    end
  end
  return kind
end

-- The import's synced Buyout lists. Companions from before them wrote one list of the newest
-- scan's Buyouts, which saw random-enchant variants only if it has any.
---@param market ArbitrageImportMarket
---@return ArbitrageBuyoutList? items, ArbitrageBuyoutList? variants
local function ReadSyncedBuyouts(market)
  if type(market.buyouts) == "table" then
    local items, variants = AsTable(market.buyouts.items), AsTable(market.buyouts.variants)
    return BuyoutList(items.at, CopyBuyouts(items.prices)), BuyoutList(variants.at, CopyBuyouts(variants.prices))
  end

  local at = AsTable(market.meta).lastScan
  local latestBuyouts = CopyBuyouts(market.latestBuyouts)
  local variants = KeysOfKind(latestBuyouts, true)
  return BuyoutList(at, KeysOfKind(latestBuyouts, false)), next(variants) and BuyoutList(at, variants) or nil
end

-- Joins the account's saved scans to the import's day totals. The import already holds the scans
-- the companion synced, so only the account's scans it does not list are added.
---@param left table the account's saved market
---@param right ArbitrageImportMarket
---@return ArbitrageViewMarket
local function MergeMarket(left, right)
  local leftLastScan = AsTable(left.meta).lastScan
  local rightLastScan = AsTable(right.meta).lastScan
  leftLastScan = type(leftLastScan) == "number" and leftLastScan or nil
  rightLastScan = type(rightLastScan) == "number" and rightLastScan or nil
  local lastScan = leftLastScan
  if rightLastScan and (lastScan == nil or rightLastScan > lastScan) then
    lastScan = rightLastScan
  end
  local syncedItems, syncedVariants = ReadSyncedBuyouts(right)

  local meta = {}
  if type(lastScan) == "number" then
    meta.lastScan = lastScan
  end

  -- Scans count toward Last Seen for thirty days before the last scan, and toward market value
  -- only within its fourteen-day window, so older days are not kept.
  local cutoff = lastScan and lastScan - PRUNE_DAYS * DAY or -math.huge
  local firstDay = ScanDay(time() - WINDOW_DAYS * DAY)
  local items, scanTimes, imported = {}, {}, {}

  for _, at in ipairs(AsTable(right.scans)) do
    if type(at) == "number" then
      imported[at] = true
      if at >= cutoff then
        scanTimes[at] = true
      end
    end
  end

  -- The view takes over the import's tables, which are not read again.
  for dbKey, history in pairs(AsTable(right.items)) do
    if
      type(history) == "table"
      and type(history.days) == "table"
      and type(history.latest) == "number"
      and history.latest >= cutoff
    then
      for day, packed in pairs(history.days) do
        if type(day) ~= "number" or type(packed) ~= "number" or day < firstDay then
          history.days[day] = nil
        end
      end
      items[dbKey] = history
    end
  end

  for dbKey, item in pairs(AsTable(left.items)) do
    for key, copper in pairs(AsTable(AsTable(item).scans)) do
      local at = tonumber(key)
      if at and not imported[at] and at >= cutoff and type(copper) == "number" and copper > 0 then
        AddScan(items, dbKey, at, copper, firstDay)
        scanTimes[at] = true
      end
    end
  end

  return {
    meta = meta,
    items = items,
    buyouts = {
      own = BuyoutList(leftLastScan, CopyBuyouts(left.latestBuyouts)),
      items = syncedItems,
      variants = syncedVariants,
    },
    scans = scanTimes,
  }
end

---@param left any
---@param right any
---@return table<string, ArbitrageViewMarket>
local function MergeMarkets(left, right)
  local markets = {}
  local seen = {}

  for name, market in pairs(AsTable(left)) do
    if type(market) == "table" then
      seen[name] = true
      local other = AsTable(right)[name]
      if type(other) == "table" then
        markets[name] = MergeMarket(market, other)
      else
        markets[name] = MergeMarket(market, { meta = {}, items = {}, latestBuyouts = {} })
      end
    end
  end

  for name, market in pairs(AsTable(right)) do
    if type(market) == "table" and not seen[name] then
      markets[name] = MergeMarket({ meta = {}, items = {}, latestBuyouts = {} }, market)
    end
  end

  return markets
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

-- The import's realm with its markets as day totals.
---@param name string
---@return table
local function ReadImportRealm(name)
  local import = ARBITRAGE_IMPORT
  if not IsValidImport(import) then
    return {}
  end
  local realm = AsTable(import.realms[name])
  if import.__version == DAILY_IMPORT_VERSION then
    return realm
  end

  local markets = {}
  for faction, market in pairs(AsTable(realm.markets)) do
    if type(market) == "table" then
      markets[faction] = AddUpImportScans(market)
    end
  end
  return { markets = markets, vendorPrices = realm.vendorPrices }
end

---@param left table
---@param right table
local function MergeRealm(left, right)
  return {
    markets = MergeMarkets(left.markets, right.markets),
    vendorPrices = MergeVendorPrices(left.vendorPrices, right.vendorPrices),
  }
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
  if
    type(market) ~= "table"
    or type(market.meta) ~= "table"
    or type(market.items) ~= "table"
    or type(market.latestBuyouts) ~= "table"
  then
    market = { meta = {}, items = {}, latestBuyouts = {} }
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

-- Every read and scan uses the player's faction market for the whole session; neutral Auction
-- Houses are not supported.
---@param market "Alliance"|"Horde"|"Unknown"
local function SelectMarket(market)
  ownMarket = EnsureMarket(ownRealm, market)
  db = viewRealm.markets[market]
  if not db then
    db = { meta = {}, items = {}, buyouts = {}, scans = {} }
    viewRealm.markets[market] = db
  end
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
  itemSource = Newest(sources.own, quickBuyouts, sources.items)
  randomEnchantItemSource = Newest(sources.own, quickBuyouts, sources.variants)
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
  if not IsValidRoot(ARBITRAGE_DATABASE, VERSION) then
    ARBITRAGE_DATABASE = { __version = VERSION, meta = {}, realms = {} }
  end
  ---@cast ARBITRAGE_DATABASE ArbitrageDatabaseRoot
  ownRoot = ARBITRAGE_DATABASE

  local realm = ns.Realm.GetName()
  ownRealm = EnsureRealm(ownRoot, realm)
  ownRealm.region = GetCurrentRegion()
  ownRealm.vendorPrices = MergeVendorPrices(ownRealm.vendorPrices, nil)

  viewRealm = MergeRealm(ownRealm, ReadImportRealm(realm))
  importLoaded = IsValidImport(ARBITRAGE_IMPORT)
  importSyncedAt = nil
  if importLoaded and type(ARBITRAGE_IMPORT.meta.syncedAt) == "number" then
    importSyncedAt = ARBITRAGE_IMPORT.meta.syncedAt
  end
  -- The view keeps what it needs, so the rest of the loaded import can be collected.
  _G.ARBITRAGE_IMPORT = nil

  local faction = UnitFactionGroup("player")
  if faction ~= "Alliance" and faction ~= "Horde" then
    faction = "Unknown"
  end
  SelectMarket(faction)
  if faction ~= "Unknown" then
    ownMarket.meta.lastPlayed = time()
  end

  quickMarketKey = tostring(ownRealm.region) .. ":" .. realm .. ":" .. faction
  quickBuyouts = nil
  local snapshot = AsTable(AsTable(ARBITRAGE_QUICK_BUYOUTS)[quickMarketKey])
  latestQuickScan = type(snapshot.at) == "number" and snapshot.at or nil
  if latestQuickScan and type(snapshot.buyouts) == "table" then
    quickBuyouts = { at = latestQuickScan, prices = CopyBuyouts(snapshot.buyouts) }
  end
  ChooseBuyoutSources()

  ownVendorPrices = EnsureVendorPrices(ownRealm, faction)
  vendorPrices = EnsureVendorPrices(viewRealm, faction)
end

---@param timestamp number
function ns.Database.RecordReplicateScan(timestamp)
  ownRoot.meta.lastReplicateScan = timestamp
end

---@return number?
function ns.Database.GetLastReplicateScan()
  return ownRoot.meta.lastReplicateScan
end

---@param results table<string, number>
---@param timestamp number
---@param checkpoint fun()
---@return table<string, ArbitrageDatabaseItem> items, number count
local function BuildScanItems(results, timestamp, checkpoint)
  local cutoff = timestamp - PRUNE_DAYS * DAY
  local items = {}
  local storedResults = {}
  local count = 0

  for dbKey, item in pairs(ownMarket.items) do
    local scans = {}
    for scanKey, marketValue in pairs(item.scans) do
      local scanTimestamp = tonumber(scanKey)
      if not scanTimestamp or scanTimestamp >= cutoff then
        scans[scanKey] = marketValue
      end
      checkpoint()
    end

    local marketValue = results[dbKey]
    if marketValue ~= nil then
      scans[timestamp] = marketValue
      storedResults[dbKey] = true
      count = count + 1
    end

    if next(scans) ~= nil then
      items[dbKey] = { scans = scans }
    end
    checkpoint()
  end

  for dbKey, marketValue in pairs(results) do
    if not storedResults[dbKey] then
      items[dbKey] = { scans = { [timestamp] = marketValue } }
      count = count + 1
    end
    checkpoint()
  end

  return items, count
end

---@param results table<string, number>
---@param timestamp number
---@param latestBuyouts table<string, number>?
---@param checkpoint fun()?
---@return number
function ns.Database.SaveScan(results, timestamp, latestBuyouts, checkpoint)
  checkpoint = checkpoint or Noop
  latestBuyouts = latestBuyouts or {}
  local items, count = BuildScanItems(results, timestamp, checkpoint)
  checkpoint()

  ownMarket.items = items
  ownMarket.meta.lastScan = timestamp
  ownMarket.latestBuyouts = latestBuyouts

  -- The view takes the whole scan between frames, so nothing reads it half applied.
  local cutoff = timestamp - PRUNE_DAYS * DAY
  for dbKey, history in pairs(db.items) do
    if history.latest < cutoff then
      db.items[dbKey] = nil
    end
  end
  for at in pairs(db.scans) do
    if at < cutoff then
      db.scans[at] = nil
    end
  end
  local firstDay = ScanDay(time() - WINDOW_DAYS * DAY)
  for dbKey, copper in pairs(results) do
    if copper > 0 then
      AddScan(db.items, dbKey, timestamp, copper, firstDay)
    end
  end
  db.scans[timestamp] = true
  db.meta.lastScan = timestamp
  db.buyouts.own = { at = timestamp, prices = latestBuyouts }
  -- An older quick scan can't win any more, so its Buyouts go; when it ran is kept.
  if quickBuyouts and quickBuyouts.at <= timestamp then
    quickBuyouts = nil
    ARBITRAGE_QUICK_BUYOUTS[quickMarketKey] = { at = latestQuickScan }
  end
  ChooseBuyoutSources()

  return count
end

---@param buyouts table<string, number>
---@param timestamp number when the last browse page arrived
---@return boolean saved
function ns.Database.SaveQuickBuyouts(buyouts, timestamp)
  local ownAt = db.buyouts.own and db.buyouts.own.at or 0
  if timestamp <= ownAt or (latestQuickScan and timestamp < latestQuickScan) then
    return false
  end
  quickBuyouts = { at = timestamp, prices = buyouts }
  latestQuickScan = timestamp
  ARBITRAGE_QUICK_BUYOUTS = AsTable(ARBITRAGE_QUICK_BUYOUTS)
  ARBITRAGE_QUICK_BUYOUTS[quickMarketKey] = { at = timestamp, buyouts = buyouts }
  ChooseBuyoutSources()
  return true
end

-- Historical and synced prices do not carry quality. Check the client without requesting
-- thousands of uncached items at once; the Database tab already loads them in batches.
---@param item number|string item ID or link
---@return boolean
function ns.Database.IsIgnoredItem(item)
  return C_Item.IsItemDataCachedByID(item) and select(3, C_Item.GetItemInfo(item)) == Enum.ItemQuality.Poor
end

---@param key string
---@return boolean
local function IsIgnoredKey(key)
  local itemID = tonumber(key) or tonumber(key:match("^equip:(%d+):"))
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

-- When a scan last listed the item: its newest Market Value scan, or the scan behind its Buyout.
---@param dbKey string|number
---@return number?
function ns.Database.GetLastSeen(dbKey)
  local key = tostring(dbKey)
  local history = db.items[key]
  local lastSeen = history and history.latest
  local source = BuyoutSourceFor(key)
  local buyoutAt = source and source.prices[key] and source.at
  if buyoutAt and (lastSeen == nil or buyoutAt > lastSeen) then
    return buyoutAt
  end
  return lastSeen
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

-- The game reads the import only at login or /reload, so its sync time can trail the companion's.
---@return boolean loaded, number? syncedAt
function ns.Database.GetImportStatus()
  return importLoaded, importSyncedAt
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
    latestQuickScan = latestQuickScan,
    recentScanCount = recentScanCount,
  }
end

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

---@class ArbitrageViewMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field latestBuyouts table<string, number>
---@field scans table<number, true> every scan time of the last thirty days

-- A market of the companion's import: its items already as day totals, and the scans they hold.
---@class ArbitrageImportMarket
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageItemHistory>
---@field latestBuyouts table<string, number>
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
---@field latestBuyoutScan number?
---@field recentScanCount number

---@class ArbitrageQuickBuyoutSnapshot
---@field at number
---@field buyouts table<string, number>

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
---@type ArbitrageQuickBuyoutSnapshot?
local quickBuyouts

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

---@param left number?
---@param right number?
---@return number
local function CompareOptional(left, right)
  if left == nil and right == nil then
    return 0
  end
  if left == nil then
    return -1
  end
  if right == nil then
    return 1
  end
  if left < right then
    return -1
  end
  if left > right then
    return 1
  end
  return 0
end

---@param map table
---@return string[]
local function SortedKeys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Buyout maps move as one snapshot; BTreeMap order decides a lastScan tie.
---@param left table
---@param right table
---@return number
local function CompareBuyoutMaps(left, right)
  local leftKeys = SortedKeys(left)
  local rightKeys = SortedKeys(right)
  local index = 1
  while true do
    local leftKey = leftKeys[index]
    local rightKey = rightKeys[index]
    if leftKey == nil and rightKey == nil then
      return 0
    end
    if leftKey == nil then
      return -1
    end
    if rightKey == nil then
      return 1
    end
    if leftKey < rightKey then
      return -1
    end
    if leftKey > rightKey then
      return 1
    end
    local leftValue = left[leftKey]
    local rightValue = right[rightKey]
    if leftValue < rightValue then
      return -1
    end
    if leftValue > rightValue then
      return 1
    end
    index = index + 1
  end
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

-- Joins the account's saved scans to the import's day totals. The import already holds the scans
-- the companion synced, so only the account's scans it does not list are added.
---@param left table the account's saved market
---@param right ArbitrageImportMarket
---@return ArbitrageViewMarket
local function MergeMarket(left, right)
  local leftBuyouts = CopyBuyouts(left.latestBuyouts)
  local rightBuyouts = CopyBuyouts(right.latestBuyouts)
  local leftLastScan = type(left.meta) == "table" and type(left.meta.lastScan) == "number" and left.meta.lastScan or nil
  local rightLastScan = type(right.meta) == "table" and type(right.meta.lastScan) == "number" and right.meta.lastScan
    or nil
  local lastScanCmp = CompareOptional(leftLastScan, rightLastScan)
  local leftWins = lastScanCmp > 0 or (lastScanCmp == 0 and CompareBuyoutMaps(leftBuyouts, rightBuyouts) >= 0)

  local lastScan
  local latestBuyouts
  if leftWins then
    lastScan = leftLastScan
    latestBuyouts = leftBuyouts
  else
    lastScan = rightLastScan
    latestBuyouts = rightBuyouts
  end

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
    latestBuyouts = latestBuyouts,
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
    db = { meta = {}, items = {}, latestBuyouts = {}, scans = {} }
    viewRealm.markets[market] = db
  end
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
  if type(snapshot.at) == "number" and snapshot.at > (db.meta.lastScan or 0) and type(snapshot.buyouts) == "table" then
    quickBuyouts = { at = snapshot.at, buyouts = CopyBuyouts(snapshot.buyouts) }
  end

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
  db.latestBuyouts = latestBuyouts
  if quickBuyouts and quickBuyouts.at <= timestamp then
    quickBuyouts = nil
    ARBITRAGE_QUICK_BUYOUTS[quickMarketKey] = nil
  end

  return count
end

---@param buyouts table<string, number>
---@param timestamp number when the last browse page arrived
---@return boolean saved
function ns.Database.SaveQuickBuyouts(buyouts, timestamp)
  if timestamp <= (db.meta.lastScan or 0) or (quickBuyouts and timestamp < quickBuyouts.at) then
    return false
  end
  quickBuyouts = { at = timestamp, buyouts = buyouts }
  ARBITRAGE_QUICK_BUYOUTS = AsTable(ARBITRAGE_QUICK_BUYOUTS)
  ARBITRAGE_QUICK_BUYOUTS[quickMarketKey] = quickBuyouts
  return true
end

---@param dbKey string|number
---@return ArbitrageItemHistory?
function ns.Database.Get(dbKey)
  return db.items[tostring(dbKey)]
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
  if quickBuyouts then
    local price = quickBuyouts.buyouts[key]
    -- An absent item that the quick scan covers has no current buyout. Gear still uses the full scan.
    if price ~= nil or ns.Keys.GetPlainKey(tonumber(key)) ~= nil then
      return price
    end
  end
  return db.latestBuyouts[key]
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
    latestBuyoutScan = quickBuyouts and quickBuyouts.at or db.meta.lastScan,
    recentScanCount = recentScanCount,
  }
end

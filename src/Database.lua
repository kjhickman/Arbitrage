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
---@field recentScanCount number

local VERSION = 2
local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30
-- A day's scans add up as total * SCANS_PER_DAY + count, so one addition records a scan. Exact while
-- a day holds under 1024 scans of an item and its prices sum below 2^43 copper (880 million gold).
local SCANS_PER_DAY = 1024
local function Noop() end

local VALID_MARKETS = {
  Alliance = true,
  Horde = true,
  Neutral = true,
  Unknown = true,
}

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
---@type string!
local currentMarket

---@param root any
---@return boolean
local function IsValidRoot(root)
  return type(root) == "table"
    and root.__version == VERSION
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

---@param left any
---@param right any
---@return table<number, number>
local function MergeScans(left, right)
  local scans = {}

  local function ingest(source)
    for key, copper in pairs(AsTable(source)) do
      local at = tonumber(key)
      if at and type(copper) == "number" then
        local existing = scans[at]
        if existing == nil or copper < existing then
          scans[at] = copper
        end
      end
    end
  end

  ingest(left)
  ingest(right)
  return scans
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

-- Merges both sides' scans of each item, keeping the lower price of a scan both hold, then keeps
-- scans from the cutoff on as day totals, with days before firstDay counting only toward latest.
---@param left any
---@param right any
---@param cutoff number
---@param firstDay number
---@param scanTimes table<number, true> collects every kept scan time
---@return table<string, ArbitrageItemHistory>
local function MergeItems(left, right, cutoff, firstDay, scanTimes)
  local keys = {}
  for _, source in ipairs({ AsTable(left), AsTable(right) }) do
    for dbKey, item in pairs(source) do
      if type(item) == "table" then
        keys[dbKey] = true
      end
    end
  end

  local items = {}
  for dbKey in pairs(keys) do
    local leftItem, rightItem = AsTable(AsTable(left)[dbKey]), AsTable(AsTable(right)[dbKey])
    local history
    for at, copper in pairs(MergeScans(leftItem.scans, rightItem.scans)) do
      if at >= cutoff and copper > 0 then
        history = history or { days = {}, latest = at }
        history.latest = math.max(history.latest, at)
        scanTimes[at] = true
        local day = ScanDay(at)
        if day >= firstDay then
          AddToDay(history.days, day, copper)
        end
      end
    end
    items[dbKey] = history
  end
  return items
end

---@param left table
---@param right table
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
  local scanTimes = {}
  return {
    meta = meta,
    items = MergeItems(left.items, right.items, cutoff, ScanDay(time() - WINDOW_DAYS * DAY), scanTimes),
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

---@param market string
function ns.Database.SetMarket(market)
  if not VALID_MARKETS[market] then
    market = "Unknown"
  end
  currentMarket = market
  ownMarket = EnsureMarket(ownRealm, market)
  db = viewRealm.markets[market]
  if not db then
    db = { meta = {}, items = {}, latestBuyouts = {}, scans = {} }
    viewRealm.markets[market] = db
  end
end

---@return string
function ns.Database.GetMarket()
  return currentMarket
end

function ns.Database.Init()
  if not IsValidRoot(ARBITRAGE_DATABASE) then
    ARBITRAGE_DATABASE = { __version = VERSION, meta = {}, realms = {} }
  end
  ---@cast ARBITRAGE_DATABASE ArbitrageDatabaseRoot
  ownRoot = ARBITRAGE_DATABASE

  local realm = ns.Realm.GetName()
  ownRealm = EnsureRealm(ownRoot, realm)
  ownRealm.region = GetCurrentRegion()
  ownRealm.vendorPrices = MergeVendorPrices(ownRealm.vendorPrices, nil)

  local importRealm = IsValidRoot(ARBITRAGE_IMPORT) and ARBITRAGE_IMPORT.realms[realm]
  viewRealm = MergeRealm(ownRealm, type(importRealm) == "table" and importRealm or {})
  -- The view holds its own copy, so the loaded import can be collected.
  _G.ARBITRAGE_IMPORT = nil

  local faction = UnitFactionGroup("player")
  if faction ~= "Alliance" and faction ~= "Horde" then
    faction = "Unknown"
  end
  ns.Database.SetMarket(faction)
  if faction ~= "Unknown" then
    ownMarket.meta.lastPlayed = time()
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

---@param targetDatabase ArbitrageMarketDatabase
---@param results table<string, number>
---@param timestamp number
---@param checkpoint fun()
---@return table<string, ArbitrageDatabaseItem> items, number count
local function BuildScanItems(targetDatabase, results, timestamp, checkpoint)
  local cutoff = timestamp - PRUNE_DAYS * DAY
  local items = {}
  local storedResults = {}
  local count = 0

  for dbKey, item in pairs(targetDatabase.items) do
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
  local items, count = BuildScanItems(ownMarket, results, timestamp, checkpoint)
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
  local day = ScanDay(timestamp)
  for dbKey, copper in pairs(results) do
    if copper > 0 then
      local history = db.items[dbKey]
      if history then
        history.latest = math.max(history.latest, timestamp)
      else
        history = { days = {}, latest = timestamp }
        db.items[dbKey] = history
      end
      AddToDay(history.days, day, copper)
    end
  end
  db.scans[timestamp] = true
  db.meta.lastScan = timestamp
  db.latestBuyouts = latestBuyouts

  return count
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
  return db.latestBuyouts[tostring(dbKey)]
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
    recentScanCount = recentScanCount,
  }
end

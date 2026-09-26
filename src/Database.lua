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
---@type ArbitrageRealmDatabase!
local viewRealm
---@type ArbitrageMarketDatabase!
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

---@param left any
---@param right any
---@return table<string, ArbitrageDatabaseItem>
local function MergeItems(left, right)
  local items = {}

  local function ingest(source)
    for dbKey, item in pairs(AsTable(source)) do
      if type(item) == "table" then
        local existing = items[dbKey]
        if existing then
          items[dbKey] = { scans = MergeScans(existing.scans, item.scans) }
        else
          items[dbKey] = { scans = MergeScans(item.scans, nil) }
        end
      end
    end
  end

  ingest(left)
  ingest(right)
  return items
end

---@param left table
---@param right table
---@return ArbitrageMarketDatabase
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

  return {
    meta = meta,
    items = MergeItems(left.items, right.items),
    latestBuyouts = latestBuyouts,
  }
end

---@param left any
---@param right any
---@return table<string, ArbitrageMarketDatabase>
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
---@return ArbitrageRealmDatabase
local function MergeRealm(left, right)
  return {
    markets = MergeMarkets(left.markets, right.markets),
    vendorPrices = MergeVendorPrices(left.vendorPrices, right.vendorPrices),
  }
end

---@param market ArbitrageMarketDatabase
local function PruneMarketScans(market)
  local lastScan = market.meta.lastScan
  if type(lastScan) ~= "number" then
    return
  end

  local cutoff = lastScan - PRUNE_DAYS * DAY
  local items = {}
  for dbKey, item in pairs(market.items) do
    local scans = {}
    for at, copper in pairs(item.scans) do
      local timestamp = tonumber(at)
      if timestamp and timestamp >= cutoff then
        scans[timestamp] = copper
      end
    end
    if next(scans) ~= nil then
      items[dbKey] = { scans = scans }
    end
  end
  market.items = items
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
  db = EnsureMarket(viewRealm, market)
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

  local realm = GetRealmName()
  ownRealm = EnsureRealm(ownRoot, realm)
  ownRealm.region = GetCurrentRegion()

  local importRealm = IsValidRoot(ARBITRAGE_IMPORT) and ARBITRAGE_IMPORT.realms[realm]
  viewRealm = MergeRealm(ownRealm, type(importRealm) == "table" and importRealm or {})
  for _, market in pairs(viewRealm.markets) do
    PruneMarketScans(market)
  end
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
  local targets = { ownMarket, db }
  local builds = {}
  local count = 0
  for index, target in ipairs(targets) do
    builds[index], count = BuildScanItems(target, results, timestamp, checkpoint)
  end

  checkpoint()
  for index, target in ipairs(targets) do
    target.items = builds[index]
    target.meta.lastScan = timestamp
    target.latestBuyouts = latestBuyouts
  end

  return count
end

---@param dbKey string|number
---@return ArbitrageDatabaseItem?
function ns.Database.Get(dbKey)
  return db.items[tostring(dbKey)]
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
  local recentScans = {}
  local latestScan = db.meta.lastScan
  local itemCount = 0

  for _, item in pairs(db.items) do
    itemCount = itemCount + 1
    for timestamp in pairs(item.scans) do
      timestamp = tonumber(timestamp)

      if timestamp then
        latestScan = math.max(latestScan or 0, timestamp)

        if timestamp >= cutoff then
          recentScans[timestamp] = true
        end
      end
    end
  end

  local recentScanCount = 0
  for _ in pairs(recentScans) do
    recentScanCount = recentScanCount + 1
  end

  return {
    itemCount = itemCount,
    latestScan = latestScan,
    recentScanCount = recentScanCount,
  }
end

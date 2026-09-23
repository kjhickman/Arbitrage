local _, ns = ...

ns.Database = {}

---@class ArbitrageDatabaseMeta
---@field lastScan number?

---@class ArbitrageDatabaseItem
---@field scans table<number|string, number>

---@class ArbitrageMarketDatabase
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageDatabaseItem>
---@field latestBuyouts table<string, number>

---@class ArbitrageRealmDatabase
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

local VERSION = 1
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

---@type ArbitrageMarketDatabase!
local db
---@type ArbitrageDatabaseRoot!
local rootDatabase
---@type ArbitrageRealmDatabase!
local realmDatabase
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
---@return number?
local function MaxOptional(left, right)
  if left == nil then
    return right
  end
  if right == nil then
    return left
  end
  if left >= right then
    return left
  end
  return right
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

---@param saved ArbitrageDatabaseRoot
---@param importRoot ArbitrageDatabaseRoot
---@return ArbitrageDatabaseRoot
local function MergeRoots(saved, importRoot)
  local lastReplicateScan = MaxOptional(saved.meta.lastReplicateScan, importRoot.meta.lastReplicateScan)
  local meta = {}
  if lastReplicateScan ~= nil then
    meta.lastReplicateScan = lastReplicateScan
  end

  local realms = {}
  local seen = {}

  for name, realm in pairs(saved.realms) do
    if type(realm) == "table" then
      seen[name] = true
      local other = importRoot.realms[name]
      if type(other) == "table" then
        realms[name] = MergeRealm(realm, other)
      else
        realms[name] = MergeRealm(realm, { markets = {}, vendorPrices = {} })
      end
    end
  end

  for name, realm in pairs(importRoot.realms) do
    if type(realm) == "table" and not seen[name] then
      realms[name] = MergeRealm({ markets = {}, vendorPrices = {} }, realm)
    end
  end

  for _, realm in pairs(realms) do
    for _, market in pairs(realm.markets) do
      PruneMarketScans(market)
    end
  end

  return {
    __version = VERSION,
    meta = meta,
    realms = realms,
  }
end

---@param market string
function ns.Database.SetMarket(market)
  if not VALID_MARKETS[market] then
    market = "Unknown"
  end
  currentMarket = market

  local marketDatabase = realmDatabase.markets[market]
  if
    type(marketDatabase) ~= "table"
    or type(marketDatabase.meta) ~= "table"
    or type(marketDatabase.items) ~= "table"
    or type(marketDatabase.latestBuyouts) ~= "table"
  then
    marketDatabase = { meta = {}, items = {}, latestBuyouts = {} }
    realmDatabase.markets[market] = marketDatabase
  end
  ---@cast marketDatabase ArbitrageMarketDatabase
  db = marketDatabase
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
  if IsValidRoot(ARBITRAGE_IMPORT) then
    local importRoot = ARBITRAGE_IMPORT
    ---@cast importRoot ArbitrageDatabaseRoot
    ARBITRAGE_DATABASE = MergeRoots(ARBITRAGE_DATABASE, importRoot)
  end
  rootDatabase = ARBITRAGE_DATABASE

  local realm = GetRealmName()
  realmDatabase = rawget(rootDatabase.realms, realm)
  if
    type(realmDatabase) ~= "table"
    or type(realmDatabase.markets) ~= "table"
    or type(realmDatabase.vendorPrices) ~= "table"
  then
    realmDatabase = { markets = {}, vendorPrices = {} }
    rootDatabase.realms[realm] = realmDatabase
  end

  local faction = UnitFactionGroup("player")
  if faction ~= "Alliance" and faction ~= "Horde" then
    faction = "Unknown"
  end
  ns.Database.SetMarket(faction)

  if type(realmDatabase.vendorPrices[faction]) ~= "table" then
    realmDatabase.vendorPrices[faction] = {}
  end
  vendorPrices = realmDatabase.vendorPrices[faction]
end

---@param timestamp number
function ns.Database.RecordReplicateScan(timestamp)
  rootDatabase.meta.lastReplicateScan = timestamp
end

---@return number?
function ns.Database.GetLastReplicateScan()
  return rootDatabase.meta.lastReplicateScan
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
  local targetDatabase = db
  local items, count = BuildScanItems(targetDatabase, results, timestamp, checkpoint)

  checkpoint()
  targetDatabase.items = items
  targetDatabase.meta.lastScan = timestamp
  targetDatabase.latestBuyouts = latestBuyouts or {}

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

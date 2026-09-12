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
---@field lastKnownScan number?

---@class ArbitrageDatabaseStatus
---@field itemCount number
---@field latestScan number?
---@field recentScanCount number

local VERSION = 4
local PREVIOUS_VERSION = 3
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
---@type ArbitrageRealmDatabase!
local realmDatabase
---@type table<string, number>!
local vendorPrices

---@param root table
local function MigrateVersion3(root)
  for realm, oldRealmDatabase in pairs(root) do
    if realm ~= "__version" and type(oldRealmDatabase) == "table" then
      oldRealmDatabase.markets = {
        Unknown = {
          meta = oldRealmDatabase.meta,
          items = oldRealmDatabase.items,
          latestBuyouts = oldRealmDatabase.latestBuyouts,
        },
      }
      oldRealmDatabase.meta = nil
      oldRealmDatabase.items = nil
      oldRealmDatabase.latestBuyouts = nil
    end
  end
  root.__version = VERSION
end

---@param market string
function ns.Database.SetMarket(market)
  if not VALID_MARKETS[market] then
    market = "Unknown"
  end

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

function ns.Database.Init()
  if type(ARBITRAGE_DATABASE) == "table" and ARBITRAGE_DATABASE.__version == PREVIOUS_VERSION then
    MigrateVersion3(ARBITRAGE_DATABASE)
  elseif type(ARBITRAGE_DATABASE) ~= "table" or ARBITRAGE_DATABASE.__version ~= VERSION then
    ARBITRAGE_DATABASE = { __version = VERSION }
  end

  local realm = GetRealmName()
  realmDatabase = rawget(ARBITRAGE_DATABASE, realm)
  if
    type(realmDatabase) ~= "table"
    or type(realmDatabase.markets) ~= "table"
    or type(realmDatabase.vendorPrices) ~= "table"
  then
    realmDatabase = { markets = {}, vendorPrices = {} }
    ARBITRAGE_DATABASE[realm] = realmDatabase
  end

  local faction = UnitFactionGroup("player")
  if faction ~= "Alliance" and faction ~= "Horde" then
    faction = "Unknown"
  end
  local market = faction
  local factionDatabase = realmDatabase.markets[faction]
  if
    (type(factionDatabase) ~= "table" or type(factionDatabase.meta) ~= "table" or factionDatabase.meta.lastScan == nil)
    and realmDatabase.markets.Unknown
  then
    market = "Unknown"
  end
  ns.Database.SetMarket(market)

  if type(realmDatabase.vendorPrices[faction]) ~= "table" then
    realmDatabase.vendorPrices[faction] = {}
  end
  vendorPrices = realmDatabase.vendorPrices[faction]
end

---@param timestamp number
function ns.Database.RecordKnownScan(timestamp)
  realmDatabase.lastKnownScan = timestamp
end

---@return number?
function ns.Database.GetLastKnownScan()
  return realmDatabase.lastKnownScan
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

function ns.Database.Count()
  local count = 0
  for _ in pairs(db.items) do
    count = count + 1
  end

  return count
end

---@param dbKey string|number
---@return ArbitrageDatabaseItem?
function ns.Database.Get(dbKey)
  return db.items[tostring(dbKey)]
end

---@param dbKeys string[]
---@return number?
function ns.Database.GetLatestBuyout(dbKeys)
  for _, dbKey in ipairs(dbKeys) do
    local price = db.latestBuyouts[tostring(dbKey)]
    if price then
      return price
    end
  end
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

  for _, item in pairs(db.items) do
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
    itemCount = ns.Database.Count(),
    latestScan = latestScan,
    recentScanCount = recentScanCount,
  }
end

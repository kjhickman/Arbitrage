local _, ns = ...

ns.Database = {}

---@class ArbitrageDatabaseMeta
---@field lastScan number?
---@field lastScanItems number?

---@class ArbitrageDatabaseItem
---@field scans table<number|string, number>

---@class ArbitrageRealmDatabase
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageDatabaseItem>
---@field latestBuyouts table<string, number>
---@field vendorPrices table<string, table<string, number>>

---@class ArbitrageDatabaseStatus
---@field itemCount number
---@field latestScan number?
---@field recentScanCount number

local VERSION = 3
local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30

---@type ArbitrageRealmDatabase!
local db
---@type table<string, number>!
local vendorPrices

local function GetRealm()
  return GetRealmName()
end

---@param value any
---@return boolean
local function IsPositiveFiniteNumber(value)
  return type(value) == "number" and value > 0 and value < math.huge
end

---@param value any
---@return boolean
local function IsNonNegativeInteger(value)
  return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

function ns.Database.Init()
  if type(ARBITRAGE_DATABASE) ~= "table" or ARBITRAGE_DATABASE.__version ~= VERSION then
    -- ponytail: reset incompatible data instead of maintaining speculative migrations
    ARBITRAGE_DATABASE = { __version = VERSION }
  end

  local realm = GetRealm()
  local realmDatabase = rawget(ARBITRAGE_DATABASE, realm)
  if type(realmDatabase) ~= "table" then
    realmDatabase = {}
    ARBITRAGE_DATABASE[realm] = realmDatabase
  end
  if type(realmDatabase.meta) ~= "table" then
    realmDatabase.meta = {}
  end
  if type(realmDatabase.items) ~= "table" then
    realmDatabase.items = {}
  end
  if type(realmDatabase.latestBuyouts) ~= "table" then
    realmDatabase.latestBuyouts = {}
  end
  if type(realmDatabase.vendorPrices) ~= "table" then
    realmDatabase.vendorPrices = {}
  end

  if not IsPositiveFiniteNumber(realmDatabase.meta.lastScan) then
    realmDatabase.meta.lastScan = nil
  end
  if not IsNonNegativeInteger(realmDatabase.meta.lastScanItems) then
    realmDatabase.meta.lastScanItems = nil
  end
  for dbKey, item in pairs(realmDatabase.items) do
    if type(dbKey) ~= "string" or type(item) ~= "table" or type(item.scans) ~= "table" then
      realmDatabase.items[dbKey] = nil
    else
      for scanKey, marketValue in pairs(item.scans) do
        if not IsPositiveFiniteNumber(tonumber(scanKey)) or not IsPositiveFiniteNumber(marketValue) then
          item.scans[scanKey] = nil
        end
      end
      if next(item.scans) == nil then
        realmDatabase.items[dbKey] = nil
      end
    end
  end
  for dbKey, price in pairs(realmDatabase.latestBuyouts) do
    if type(dbKey) ~= "string" or not IsPositiveFiniteNumber(price) then
      realmDatabase.latestBuyouts[dbKey] = nil
    end
  end

  ---@cast realmDatabase ArbitrageRealmDatabase
  db = realmDatabase

  local faction = UnitFactionGroup("player")
  if type(db.vendorPrices[faction]) ~= "table" then
    db.vendorPrices[faction] = {}
  end
  vendorPrices = db.vendorPrices[faction]
  for itemID, price in pairs(vendorPrices) do
    if type(itemID) ~= "string" or not IsPositiveFiniteNumber(price) then
      vendorPrices[itemID] = nil
    end
  end
end

---@param results table<string, number>
---@param timestamp number
---@param latestBuyouts table<string, number>?
---@return number
function ns.Database.SaveScan(results, timestamp, latestBuyouts)
  local count = 0
  for dbKey, marketValue in pairs(results) do
    local item = db.items[dbKey]
    if item == nil then
      item = { scans = {} }
      db.items[dbKey] = item
    end

    item.scans[timestamp] = marketValue
    count = count + 1
  end

  db.meta.lastScan = timestamp
  db.meta.lastScanItems = count
  db.latestBuyouts = latestBuyouts or {}
  ns.Database.PruneOldScans(timestamp)

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
  if not IsPositiveFiniteNumber(itemID) or not IsPositiveFiniteNumber(unitPrice) then
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

---@param now number
function ns.Database.PruneOldScans(now)
  local cutoff = now - PRUNE_DAYS * DAY

  for dbKey, item in pairs(db.items) do
    for scanKey in pairs(item.scans) do
      local timestamp = tonumber(scanKey)

      if timestamp and timestamp < cutoff then
        item.scans[scanKey] = nil
      end
    end

    if next(item.scans) == nil then
      db.items[dbKey] = nil
    end
  end
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

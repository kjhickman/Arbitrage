local _, ns = ...

ns.Database = {}

---@class ArbitrageDatabaseMeta
---@field lastScan number?
---@field lastScanItems number?

---@class ArbitrageDatabaseItem
---@field scans table<number|string, number>?

---@class ArbitrageRealmDatabase
---@field meta ArbitrageDatabaseMeta
---@field items table<string, ArbitrageDatabaseItem>
---@field latestBuyouts table<string, number>
---@field vendorPrices table<string, table<string, number>>

---@class ArbitrageDatabaseStatus
---@field itemCount number
---@field latestScan number?
---@field recentScanCount number

---@class ArbitrageMarketValueResult : ArbitragePriceInfo
---@field dbKey string
---@field value number
---@field scanCount number
---@field dayCount number
---@field latestTimestamp number
---@field latestAgeDays number
---@field volatility number
---@field usedFallback boolean
---@field reasons string[]
---@field isUncertain boolean

local VERSION = 3
local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30
local HALF_LIFE_DAYS = 2
local MIN_CONFIDENT_DAYS = 3
local MIN_CONFIDENT_SCANS = 3
local STALE_DAYS = 3
local VOLATILE_RATIO = 0.30

---@type ArbitrageRealmDatabase!
local db
---@type table<string, number>!
local vendorPrices

local function GetRealm()
  return GetRealmName()
end

function ns.Database.Init()
  ARBITRAGE_DATABASE = ARBITRAGE_DATABASE or {}

  if ARBITRAGE_DATABASE.__version ~= VERSION then
    -- ponytail: scan data is regenerable, reset instead of migrating
    ARBITRAGE_DATABASE = { __version = VERSION }
  end

  local realm = GetRealm()
  ARBITRAGE_DATABASE[realm] = ARBITRAGE_DATABASE[realm] or { meta = {}, items = {} }

  local realmDatabase = ARBITRAGE_DATABASE[realm]
  ---@cast realmDatabase ArbitrageRealmDatabase
  db = realmDatabase
  db.latestBuyouts = db.latestBuyouts or {}
  db.vendorPrices = db.vendorPrices or {}

  local faction = UnitFactionGroup("player") or "Neutral"
  db.vendorPrices[faction] = db.vendorPrices[faction] or {}
  vendorPrices = db.vendorPrices[faction]
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

    item.scans = item.scans or {}
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
    for scanKey in pairs(item.scans or {}) do
      local timestamp = tonumber(scanKey)

      if timestamp and timestamp < cutoff then
        item.scans[scanKey] = nil
      end
    end

    if next(item.scans or {}) == nil then
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
    for timestamp in pairs(item.scans or {}) do
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

local function ScanDay(timestamp)
  return math.floor(timestamp / DAY)
end

local function AddReason(reasons, reason)
  reasons[#reasons + 1] = reason
end

---@param item ArbitrageDatabaseItem
---@param now number
local function SummarizeDays(item, now)
  local cutoff = now - WINDOW_DAYS * DAY
  local days = {}
  local scanCount = 0
  local latestTimestamp = 0

  for timestamp, marketValue in pairs(item.scans or {}) do
    timestamp = tonumber(timestamp)
    marketValue = tonumber(marketValue)

    if timestamp and timestamp >= cutoff and marketValue and marketValue > 0 then
      local day = ScanDay(timestamp)
      local info = days[day]

      if info == nil then
        info = { total = 0, count = 0 }
        days[day] = info
      end

      info.total = info.total + marketValue
      info.count = info.count + 1
      scanCount = scanCount + 1
      latestTimestamp = math.max(latestTimestamp, timestamp)
    end
  end

  return days, scanCount, latestTimestamp
end

---@param item ArbitrageDatabaseItem
---@param now number
local function CalculateRollingValue(item, now)
  local days, scanCount, latestTimestamp = SummarizeDays(item, now)
  local weightedDays = {}
  local weightedTotal = 0
  local totalWeight = 0

  for day, info in pairs(days) do
    local dayValue = info.total / info.count
    local ageDays = math.max(0, (now / DAY) - day)
    local weight = 0.5 ^ (ageDays / HALF_LIFE_DAYS)

    weightedDays[#weightedDays + 1] = { value = dayValue, weight = weight }
    weightedTotal = weightedTotal + dayValue * weight
    totalWeight = totalWeight + weight
  end

  if totalWeight == 0 then
    return nil
  end

  local value = weightedTotal / totalWeight
  local variance = 0

  for _, day in ipairs(weightedDays) do
    local distance = day.value - value

    variance = variance + distance * distance * day.weight
  end

  return {
    value = math.floor(value + 0.5),
    scanCount = scanCount,
    dayCount = #weightedDays,
    latestTimestamp = latestTimestamp,
    latestAgeDays = math.floor((now - latestTimestamp) / DAY),
    volatility = math.sqrt(variance / totalWeight) / value,
  }
end

local function GetRollingForKey(dbKey, now)
  local item = ns.Database.Get(dbKey)
  if item == nil then
    return nil
  end

  local result = CalculateRollingValue(item, now)
  if result == nil then
    return nil
  end

  result.dbKey = tostring(dbKey)
  return result
end

---@param dbKeys string[]
---@return ArbitrageMarketValueResult?
function ns.Database.GetRollingMarketValue(dbKeys)
  local now = time()
  local result

  for index, dbKey in ipairs(dbKeys) do
    result = GetRollingForKey(dbKey, now)
    if result then
      result.usedFallback = index > 1
      break
    end
  end

  if result == nil then
    return nil
  end

  result.reasons = {}

  if result.dayCount < MIN_CONFIDENT_DAYS then
    AddReason(result.reasons, "limited days")
  end

  if result.scanCount < MIN_CONFIDENT_SCANS then
    AddReason(result.reasons, "limited scans")
  end

  if result.latestAgeDays > STALE_DAYS then
    AddReason(result.reasons, "stale")
  end

  if result.usedFallback then
    AddReason(result.reasons, "generic fallback")
  end

  if result.volatility > VOLATILE_RATIO then
    AddReason(result.reasons, "volatile")
  end

  result.isUncertain = #result.reasons > 0

  return result
end

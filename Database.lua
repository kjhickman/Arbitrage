local _, ns = ...

ns.Database = {}

local VERSION = 1
local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local PRUNE_DAYS = 30
local HALF_LIFE_DAYS = 2
local MIN_CONFIDENT_DAYS = 3
local MIN_CONFIDENT_SCANS = 3
local STALE_DAYS = 3
local VOLATILE_RATIO = 0.30

local function GetRealm()
  return Auctionator.State and Auctionator.State.CurrentRealm or GetRealmName()
end

function ns.Database.Init()
  AUCTIONATOR_MARKET_PRICE_DATABASE = AUCTIONATOR_MARKET_PRICE_DATABASE or {}
  AUCTIONATOR_MARKET_PRICE_DATABASE.__version = VERSION

  local realm = GetRealm()
  AUCTIONATOR_MARKET_PRICE_DATABASE[realm] = AUCTIONATOR_MARKET_PRICE_DATABASE[realm] or {}

  ns.db = AUCTIONATOR_MARKET_PRICE_DATABASE[realm]
end

function ns.Database.SaveScan(results, timestamp)
  ns.Database.Init()

  local count = 0
  for dbKey, marketValue in pairs(results) do
    local item = ns.db[dbKey]
    if item == nil then
      item = { scans = {} }
      ns.db[dbKey] = item
    end

    item.scans = item.scans or {}
    item.marketValue = marketValue
    item.timestamp = timestamp
    item.scans[timestamp] = marketValue
    count = count + 1
  end

  ns.db.__lastScan = timestamp
  ns.db.__lastScanItems = count
  ns.Database.PruneOldScans(timestamp)

  return count
end

function ns.Database.Count()
  ns.Database.Init()

  local count = 0
  for key in pairs(ns.db) do
    if key ~= "__version" then
      count = count + 1
    end
  end

  return count
end

function ns.Database.Get(dbKey)
  ns.Database.Init()
  return ns.db[tostring(dbKey)]
end

function ns.Database.PruneOldScans(now)
  ns.Database.Init()

  local cutoff = now - PRUNE_DAYS * DAY

  for dbKey, item in pairs(ns.db) do
    if dbKey ~= "__lastScan" and dbKey ~= "__lastScanItems" and type(item) == "table" then
      for scanKey in pairs(item.scans or {}) do
        local timestamp = tonumber(scanKey)

        if timestamp and timestamp < cutoff then
          item.scans[scanKey] = nil
        end
      end

      if next(item.scans or {}) == nil then
        ns.db[dbKey] = nil
      end
    end
  end
end

function ns.Database.GetStatus()
  ns.Database.Init()

  local cutoff = time() - WINDOW_DAYS * DAY
  local recentScans = {}
  local latestScan = ns.db.__lastScan

  for key, item in pairs(ns.db) do
    if key ~= "__lastScan" and key ~= "__lastScanItems" and type(item) == "table" then
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

local function CalculateRollingValue(item, now)
  local days, scanCount, latestTimestamp = SummarizeDays(item, now)
  local weightedTotal = 0
  local totalWeight = 0
  local dayCount = 0

  for day, info in pairs(days) do
    local dayValue = info.total / info.count
    local ageDays = math.max(0, (now / DAY) - day)
    local weight = 0.5 ^ (ageDays / HALF_LIFE_DAYS)

    weightedTotal = weightedTotal + dayValue * weight
    totalWeight = totalWeight + weight
    dayCount = dayCount + 1
  end

  if totalWeight == 0 then
    return nil
  end

  local value = weightedTotal / totalWeight
  local variance = 0

  for day, info in pairs(days) do
    local dayValue = info.total / info.count
    local ageDays = math.max(0, (now / DAY) - day)
    local weight = 0.5 ^ (ageDays / HALF_LIFE_DAYS)
    local distance = dayValue - value

    variance = variance + distance * distance * weight
  end

  return {
    value = math.floor(value + 0.5),
    scanCount = scanCount,
    dayCount = dayCount,
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

function ns.Database.GetRollingMarketValue(dbKeys)
  ns.Database.Init()

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

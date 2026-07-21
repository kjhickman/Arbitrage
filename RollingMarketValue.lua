local _, ns = ...

ns.RollingMarketValue = {}

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

local DAY = 24 * 60 * 60
local WINDOW_DAYS = 14
local HALF_LIFE_DAYS = 2
local MIN_CONFIDENT_DAYS = 3
local MIN_CONFIDENT_SCANS = 3
local STALE_DAYS = 3
local VOLATILE_RATIO = 0.30

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

  for scanKey, storedMarketValue in pairs(item.scans) do
    local timestamp = tonumber(scanKey)
    local marketValue = tonumber(storedMarketValue)

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

local function GetForKey(dbKey, now)
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
function ns.RollingMarketValue.Get(dbKeys)
  local now = time()
  local result

  for index, dbKey in ipairs(dbKeys) do
    result = GetForKey(dbKey, now)
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

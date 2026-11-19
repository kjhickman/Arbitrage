local _, ns = ...

ns.RollingMarketValue = {}

---@class ArbitrageMarketValueResult : ArbitragePriceInfo
---@field value number
---@field scanCount number
---@field dayCount number
---@field latestAgeDays number
---@field latest number timestamp of the newest scan that saw the item
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

-- Each day's average counts once, with recent days weighing more. The window covers whole days,
-- from the one fourteen days ago through today.
---@param history ArbitrageItemHistory
---@param now number
local function CalculateRollingValue(history, now)
  local firstDay = ScanDay(now - WINDOW_DAYS * DAY)
  -- A common decay factor cancels out of the average. Anchor weights to the latest scan
  -- so time alone cannot introduce rounding noise while the same days are in the window.
  local latestDay = ScanDay(history.latest)
  local weightedDays = {}
  local weightedTotal = 0
  local totalWeight = 0
  local scanCount = 0

  for day, packed in pairs(history.days) do
    if day >= firstDay then
      local total, count = ns.Database.UnpackDay(packed)
      local dayValue = total / count
      local weight = 0.5 ^ ((latestDay - day) / HALF_LIFE_DAYS)

      weightedDays[#weightedDays + 1] = { value = dayValue, weight = weight }
      weightedTotal = weightedTotal + dayValue * weight
      totalWeight = totalWeight + weight
      scanCount = scanCount + count
    end
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
    latestAgeDays = math.floor((now - history.latest) / DAY),
    latest = history.latest,
    volatility = math.sqrt(variance / totalWeight) / value,
  }
end

---@param dbKeys string[]
---@return ArbitrageMarketValueResult?
function ns.RollingMarketValue.Get(dbKeys)
  local now = time()
  local result

  for index, dbKey in ipairs(dbKeys) do
    local item = ns.Database.Get(dbKey)
    if item then
      result = CalculateRollingValue(item, now)
    end
    if result then
      result.usedFallback = index > 1
      break
    end
  end

  if result == nil then
    return nil
  end

  -- Players read these joined with commas after "Estimate: ", so each explains itself briefly.
  result.reasons = {}

  if result.dayCount < MIN_CONFIDENT_DAYS then
    AddReason(result.reasons, "fewer than " .. MIN_CONFIDENT_DAYS .. " days of scans")
  end

  if result.scanCount < MIN_CONFIDENT_SCANS then
    AddReason(result.reasons, "fewer than " .. MIN_CONFIDENT_SCANS .. " scans")
  end

  if result.latestAgeDays > STALE_DAYS then
    AddReason(result.reasons, "last seen over " .. STALE_DAYS .. " days ago")
  end

  if result.usedFallback then
    AddReason(result.reasons, "priced from the base item")
  end

  if result.volatility > VOLATILE_RATIO then
    AddReason(result.reasons, "prices swing a lot")
  end

  result.isUncertain = #result.reasons > 0

  return result
end

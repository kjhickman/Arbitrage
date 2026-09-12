local _, ns = ...

ns.MarketValue = {}

---@class ArbitrageMarketRecord
---@field price number
---@field quantity number

local MIN_SCAN_PERCENT = 0.15
local MAX_SCAN_PERCENT = 0.30
local JUMP_THRESHOLD = 1.20
local STDDEV_FACTOR = 1.5

local function Noop() end

---@param records ArbitrageMarketRecord[]
---@param checkpoint fun()
---@return (number average, number totalQuantity) | (nil)
local function WeightedAverage(records, checkpoint)
  local totalValue = 0
  local totalQuantity = 0

  for _, record in ipairs(records) do
    totalValue = totalValue + record.price * record.quantity
    totalQuantity = totalQuantity + record.quantity
    checkpoint()
  end

  if totalQuantity == 0 then
    return nil
  end

  return totalValue / totalQuantity, totalQuantity
end

---@param records ArbitrageMarketRecord[]
---@param average number
---@param totalQuantity number
---@param checkpoint fun()
---@return number
local function WeightedStdDev(records, average, totalQuantity, checkpoint)
  local variance = 0

  for _, record in ipairs(records) do
    local distance = record.price - average
    variance = variance + distance * distance * record.quantity
    checkpoint()
  end

  return math.sqrt(variance / totalQuantity)
end

---@param records ArbitrageMarketRecord[]
---@param price number
---@param quantity number
local function AddAcceptedRecord(records, price, quantity)
  if quantity > 0 then
    records[#records + 1] = {
      price = price,
      quantity = quantity,
    }
  end
end

---@param records ArbitrageMarketRecord[]
---@param checkpoint fun()
---@return ArbitrageMarketRecord[]
local function TrimHighOutliers(records, checkpoint)
  table.sort(records, function(left, right)
    return left.price < right.price
  end)
  checkpoint()

  local totalQuantity = 0
  for _, record in ipairs(records) do
    totalQuantity = totalQuantity + record.quantity
    checkpoint()
  end

  if totalQuantity == 0 then
    return {}
  end

  local minQuantity = math.max(1, math.floor(totalQuantity * MIN_SCAN_PERCENT))
  local maxQuantity = math.max(1, math.floor(totalQuantity * MAX_SCAN_PERCENT))
  ---@type ArbitrageMarketRecord[]
  local accepted = {}
  local acceptedQuantity = 0
  local previousPrice

  for _, record in ipairs(records) do
    if acceptedQuantity >= minQuantity and previousPrice and record.price >= previousPrice * JUMP_THRESHOLD then
      break
    end

    local remainingQuantity = maxQuantity - acceptedQuantity
    if remainingQuantity <= 0 then
      break
    end

    local quantity = math.min(record.quantity, remainingQuantity)
    AddAcceptedRecord(accepted, record.price, quantity)
    acceptedQuantity = acceptedQuantity + quantity
    previousPrice = record.price
    checkpoint()
  end

  return accepted
end

---@param records ArbitrageMarketRecord[]
---@param checkpoint fun()?
---@return number?
function ns.MarketValue.Calculate(records, checkpoint)
  checkpoint = checkpoint or Noop
  local accepted = TrimHighOutliers(records, checkpoint)
  local average, totalQuantity = WeightedAverage(accepted, checkpoint)

  if average == nil then
    return nil
  end

  local stdDev = WeightedStdDev(accepted, average, totalQuantity, checkpoint)
  ---@type ArbitrageMarketRecord[]
  local filtered = {}
  local maxDistance = stdDev * STDDEV_FACTOR

  for _, record in ipairs(accepted) do
    if math.abs(record.price - average) <= maxDistance then
      AddAcceptedRecord(filtered, record.price, record.quantity)
    end
    checkpoint()
  end

  local finalAverage = WeightedAverage(filtered, checkpoint)
  if finalAverage == nil then
    return nil
  end

  return math.floor(finalAverage + 0.5)
end

---@param groups table<string, ArbitrageMarketRecord[]>
---@param checkpoint fun()?
---@return table<string, number>
function ns.MarketValue.CalculateAll(groups, checkpoint)
  checkpoint = checkpoint or Noop
  local results = {}

  for dbKey, records in pairs(groups) do
    local marketValue = ns.MarketValue.Calculate(records, checkpoint)
    if marketValue ~= nil then
      results[dbKey] = marketValue
    end
    checkpoint()
  end

  return results
end

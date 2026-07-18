local _, ns = ...

ns.MarketValue = {}

local MIN_SCAN_PERCENT = 0.15
local MAX_SCAN_PERCENT = 0.30
local JUMP_THRESHOLD = 1.20
local STDDEV_FACTOR = 1.5

local function WeightedAverage(records)
  local totalValue = 0
  local totalQuantity = 0

  for _, record in ipairs(records) do
    totalValue = totalValue + record.price * record.quantity
    totalQuantity = totalQuantity + record.quantity
  end

  if totalQuantity == 0 then
    return nil
  end

  return totalValue / totalQuantity, totalQuantity
end

local function WeightedStdDev(records, average, totalQuantity)
  local variance = 0

  for _, record in ipairs(records) do
    local distance = record.price - average
    variance = variance + distance * distance * record.quantity
  end

  return math.sqrt(variance / totalQuantity)
end

local function AddAcceptedRecord(records, price, quantity)
  if quantity > 0 then
    records[#records + 1] = {
      price = price,
      quantity = quantity,
    }
  end
end

local function TrimHighOutliers(records)
  table.sort(records, function(left, right)
    return left.price < right.price
  end)

  local totalQuantity = 0
  for _, record in ipairs(records) do
    totalQuantity = totalQuantity + record.quantity
  end

  if totalQuantity == 0 then
    return {}
  end

  local minQuantity = math.max(1, math.floor(totalQuantity * MIN_SCAN_PERCENT))
  local maxQuantity = math.max(1, math.floor(totalQuantity * MAX_SCAN_PERCENT))
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
  end

  return accepted
end

function ns.MarketValue.Calculate(records)
  local accepted = TrimHighOutliers(records)
  local average, totalQuantity = WeightedAverage(accepted)

  if average == nil then
    return nil
  end

  local stdDev = WeightedStdDev(accepted, average, totalQuantity)
  local filtered = {}
  local maxDistance = stdDev * STDDEV_FACTOR

  for _, record in ipairs(accepted) do
    if math.abs(record.price - average) <= maxDistance then
      AddAcceptedRecord(filtered, record.price, record.quantity)
    end
  end

  local finalAverage = WeightedAverage(filtered)
  if finalAverage == nil then
    return nil
  end

  return math.floor(finalAverage + 0.5)
end

function ns.MarketValue.CalculateAll(groups)
  local results = {}

  for dbKey, records in pairs(groups) do
    local marketValue = ns.MarketValue.Calculate(records)
    if marketValue ~= nil then
      results[dbKey] = marketValue
    end
  end

  return results
end

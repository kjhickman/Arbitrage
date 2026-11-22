local _, ns = ...

ns.MarketValue = {}

---@class ArbitrageMarketRecord
---@field price number
---@field quantity number

-- An item's auctions with the same unit price added together, so pricing sorts each price once.
---@class ArbitrageMarketListings
---@field prices number[] each unit price once, in no particular order
---@field quantities table<number, number> the total quantity listed at each price

local MIN_SCAN_PERCENT = 0.15
local MAX_SCAN_PERCENT = 0.30
local JUMP_THRESHOLD = 1.20
local STDDEV_FACTOR = 1.5

local function Noop() end

---@param groups table<string, ArbitrageMarketListings>
---@param dbKey string
---@param price number
---@param quantity number
function ns.MarketValue.AddListing(groups, dbKey, price, quantity)
  local listings = groups[dbKey]
  if not listings then
    listings = { prices = {}, quantities = {} }
    groups[dbKey] = listings
  end
  local listed = listings.quantities[price]
  if listed then
    listings.quantities[price] = listed + quantity
  else
    listings.prices[#listings.prices + 1] = price
    listings.quantities[price] = quantity
  end
end

---@param records ArbitrageMarketRecord[]
---@return (number average, number totalQuantity) | (nil)
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

---@param records ArbitrageMarketRecord[]
---@param average number
---@param totalQuantity number
---@return number
local function WeightedStdDev(records, average, totalQuantity)
  local variance = 0

  for _, record in ipairs(records) do
    local distance = record.price - average
    variance = variance + distance * distance * record.quantity
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

-- Auctions at one price never cross the jump threshold between them, so accepting their combined
-- quantity accepts the same as taking them one at a time.
---@param listings ArbitrageMarketListings
---@return ArbitrageMarketRecord[]
local function TrimHighOutliers(listings)
  local prices, quantities = listings.prices, listings.quantities
  table.sort(prices)

  local totalQuantity = 0
  for _, price in ipairs(prices) do
    totalQuantity = totalQuantity + quantities[price]
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

  for _, price in ipairs(prices) do
    if acceptedQuantity >= minQuantity and previousPrice and price >= previousPrice * JUMP_THRESHOLD then
      break
    end

    local remainingQuantity = maxQuantity - acceptedQuantity
    if remainingQuantity <= 0 then
      break
    end

    local quantity = math.min(quantities[price], remainingQuantity)
    AddAcceptedRecord(accepted, price, quantity)
    acceptedQuantity = acceptedQuantity + quantity
    previousPrice = price
  end

  return accepted
end

---@param listings ArbitrageMarketListings
---@return number?
function ns.MarketValue.Calculate(listings)
  local accepted = TrimHighOutliers(listings)
  local average, totalQuantity = WeightedAverage(accepted)

  if average == nil then
    return nil
  end

  local stdDev = WeightedStdDev(accepted, average, totalQuantity)
  ---@type ArbitrageMarketRecord[]
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

-- Checks the frame budget between items rather than prices: an item's passes cost little next to
-- sorting its prices, which can't pause anyway.
---@param groups table<string, ArbitrageMarketListings>
---@param checkpoint ArbitragePricingCheckpoint?
---@return table<string, number>
function ns.MarketValue.CalculateAll(groups, checkpoint)
  local total, completed = 0, 0
  if checkpoint then
    for _ in pairs(groups) do
      total = total + 1
      checkpoint()
    end
  end
  checkpoint = checkpoint or Noop
  local results = {}

  for dbKey, listings in pairs(groups) do
    local marketValue = ns.MarketValue.Calculate(listings)
    if marketValue ~= nil then
      results[dbKey] = marketValue
    end
    completed = completed + 1
    checkpoint(completed, total)
  end

  return results
end

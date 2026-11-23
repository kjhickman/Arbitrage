local _, ns = ...

ns.MarketValue = {}

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

-- Takes the cheapest listings, at least 15% and at most 30% of the quantity listed, stopping early
-- at a price 20% above the one before. Listings at one price never cross that jump between them, so
-- accepting their combined quantity accepts the same as taking them one at a time. Only the last
-- price accepted can be cut short, so the accepted listings are the first prices, with the last
-- one's quantity given separately.
---@param prices number[] sorted
---@param quantities table<number, number>
---@return number count prices accepted, number lastQuantity
local function AcceptCheapest(prices, quantities)
  local totalQuantity = 0
  for _, price in ipairs(prices) do
    totalQuantity = totalQuantity + quantities[price]
  end
  if totalQuantity == 0 then
    return 0, 0
  end

  local minQuantity = math.max(1, math.floor(totalQuantity * MIN_SCAN_PERCENT))
  local maxQuantity = math.max(1, math.floor(totalQuantity * MAX_SCAN_PERCENT))
  local count, lastQuantity = 0, 0
  local acceptedQuantity = 0
  local previousPrice

  for index, price in ipairs(prices) do
    if acceptedQuantity >= minQuantity and previousPrice and price >= previousPrice * JUMP_THRESHOLD then
      break
    end

    local remainingQuantity = maxQuantity - acceptedQuantity
    if remainingQuantity <= 0 then
      break
    end

    local quantity = math.min(quantities[price], remainingQuantity)
    if quantity > 0 then
      count, lastQuantity = index, quantity
    end
    acceptedQuantity = acceptedQuantity + quantity
    previousPrice = price
  end

  return count, lastQuantity
end

-- The weighted average of the accepted listings within maxDistance of center, or of all of them
-- when maxDistance is nil.
---@param prices number[]
---@param quantities table<number, number>
---@param count number
---@param lastQuantity number
---@param center number?
---@param maxDistance number?
---@return (number average, number totalQuantity) | (nil)
local function WeightedAverage(prices, quantities, count, lastQuantity, center, maxDistance)
  local totalValue = 0
  local totalQuantity = 0

  for index = 1, count do
    local price = prices[index]
    if maxDistance == nil or math.abs(price - center) <= maxDistance then
      local quantity = index == count and lastQuantity or quantities[price]
      totalValue = totalValue + price * quantity
      totalQuantity = totalQuantity + quantity
    end
  end

  if totalQuantity == 0 then
    return nil
  end

  return totalValue / totalQuantity, totalQuantity
end

-- Works on the listings in place, so a scan pricing thousands of items allocates nothing per item.
---@param listings ArbitrageMarketListings
---@return number?
function ns.MarketValue.Calculate(listings)
  local prices, quantities = listings.prices, listings.quantities
  table.sort(prices)
  local count, lastQuantity = AcceptCheapest(prices, quantities)
  local average, totalQuantity = WeightedAverage(prices, quantities, count, lastQuantity)

  if average == nil then
    return nil
  end

  local variance = 0
  for index = 1, count do
    local price = prices[index]
    local distance = price - average
    variance = variance + distance * distance * (index == count and lastQuantity or quantities[price])
  end
  local stdDev = math.sqrt(variance / totalQuantity)

  local finalAverage = WeightedAverage(prices, quantities, count, lastQuantity, average, stdDev * STDDEV_FACTOR)
  if finalAverage == nil then
    return nil
  end

  return math.floor(finalAverage + 0.5)
end

-- Checks the frame budget between items rather than prices: an item's passes cost little next to
-- sorting its prices, which can't pause anyway. Each item's listings are released once priced, so
-- a scan doesn't hold them all while it saves.
---@param groups table<string, ArbitrageMarketListings> emptied as it goes
---@param checkpoint ArbitragePricingCheckpoint?
---@return ArbitrageScanColumns columns each item's market value, lowest Buyout, and units
function ns.MarketValue.CalculateAll(groups, checkpoint)
  local total, completed = 0, 0
  if checkpoint then
    for _ in pairs(groups) do
      total = total + 1
      checkpoint()
    end
  end
  checkpoint = checkpoint or Noop
  local keys, marketValues, buyouts, quantities = {}, {}, {}, {}

  local count = 0
  for dbKey, listings in pairs(groups) do
    local marketValue = ns.MarketValue.Calculate(listings)
    -- Pricing sorted the prices, so the first is the lowest Buyout.
    local prices, listed = listings.prices, listings.quantities
    if prices[1] then
      local quantity = 0
      for index = 1, #prices do
        quantity = quantity + listed[prices[index]]
      end
      count = count + 1
      keys[count], marketValues[count], buyouts[count] = dbKey, marketValue or 0, prices[1]
      quantities[count] = quantity
    end
    groups[dbKey] = nil
    completed = completed + 1
    checkpoint(completed, total)
  end

  return { keys = keys, marketValues = marketValues, buyouts = buyouts, quantities = quantities }
end

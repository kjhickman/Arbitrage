local events = {}
local onEvent

function CreateFrame()
  return {
    RegisterEvent = function(_, eventName)
      events[eventName] = true
    end,
    SetScript = function(_, _, callback)
      onEvent = callback
    end,
  }
end

local offers = {
  {
    itemID = 100,
    info = { price = 25, stackCount = 5, numAvailable = -1, isPurchasable = true, hasExtendedCost = false },
  },
  {
    itemID = 100,
    info = { price = 5, stackCount = 1, numAvailable = 1, isPurchasable = true, hasExtendedCost = false },
  },
  {
    itemID = 200,
    info = { price = 10, stackCount = 1, numAvailable = -1, isPurchasable = true, hasExtendedCost = true },
  },
  {
    itemID = 300,
    info = { price = 0, stackCount = 1, numAvailable = -1, isPurchasable = true, hasExtendedCost = false },
  },
  {
    itemID = 400,
    info = { price = 10, stackCount = 1, numAvailable = -1, isPurchasable = false, hasExtendedCost = false },
  },
  {
    itemID = 500,
    info = nil,
  },
}

function GetMerchantNumItems()
  return #offers
end

function GetMerchantItemID(index)
  return offers[index].itemID
end

C_MerchantFrame = {
  GetItemInfo = function(index)
    return offers[index].info
  end,
}

local prices = {}
local ns = {
  Database = {
    RecordVendorPrice = function(itemID, price)
      prices[itemID] = math.min(prices[itemID] or price, price)
    end,
  },
}
assert(loadfile("src/Vendor.lua"), "loads Vendor.lua")("Arbitrage", ns)

ns.Vendor.Register()
assert(events.MERCHANT_SHOW and events.MERCHANT_UPDATE, "registers merchant refresh events")
assert(type(onEvent) == "function", "registers a merchant event handler")

onEvent()
assert(prices[100] == 5, "converts a vendor batch to its per-unit price")
assert(prices[200] == nil, "ignores extended-cost offers")
assert(prices[300] == nil, "ignores free offers")
assert(prices[400] == nil, "ignores unpurchasable offers")
assert(prices[500] == nil, "ignores unavailable merchant info")

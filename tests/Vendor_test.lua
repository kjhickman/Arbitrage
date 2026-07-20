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
  { itemID = 100, price = 25, quantity = 5, available = -1, purchasable = true, extended = false },
  { itemID = 100, price = 5, quantity = 1, available = 1, purchasable = true, extended = false },
  { itemID = 200, price = 10, quantity = 1, available = -1, purchasable = true, extended = true },
  { itemID = 300, price = 0, quantity = 1, available = -1, purchasable = true, extended = false },
  { itemID = 400, price = 10, quantity = 1, available = -1, purchasable = false, extended = false },
}

function GetMerchantNumItems()
  return #offers
end

function GetMerchantItemID(index)
  return offers[index].itemID
end

function GetMerchantItemInfo(index)
  local offer = offers[index]
  return "Item", nil, offer.price, offer.quantity, offer.available, offer.purchasable, true, offer.extended
end

local prices = {}
local ns = {
  Database = {
    RecordVendorPrice = function(itemID, price)
      prices[itemID] = math.min(prices[itemID] or price, price)
    end,
  },
}
assert(loadfile("Vendor.lua"), "loads Vendor.lua")("Arbitrage", ns)

ns.Vendor.Register()
assert(events.MERCHANT_SHOW and events.MERCHANT_UPDATE, "registers merchant refresh events")
assert(type(onEvent) == "function", "registers a merchant event handler")

onEvent()
assert(prices[100] == 5, "converts a vendor batch to its per-unit price")
assert(prices[200] == nil, "ignores extended-cost offers")
assert(prices[300] == nil, "ignores free offers")
assert(prices[400] == nil, "ignores unpurchasable offers")

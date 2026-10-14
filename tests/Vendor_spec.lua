local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Vendor", function()
  local environment
  local ns
  local events
  local onEvent
  local prices

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    events = {}
    onEvent = nil
    prices = {}

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
        info = { price = 10, stackCount = 200, numAvailable = -1, isPurchasable = true, hasExtendedCost = false },
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

    local sellPrices = { [100] = 3, [200] = 0 }
    C_Item = {
      GetItemInfo = function(itemID)
        return nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, sellPrices[itemID]
      end,
    }

    ns = {
      Database = {
        RecordVendorPrice = function(itemID, price)
          prices[itemID] = math.min(prices[itemID] or price, price)
        end,
      },
    }
    assert(loadfile("src/Vendor.lua"), "loads Vendor.lua")("Arbitrage", ns)
  end)

  it("reads per-item sell prices while preserving zero and unknown values", function()
    setfenv(1, environment)
    assert(ns.Vendor.GetSellPrice(100) == 3, "reads the per-item vendor sell price rather than the purchase price")
    assert(ns.Vendor.GetSellPrice(200) == 0, "preserves zero for items that cannot be sold")
    assert(ns.Vendor.GetSellPrice(300) == nil, "leaves uncached sell prices unknown")
  end)

  it("registers merchant refresh events and their handler", function()
    setfenv(1, environment)
    ns.Vendor.Register()
    assert(events.MERCHANT_SHOW and events.MERCHANT_UPDATE, "registers merchant refresh events")
    assert(type(onEvent) == "function", "registers a merchant event handler")
  end)

  it("normalizes batch prices to whole copper per unit", function()
    setfenv(1, environment)
    ns.Vendor.Register()
    onEvent()
    assert(prices[100] == 5, "converts a vendor batch to its per-unit price")
    assert(prices[500] == 1, "rounds a sub-copper per-unit price up to whole copper")
  end)

  it("ignores extended-cost, free, and unpurchasable offers", function()
    setfenv(1, environment)
    ns.Vendor.Register()
    onEvent()
    assert(prices[200] == nil, "ignores extended-cost offers")
    assert(prices[300] == nil, "ignores free offers")
    assert(prices[400] == nil, "ignores unpurchasable offers")
  end)
end)

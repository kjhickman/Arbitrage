local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Vendor opportunity refresh", function()
  local environment
  local harness

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    harness.FindComponents().tab:Click()
  end)

  it("evaluates opportunities when the tab opens", function()
    setfenv(1, environment)
    assert(harness.GetOpportunityCalls() == 1, "evaluates opportunities when the tab opens")
  end)

  it("ignores unrelated item data", function()
    setfenv(1, environment)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    assert(#harness.timers == 0, "does not recalculate sale prices for unrelated item data")
  end)

  it("coalesces loaded vendor prices and reevaluates omitted opportunities", function()
    setfenv(1, environment)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    assert(#harness.timers == 0, "does not recalculate sale prices for unrelated item data")
    harness.pendingSaleItemIDs[300] = true
    harness.pendingSaleItemIDs[301] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 300, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 301, true)
    assert(
      #harness.timers == 1 and harness.GetOpportunityCalls() == 1,
      "coalesces a batch of loaded vendor prices into one refresh"
    )
    harness.RunTimers()
    assert(
      harness.GetOpportunityCalls() == 2,
      "reevaluates previously omitted vendor opportunities after item data loads"
    )
  end)

  it("does not immediately retry failed vendor-price requests", function()
    setfenv(1, environment)
    harness.pendingSaleItemIDs[302] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 302, false)
    assert(#harness.timers == 0, "does not immediately retry failed vendor-price requests")
  end)

  it("can schedule another batch after a completed refresh and a failed request", function()
    setfenv(1, environment)
    harness.pendingSaleItemIDs[300] = true
    harness.pendingSaleItemIDs[301] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 300, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 301, true)
    harness.RunTimers()
    harness.pendingSaleItemIDs[302] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 302, false)
    assert(#harness.timers == 0, "does not immediately retry failed vendor-price requests")
    harness.pendingSaleItemIDs[303] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 303, true)
    assert(#harness.timers == 1, "can schedule another price refresh after the previous batch completes")
  end)
end)

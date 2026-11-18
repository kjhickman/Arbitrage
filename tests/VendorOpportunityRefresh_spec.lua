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

  it("coalesces loaded vendor prices and reevaluates omitted opportunities", function()
    setfenv(1, environment)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    harness.RunAllTimers()
    assert.are.equal(1, harness.GetOpportunityCalls(), "does not recalculate sale prices for unrelated item data")

    harness.pendingSaleItemIDs[300] = true
    harness.pendingSaleItemIDs[301] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 300, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 301, true)
    assert.are.equal(1, harness.GetOpportunityCalls(), "waits for the batch of loaded vendor prices")
    harness.RunAllTimers()
    assert.are.equal(2, harness.GetOpportunityCalls(), "reevaluates a batch of loaded vendor prices once")
  end)

  it("can schedule another batch after a completed refresh", function()
    setfenv(1, environment)
    harness.pendingSaleItemIDs[300] = true
    harness.pendingSaleItemIDs[301] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 300, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 301, true)
    harness.RunAllTimers()
    harness.pendingSaleItemIDs[303] = true
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 303, true)
    harness.RunAllTimers()
    assert.are.equal(3, harness.GetOpportunityCalls(), "reevaluates again after the previous batch completes")
  end)
end)

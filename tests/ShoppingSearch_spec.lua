local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingSearch", function()
  local environment
  local ns, onEvent, registered, delayed, ready, sent, commodities, items, full, moreRequests, changes, chat

  local COPPER_ORE, TIN_ORE, AXE = 30, 31, 50

  local function Fire(eventName, ...)
    assert(registered[eventName], "listens for " .. eventName)
    onEvent(nil, eventName, ...)
  end

  local function RunDelayed()
    local queued = delayed
    delayed = {}
    for _, callback in ipairs(queued) do
      callback()
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    registered, delayed, sent, commodities, items, full, moreRequests = {}, {}, {}, {}, {}, {}, {}
    ready, changes, chat = true, 0, {}

    function CreateFrame()
      return {
        RegisterEvent = function(_, eventName)
          registered[eventName] = true
        end,
        SetScript = function(_, _, callback)
          onEvent = callback
        end,
      }
    end
    C_Timer = {
      After = function(seconds, callback)
        assert.are.equal(2, seconds)
        delayed[#delayed + 1] = callback
      end,
    }
    function print(message)
      chat[#chat + 1] = message
    end
    C_Item = {
      GetItemInfo = function() end,
    }
    function time()
      return 5000
    end
    Enum = { AuctionHouseSortOrder = { Price = 0 } }
    C_AuctionHouse = {
      IsThrottledMessageSystemReady = function()
        return ready
      end,
      MakeItemKey = function(itemID)
        return { itemID = itemID }
      end,
      SendSearchQuery = function(itemKey, sorts, separateOwnerItems)
        assert.are.same({ { sortOrder = 0, reverseSort = false } }, sorts)
        assert.is_false(separateOwnerItems)
        sent[#sent + 1] = itemKey.itemID
      end,
      GetNumCommoditySearchResults = function(itemID)
        return #(commodities[itemID] or {})
      end,
      GetCommoditySearchResultInfo = function(itemID, index)
        return commodities[itemID][index]
      end,
      HasFullCommoditySearchResults = function(itemID)
        return full[itemID] ~= false
      end,
      RequestMoreCommoditySearchResults = function(itemID)
        moreRequests[#moreRequests + 1] = itemID
      end,
      GetNumItemSearchResults = function(itemKey)
        return #(items[itemKey.itemID] or {})
      end,
      GetItemSearchResultInfo = function(itemKey, index)
        return items[itemKey.itemID][index]
      end,
      HasFullItemSearchResults = function(itemKey)
        return full[itemKey.itemID] ~= false
      end,
      RequestMoreItemSearchResults = function(itemKey)
        moreRequests[#moreRequests + 1] = itemKey.itemID
      end,
    }
    ns = {}
    assert(loadfile("src/ShoppingSearch.lua"), "loads ShoppingSearch.lua")("Arbitrage", ns)
    ns.ShoppingSearch.Register()
    ns.ShoppingSearch.OnChange(function()
      changes = changes + 1
    end)
  end)

  it("searches one material at a time and prices what's needed from the cheapest listings", function()
    setfenv(1, environment)
    assert.is_nil(ns.ShoppingSearch.GetRun())
    assert.is_true(
      ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 8 }, { itemID = TIN_ORE, quantity = 3 } })
    )
    assert.are.same({ COPPER_ORE }, sent)
    assert.is_true(ns.ShoppingSearch.IsRunning())
    assert.are.same({ total = 2, done = 0 }, ns.ShoppingSearch.GetRun())
    assert.is_false(ns.ShoppingSearch.Start({ { itemID = AXE, quantity = 1 } }), "lets a running refresh finish")

    -- Another material's results, such as one Blizzard's Buy tab asked for, aren't this search's.
    commodities[TIN_ORE] = { { unitPrice = 30, quantity = 9, numOwnerItems = 0 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", TIN_ORE)
    assert.are.same({ COPPER_ORE }, sent)
    assert.is_nil(ns.ShoppingSearch.Quote(TIN_ORE, 1))

    -- The listings arrive out of order; the cheapest are bought first.
    commodities[COPPER_ORE] = {
      { unitPrice = 2810, quantity = 10, numOwnerItems = 0 },
      { unitPrice = 2630, quantity = 5, numOwnerItems = 0 },
      { unitPrice = 2700, quantity = 2, numOwnerItems = 0 },
    }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.are.same({ COPPER_ORE, TIN_ORE }, sent)
    assert.are.same(
      { cost = 5 * 2630 + 2 * 2700 + 2810, listed = 17, at = 5000 },
      ns.ShoppingSearch.Quote(COPPER_ORE, 8)
    )
    assert.are.equal(1, ns.ShoppingSearch.GetRun().done)

    Fire("COMMODITY_SEARCH_RESULTS_ADDED", TIN_ORE)
    assert.is_false(ns.ShoppingSearch.IsRunning())
    assert.are.same({ total = 2, done = 2, finished = true }, ns.ShoppingSearch.GetRun())
    assert.are.same({ cost = 90, listed = 9, at = 5000 }, ns.ShoppingSearch.Quote(TIN_ORE, 3))
    assert.are.same({}, chat, "says nothing when every search answers")
    -- Started, then each answer.
    assert.are.equal(3, changes)
  end)

  it("waits until the Auction House is ready for each search", function()
    setfenv(1, environment)
    ready = false
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 1 } })
    assert.are.same({}, sent)
    ready = true
    Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    assert.are.same({ COPPER_ORE }, sent)
    Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    assert.are.same({ COPPER_ORE }, sent, "sends nothing more while a search is out")
  end)

  it("leaves out your own auctions and asks for more listings while it's short", function()
    setfenv(1, environment)
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 6 } })
    commodities[COPPER_ORE] = {
      { unitPrice = 20, quantity = 4, numOwnerItems = 4 },
      { unitPrice = 25, quantity = 5, numOwnerItems = 1 },
    }
    full[COPPER_ORE] = false
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.are.same({ COPPER_ORE }, moreRequests)
    assert.is_true(ns.ShoppingSearch.IsRunning())

    commodities[COPPER_ORE][3] = { unitPrice = 26, quantity = 3, numOwnerItems = 0 }
    full[COPPER_ORE] = true
    Fire("COMMODITY_SEARCH_RESULTS_ADDED", COPPER_ORE)
    assert.is_false(ns.ShoppingSearch.IsRunning())
    assert.are.same({ cost = 4 * 25 + 2 * 26, listed = 7, at = 5000 }, ns.ShoppingSearch.Quote(COPPER_ORE, 6))
    -- Fewer listed than asked for costs all of them.
    assert.are.same({ cost = 4 * 25 + 3 * 26, listed = 7, at = 5000 }, ns.ShoppingSearch.Quote(COPPER_ORE, 10))
  end)

  it("quotes only what it searched for unless it fetched every listing", function()
    setfenv(1, environment)
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 2 } })
    commodities[COPPER_ORE] = {
      { unitPrice = 20, quantity = 2, numOwnerItems = 0 },
      { unitPrice = 30, quantity = 1, numOwnerItems = 0 },
    }
    full[COPPER_ORE] = false
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.are.same({}, moreRequests, "had enough for what it searched for")
    assert.are.equal(70, ns.ShoppingSearch.Quote(COPPER_ORE, 3).cost)
    assert.is_nil(ns.ShoppingSearch.Quote(COPPER_ORE, 4), "may be missing listings beyond what it fetched")
    assert.are.equal(20, ns.ShoppingSearch.UnitPrice(COPPER_ORE), "averages over what it searched for")

    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 2 } })
    full[COPPER_ORE] = true
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.are.same({ cost = 70, listed = 3, at = 5000 }, ns.ShoppingSearch.Quote(COPPER_ORE, 4))

    -- None listed has no price to average.
    ns.ShoppingSearch.Start({ { itemID = TIN_ORE, quantity = 1 } })
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", TIN_ORE)
    assert.is_nil(ns.ShoppingSearch.UnitPrice(TIN_ORE))
    assert.is_nil(ns.ShoppingSearch.UnitPrice(AXE))
  end)

  it("says when every search has answered or given up, but not when the Auction House closes", function()
    setfenv(1, environment)
    local finished = 0
    local function OnFinished()
      finished = finished + 1
    end
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 1 }, { itemID = TIN_ORE, quantity = 1 } }, OnFinished)
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.are.equal(0, finished)
    -- Tin Ore never answers, even when sent again.
    RunDelayed()
    RunDelayed()
    assert.are.equal(1, finished)

    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 1 } }, OnFinished)
    Fire("AUCTION_HOUSE_CLOSED")
    RunDelayed()
    assert.are.equal(1, finished)
  end)

  it("prices anything that isn't a commodity from its auctions' buyouts", function()
    setfenv(1, environment)
    ns.ShoppingSearch.Start({ { itemID = AXE, quantity = 3 } })
    items[AXE] = {
      { quantity = 1, buyoutAmount = 500, containsOwnerItem = false },
      { quantity = 2, buyoutAmount = 900, containsOwnerItem = false },
      { quantity = 1, buyoutAmount = 100, containsOwnerItem = true },
      { quantity = 1, minBid = 50, containsOwnerItem = false },
    }
    Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = AXE }, nil)
    assert.are.same({ cost = 2 * 450 + 500, listed = 3, at = 5000 }, ns.ShoppingSearch.Quote(AXE, 3))
  end)

  it("sends a search the server doesn't answer once more, then says so in chat and moves on", function()
    setfenv(1, environment)
    C_Item = {
      GetItemInfo = function(itemID)
        if itemID == COPPER_ORE then
          return "Copper Ore", "[Copper Ore]"
        end
      end,
    }
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 1 }, { itemID = TIN_ORE, quantity = 1 } })
    RunDelayed()
    assert.are.same({ COPPER_ORE, COPPER_ORE }, sent, "tries again after 2 seconds")
    assert.are.equal(0, ns.ShoppingSearch.GetRun().done)
    RunDelayed()
    assert.are.same({ COPPER_ORE, COPPER_ORE, TIN_ORE }, sent)
    assert.are.equal(1, ns.ShoppingSearch.GetRun().done)
    assert.are.same(
      { "|cff00ccffArbitrage:|r Couldn't refresh the price of [Copper Ore]: the Auction House didn't answer." },
      chat
    )

    -- A late answer to the abandoned search changes nothing; the timer of an answered one neither.
    commodities[COPPER_ORE] = { { unitPrice = 20, quantity = 1, numOwnerItems = 0 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    assert.is_nil(ns.ShoppingSearch.Quote(COPPER_ORE, 1))
    commodities[TIN_ORE] = { { unitPrice = 30, quantity = 1, numOwnerItems = 0 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", TIN_ORE)
    RunDelayed()
    assert.are.equal(2, ns.ShoppingSearch.GetRun().done)
    assert.is_false(ns.ShoppingSearch.IsRunning())

    -- Answered on its second try, a search counts like any other; an unloaded item goes by its ID.
    C_Item.GetItemInfo = function() end
    ns.ShoppingSearch.Start({ { itemID = TIN_ORE, quantity = 1 }, { itemID = AXE, quantity = 1 } })
    RunDelayed()
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", TIN_ORE)
    RunDelayed()
    RunDelayed()
    assert.are.equal(
      "|cff00ccffArbitrage:|r Couldn't refresh the price of item 50: the Auction House didn't answer.",
      chat[2]
    )
    assert.are.equal(2, #chat)
  end)

  it("stops when the Auction House closes", function()
    setfenv(1, environment)
    ns.ShoppingSearch.Start({ { itemID = COPPER_ORE, quantity = 1 }, { itemID = TIN_ORE, quantity = 1 } })
    Fire("AUCTION_HOUSE_CLOSED")
    assert.is_false(ns.ShoppingSearch.IsRunning())
    assert.is_true(ns.ShoppingSearch.GetRun().stopped)
    assert.are.same({ "|cff00ccffArbitrage:|r Stopped refreshing prices: the Auction House closed." }, chat)
    Fire("AUCTION_HOUSE_CLOSED")
    assert.are.equal(1, #chat, "says nothing when no refresh is running")

    commodities[COPPER_ORE] = { { unitPrice = 20, quantity = 1, numOwnerItems = 0 } }
    Fire("COMMODITY_SEARCH_RESULTS_UPDATED", COPPER_ORE)
    Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    RunDelayed()
    assert.are.same({ COPPER_ORE }, sent)
    assert.is_nil(ns.ShoppingSearch.Quote(COPPER_ORE, 1))
    assert.is_false(ns.ShoppingSearch.Start({}), "has nothing to search")
  end)
end)

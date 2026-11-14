local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Scan", function()
  local environment
  local ns
  local onEvent
  local onUpdate
  local replicateHook
  local rows
  local rowCount
  local requestedIndexes
  local requestedLinkIndexes
  local timers
  local itemLoadRequests
  local messages
  local events
  local mapID
  local selectedMarket
  local profileTime
  local profileStep
  local currentTime
  local lastReplicateScan
  local throttleReady
  local auctionHouseShown
  local replicateCalls
  local processed
  local rawCounts
  local needsLink
  local itemExists

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    onUpdate = nil
    replicateHook = nil
    rows = {}
    rowCount = 0
    requestedIndexes = {}
    requestedLinkIndexes = {}
    timers = {}
    itemLoadRequests = {}
    messages = {}
    events = {}
    mapID = 1453
    selectedMarket = nil
    profileTime = 0
    profileStep = 0
    currentTime = 1000
    lastReplicateScan = nil
    throttleReady = true
    auctionHouseShown = true
    replicateCalls = 0
    processed = {}
    rawCounts = {}
    -- Linkless rows are gear unless a test says otherwise, so the existing
    -- item-link cases keep exercising the wait-and-retry path.
    needsLink = function()
      return true
    end
    itemExists = function()
      return true
    end

    function CreateFrame()
      return {
        RegisterEvent = function(_, eventName)
          events[eventName] = true
        end,
        SetScript = function(_, scriptName, callback)
          if scriptName == "OnEvent" then
            onEvent = callback
          elseif scriptName == "OnUpdate" then
            onUpdate = callback
          end
        end,
      }
    end

    function debugprofilestop()
      local result = profileTime
      profileTime = profileTime + profileStep
      return result
    end

    function hooksecurefunc(target, methodName, callback)
      assert(target == C_AuctionHouse and methodName == "ReplicateItems", "hooks native replication")
      replicateHook = callback
    end

    function print(message)
      messages[#messages + 1] = message
    end

    function UnitFactionGroup()
      return "Alliance"
    end

    function time()
      return currentTime
    end

    AuctionHouseFrame = {
      IsShown = function()
        return auctionHouseShown
      end,
    }

    C_AuctionHouse = {
      GetNumReplicateItems = function()
        return rowCount
      end,
      GetReplicateItemInfo = function(index)
        local row = assert(rows[index], "uses zero-based replicate indexes")
        requestedIndexes[#requestedIndexes + 1] = index
        return row.name,
          nil,
          row.quantity,
          nil,
          nil,
          nil,
          nil,
          nil,
          nil,
          row.buyout,
          nil,
          nil,
          nil,
          nil,
          nil,
          nil,
          row.itemID,
          row.hasAllInfo
      end,
      GetReplicateItemLink = function(index)
        requestedLinkIndexes[#requestedLinkIndexes + 1] = index
        return assert(rows[index], "uses zero-based link indexes").itemLink
      end,
      IsThrottledMessageSystemReady = function()
        return throttleReady
      end,
      ReplicateItems = function()
        replicateCalls = replicateCalls + 1
        if replicateHook then
          replicateHook()
        end
      end,
    }

    C_Item = {
      DoesItemExistByID = function(itemID)
        return itemExists(itemID)
      end,
      RequestLoadItemDataByID = function(itemID)
        itemLoadRequests[itemID] = (itemLoadRequests[itemID] or 0) + 1
      end,
    }

    C_Map = {
      GetBestMapForUnit = function()
        return mapID
      end,
    }

    C_Timer = {
      After = function(delay, callback)
        timers[#timers + 1] = { delay = delay, callback = callback }
      end,
    }

    ns = {
      Keys = {
        NeedsLink = function(itemID)
          return needsLink(itemID)
        end,
      },
      Database = {
        GetLastReplicateScan = function()
          return lastReplicateScan
        end,
        RecordReplicateScan = function(timestamp)
          lastReplicateScan = timestamp
        end,
        SetMarket = function(market)
          selectedMarket = market
        end,
      },
    }
    assert(loadfile("src/Scan.lua"), "loads Scan.lua")("Arbitrage", ns)

    ns.Scan.Init(function(data, rawCount, checkpoint)
      checkpoint()
      processed[#processed + 1] = data
      rawCounts[#rawCounts + 1] = rawCount
    end)
  end)

  it("registers replication and Auction House lifecycle events", function()
    setfenv(1, environment)
    assert(events.REPLICATE_ITEM_LIST_UPDATE, "registers the replication result event")
    assert(events.ITEM_DATA_LOAD_RESULT, "registers the item-data load event")
    assert(events.AUCTION_HOUSE_SHOW and events.AUCTION_HOUSE_CLOSED, "registers Auction House lifecycle events")
  end)

  it("selects faction and neutral markets when the Auction House opens", function()
    setfenv(1, environment)
    onEvent(nil, "AUCTION_HOUSE_SHOW")
    assert(selectedMarket == "Alliance", "selects the faction Auction House market")
    mapID = 1446
    onEvent(nil, "AUCTION_HOUSE_SHOW")
    assert(selectedMarket == "Neutral", "selects the neutral Tanaris Auction House market")
  end)

  local function GetLastTimer(delay)
    for index = #timers, 1, -1 do
      if timers[index].delay == delay then
        return timers[index]
      end
    end
  end

  local function RunWorker()
    onUpdate()
  end

  local function FillRows(count)
    for index = 0, count - 1 do
      rows[index] = {
        name = "Item " .. index,
        quantity = 1,
        buyout = index + 1,
        itemID = index + 1,
        itemLink = "item:" .. (index + 1),
      }
    end
    rowCount = count
  end

  local function RunWorkerUntilProcessed(maxFrames)
    for _ = 1, maxFrames do
      RunWorker()
      if #processed > 0 then
        return
      end
    end
    error("worker did not finish within " .. maxFrames .. " frames")
  end

  local function CountMessages(text)
    local matches = 0
    for _, message in ipairs(messages) do
      if message:find(text, 1, true) then
        matches = matches + 1
      end
    end
    return matches
  end

  it("processes an external replication once using zero-based rows", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
      [1] = { name = "Two", quantity = 2, buyout = 300, itemID = 200, itemLink = "item:200" },
    }
    rowCount = 2
    C_AuctionHouse.ReplicateItems()
    assert(lastReplicateScan == currentTime, "records an external replication attempt against the cooldown")
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    assert(lastReplicateScan == currentTime, "records a successful external replication")
    RunWorker()

    assert(#processed == 1 and #processed[1] == 2, "processes an external replication")
    assert(rawCounts[1] == 2, "reports the raw replication row count")
    assert(requestedIndexes[1] == 0 and requestedIndexes[2] == 1, "reads zero-based replication rows")
    assert(processed[1][2].quantity == 2 and processed[1][2].buyout == 300, "normalizes replication data")
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#processed == 1, "ignores repeated item-cache replication events")
  end)

  it("processes an owned replication without treating it as external", function()
    setfenv(1, environment)
    rows[0] = { name = "Owned", quantity = 1, buyout = 700, itemID = 300, itemLink = "item:300" }
    rowCount = 1
    ns.Scan.Start()
    assert(replicateCalls == 1, "starts native replication")
    assert(lastReplicateScan == currentTime, "records an Arbitrage replication attempt against the cooldown")
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    assert(lastReplicateScan == currentTime, "records a successful Arbitrage replication")
    RunWorker()
    assert(#processed == 1 and processed[1][1].itemLink == "item:300", "does not treat its own call as external")
  end)

  it("collects at most 500 replication rows per frame", function()
    setfenv(1, environment)
    for index = 0, 500 do
      rows[index] = {
        name = "Item " .. index,
        quantity = 1,
        buyout = index + 1,
        itemID = index + 1,
        itemLink = "item:" .. (index + 1),
      }
    end
    rowCount = 501
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#requestedIndexes == 500 and #processed == 0, "limits replicate accessors to 500 rows per frame")
    RunWorker()
    assert(#requestedIndexes == 501 and #processed == 1, "resumes batched replication on the next frame")
  end)

  it("reports collection progress every 25000 auctions", function()
    setfenv(1, environment)
    FillRows(25001)
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorkerUntilProcessed(100)

    assert(CountMessages("Read 25000 of 25001 auctions") == 1, "reports a milestone once per 25000 rows")
    assert(CountMessages("Read 25001 of 25001 auctions") == 0, "does not repeat the total as a milestone")
    assert(messages[#messages]:find("Read 25001 usable auctions", 1, true), "reports the usable total before pricing")
  end)

  it("stays quiet about collection progress during an external replication", function()
    setfenv(1, environment)
    FillRows(25001)
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorkerUntilProcessed(100)

    assert(#messages == 0, "leaves another addon's replication unannounced")
  end)

  it("resumes collection after reaching the per-frame time budget", function()
    setfenv(1, environment)
    for index = 0, 2 do
      rows[index] = {
        name = "Item " .. index,
        quantity = 1,
        buyout = index + 1,
        itemID = index + 1,
        itemLink = "item:" .. (index + 1),
      }
    end
    rowCount = 3
    profileStep = 5
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#requestedIndexes == 1 and #processed == 0, "honors the per-frame time budget")
    profileStep = 0
    RunWorker()
    assert(#requestedIndexes == 3 and #processed == 1, "resumes time-sliced collection")
  end)

  it("keys suffix-free rows from the item ID without waiting for a link", function()
    setfenv(1, environment)
    needsLink = function()
      return false
    end
    rows[0] = { name = "Copper Ore", quantity = 20, buyout = 1000, itemID = 2770 }
    rowCount = 1
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()

    assert(#processed == 1 and #processed[1] == 1, "collects a linkless row immediately")
    assert(processed[1][1].itemID == 2770, "carries the item ID for keying")
    assert(processed[1][1].itemLink == nil, "does not invent a link")
    assert(next(itemLoadRequests) == nil, "does not queue item data it will not use")
    assert(GetLastTimer(2) == nil, "does not arm an item-link deadline")
  end)

  it("waits only on the rows whose keys need a link", function()
    setfenv(1, environment)
    needsLink = function(itemID)
      return itemID == 800
    end
    rows = {
      [0] = { name = "Ore", quantity = 20, buyout = 1000, itemID = 2770 },
      [1] = { name = "Sword", quantity = 1, buyout = 5000, itemID = 800 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()

    assert(#processed == 0, "still waits for the gear row")
    assert(itemLoadRequests[800] == 1 and itemLoadRequests[2770] == nil, "queues item data for gear only")
    rows[1].itemLink = "item:800"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 800, true)
    RunWorker()
    assert(#processed == 1 and #processed[1] == 2, "collects both rows once the gear link arrives")
  end)

  it("deduplicates item loads and rechecks every pending row", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Slow One", quantity = 1, buyout = 100, itemID = 400 },
      [1] = { name = "Slow Two", quantity = 2, buyout = 300, itemID = 400 },
    }
    rowCount = 2
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(itemLoadRequests[400] == 1, "deduplicates item-load requests")
    assert(#processed == 0, "waits for missing item links")
    rows[0].itemLink = "item:400"
    rows[1].itemLink = "item:400"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 400, true)
    RunWorker()
    assert(#processed == 1 and #processed[1] == 2, "re-reads rows after their item data loads")
    assert(#requestedIndexes == 4, "verifies every pending row in a second pass")
  end)

  it("re-requests unresolved item IDs every 0.4 seconds", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Resolved", quantity = 1, buyout = 100, itemID = 800 },
      [1] = { name = "Dropped", quantity = 1, buyout = 100, itemID = 801 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(itemLoadRequests[800] == 1 and itemLoadRequests[801] == 1, "requests each pending item once initially")

    rows[0].itemLink = "item:800"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 800, true)
    RunWorker()
    assert(#processed == 0, "keeps waiting for the remaining pending item")

    local itemRetry = assert(GetLastTimer(0.4), "schedules a 0.4-second item-load retry")
    rows[1].itemLink = "item:801"
    itemRetry.callback()
    assert(itemLoadRequests[800] == 1, "does not re-request an already resolved item")
    assert(itemLoadRequests[801] == 2, "re-requests the still-pending item")
    RunWorker()
    assert(#processed == 1 and #processed[1] == 2, "collects the remaining row after the retry")
  end)

  it("keeps valid rows and silently drops item links that time out after 2 seconds", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 499, itemLink = "item:499" },
      [1] = { name = "Slow", quantity = 1, buyout = 100, itemID = 500 },
      [2] = { name = "Also Slow", quantity = 1, buyout = 100, itemID = 501 },
    }
    rowCount = 3
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(messages[#messages]:find("Waiting for item data on 2 auctions", 1, true), "reports the waiting rows")
    local itemTimeout = assert(GetLastTimer(2), "starts a 2-second item-link timeout")
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 500, true)
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 501, true)
    RunWorker()
    assert(#processed == 0, "keeps retrying when a loaded item link remains unavailable")
    itemTimeout.callback()
    RunWorker()
    assert(#processed == 1 and #processed[1] == 1, "keeps valid rows when item links time out")
    assert(CountMessages("skipped") == 0, "does not spam chat with skipped item IDs")
    assert(messages[#messages]:find("Read 1 usable auctions", 1, true), "reports the usable auction count")
    rows[1].itemLink = "item:500"
    rows[2].itemLink = "item:501"
    RunWorker()
    assert(#processed == 1, "does not resume retries after completing a timed-out scan")
  end)

  it("recovers transiently unavailable links during the retry window", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 599, itemLink = "item:599" },
      [1] = { name = "Linkless", quantity = 1, buyout = 100, itemID = 600 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 600, true)
    RunWorker()
    assert(#processed == 0, "does not discard a link that is transiently unavailable after item load")
    rows[1].itemLink = "item:600"
    local itemRetry = assert(GetLastTimer(0.4), "schedules a throttled item-link retry")
    itemRetry.callback()
    RunWorker()
    assert(#processed == 1 and #processed[1] == 2, "includes a link that becomes available during the retry window")
    assert(processed[1][2].itemLink == "item:600", "keeps the recovered row")
  end)

  it("skips changed pending rows and keeps valid rows", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 699, itemLink = "item:699" },
      [1] = { name = "Changed", quantity = 1, buyout = 100, itemID = 700 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    rows[1] = { name = "Replacement", quantity = 1, buyout = 200, itemID = 701, itemLink = "item:701" }
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 700, true)
    RunWorker()
    assert(#processed == 1 and #processed[1] == 1, "keeps valid rows when a pending row changes")
    assert(processed[1][1].itemLink == "item:699", "skips the changed row")
    assert(CountMessages("skipped") == 0, "does not report skipped rows in chat")
  end)

  it("filters bid-only, malformed, and non-existent item rows while keeping valid auctions", function()
    setfenv(1, environment)
    itemExists = function(itemID)
      return itemID ~= 703
    end
    rows = {
      [0] = { name = "Valid", quantity = 5, buyout = 500, itemID = 700, itemLink = "item:700" },
      [1] = { name = "Bid Only", quantity = 1, buyout = 0, itemID = 701, itemLink = "item:701" },
      [2] = { name = "Bad Quantity", quantity = 0 / 0, buyout = 200, itemID = 702, itemLink = "item:702" },
      [3] = { name = "No Identity", quantity = 1, buyout = 300 },
      [4] = { name = "Missing Item", quantity = 1, buyout = 300, itemID = 703 },
    }
    rowCount = 5
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#processed == 1 and #processed[1] == 1, "filters bid-only, malformed, and non-existent item rows")
    assert(processed[1][1].itemLink == "item:700", "keeps valid rows")
    assert(next(itemLoadRequests) == nil, "does not request item data for a non-existent item")
  end)

  it("reports response timeouts and ignores late replication results", function()
    setfenv(1, environment)
    ns.Scan.Start()
    local responseTimeout = assert(GetLastTimer(30), "starts a replication response timeout")
    responseTimeout.callback()
    assert(messages[#messages]:find("no Auction House response after 30 seconds", 1, true), "reports response timeout")
    currentTime = 2000
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#processed == 0 and lastReplicateScan == 1000, "ignores responses after timeout")
  end)

  it("fails fast when the Auction House drops the throttled request", function()
    setfenv(1, environment)
    assert(events.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED, "registers the dropped-request event")
    ns.Scan.Start()
    onEvent(nil, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert(messages[#messages]:find("throttled the request", 1, true), "reports the dropped request")
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#processed == 0, "ignores a response that arrives after a dropped request")
  end)

  it("ignores a dropped throttled request outside a scan", function()
    setfenv(1, environment)
    onEvent(nil, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert(#messages == 0, "stays quiet when no scan is waiting")
  end)

  it("cancels owned collection when the Auction House closes", function()
    setfenv(1, environment)
    rows[0] = { name = "Cancelled", quantity = 1, buyout = 100, itemID = 800, itemLink = "item:800" }
    rowCount = 1
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    onEvent(nil, "AUCTION_HOUSE_CLOSED")
    RunWorker()
    assert(#processed == 0, "cancels collection when the Auction House closes")
    assert(messages[#messages]:find("Auction House closed", 1, true), "reports an owned scan cancellation")
  end)

  it("estimates the remaining local replication cooldown", function()
    setfenv(1, environment)
    lastReplicateScan = 1000
    currentTime = 1451
    ns.Scan.Start()
    assert(replicateCalls == 0, "does not call replication during the local cooldown")
    assert(messages[#messages]:find("best guess: try again in 8 minutes", 1, true), "estimates remaining cooldown")
  end)

  it("does not replicate while the Auction House throttle is busy", function()
    setfenv(1, environment)
    throttleReady = false
    ns.Scan.Start()
    assert(replicateCalls == 0, "does not send while the Auction House throttle is busy")
    assert(messages[#messages]:find("Auction House is busy", 1, true), "reports the throttle state")
  end)

  it("requires an open Auction House before replicating", function()
    setfenv(1, environment)
    auctionHouseShown = false
    ns.Scan.Start()
    assert(replicateCalls == 0, "requires an open Auction House")
    assert(messages[#messages]:find("Open the Auction House", 1, true), "reports the open-window requirement")
  end)
end)

local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Scan", function()
  local environment
  local ns
  local onEvent
  local onUpdate
  local hooks
  local browseQueries
  local browseResults
  local fullBrowseResults
  local requestedPages
  local quickSnapshots
  local auctionatorListener
  local queuedAuctionatorQuery
  local queueAuctionatorQuery
  local rows
  local rowCount
  local requestedIndexes
  local requestedLinkIndexes
  local timers
  local itemLoadRequests
  local messages
  local events
  local mapID
  local profileTime
  local profileStep
  local scanWorkBudget
  local currentTime
  local lastReplicateScan
  local throttleReady
  local auctionHouseShown
  local replicateCalls
  local processed
  local rawCounts
  local statusHistory
  local needsLink
  local itemExists
  local itemNames

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    onUpdate = nil
    hooks = {}
    browseQueries = {}
    browseResults = {}
    fullBrowseResults = false
    requestedPages = 0
    quickSnapshots = {}
    auctionatorListener = nil
    queuedAuctionatorQuery = nil
    queueAuctionatorQuery = false
    rows = {}
    rowCount = 0
    requestedIndexes = {}
    requestedLinkIndexes = {}
    timers = {}
    itemLoadRequests = {}
    messages = {}
    events = {}
    mapID = 1453
    profileTime = 0
    profileStep = 0
    scanWorkBudget = 10
    currentTime = 1000
    lastReplicateScan = nil
    throttleReady = true
    auctionHouseShown = true
    replicateCalls = 0
    processed = {}
    rawCounts = {}
    statusHistory = {}
    -- Linkless rows are gear unless a test says otherwise, so the existing
    -- item-link cases keep exercising the wait-and-retry path.
    needsLink = function()
      return true
    end
    itemExists = function()
      return true
    end
    itemNames = {}

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
      hooks[target] = hooks[target] or {}
      hooks[target][methodName] = callback
    end

    function print(message)
      messages[#messages + 1] = message
    end

    function time()
      return currentTime
    end

    AuctionHouseFrame = {
      IsShown = function()
        return auctionHouseShown
      end,
    }

    Enum = { ItemQuality = { Poor = 0 } }
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
          row.quality or 1,
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
        hooks[C_AuctionHouse].ReplicateItems()
      end,
      SendBrowseQuery = function(query)
        browseQueries[#browseQueries + 1] = query
        hooks[C_AuctionHouse].SendBrowseQuery(query)
      end,
      RequestMoreBrowseResults = function()
        requestedPages = requestedPages + 1
      end,
      HasFullBrowseResults = function()
        return fullBrowseResults
      end,
      GetBrowseResults = function()
        assert.is_true(fullBrowseResults, "only reads the cumulative result list after the final page")
        return { unpack(browseResults) }
      end,
      GetItemKeyInfo = function(itemKey)
        return { quality = itemKey.quality or 1 }
      end,
    }

    Auctionator = {
      IncrementalScan = {
        Events = { ScanStart = "start", ScanComplete = "finish", ScanFailed = "fail" },
      },
      EventBus = {
        Register = function(_, listener, names)
          assert.are.same({ "start", "finish", "fail" }, names)
          auctionatorListener = listener
        end,
      },
      AH = {
        SendBrowseQuery = function(query)
          if queueAuctionatorQuery then
            queuedAuctionatorQuery = query
          else
            C_AuctionHouse.SendBrowseQuery(query)
          end
          hooks[Auctionator.AH].SendBrowseQuery(query)
        end,
      },
    }

    C_Item = {
      IsItemDataCachedByID = function()
        return false
      end,
      DoesItemExistByID = function(itemID)
        return itemExists(itemID)
      end,
      GetItemInfo = function(itemID)
        return itemNames[itemID]
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
      Config = {
        Get = function(key)
          assert.are.equal("scanWorkBudget", key)
          return scanWorkBudget
        end,
      },
      OpportunityPanel = {
        RefreshScanStatus = function()
          statusHistory[#statusHistory + 1] = ns.Scan.GetStatus()
        end,
      },
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
      },
    }
    assert(loadfile("src/Scan.lua"), "loads Scan.lua")("Arbitrage", ns)

    ns.Scan.Init(function()
      local data = {}
      return {
        Add = function(entry)
          data[#data + 1] = entry
        end,
        Finish = function(rawCount, checkpoint)
          checkpoint(42.4)
          checkpoint(42.9)
          processed[#processed + 1] = data
          rawCounts[#rawCounts + 1] = rawCount
          return "Full scan done: test"
        end,
      }
    end, function(buyouts, observedAt)
      quickSnapshots[#quickSnapshots + 1] = { buyouts = buyouts, at = observedAt }
      return true
    end)
  end)

  it("registers replication and Auction House lifecycle events", function()
    setfenv(1, environment)
    assert(events.REPLICATE_ITEM_LIST_UPDATE, "registers the replication result event")
    assert(events.ITEM_DATA_LOAD_RESULT, "registers the item-data load event")
    assert(events.AUCTION_HOUSE_CLOSED, "registers the Auction House closing event")
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

  local function BrowseRow(itemID, minPrice, quantity)
    return { itemKey = { itemID = itemID, battlePetSpeciesID = 0 }, minPrice = minPrice, totalQuantity = quantity }
  end

  it("ignores grey listings in Quick Scans without discarding Common items", function()
    setfenv(1, environment)
    ns.Scan.StartQuick()
    fullBrowseResults = true
    local grey = BrowseRow(10, 1, 1)
    grey.itemKey.quality = Enum.ItemQuality.Poor
    browseResults = { grey, BrowseRow(20, 2, 1) }
    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    RunWorker()
    assert.are.same({ { at = currentTime, buyouts = { ["20"] = 2 } } }, quickSnapshots)
  end)

  it("skips grey items before requesting links and when uncached quality arrives", function()
    setfenv(1, environment)
    rows = {
      [0] = { itemID = 10, quantity = 1, buyout = 1, quality = Enum.ItemQuality.Poor },
      [1] = { itemID = 20, quantity = 1, buyout = 2, quality = -1 },
      [2] = { itemID = 30, quantity = 1, buyout = 3, itemLink = "item:30" },
    }
    rowCount = 3
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert.are.same({ 1, 2 }, requestedLinkIndexes)
    assert.are.same({ [20] = 1 }, itemLoadRequests)
    rows[1].quality = Enum.ItemQuality.Poor
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 20, true)
    RunWorker()
    assert.are.same({ 1, 2 }, requestedLinkIndexes)
    assert.are.equal(1, #processed)
    assert.are.same({ { itemLink = "item:30", quantity = 1, buyout = 3 } }, processed[1])
  end)

  it("uses every browse page but only commits per-unit minimums after all pages arrive", function()
    setfenv(1, environment)
    lastReplicateScan = 980
    itemExists = function(itemID)
      return itemID ~= 777
    end
    ns.Scan.StartQuick()
    assert.are.same({ { searchString = "", sorts = {}, filters = {}, itemClassFilters = {} } }, browseQueries)
    assert.are.equal("quick", ns.Scan.GetStatus().kind)
    assert.are.equal(980, lastReplicateScan)

    browseResults = { BrowseRow(2589, 300, 12), BrowseRow(4306, 10, 20), BrowseRow(999, 3, 1) }
    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    throttleReady = false
    RunWorker()
    assert.are.equal(0, requestedPages)
    assert.are.same({}, quickSnapshots)
    throttleReady = true
    RunWorker()
    RunWorker()
    assert.are.equal(1, requestedPages, "doesn't ask again before the page comes back")

    currentTime = 1020
    fullBrowseResults = true
    local pet = BrowseRow(808, 2, 1)
    pet.itemKey.battlePetSpeciesID = 50
    local added = {
      BrowseRow(2589, 200, 4),
      BrowseRow(50, 0, 1),
      BrowseRow(51, 9, 0),
      BrowseRow(777, 5, 1),
      pet,
    }
    for _, row in ipairs(added) do
      browseResults[#browseResults + 1] = row
    end
    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", added)
    assert.are.same({}, quickSnapshots, "nothing reads a partial price map")
    onEvent(nil, "AUCTION_HOUSE_CLOSED") -- safe once all pages have arrived
    RunWorker()
    assert.are.same({ { at = 1020, buyouts = { ["2589"] = 200, ["4306"] = 10, ["999"] = 3 } } }, quickSnapshots)
    assert.are.same({}, processed)
    assert.are.equal(0, replicateCalls)
    assert.are.equal(980, lastReplicateScan)
    assert.are.equal("idle", ns.Scan.GetStatus().phase)
    assert.is_nil(ns.Scan.GetLastOutcome())
    assert.are.equal("Quick scan done: refreshed Buyouts for 3 items", ns.Scan.GetLastOutcome("quick").message)
  end)

  it("does not start quick scans outside a faction Auction House or while the server is busy", function()
    setfenv(1, environment)
    auctionHouseShown = false
    ns.Scan.StartQuick()
    auctionHouseShown = true
    mapID = 1434
    ns.Scan.StartQuick()
    mapID = 1453
    throttleReady = false
    ns.Scan.StartQuick()
    assert.are.same({}, browseQueries)
    assert.are.equal("idle", ns.Scan.GetStatus().phase)
  end)

  it("discards interrupted or timed-out browse data and ignores later results", function()
    setfenv(1, environment)
    local function ReadPartial()
      ns.Scan.StartQuick()
      browseResults = { BrowseRow(2589, 123, 10) }
      fullBrowseResults = false
      onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end

    local function CheckStopped()
      fullBrowseResults = true
      onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { BrowseRow(4306, 9, 1) })
      RunWorker()
      assert.are.same({}, quickSnapshots)
      assert.are.equal("idle", ns.Scan.GetStatus().phase)
      assert.is_nil(lastReplicateScan)
    end

    ReadPartial()
    ns.Scan.Cancel()
    CheckStopped()
    ReadPartial()
    onEvent(nil, "AUCTION_HOUSE_BROWSE_FAILURE")
    CheckStopped()
    ReadPartial()
    onEvent(nil, "AUCTION_HOUSE_CLOSED")
    CheckStopped()
    ReadPartial()
    C_AuctionHouse.SendBrowseQuery({ searchString = "Linen Cloth" })
    CheckStopped()
    ReadPartial()
    currentTime = currentTime + 60
    RunWorker()
    CheckStopped()
    assert.are.equal(
      "Quick scan incomplete: timed out waiting for browse results; previous data kept",
      ns.Scan.GetLastOutcome("quick").message
    )
  end)

  it("abandons its own quick scan when another addon starts a full scan", function()
    setfenv(1, environment)
    ns.Scan.StartQuick()
    ns.Scan.Start()
    assert.are.equal(0, replicateCalls)
    C_AuctionHouse.ReplicateItems()
    assert.are.equal("full", ns.Scan.GetStatus().kind)
    assert.are.equal(currentTime, lastReplicateScan)
    assert.are.same({}, quickSnapshots)
  end)

  it("consumes Auctionator's completed summary only, without issuing or paging a query", function()
    setfenv(1, environment)
    auctionatorListener:ReceiveEvent("finish", { BrowseRow(2589, 500, 2) })
    queueAuctionatorQuery = true
    Auctionator.AH.SendBrowseQuery({ searchString = "" })
    auctionatorListener:ReceiveEvent("start")
    assert.are.same({}, browseQueries)

    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") -- stale result while the query is still queued
    auctionatorListener:ReceiveEvent("finish", { BrowseRow(2589, 500, 2) })
    C_AuctionHouse.SendBrowseQuery(queuedAuctionatorQuery)
    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    RunWorker()
    assert.are.equal(0, requestedPages)
    assert.are.same({}, quickSnapshots)

    fullBrowseResults = true
    currentTime = 1025
    onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})
    currentTime = 1026
    auctionatorListener:ReceiveEvent("finish", { BrowseRow(2589, 125, 4) })
    RunWorker()
    assert.are.same({ { at = 1025, buyouts = { ["2589"] = 125 } } }, quickSnapshots)
    assert.are.equal(1, #browseQueries)
    assert.are.equal(0, requestedPages)
    assert.are.equal(0, replicateCalls)
    assert.is_nil(lastReplicateScan)
  end)

  it("ignores Auctionator's neutral scans and cancelled summary results", function()
    setfenv(1, environment)
    local function StartExternal()
      Auctionator.AH.SendBrowseQuery({ searchString = "" })
      auctionatorListener:ReceiveEvent("start")
      fullBrowseResults = true
      onEvent(nil, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end

    mapID = 1434
    StartExternal()
    auctionatorListener:ReceiveEvent("finish", { BrowseRow(2589, 500, 2) })
    RunWorker()
    assert.are.equal("idle", ns.Scan.GetStatus().phase)
    assert.are.same({}, quickSnapshots)

    mapID = 1453
    StartExternal()
    assert.are.equal("quick", ns.Scan.GetStatus().kind)
    auctionatorListener:ReceiveEvent("fail")
    auctionatorListener:ReceiveEvent("finish", { BrowseRow(2589, 500, 2) })
    RunWorker()
    assert.are.equal("idle", ns.Scan.GetStatus().phase)
    assert.are.same({}, quickSnapshots)
  end)

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

  it("processes an external replication once using zero-based rows", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
      [1] = { name = "Two", quantity = 2, buyout = 300, itemID = 200, itemLink = "item:200" },
    }
    rowCount = 2
    C_AuctionHouse.ReplicateItems()
    assert(lastReplicateScan == currentTime, "records an external replication attempt against the cooldown")
    currentTime = currentTime + 10
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    assert(lastReplicateScan == currentTime, "records when the external replication responds")
    RunWorker()

    assert(#processed == 1 and #processed[1] == 2, "processes an external replication")
    assert(rawCounts[1] == 2, "reports the raw replication row count")
    assert(requestedIndexes[1] == 0 and requestedIndexes[2] == 1, "reads zero-based replication rows")
    assert(processed[1][2].quantity == 2 and processed[1][2].buyout == 300, "normalizes replication data")
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#processed == 1, "ignores repeated item-cache replication events")
  end)

  it("starts an owned replication and records the attempt against the cooldown", function()
    setfenv(1, environment)
    ns.Scan.Start()
    assert(replicateCalls == 1, "starts native replication")
    assert(lastReplicateScan == currentTime, "records an Arbitrage replication attempt against the cooldown")
  end)

  it("collects at most 2000 replication rows per frame", function()
    setfenv(1, environment)
    for index = 0, 2000 do
      rows[index] = {
        name = "Item " .. index,
        quantity = 1,
        buyout = index + 1,
        itemID = index + 1,
        itemLink = "item:" .. (index + 1),
      }
    end
    rowCount = 2001
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#requestedIndexes == 2000 and #processed == 0, "limits replicate accessors to 2000 rows per frame")
    RunWorker()
    assert(#requestedIndexes == 2001 and #processed == 1, "resumes batched replication on the next frame")
  end)

  it("reports the wait in whole seconds and progress while reading and pricing", function()
    setfenv(1, environment)
    FillRows(2)
    ns.Scan.Start()
    assert.are.same({ phase = "waiting", kind = "full", elapsedSeconds = 0 }, statusHistory[1])

    currentTime = currentTime + 32
    RunWorker()
    assert.are.same({ phase = "waiting", kind = "full", elapsedSeconds = 32 }, statusHistory[2])
    RunWorker()
    assert.are.equal(2, #statusHistory)

    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorkerUntilProcessed(10)
    assert.are.same({
      { phase = "reading", kind = "full", progress = 0 },
      { phase = "reading", kind = "full", progress = 50 },
      { phase = "reading", kind = "full", progress = 100 },
      { phase = "pricing", kind = "full", progress = 0 },
      { phase = "pricing", kind = "full", progress = 42 },
      { phase = "idle", cooldownRemainingMinutes = 15 },
    }, { unpack(statusHistory, 3) })
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
    profileStep = 10
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(#requestedIndexes == 1 and #processed == 0, "honors the per-frame time budget")
    profileStep = 0
    RunWorker()
    assert(#requestedIndexes == 3 and #processed == 1, "resumes time-sliced collection")
  end)

  it("works for as long each frame as the scan work setting allows", function()
    setfenv(1, environment)
    FillRows(3)
    scanWorkBudget = 20
    profileStep = 10
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert.are.same({ 0, 1 }, requestedIndexes)
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
    assert.are.same({ phase = "reading", kind = "full", progress = 50 }, ns.Scan.GetStatus())
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
  end)

  it("requests an item again when it loads with its auctions incomplete, up to three loads", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Resolved", quantity = 1, buyout = 100, itemID = 800 },
      [1] = { name = "Stubborn", quantity = 1, buyout = 100, itemID = 801 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(itemLoadRequests[800] == 1 and itemLoadRequests[801] == 1, "requests each waiting item once")

    rows[0].itemLink = "item:800"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 800, true)
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 801, true)
    RunWorker()
    assert(itemLoadRequests[800] == 1, "does not request an item whose auctions are priced")
    assert(itemLoadRequests[801] == 2, "requests an item again that loaded with its auctions incomplete")
    assert(#processed == 0, "keeps waiting for the incomplete item")

    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 801, true)
    RunWorker()
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 801, true)
    RunWorker()
    assert(itemLoadRequests[801] == 3, "stops requesting after three incomplete loads")
    assert.are.same({
      { itemID = 800, itemLink = "item:800", quantity = 1, buyout = 100 },
      { itemID = 801, quantity = 1, buyout = 100 },
    }, processed[1], "finishes once nothing is loading, without waiting for the timeout")
  end)

  it("keeps waiting while loads keep pricing auctions", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "First", quantity = 1, buyout = 100, itemID = 800 },
      [1] = { name = "Second", quantity = 1, buyout = 100, itemID = 801 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    local firstTimeout = assert(GetLastTimer(2), "starts waiting after reading")

    rows[0].itemLink = "item:800"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 800, true)
    RunWorker()
    local secondTimeout = GetLastTimer(2)
    assert(secondTimeout ~= firstTimeout, "restarts the wait when a load prices an auction")
    firstTimeout.callback()
    RunWorker()
    assert(#processed == 0, "ignores the superseded timeout")

    secondTimeout.callback()
    RunWorker()
    assert.are.same({
      { itemID = 800, itemLink = "item:800", quantity = 1, buyout = 100 },
      { itemID = 801, quantity = 1, buyout = 100 },
    }, processed[1])
  end)

  it("requests each waiting item once, after reading, however its auctions are spread", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Early", quantity = 1, buyout = 100, itemID = 800 },
      [1] = { name = "Other", quantity = 1, buyout = 200, itemID = 900, itemLink = "item:900" },
      [2] = { name = "Late", quantity = 2, buyout = 300, itemID = 800 },
    }
    rowCount = 3
    -- Each clock read spends the frame budget, so the worker reads one auction a frame.
    profileStep = 10
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    repeat
      RunWorker()
    until requestedIndexes[#requestedIndexes] == 2
    assert(next(itemLoadRequests) == nil, "requests nothing while reading")

    profileStep = 0
    RunWorker()
    assert.are.same({ [800] = 1 }, itemLoadRequests)
    rows[0].itemLink = "item:800"
    rows[2].itemLink = "item:800"
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 800, true)
    RunWorker()
    assert.are.same({
      { itemLink = "item:900", quantity = 1, buyout = 200 },
      { itemID = 800, itemLink = "item:800", quantity = 1, buyout = 100 },
      { itemID = 800, itemLink = "item:800", quantity = 2, buyout = 300 },
    }, processed[1])
  end)

  it("prices gear by item ID with the quality it had before the game let go of its data", function()
    setfenv(1, environment)
    rows = { [0] = { name = "Gear", quantity = 1, buyout = 100, itemID = 801, quality = 2 } }
    rowCount = 1
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    rows[0].quality = -1
    assert(GetLastTimer(2)).callback()
    RunWorker()
    assert.are.same({ { itemID = 801, quantity = 1, buyout = 100 } }, processed[1])
  end)

  it("keeps at most 500 items loading at once", function()
    setfenv(1, environment)
    local function CountRequestedItems()
      local requested = 0
      for _ in pairs(itemLoadRequests) do
        requested = requested + 1
      end
      return requested
    end
    rows = {}
    for index = 0, 599 do
      rows[index] = { name = "Slow", quantity = 1, buyout = 100, itemID = 1000 + index }
    end
    rowCount = 600
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    RunWorker()
    assert.are.equal(500, CountRequestedItems())

    for index = 0, 99 do
      rows[index].itemLink = "item:" .. (1000 + index)
      onEvent(nil, "ITEM_DATA_LOAD_RESULT", 1000 + index, true)
    end
    RunWorker()
    assert.are.equal(600, CountRequestedItems(), "requests the rest as earlier items finish")
  end)

  it("prices gear by item ID when its link times out after 2 seconds, and names it in chat", function()
    setfenv(1, environment)
    itemNames[500] = "Lionheart Helm"
    rows = {
      [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 499, itemLink = "item:499" },
      [1] = { name = "Slow", quantity = 1, buyout = 100, itemID = 500 },
      [2] = { name = "Also Slow", quantity = 2, buyout = 300, itemID = 501 },
    }
    rowCount = 3
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    local itemTimeout = assert(GetLastTimer(2), "starts a 2-second item-link timeout")
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 500, true)
    onEvent(nil, "ITEM_DATA_LOAD_RESULT", 501, true)
    RunWorker()
    assert(#processed == 0, "keeps retrying when a loaded item link remains unavailable")
    itemTimeout.callback()
    RunWorker()
    assert.are.same({
      { itemLink = "item:499", quantity = 1, buyout = 200 },
      { itemID = 500, quantity = 1, buyout = 100 },
      { itemID = 501, quantity = 2, buyout = 300 },
    }, processed[1])
    assert.are.equal(
      "|cff00ccffArbitrage:|r Priced 2 gear items without their random enchants because their item links didn't load: "
        .. "Item #501, Lionheart Helm",
      messages[#messages]
    )
    rows[1].itemLink = "item:500"
    rows[2].itemLink = "item:501"
    RunWorker()
    assert(#processed == 1, "does not resume retries after completing a timed-out scan")
  end)

  it("keeps a link that loads after the last check before the timeout", function()
    setfenv(1, environment)
    rows = {
      [0] = { name = "Late", quantity = 1, buyout = 100, itemID = 500 },
      [1] = { name = "Never", quantity = 2, buyout = 300, itemID = 501 },
    }
    rowCount = 2
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    rows[0].itemLink = "item:500"
    assert(GetLastTimer(2)).callback()
    RunWorker()
    assert.are.same({
      { itemID = 500, itemLink = "item:500", quantity = 1, buyout = 100 },
      { itemID = 501, quantity = 2, buyout = 300 },
    }, processed[1])
    assert.are.equal(
      "|cff00ccffArbitrage:|r Priced 1 gear item without their random enchants because their item links didn't load: "
        .. "Item #501",
      messages[#messages]
    )
  end)

  it("keeps the chat line short when hundreds of gear links time out", function()
    setfenv(1, environment)
    rows = {}
    for index = 0, 299 do
      rows[index] = { name = "Slow", quantity = 1, buyout = 100, itemID = 1000 + index }
      itemNames[1000 + index] = string.format("Gear %03d", index)
    end
    rowCount = 300
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert(GetLastTimer(2)).callback()
    RunWorkerUntilProcessed(20)
    assert.are.equal(300, #processed[1])
    assert.are.equal(
      "|cff00ccffArbitrage:|r Priced 300 gear items without their random enchants because their item links didn't load: "
        .. "Gear 000, Gear 001, Gear 002, Gear 003, Gear 004 and 295 more",
      messages[#messages]
    )
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

  it("fails fast when the Auction House drops the throttled request", function()
    setfenv(1, environment)
    assert(events.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED, "registers the dropped-request event")
    ns.Scan.Start()
    onEvent(nil, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 15 }, statusHistory[#statusHistory])
    assert(messages[#messages]:find("throttled the request", 1, true), "reports the dropped request")
    local refreshCount = #statusHistory
    currentTime = currentTime + 1
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert.are.equal(refreshCount, #statusHistory)
    assert(#processed == 0, "ignores a response that arrives after a dropped request")
  end)

  it("refuses to scan a neutral Auction House and ignores other addons' scans there", function()
    setfenv(1, environment)
    assert.is_false(ns.Scan.IsAtNeutralAuctionHouse())
    mapID = 1446
    assert.is_true(ns.Scan.IsAtNeutralAuctionHouse())

    ns.Scan.Start()
    assert.are.equal(0, replicateCalls)
    assert(messages[#messages]:find("only scans your faction's Auction House", 1, true), "explains the refusal")
    assert.is_nil(lastReplicateScan)

    FillRows(1)
    C_AuctionHouse.ReplicateItems()
    assert(
      messages[#messages]:find("Ignoring another addon's full scan", 1, true),
      "says another addon's scan is ignored"
    )
    assert.are.equal(currentTime, lastReplicateScan, "still counts the request against the cooldown")
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 15 }, statusHistory[#statusHistory])
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert.are.equal(0, #processed)
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
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 15 }, statusHistory[#statusHistory])
    RunWorker()
    assert(#processed == 0, "cancels collection when the Auction House closes")
    assert(messages[#messages]:find("Auction House closed", 1, true), "reports an owned scan cancellation")
  end)

  it("reports another addon's scan in chat when it starts, is cancelled, or is throttled", function()
    setfenv(1, environment)
    C_AuctionHouse.ReplicateItems()
    assert.are.equal(1, #messages)
    assert(messages[1]:find("Another addon started a full scan", 1, true), "says Arbitrage is pricing the scan")

    auctionHouseShown = false
    onEvent(nil, "AUCTION_HOUSE_CLOSED")
    assert(messages[2]:find("Full scan cancelled: Auction House closed", 1, true), "reports the cancellation")

    auctionHouseShown = true
    C_AuctionHouse.ReplicateItems()
    onEvent(nil, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert(messages[#messages]:find("throttled the request", 1, true), "reports the dropped request")
  end)

  it("cancels only a scan still waiting for the server and ignores its late response", function()
    setfenv(1, environment)
    FillRows(1)
    ns.Scan.Start()
    ns.Scan.Cancel()
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 15 }, statusHistory[#statusHistory])
    assert(messages[#messages]:find("Full scan cancelled: stopped waiting for the server", 1, true))
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorker()
    assert.are.equal(0, #processed)

    currentTime = currentTime + 900
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    ns.Scan.Cancel()
    assert.are.equal("reading", ns.Scan.GetStatus().phase)
    RunWorkerUntilProcessed(10)
  end)

  it("remembers how the latest scan ended", function()
    setfenv(1, environment)
    assert.is_nil(ns.Scan.GetLastOutcome())
    FillRows(1)
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    RunWorkerUntilProcessed(10)
    assert.are.same({ message = "Full scan done: test", at = currentTime }, ns.Scan.GetLastOutcome())
    assert(messages[#messages]:find("Full scan done: test", 1, true), "reports the outcome in chat")

    currentTime = currentTime + 900
    ns.Scan.Start()
    onEvent(nil, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert.are.same({
      message = "Full scan incomplete: the Auction House throttled the request; previous data kept",
      at = currentTime,
    }, ns.Scan.GetLastOutcome())
  end)

  it("finishes pricing a scan when the Auction House closes after its auctions are read", function()
    setfenv(1, environment)
    FillRows(1)
    ns.Scan.Start()
    onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
    -- Each clock read spends the frame budget, so the worker pauses at every checkpoint.
    profileStep = 10
    RunWorker()
    RunWorker()
    assert.are.same({ phase = "pricing", kind = "full", progress = 42 }, ns.Scan.GetStatus())

    auctionHouseShown = false
    onEvent(nil, "AUCTION_HOUSE_CLOSED")
    RunWorkerUntilProcessed(10)
    assert.are.equal(1, #processed[1])
    for _, message in ipairs(messages) do
      assert.is_nil(message:find("cancelled", 1, true))
    end
  end)

  it("estimates the remaining local replication cooldown and refreshes when minutes tick down", function()
    setfenv(1, environment)
    lastReplicateScan = 1000
    currentTime = 1451
    ns.Scan.Start()
    assert(replicateCalls == 0, "does not call replication during the local cooldown")
    assert(messages[#messages]:find("best guess: try again in 8 minutes", 1, true), "estimates remaining cooldown")
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 8 }, ns.Scan.GetStatus())

    local refreshCount = #statusHistory
    currentTime = 1479
    RunWorker()
    assert.are.equal(refreshCount, #statusHistory)

    currentTime = 1480
    RunWorker()
    assert.are.equal(refreshCount + 1, #statusHistory)
    assert.are.same({ phase = "idle", cooldownRemainingMinutes = 7 }, statusHistory[#statusHistory])

    currentTime = 1900
    RunWorker()
    assert.are.equal(refreshCount + 2, #statusHistory)
    assert.are.same({ phase = "idle" }, statusHistory[#statusHistory])
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

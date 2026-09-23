local onEvent
local onUpdate
local replicateHook
local rows = {}
local rowCount = 0
local requestedIndexes = {}
local requestedLinkIndexes = {}
local timers = {}
local itemLoadCallbacks = {}
local itemLoadRequests = {}
local messages = {}
local events = {}
local mapID = 1453
local selectedMarket
local profileTime = 0
local profileStep = 0
local currentTime = 1000
local lastReplicateScan
local throttleReady = true
local auctionHouseShown = true
local replicateCalls = 0

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

Item = {
  CreateFromItemID = function(_, itemID)
    itemLoadRequests[itemID] = (itemLoadRequests[itemID] or 0) + 1
    return {
      ContinueOnItemLoad = function(_, callback)
        itemLoadCallbacks[itemID] = callback
      end,
    }
  end,
}

local ns = {
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

local processed = {}
local rawCounts = {}
ns.Scan.Init(function(data, rawCount, checkpoint)
  checkpoint()
  processed[#processed + 1] = data
  rawCounts[#rawCounts + 1] = rawCount
end)

assert(events.REPLICATE_ITEM_LIST_UPDATE, "registers the replication result event")
assert(events.AUCTION_HOUSE_SHOW and events.AUCTION_HOUSE_CLOSED, "registers Auction House lifecycle events")

onEvent(nil, "AUCTION_HOUSE_SHOW")
assert(selectedMarket == "Alliance", "selects the faction Auction House market")
mapID = 1446
onEvent(nil, "AUCTION_HOUSE_SHOW")
assert(selectedMarket == "Neutral", "selects the neutral Tanaris Auction House market")
mapID = 1453

local function ResetHarness()
  onEvent(nil, "AUCTION_HOUSE_CLOSED")
  rows = {}
  rowCount = 0
  requestedIndexes = {}
  requestedLinkIndexes = {}
  timers = {}
  itemLoadCallbacks = {}
  itemLoadRequests = {}
  messages = {}
  processed = {}
  rawCounts = {}
  profileTime = 0
  profileStep = 0
  currentTime = 1000
  lastReplicateScan = nil
  throttleReady = true
  auctionHouseShown = true
  replicateCalls = 0
end

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

rows = {
  [0] = { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
  [1] = { name = "Two", quantity = 2, buyout = 300, itemID = 200, itemLink = "item:200" },
}
rowCount = 2
C_AuctionHouse.ReplicateItems()
assert(lastReplicateScan == nil, "does not record an external replication attempt")
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

ResetHarness()
rows[0] = { name = "Owned", quantity = 1, buyout = 700, itemID = 300, itemLink = "item:300" }
rowCount = 1
ns.Scan.Start()
assert(replicateCalls == 1, "starts native replication")
assert(lastReplicateScan == nil, "does not record an Arbitrage replication attempt")
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
assert(lastReplicateScan == currentTime, "records a successful Arbitrage replication")
RunWorker()
assert(#processed == 1 and processed[1][1].itemLink == "item:300", "does not treat its own call as external")

ResetHarness()
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

ResetHarness()
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

ResetHarness()
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
itemLoadCallbacks[400]()
RunWorker()
assert(#processed == 1 and #processed[1] == 2, "re-reads rows after their item data loads")
assert(#requestedIndexes == 4, "verifies every pending row in a second pass")

ResetHarness()
rows = {
  [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 499, itemLink = "item:499" },
  [1] = { name = "Slow", quantity = 1, buyout = 100, itemID = 500 },
}
rowCount = 2
ns.Scan.Start()
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
RunWorker()
local itemTimeout = assert(GetLastTimer(10), "starts an item-load timeout")
itemTimeout.callback()
RunWorker()
assert(#processed == 1 and #processed[1] == 1, "keeps valid rows when an item load times out")
assert(messages[#messages]:find("skipped 1 auction", 1, true), "reports the skipped timed-out row")
rows[1].itemLink = "item:500"
itemLoadCallbacks[500]()
RunWorker()
assert(#processed == 1, "ignores item callbacks after completing a timed-out scan")

ResetHarness()
rows = {
  [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 599, itemLink = "item:599" },
  [1] = { name = "Linkless", quantity = 1, buyout = 100, itemID = 600 },
}
rowCount = 2
ns.Scan.Start()
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
RunWorker()
itemLoadCallbacks[600]()
RunWorker()
assert(#processed == 1 and #processed[1] == 1, "keeps valid rows when a loaded item link remains unavailable")
assert(processed[1][1].itemLink == "item:599", "skips only the row without a link")
assert(messages[#messages]:find("skipped 1 auction", 1, true), "reports the skipped linkless row")

ResetHarness()
rows = {
  [0] = { name = "Valid", quantity = 1, buyout = 200, itemID = 699, itemLink = "item:699" },
  [1] = { name = "Changed", quantity = 1, buyout = 100, itemID = 700 },
}
rowCount = 2
ns.Scan.Start()
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
RunWorker()
rows[1] = { name = "Replacement", quantity = 1, buyout = 200, itemID = 701, itemLink = "item:701" }
itemLoadCallbacks[700]()
RunWorker()
assert(#processed == 1 and #processed[1] == 1, "keeps valid rows when a pending row changes")
assert(processed[1][1].itemLink == "item:699", "skips the changed row")
assert(messages[#messages]:find("skipped 1 auction", 1, true), "reports the skipped changed row")

ResetHarness()
rows = {
  [0] = { name = "Valid", quantity = 5, buyout = 500, itemID = 700, itemLink = "item:700" },
  [1] = { name = "Bid Only", quantity = 1, buyout = 0, itemID = 701, itemLink = "item:701" },
  [2] = { name = "Bad Quantity", quantity = 0 / 0, buyout = 200, itemID = 702, itemLink = "item:702" },
  [3] = { name = "No Identity", quantity = 1, buyout = 300 },
}
rowCount = 4
C_AuctionHouse.ReplicateItems()
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
RunWorker()
assert(#processed == 1 and #processed[1] == 1, "filters bid-only and malformed rows")
assert(processed[1][1].itemLink == "item:700", "keeps valid rows")

ResetHarness()
ns.Scan.Start()
local responseTimeout = assert(GetLastTimer(30), "starts a replication response timeout")
responseTimeout.callback()
assert(messages[#messages]:find("no Auction House response after 30 seconds", 1, true), "reports response timeout")
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
RunWorker()
assert(#processed == 0 and lastReplicateScan == nil, "ignores responses after timeout")

ResetHarness()
rows[0] = { name = "Cancelled", quantity = 1, buyout = 100, itemID = 800, itemLink = "item:800" }
rowCount = 1
ns.Scan.Start()
onEvent(nil, "REPLICATE_ITEM_LIST_UPDATE")
onEvent(nil, "AUCTION_HOUSE_CLOSED")
RunWorker()
assert(#processed == 0, "cancels collection when the Auction House closes")
assert(messages[#messages]:find("Auction House closed", 1, true), "reports an owned scan cancellation")

ResetHarness()
lastReplicateScan = 1000
currentTime = 1451
ns.Scan.Start()
assert(replicateCalls == 0, "does not call replication during the local cooldown")
assert(messages[#messages]:find("best guess: try again in 8 minutes", 1, true), "estimates remaining cooldown")

ResetHarness()
throttleReady = false
ns.Scan.Start()
assert(replicateCalls == 0, "does not send while the Auction House throttle is busy")
assert(messages[#messages]:find("Auction House is busy", 1, true), "reports the throttle state")

ResetHarness()
auctionHouseShown = false
ns.Scan.Start()
assert(replicateCalls == 0, "requires an open Auction House")
assert(messages[#messages]:find("Open the Auction House", 1, true), "reports the open-window requirement")

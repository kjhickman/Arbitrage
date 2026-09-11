local onEvent
local onUpdate
local queryHook
local auctionatorListener
local rows = {}
local requestedIndexes = {}
local timers = {}
local itemLoadCallbacks = {}
local messages = {}
local mapID = 1453
local selectedMarket
local profileTime = 0
local profileStep = 0

function CreateFrame()
  return {
    RegisterEvent = function() end,
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
  local currentTime = profileTime
  profileTime = profileTime + profileStep
  return currentTime
end

function hooksecurefunc(_, callback)
  queryHook = callback
end

function print(message)
  messages[#messages + 1] = message
end

function GetNumAuctionItems()
  return #rows
end

function UnitFactionGroup()
  return "Alliance"
end

AuctionFrame = {
  IsShown = function()
    return true
  end,
}

function CanSendAuctionQuery()
  return true, true
end

function QueryAuctionItems(...)
  queryHook(...)
end

function GetAuctionItemInfo(_, index)
  local row = assert(rows[index], "uses one-based auction indexes")
  requestedIndexes[#requestedIndexes + 1] = index
  return row.name, nil, row.quantity, nil, nil, nil, nil, nil, nil, row.buyout, nil, nil, nil, nil, nil, nil, row.itemID
end

function GetAuctionItemLink(_, index)
  return assert(rows[index], "uses one-based auction indexes").itemLink
end

C_Item = {
  GetItemInfoInstant = function(itemID)
    return itemID
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
    return {
      ContinueOnItemLoad = function(_, callback)
        itemLoadCallbacks[itemID] = callback
      end,
    }
  end,
}

Auctionator = {
  FullScan = {
    Events = {
      ScanStart = "AUCTIONATOR_SCAN_START",
      ScanComplete = "AUCTIONATOR_SCAN_COMPLETE",
      ScanFailed = "AUCTIONATOR_SCAN_FAILED",
    },
  },
  EventBus = {
    Register = function(_, listener)
      auctionatorListener = listener
    end,
  },
}

local ns = {}
local useAuctionatorScans = true
ns.Config = {
  Get = function(key)
    if key == "useAuctionatorScans" then
      return useAuctionatorScans
    end
    return true
  end,
}
ns.Database = {
  SetMarket = function(market)
    selectedMarket = market
  end,
}
assert(loadfile("src/Scan.lua"), "loads Scan.lua")("Arbitrage", ns)

local processed = {}
ns.Scan.Init(function(data, _, checkpoint)
  checkpoint()
  processed[#processed + 1] = data
end)
ns.Scan.RegisterAuctionator()

onEvent(nil, "AUCTION_HOUSE_SHOW")
assert(selectedMarket == "Alliance", "selects the faction auction market")
mapID = 1446
onEvent(nil, "AUCTION_HOUSE_SHOW")
assert(selectedMarket == "Neutral", "selects the neutral Tanaris auction market")
mapID = 1453

local function ResetHarness()
  onEvent(nil, "AUCTION_HOUSE_CLOSED")
  rows = {}
  requestedIndexes = {}
  timers = {}
  itemLoadCallbacks = {}
  messages = {}
  processed = {}
  profileTime = 0
  profileStep = 0
end

local function GetTimer(delay)
  for _, timer in ipairs(timers) do
    if timer.delay == delay then
      return timer
    end
  end
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
  { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
  { name = "Two", quantity = 2, buyout = 300, itemID = 200, itemLink = "item:200" },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()

assert(#processed == 1 and #processed[1] == 2, "finishes a scan within the available frame budget")
assert(requestedIndexes[1] == 1 and requestedIndexes[2] == 2, "reads every auction exactly once")
assert(processed[1][1].quantity == 1 and processed[1][1].buyout == 100, "normalizes native auction data")

ResetHarness()
for index = 1, 3 do
  rows[index] = {
    name = "Item " .. index,
    quantity = 1,
    buyout = index,
    itemID = index,
    itemLink = "item:" .. index,
  }
end
profileStep = 5
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()

assert(#processed == 0, "waits for the next worker frame")
assert(#requestedIndexes == 1, "stops collecting rows when the frame budget is exhausted")
rows[1] = { name = "Replacement", quantity = 9, buyout = 999, itemID = 999, itemLink = "item:999" }
profileStep = 0
RunWorker()
assert(#processed == 1 and #processed[1] == 3, "resumes the worker on the next frame")
assert(processed[1][1].itemLink == "item:1", "keeps data snapshotted before yielding")
assert(#requestedIndexes == 3, "reads each auction exactly once")

ResetHarness()
for index = 1, 3 do
  rows[index] = {
    name = "Item " .. index,
    quantity = 1,
    buyout = index,
    itemID = index,
    itemLink = "item:" .. index,
  }
end
profileStep = 5
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
assert(#requestedIndexes == 1, "collects only within the current frame budget")
queryHook(nil, nil, nil, nil, nil, nil, false)
profileStep = 0
RunWorker()
assert(#requestedIndexes == 1 and #processed == 0, "cancels collection before reading a replacement list")

ResetHarness()
rows = {
  { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
}
profileStep = 3
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
assert(#requestedIndexes == 1 and #processed == 0, "yields after collection when the budget is exhausted")
queryHook(nil, nil, nil, nil, nil, nil, false)
profileStep = 0
RunWorker()
assert(#processed == 0, "cancels downstream processing with the scan generation")

ResetHarness()
rows = {
  { name = "Slow", quantity = 1, buyout = 100, itemID = 300 },
}
ns.Scan.Start()
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()

assert(#processed == 0, "waits for missing item links")
local timeout = assert(GetLastTimer(2), "starts an item-link timeout after collecting the response")
timeout.callback()
assert(#processed == 0, "does not process an incomplete scan")
assert(
  messages[#messages]:find("timed out waiting for 1 item link after 2 seconds", 1, true),
  "reports the item-link timeout reason"
)
itemLoadCallbacks[300]()
assert(#processed == 0, "ignores item loads after timeout")

ResetHarness()
ns.Scan.Start()
timeout = assert(GetTimer(30), "allows time for the full-scan response")
timeout.callback()
assert(
  messages[#messages]:find("no Auction House response after 30 seconds", 1, true),
  "reports the response timeout reason"
)
assert(messages[#messages]:find("WoW still reports full scans available", 1, true), "reports the cooldown state")
rows = {
  { name = "Late", quantity = 1, buyout = 100, itemID = 301, itemLink = "item:301" },
}
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
assert(#processed == 0, "ignores a response that arrives after the query timeout")
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
assert(#processed == 1, "allows another full scan after a missing response")

ResetHarness()
rows = {
  { name = "Slow", quantity = 1, buyout = 100, itemID = 302 },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
local responseTimeout = assert(GetTimer(30), "starts the response timeout with the query")
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
responseTimeout.callback()
rows[1] = { name = "Changed", quantity = 9, buyout = 900, itemID = 302, itemLink = "item:302" }
itemLoadCallbacks[302]()
RunWorker()
assert(#processed == 1, "accepts a delayed link when the row still has the original item")
assert(processed[1][1].quantity == 1 and processed[1][1].buyout == 100, "keeps snapshotted auction data")

ResetHarness()
rows = {
  { name = "Slow", quantity = 1, buyout = 100, itemID = 303 },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
rows[1] = { name = "Replacement", quantity = 1, buyout = 500, itemID = 304, itemLink = "item:304" }
itemLoadCallbacks[303]()
assert(#processed == 0, "rejects a delayed link when the row item changed")
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
assert(#processed == 0, "cancels the scan after a delayed row mismatch")

ResetHarness()
rows = {
  { name = "Slow", quantity = 1, buyout = 100, itemID = 305 },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
queryHook(nil, nil, nil, nil, nil, nil, false)
rows[1].itemLink = "item:305"
itemLoadCallbacks[305]()
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
assert(#processed == 0, "cancels an active scan when a normal query supersedes it")

ResetHarness()
rows = {
  { name = "Old", quantity = 1, buyout = 100, itemID = 306 },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
local oldTimeout = assert(GetTimer(30), "keeps the original full-query timeout")
rows = {
  { name = "New", quantity = 2, buyout = 600, itemID = 307, itemLink = "item:307" },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
oldTimeout.callback()
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
itemLoadCallbacks[306]()
assert(#processed == 1 and processed[1][1].itemLink == "item:307", "tracks a superseding full query")

ResetHarness()
rows = {
  { name = "Owned", quantity = 1, buyout = 700, itemID = 308, itemLink = "item:308" },
}
ns.Scan.Start()
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")
RunWorker()
assert(#processed == 1 and processed[1][1].itemLink == "item:308", "does not cancel Arbitrage's own query")

ResetHarness()
profileStep = 5
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_START")
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_COMPLETE", {
  { itemLink = "item:401", auctionInfo = { [3] = 1, [10] = 401 } },
  { itemLink = "item:402", auctionInfo = { [3] = 1, [10] = 402 } },
  { itemLink = "item:403", auctionInfo = { [3] = 1, [10] = 403 } },
})
RunWorker()
assert(#processed == 0, "time-slices Auctionator normalization")
profileStep = 0
RunWorker()
assert(#processed == 1 and #processed[1] == 3, "resumes Auctionator normalization on the next frame")

ResetHarness()
profileStep = 5
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_START")
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_COMPLETE", {
  { itemLink = "item:404", auctionInfo = { [3] = 1, [10] = 404 } },
  { itemLink = "item:405", auctionInfo = { [3] = 1, [10] = 405 } },
})
RunWorker()
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_START")
profileStep = 0
RunWorker()
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_FAILED")
assert(#processed == 0, "cancels an older Auctionator worker when a new scan starts")

ResetHarness()
queryHook(nil, nil, nil, nil, nil, nil, true)
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_COMPLETE", {
  { itemLink = "item:400", auctionInfo = { [3] = 1, [10] = 400 } },
})
assert(#processed == 0, "ignores Auctionator completion for another scan source")

onEvent(nil, "AUCTION_HOUSE_CLOSED")
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_START")
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_COMPLETE", {
  { itemLink = "item:500", auctionInfo = { [3] = 5, [10] = 500 } },
  { itemLink = "item:600", auctionInfo = { [3] = 0, [10] = 600 } },
  { itemLink = "item:700", auctionInfo = { [3] = 1, [10] = 0 } },
  { itemLink = "item:800", auctionInfo = { [3] = 0 / 0, [10] = 800 } },
  { itemLink = "item:900", auctionInfo = { [3] = 1, [10] = math.huge } },
  "invalid",
})
RunWorker()
assert(#processed == 1 and #processed[1] == 1, "filters malformed Auctionator rows")
assert(processed[1][1].itemLink == "item:500", "accepts the active Auctionator scan")
assert(processed[1][1].quantity == 5 and processed[1][1].buyout == 500, "normalizes Auctionator data")

ResetHarness()
useAuctionatorScans = false
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_START")
auctionatorListener:ReceiveEvent("AUCTIONATOR_SCAN_COMPLETE", {
  { itemLink = "item:1000", auctionInfo = { [3] = 1, [10] = 1000 } },
})
assert(#processed == 0, "ignores Auctionator scans when disabled")
useAuctionatorScans = true

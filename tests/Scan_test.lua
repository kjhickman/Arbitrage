local onEvent
local queryHook
local auctionatorListener
local rows = {}
local requestedIndexes = {}
local timers = {}
local itemLoadCallbacks = {}

function CreateFrame()
  return {
    RegisterEvent = function() end,
    SetScript = function(_, _, callback)
      onEvent = callback
    end,
  }
end

function hooksecurefunc(_, callback)
  queryHook = callback
end

function GetNumAuctionItems()
  return #rows
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
assert(loadfile("src/Scan.lua"), "loads Scan.lua")("Arbitrage", ns)

local processed = {}
ns.Scan.Init(function(data)
  processed[#processed + 1] = data
end)
ns.Scan.RegisterAuctionator()

local function ResetHarness()
  onEvent(nil, "AUCTION_HOUSE_CLOSED")
  rows = {}
  requestedIndexes = {}
  timers = {}
  itemLoadCallbacks = {}
  processed = {}
end

rows = {
  { name = "One", quantity = 1, buyout = 100, itemID = 100, itemLink = "item:100" },
  { name = "Two", quantity = 2, buyout = 300, itemID = 200, itemLink = "item:200" },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")

assert(#processed == 1 and #processed[1] == 2, "finishes a synchronous scan")
assert(requestedIndexes[1] == 1 and requestedIndexes[2] == 2, "reads every auction exactly once")
assert(processed[1][1].quantity == 1 and processed[1][1].buyout == 100, "normalizes native auction data")

ResetHarness()
for index = 1, 251 do
  rows[index] = {
    name = "Item " .. index,
    quantity = 1,
    buyout = index,
    itemID = index,
    itemLink = "item:" .. index,
  }
end
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")

assert(#processed == 0, "waits for the next batch")
assert(#timers == 1 and timers[1].delay == 0.01, "schedules another batch")
timers[1].callback()
assert(#processed == 1 and #processed[1] == 251, "processes every batch")
assert(requestedIndexes[250] == 250 and requestedIndexes[251] == 251, "continues at the batch boundary")

ResetHarness()
rows = {
  { name = "Slow", quantity = 1, buyout = 100, itemID = 300 },
}
queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")

assert(#processed == 0, "waits for missing item links")
assert(#timers == 1 and timers[1].delay == 2, "schedules the incomplete-scan timeout")
timers[1].callback()
assert(#processed == 0, "does not process an incomplete scan")
itemLoadCallbacks[300]()
assert(#processed == 0, "ignores item loads after timeout")

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
assert(#processed == 1 and #processed[1] == 1, "filters malformed Auctionator rows")
assert(processed[1][1].itemLink == "item:500", "accepts the active Auctionator scan")
assert(processed[1][1].quantity == 5 and processed[1][1].buyout == 500, "normalizes Auctionator data")

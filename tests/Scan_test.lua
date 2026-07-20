local onEvent
local queryHook

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
  return 1
end

function GetAuctionItemInfo()
  return "Item", nil, 1, nil, nil, nil, nil, nil, nil, 100, nil, nil, nil, nil, nil, nil, 100
end

function GetAuctionItemLink()
  return "item:100"
end

C_Item = {
  GetItemInfoInstant = function()
    return 100
  end,
}

C_Timer = { After = function() end }
Item = {}

local ns = {}
assert(loadfile("Scan.lua"), "loads Scan.lua")("Arbitrage", ns)

local processed
ns.Scan.Init(function(data)
  processed = data
end)

queryHook(nil, nil, nil, nil, nil, nil, true)
onEvent(nil, "AUCTION_ITEM_LIST_UPDATE")

assert(#processed == 1, "finishes a synchronous scan")
assert(processed[1].itemLink == "item:100", "keeps the scanned item link")

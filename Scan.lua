local _, ns = ...

ns.Scan = {}

local frame = CreateFrame("Frame")
local processFullScan
local source
local scanData
local pendingLinks
local capturing = false
local scanGeneration = 0

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Reset()
  source = nil
  scanData = nil
  pendingLinks = nil
  capturing = false
  scanGeneration = scanGeneration + 1
end

local function Finish()
  if source == nil or pendingLinks ~= 0 then
    return
  end

  local data = scanData
  Reset()
  processFullScan(data)
end

local function AddAuction(index, info, itemLink)
  if itemLink then
    scanData[#scanData + 1] = {
      auctionInfo = info,
      itemLink = itemLink,
    }
  end
  pendingLinks = pendingLinks - 1
  Finish()
end

local function ProcessBatch(startIndex, count, generation)
  if generation ~= scanGeneration or source == nil then
    return
  end

  local lastIndex = math.min(startIndex + 249, count - 1)
  for index = startIndex, lastIndex do
    local info = { GetAuctionItemInfo("list", index) }
    local itemID = info[17]
    local itemLink = GetAuctionItemLink("list", index)

    if itemID and itemID ~= 0 and C_Item.GetItemInfoInstant(itemID) and not itemLink then
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad(function()
        if generation == scanGeneration and source ~= nil then
          AddAuction(index, { GetAuctionItemInfo("list", index) }, GetAuctionItemLink("list", index))
        end
      end)
    else
      AddAuction(index, info, itemLink)
    end
  end

  if lastIndex < count - 1 then
    C_Timer.After(0.01, function()
      ProcessBatch(lastIndex + 1, count, generation)
    end)
  elseif pendingLinks > 0 then
    C_Timer.After(2, function()
      if generation == scanGeneration and source ~= nil and pendingLinks > 0 then
        pendingLinks = 0
        Finish()
      end
    end)
  else
    Finish()
  end
end

local function CaptureResponse()
  if source == nil then
    return
  end

  local count = GetNumAuctionItems("list")
  if source == "arbitrage" then
    Print("Received " .. count .. " auctions; calculating market prices")
  end
  capturing = true
  scanData = {}
  pendingLinks = count
  local generation = scanGeneration

  if count == 0 then
    Finish()
    return
  end

  ProcessBatch(0, count, generation)
end

local auctionatorListener = {
  ReceiveEvent = function(_, eventName, rawFullScan)
    if eventName == Auctionator.FullScan.Events.ScanStart then
      Reset()
      source = "auctionator"
    elseif eventName == Auctionator.FullScan.Events.ScanComplete then
      Reset()
      processFullScan(rawFullScan)
    elseif eventName == Auctionator.FullScan.Events.ScanFailed and source == "auctionator" then
      Reset()
    end
  end,
}

function ns.Scan.RegisterAuctionator()
  if not (Auctionator and Auctionator.EventBus and Auctionator.FullScan and Auctionator.FullScan.Events) then
    return
  end

  Auctionator.EventBus:Register(auctionatorListener, {
    Auctionator.FullScan.Events.ScanStart,
    Auctionator.FullScan.Events.ScanComplete,
    Auctionator.FullScan.Events.ScanFailed,
  })
end

function ns.Scan.Start()
  if source ~= nil then
    Print("A full scan is already in progress")
    return
  end

  if not AuctionFrame or not AuctionFrame:IsShown() then
    Print("Open the Auction House before starting a full scan")
    return
  end

  local _, canDoGetAll = CanSendAuctionQuery()
  if not canDoGetAll then
    Print("Full scans are unavailable; try again later")
    return
  end

  source = "arbitrage"
  Print("Starting full scan")
  QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
end

function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "AUCTION_ITEM_LIST_UPDATE" and not capturing and (source == "arbitrage" or source == "external") then
      CaptureResponse()
    elseif eventName == "AUCTION_HOUSE_CLOSED" then
      if source == "arbitrage" then
        Print("Full scan cancelled")
      end
      Reset()
    end
  end)

  hooksecurefunc("QueryAuctionItems", function(_, _, _, _, _, _, getAll)
    if getAll and source == nil then
      source = "external"
    end
  end)
end

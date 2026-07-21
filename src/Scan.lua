local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"auctionator"|"external"

---@class ArbitrageScanEntry
---@field itemLink string
---@field quantity number
---@field buyout number

---@class ArbitrageRawScanEntry
---@field itemLink string?
---@field auctionInfo table?

local frame = CreateFrame("Frame")
---@type fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?)
local processFullScan
---@type ArbitrageScanSource?
local source
---@type ArbitrageScanEntry[]?
local scanData
---@type number?
local remainingEntries
---@type number?
local rawEntryCount
local capturing = false
local scanGeneration = 0

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Reset()
  source = nil
  scanData = nil
  remainingEntries = nil
  rawEntryCount = nil
  capturing = false
  scanGeneration = scanGeneration + 1
end

local function Finish()
  if source == nil or remainingEntries ~= 0 then
    return
  end

  local data = scanData
  local total = rawEntryCount
  Reset()
  processFullScan(data, total)
end

---@param itemLink string?
---@param info table?
---@return ArbitrageScanEntry?
local function CreateScanEntry(itemLink, info)
  if type(itemLink) ~= "string" or type(info) ~= "table" then
    return nil
  end

  local quantity = info[3]
  local buyout = info[10]
  if
    type(quantity) ~= "number"
    or type(buyout) ~= "number"
    or quantity ~= quantity
    or buyout ~= buyout
    or quantity <= 0
    or buyout <= 0
    or quantity == math.huge
    or buyout == math.huge
  then
    return nil
  end

  return {
    itemLink = itemLink,
    quantity = quantity,
    buyout = buyout,
  }
end

---@param rawFullScan ArbitrageRawScanEntry[]?
---@return ArbitrageScanEntry[]?, number?
local function NormalizeFullScan(rawFullScan)
  if type(rawFullScan) ~= "table" then
    return nil
  end

  local entries = {}
  for _, rawEntry in ipairs(rawFullScan) do
    if type(rawEntry) == "table" then
      local entry = CreateScanEntry(rawEntry.itemLink, rawEntry.auctionInfo)
      if entry then
        entries[#entries + 1] = entry
      end
    end
  end
  return entries, #rawFullScan
end

---@param info table
---@param itemLink string?
local function AppendScanEntry(info, itemLink)
  if scanData == nil or remainingEntries == nil then
    return
  end

  local entry = CreateScanEntry(itemLink, info)
  if entry then
    scanData[#scanData + 1] = entry
  end
  remainingEntries = remainingEntries - 1
  Finish()
end

---@param startIndex number
---@param count number
---@param generation number
local function ProcessBatch(startIndex, count, generation)
  if generation ~= scanGeneration or source == nil or remainingEntries == nil then
    return
  end

  local lastIndex = math.min(startIndex + 249, count)
  for index = startIndex, lastIndex do
    local info = { GetAuctionItemInfo("list", index) }
    local itemID = tonumber(info[17])
    local itemLink = GetAuctionItemLink("list", index)

    if itemID and itemID ~= 0 and C_Item.GetItemInfoInstant(itemID) and not itemLink then
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad(function()
        if generation == scanGeneration and source ~= nil then
          AppendScanEntry({ GetAuctionItemInfo("list", index) }, GetAuctionItemLink("list", index))
        end
      end)
    else
      AppendScanEntry(info, itemLink)
    end
  end

  if lastIndex < count then
    C_Timer.After(0.01, function()
      ProcessBatch(lastIndex + 1, count, generation)
    end)
  elseif remainingEntries ~= nil and remainingEntries > 0 then
    C_Timer.After(2, function()
      if generation == scanGeneration and source ~= nil and remainingEntries ~= nil and remainingEntries > 0 then
        local timedOutSource = source
        Reset()
        if timedOutSource == "arbitrage" then
          Print("Full scan incomplete; try again")
        end
      end
    end)
  elseif remainingEntries ~= nil then
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
  remainingEntries = count
  rawEntryCount = count
  local generation = scanGeneration

  if count == 0 then
    Finish()
    return
  end

  ProcessBatch(1, count, generation)
end

local auctionatorListener = {
  ---@param eventName string
  ---@param rawFullScan ArbitrageRawScanEntry[]?
  ReceiveEvent = function(_, eventName, rawFullScan)
    if eventName == Auctionator.FullScan.Events.ScanStart then
      Reset()
      source = "auctionator"
    elseif eventName == Auctionator.FullScan.Events.ScanComplete and source == "auctionator" then
      local data, normalizedEntryCount = NormalizeFullScan(rawFullScan)
      Reset()
      processFullScan(data, normalizedEntryCount)
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
  QueryAuctionItems("", nil, nil, 0, false, nil, true, false, nil)
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?)
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName)
    if
      eventName == "AUCTION_ITEM_LIST_UPDATE"
      and not capturing
      and (source == "arbitrage" or source == "external")
    then
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

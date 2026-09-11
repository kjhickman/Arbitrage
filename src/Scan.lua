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
---@type fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
local processFullScan
---@type ArbitrageScanSource?
local source
local capturing = false
local awaitingResponse = false
local scanGeneration = 0
local issuingArbitrageQuery = false
---@type thread?
local scanWorker
---@type number?
local workerGeneration
local workerDeadline = 0
local QUERY_TIMEOUT_SECONDS = 30
local ITEM_LOAD_TIMEOUT_SECONDS = 2
local WORK_BUDGET_MILLISECONDS = 4
local NEUTRAL_AUCTION_HOUSE_MAPS = {
  [1434] = true, -- Stranglethorn Vale
  [1446] = true, -- Tanaris
  [1452] = true, -- Winterspring
}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function SelectAuctionHouseMarket()
  local mapID = C_Map.GetBestMapForUnit("player")
  local market = mapID and NEUTRAL_AUCTION_HOUSE_MAPS[mapID] and "Neutral" or UnitFactionGroup("player")
  ns.Database.SetMarket(market)
end

local function Reset()
  source = nil
  capturing = false
  awaitingResponse = false
  scanWorker = nil
  workerGeneration = nil
  scanGeneration = scanGeneration + 1
end

local function IsNativeScan()
  return source == "arbitrage" or source == "external"
end

---@param reason string
local function CancelNativeScan(reason)
  local cancelledSource = source
  Reset()
  if cancelledSource == "arbitrage" then
    Print("Full scan cancelled: " .. reason)
  end
end

---@param reason string
local function FailNativeScan(reason)
  local failedSource = source
  Reset()
  if failedSource == "arbitrage" then
    Print("Full scan incomplete: " .. reason .. "; try again")
  end
end

---@param newSource "arbitrage"|"external"
local function BeginNativeScan(newSource)
  source = newSource
  awaitingResponse = true
  local generation = scanGeneration
  C_Timer.After(QUERY_TIMEOUT_SECONDS, function()
    if generation == scanGeneration and IsNativeScan() and awaitingResponse then
      local _, canDoGetAll = CanSendAuctionQuery()
      local cooldownState = canDoGetAll and "WoW still reports full scans available" or "full-scan cooldown is active"
      FailNativeScan(
        "no Auction House response after " .. QUERY_TIMEOUT_SECONDS .. " seconds (" .. cooldownState .. ")"
      )
    end
  end)
end

local function Checkpoint()
  if debugprofilestop() >= workerDeadline then
    coroutine.yield()
  end
end

---@param task fun()
local function StartWorker(task)
  workerGeneration = scanGeneration
  scanWorker = coroutine.create(task)
end

local function ResumeWorker()
  local activeWorker = scanWorker
  if activeWorker == nil then
    return
  end
  if workerGeneration ~= scanGeneration or source == nil then
    scanWorker = nil
    workerGeneration = nil
    return
  end

  workerDeadline = debugprofilestop() + WORK_BUDGET_MILLISECONDS
  local success, message = coroutine.resume(activeWorker)
  if scanWorker ~= activeWorker then
    return
  end
  if not success then
    Reset()
    error(message, 0)
  elseif coroutine.status(activeWorker) == "dead" then
    Reset()
  end
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
---@param checkpoint fun()
---@return ArbitrageScanEntry[]?, number?
local function NormalizeFullScan(rawFullScan, checkpoint)
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
    checkpoint()
  end
  return entries, #rawFullScan
end

---@param entries ArbitrageScanEntry[]
---@param itemLink string?
---@param info table
local function AppendScanEntry(entries, itemLink, info)
  local entry = CreateScanEntry(itemLink, info)
  if entry then
    entries[#entries + 1] = entry
  end
end

---@param count number
---@param generation number
local function ProcessNativeFullScan(count, generation)
  local entries = {}
  local pendingItemLinks = 0

  for index = 1, count do
    local info = { GetAuctionItemInfo("list", index) }
    local itemID = tonumber(info[17])
    local itemLink = GetAuctionItemLink("list", index)

    if itemID and itemID ~= 0 and C_Item.GetItemInfoInstant(itemID) and not itemLink then
      local row = {
        index = index,
        itemID = itemID,
        auctionInfo = info,
      }
      pendingItemLinks = pendingItemLinks + 1
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad(function()
        if generation == scanGeneration and IsNativeScan() then
          local currentInfo = { GetAuctionItemInfo("list", row.index) }
          local currentItemID = tonumber(currentInfo[17])
          if currentItemID ~= row.itemID then
            FailNativeScan(
              "auction row " .. row.index .. " changed from item " .. row.itemID .. " to " .. tostring(currentItemID)
            )
            return
          end
          AppendScanEntry(entries, GetAuctionItemLink("list", row.index), row.auctionInfo)
          pendingItemLinks = pendingItemLinks - 1
        end
      end)
    else
      AppendScanEntry(entries, itemLink, info)
    end
    if generation ~= scanGeneration then
      return
    end
    Checkpoint()
  end

  if pendingItemLinks > 0 then
    C_Timer.After(ITEM_LOAD_TIMEOUT_SECONDS, function()
      if generation == scanGeneration and IsNativeScan() and pendingItemLinks > 0 then
        local itemLabel = pendingItemLinks == 1 and "item link" or "item links"
        FailNativeScan(
          "timed out waiting for "
            .. pendingItemLinks
            .. " "
            .. itemLabel
            .. " after "
            .. ITEM_LOAD_TIMEOUT_SECONDS
            .. " seconds"
        )
      end
    end)
    while pendingItemLinks > 0 do
      coroutine.yield()
    end
  end

  processFullScan(entries, count, Checkpoint)
end

local function CaptureResponse()
  if not IsNativeScan() then
    return
  end

  local count = GetNumAuctionItems("list")
  if source == "arbitrage" then
    Print("Received " .. count .. " auctions; calculating market prices")
  end
  capturing = true
  awaitingResponse = false
  local generation = scanGeneration
  StartWorker(function()
    ProcessNativeFullScan(count, generation)
  end)
end

local auctionatorListener = {
  ---@param eventName string
  ---@param rawFullScan ArbitrageRawScanEntry[]?
  ReceiveEvent = function(_, eventName, rawFullScan)
    if not ns.Config.Get("useAuctionatorScans") then
      if source == "auctionator" then
        Reset()
      end
      return
    end

    if eventName == Auctionator.FullScan.Events.ScanStart then
      Reset()
      SelectAuctionHouseMarket()
      source = "auctionator"
    elseif eventName == Auctionator.FullScan.Events.ScanComplete and source == "auctionator" and not capturing then
      capturing = true
      StartWorker(function()
        local data, normalizedEntryCount = NormalizeFullScan(rawFullScan, Checkpoint)
        processFullScan(data, normalizedEntryCount, Checkpoint)
      end)
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

  SelectAuctionHouseMarket()
  BeginNativeScan("arbitrage")
  Print("Starting full scan")
  issuingArbitrageQuery = true
  QueryAuctionItems("", nil, nil, 0, false, nil, true, false, nil)
  issuingArbitrageQuery = false
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "AUCTION_HOUSE_SHOW" then
      SelectAuctionHouseMarket()
    elseif
      eventName == "AUCTION_ITEM_LIST_UPDATE"
      and not capturing
      and (source == "arbitrage" or source == "external")
    then
      CaptureResponse()
    elseif eventName == "AUCTION_HOUSE_CLOSED" then
      if IsNativeScan() then
        CancelNativeScan("Auction House closed")
      else
        Reset()
      end
    end
  end)
  frame:SetScript("OnUpdate", ResumeWorker)

  hooksecurefunc("QueryAuctionItems", function(_, _, _, _, _, _, getAll)
    if issuingArbitrageQuery then
      return
    end

    if IsNativeScan() then
      CancelNativeScan("another auction query was sent")
    end

    if getAll and source == nil then
      SelectAuctionHouseMarket()
      BeginNativeScan("external")
    end
  end)
end

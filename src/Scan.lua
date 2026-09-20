local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"external"

---@class ArbitrageScanEntry
---@field itemLink string
---@field quantity number
---@field buyout number

---@class ArbitragePendingReplicateEntry
---@field index number
---@field itemID number
---@field quantity number
---@field buyout number

local frame = CreateFrame("Frame")
---@type fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
local processFullScan
---@type ArbitrageScanSource?
local source
local awaitingResponse = false
local scanGeneration = 0
local issuingArbitrageReplication = false
---@type thread?
local scanWorker
---@type number?
local workerGeneration
local workerDeadline = 0
local replicateRowsThisFrame = 0
local RESPONSE_TIMEOUT_SECONDS = 30
local ITEM_LOAD_TIMEOUT_SECONDS = 10
local WORK_BUDGET_MILLISECONDS = 4
local MAX_REPLICATE_ROWS_PER_FRAME = 500
local FULL_SCAN_COOLDOWN_SECONDS = 15 * 60
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
  awaitingResponse = false
  scanWorker = nil
  workerGeneration = nil
  scanGeneration = scanGeneration + 1
end

---@param reason string
local function CancelScan(reason)
  local cancelledSource = source
  Reset()
  if cancelledSource == "arbitrage" then
    Print("Full scan cancelled: " .. reason)
  end
end

---@param reason string
local function FailScan(reason)
  local failedSource = source
  Reset()
  if failedSource == "arbitrage" then
    Print("Full scan incomplete: " .. reason .. "; previous data kept")
  end
end

---@param newSource ArbitrageScanSource
local function BeginScan(newSource)
  source = newSource
  awaitingResponse = true
  local generation = scanGeneration
  C_Timer.After(RESPONSE_TIMEOUT_SECONDS, function()
    if generation == scanGeneration and source ~= nil and awaitingResponse then
      FailScan("no Auction House response after " .. RESPONSE_TIMEOUT_SECONDS .. " seconds")
    end
  end)
end

local function Checkpoint()
  if debugprofilestop() >= workerDeadline then
    coroutine.yield()
  end
end

local function ReplicateCheckpoint()
  replicateRowsThisFrame = replicateRowsThisFrame + 1
  if replicateRowsThisFrame >= MAX_REPLICATE_ROWS_PER_FRAME or debugprofilestop() >= workerDeadline then
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
  replicateRowsThisFrame = 0
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

---@param value any
---@return boolean
local function IsPositiveNumber(value)
  return type(value) == "number" and value == value and value > 0 and value < math.huge
end

---@param index number
---@return number? quantity, number? buyout, number? itemID
local function GetReplicateValues(index)
  local _, _, quantity, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(index)
  return quantity, buyout, itemID
end

---@param itemLink string?
---@param quantity number?
---@param buyout number?
---@return ArbitrageScanEntry?
local function CreateScanEntry(itemLink, quantity, buyout)
  if type(itemLink) ~= "string" or not IsPositiveNumber(quantity) or not IsPositiveNumber(buyout) then
    return nil
  end

  return {
    itemLink = itemLink,
    quantity = quantity,
    buyout = buyout,
  }
end

---@param entries ArbitrageScanEntry[]
---@param itemLink string?
---@param quantity number?
---@param buyout number?
local function AppendScanEntry(entries, itemLink, quantity, buyout)
  local entry = CreateScanEntry(itemLink, quantity, buyout)
  if entry then
    entries[#entries + 1] = entry
  end
end

---@param count number
---@param generation number
local function ProcessReplicateScan(count, generation)
  ---@type ArbitrageScanEntry[]
  local entries = {}
  ---@type ArbitragePendingReplicateEntry[]
  local pendingRows = {}
  local pendingItems = {}
  local pendingItemLoads = 0

  for index = 0, count - 1 do
    local quantity, buyout, itemID = GetReplicateValues(index)
    if IsPositiveNumber(quantity) and IsPositiveNumber(buyout) then
      local itemLink = C_AuctionHouse.GetReplicateItemLink(index)
      if type(itemLink) == "string" then
        AppendScanEntry(entries, itemLink, quantity, buyout)
      elseif IsPositiveNumber(itemID) then
        ---@cast itemID number
        pendingRows[#pendingRows + 1] = {
          index = index,
          itemID = itemID,
          quantity = quantity,
          buyout = buyout,
        }

        if not pendingItems[itemID] then
          pendingItems[itemID] = true
          pendingItemLoads = pendingItemLoads + 1
          Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
            if generation == scanGeneration and source ~= nil and pendingItems[itemID] then
              pendingItems[itemID] = nil
              pendingItemLoads = pendingItemLoads - 1
            end
          end)
        end
      end
    end

    if generation ~= scanGeneration then
      return
    end
    ReplicateCheckpoint()
  end

  if pendingItemLoads > 0 then
    C_Timer.After(ITEM_LOAD_TIMEOUT_SECONDS, function()
      if generation == scanGeneration and source ~= nil and pendingItemLoads > 0 then
        local itemLabel = pendingItemLoads == 1 and "item" or "items"
        FailScan(
          "timed out waiting for "
            .. pendingItemLoads
            .. " "
            .. itemLabel
            .. " after "
            .. ITEM_LOAD_TIMEOUT_SECONDS
            .. " seconds"
        )
      end
    end)
    while pendingItemLoads > 0 do
      coroutine.yield()
    end
  end

  for _, pendingRow in ipairs(pendingRows) do
    local _, _, currentItemID = GetReplicateValues(pendingRow.index)
    if currentItemID ~= pendingRow.itemID then
      FailScan(
        "auction row "
          .. pendingRow.index
          .. " changed from item "
          .. pendingRow.itemID
          .. " to "
          .. tostring(currentItemID)
      )
      return
    end

    local itemLink = C_AuctionHouse.GetReplicateItemLink(pendingRow.index)
    if type(itemLink) ~= "string" then
      FailScan("item link for auction row " .. pendingRow.index .. " remained unavailable")
      return
    end

    AppendScanEntry(entries, itemLink, pendingRow.quantity, pendingRow.buyout)
    ReplicateCheckpoint()
  end

  processFullScan(entries, count, Checkpoint)
end

local function CaptureResponse()
  if source == nil or not awaitingResponse then
    return
  end

  awaitingResponse = false
  ns.Database.RecordReplicateScan(time())
  local count = C_AuctionHouse.GetNumReplicateItems()
  if source == "arbitrage" then
    Print("Received " .. count .. " auctions; calculating market prices")
  end

  local generation = scanGeneration
  StartWorker(function()
    ProcessReplicateScan(count, generation)
  end)
end

function ns.Scan.Start()
  if source ~= nil then
    Print("A full scan is already in progress")
    return
  end

  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Print("Open the Auction House before starting a full scan")
    return
  end

  local lastReplicateScan = ns.Database.GetLastReplicateScan()
  if type(lastReplicateScan) == "number" then
    local elapsedSeconds = time() - lastReplicateScan
    if elapsedSeconds >= 0 and elapsedSeconds < FULL_SCAN_COOLDOWN_SECONDS then
      local remainingSeconds = FULL_SCAN_COOLDOWN_SECONDS - elapsedSeconds
      local remainingMinutes = math.ceil(remainingSeconds / 60)
      local minuteLabel = remainingMinutes == 1 and "minute" or "minutes"
      Print("Full scans are unavailable; best guess: try again in " .. remainingMinutes .. " " .. minuteLabel)
      return
    end
  end

  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    Print("The Auction House is busy; try again shortly")
    return
  end

  SelectAuctionHouseMarket()
  BeginScan("arbitrage")
  Print("Starting full scan")
  issuingArbitrageReplication = true
  C_AuctionHouse.ReplicateItems()
  issuingArbitrageReplication = false
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "AUCTION_HOUSE_SHOW" then
      SelectAuctionHouseMarket()
    elseif eventName == "REPLICATE_ITEM_LIST_UPDATE" then
      CaptureResponse()
    elseif eventName == "AUCTION_HOUSE_CLOSED" and source ~= nil then
      CancelScan("Auction House closed")
    end
  end)
  frame:SetScript("OnUpdate", ResumeWorker)

  hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
    if issuingArbitrageReplication or source ~= nil then
      return
    end

    SelectAuctionHouseMarket()
    BeginScan("external")
  end)
end

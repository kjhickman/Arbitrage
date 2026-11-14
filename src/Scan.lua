local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"external"

---@class ArbitrageScanEntry
---@field itemLink string? present when the row's key needs the link's suffix
---@field itemID number? present when the row is keyed by item ID alone
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
---@type thread?
local scanWorker
---@type number?
local workerGeneration
local workerDeadline = 0
local replicateRowsThisFrame = 0
local RESPONSE_TIMEOUT_SECONDS = 30
local ITEM_LINK_STALL_SECONDS = 10
local ITEM_LINK_TIMEOUT_SECONDS = 60
local ITEM_LINK_RETRY_SECONDS = 0.2
local WORK_BUDGET_MILLISECONDS = 4
local MAX_REPLICATE_ROWS_PER_FRAME = 500
local PROGRESS_INTERVAL_ROWS = 25000
local MAX_REPORTED_ITEM_IDS = 10
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
  -- The throttle is account-wide and spends itself on refused requests too, so
  -- the cooldown has to count attempts rather than completed scans.
  ns.Database.RecordReplicateScan(time())
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

-- A full scan of a busy realm reads hundreds of thousands of rows over several
-- minutes, so report milestones rather than leaving the chat frame silent.
---@param rowsRead number
---@param count number
local function ReportCollectionProgress(rowsRead, count)
  if source ~= "arbitrage" or rowsRead % PROGRESS_INTERVAL_ROWS ~= 0 or rowsRead >= count then
    return
  end

  Print("Read " .. rowsRead .. " of " .. count .. " auctions")
end

---@param count number
---@param generation number
local function ProcessReplicateScan(count, generation)
  ---@type ArbitrageScanEntry[]
  local entries = {}
  ---@type ArbitragePendingReplicateEntry[]
  local pendingRows = {}
  local pendingItems = {}
  local retryReady = false
  local retryScheduled = false
  local itemLinkTimedOut = false
  local resolvedSinceDeadline = false
  local skippedRows = 0
  local failedItemIDs = {}

  ---@param pendingRow ArbitragePendingReplicateEntry
  local function RecordSkippedRow(pendingRow)
    skippedRows = skippedRows + 1
    failedItemIDs[pendingRow.itemID] = true
  end

  local function ScheduleRetry()
    if retryScheduled then
      return
    end

    retryScheduled = true
    C_Timer.After(ITEM_LINK_RETRY_SECONDS, function()
      if generation == scanGeneration and source ~= nil then
        retryScheduled = false
        retryReady = true
      end
    end)
  end

  for index = 0, count - 1 do
    local quantity, buyout, itemID = GetReplicateValues(index)
    if
      IsPositiveNumber(quantity)
      and IsPositiveNumber(buyout)
      and IsPositiveNumber(itemID)
      and C_Item.DoesItemExistByID(itemID)
    then
      ---@cast itemID number
      local itemLink = C_AuctionHouse.GetReplicateItemLink(index)
      if type(itemLink) == "string" then
        entries[#entries + 1] = {
          itemLink = itemLink,
          quantity = quantity,
          buyout = buyout,
        }
      else
        -- Only gear needs the link, so everything else is keyed from the item
        -- ID the replicate row already carries instead of waiting on the item
        -- cache behind a queue it does not belong in.
        if ns.Keys.NeedsLink(itemID) then
          pendingRows[#pendingRows + 1] = {
            index = index,
            itemID = itemID,
            quantity = quantity,
            buyout = buyout,
          }

          if not pendingItems[itemID] then
            pendingItems[itemID] = true
            Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
              if generation == scanGeneration and source ~= nil then
                retryReady = true
              end
            end)
          end
        else
          entries[#entries + 1] = {
            itemID = itemID,
            quantity = quantity,
            buyout = buyout,
          }
        end
      end
    end

    if generation ~= scanGeneration then
      return
    end
    ReportCollectionProgress(index + 1, count)
    ReplicateCheckpoint()
  end

  -- The item cache feeds links back at its own pace, so give up on a stall
  -- rather than on a fixed budget that a large backlog would blow through
  -- while rows were still arriving. The ceiling below bounds a slow drip.
  local function ArmStallDeadline()
    C_Timer.After(ITEM_LINK_STALL_SECONDS, function()
      if generation ~= scanGeneration or source == nil or itemLinkTimedOut then
        return
      end

      if resolvedSinceDeadline then
        resolvedSinceDeadline = false
        ArmStallDeadline()
      else
        itemLinkTimedOut = true
      end
    end)
  end

  if #pendingRows > 0 then
    if source == "arbitrage" then
      local pendingLabel = #pendingRows == 1 and "auction" or "auctions"
      Print("Waiting for item data on " .. #pendingRows .. " " .. pendingLabel)
    end

    ArmStallDeadline()
    C_Timer.After(ITEM_LINK_TIMEOUT_SECONDS, function()
      if generation == scanGeneration and source ~= nil then
        itemLinkTimedOut = true
      end
    end)
  end

  while #pendingRows > 0 and not itemLinkTimedOut do
    if not retryReady then
      ScheduleRetry()
      coroutine.yield()
    else
      retryReady = false
      ---@type ArbitragePendingReplicateEntry[]
      local unresolvedRows = {}

      for _, pendingRow in ipairs(pendingRows) do
        local _, _, currentItemID = GetReplicateValues(pendingRow.index)
        if currentItemID ~= pendingRow.itemID then
          RecordSkippedRow(pendingRow)
        else
          local itemLink = C_AuctionHouse.GetReplicateItemLink(pendingRow.index)
          if type(itemLink) == "string" then
            entries[#entries + 1] = {
              itemLink = itemLink,
              quantity = pendingRow.quantity,
              buyout = pendingRow.buyout,
            }
          else
            unresolvedRows[#unresolvedRows + 1] = pendingRow
          end
        end

        ReplicateCheckpoint()
      end

      if #unresolvedRows < #pendingRows then
        resolvedSinceDeadline = true
      end
      pendingRows = unresolvedRows
    end
  end

  for _, pendingRow in ipairs(pendingRows) do
    RecordSkippedRow(pendingRow)
  end

  if skippedRows > 0 and source == "arbitrage" then
    local auctionLabel = skippedRows == 1 and "auction" or "auctions"
    local itemIDs = {}
    for itemID in pairs(failedItemIDs) do
      itemIDs[#itemIDs + 1] = itemID
    end
    table.sort(itemIDs)
    -- A large scan can fail on hundreds of distinct items; listing them all
    -- buries every other scan message under a wall of numbers.
    local reported = {}
    for index = 1, math.min(#itemIDs, MAX_REPORTED_ITEM_IDS) do
      reported[index] = tostring(itemIDs[index])
    end
    local unreportedCount = #itemIDs - #reported
    local itemIDLabel = #itemIDs == 1 and "item ID " or "item IDs "
    local overflowLabel = unreportedCount > 0 and (" and " .. unreportedCount .. " more") or ""
    Print(
      "Full scan skipped "
        .. skippedRows
        .. " "
        .. auctionLabel
        .. " with unavailable item data ("
        .. itemIDLabel
        .. table.concat(reported, ", ")
        .. overflowLabel
        .. ")"
    )
  end

  if source == "arbitrage" then
    Print("Read " .. #entries .. " usable auctions; calculating market prices")
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
    Print("Received " .. count .. " auctions; reading auction data")
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
  C_AuctionHouse.ReplicateItems()
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  -- Registering an event the client does not know throws, which would abort the
  -- rest of this file and leave the addon unable to scan at all.
  pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "AUCTION_HOUSE_SHOW" then
      SelectAuctionHouseMarket()
    elseif eventName == "REPLICATE_ITEM_LIST_UPDATE" then
      CaptureResponse()
    elseif eventName == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and awaitingResponse then
      FailScan("the Auction House throttled the request")
    elseif eventName == "AUCTION_HOUSE_CLOSED" and source ~= nil then
      CancelScan("Auction House closed")
    end
  end)
  frame:SetScript("OnUpdate", ResumeWorker)

  hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
    if source ~= nil then
      return
    end

    SelectAuctionHouseMarket()
    BeginScan("external")
  end)
end

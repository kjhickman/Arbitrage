local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"external"
---@alias ArbitrageScanPhase "idle"|"waiting"|"reading"|"pricing"

---@class ArbitrageScanStatus
---@field phase ArbitrageScanPhase
---@field progress number?
---@field cooldownRemainingMinutes number?

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
---@type ArbitrageScanPhase
local phase = "idle"
---@type number?
local scanProgress
---@type number?
local lastReportedCooldownMinutes
local scanGeneration = 0
---@type thread?
local scanWorker
---@type number?
local workerGeneration
local workerDeadline = 0
local replicateRowsThisFrame = 0
---@type fun(itemID: number, success: boolean?)?
local onItemDataLoaded
local ITEM_LINK_TIMEOUT_SECONDS = 2
local ITEM_LINK_RETRY_SECONDS = 0.4
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

---@return number?
local function GetCooldownRemainingMinutes()
  local lastReplicateScan = ns.Database.GetLastReplicateScan()
  if type(lastReplicateScan) ~= "number" then
    return nil
  end

  local elapsedSeconds = time() - lastReplicateScan
  if elapsedSeconds < 0 or elapsedSeconds >= FULL_SCAN_COOLDOWN_SECONDS then
    return nil
  end

  return math.ceil((FULL_SCAN_COOLDOWN_SECONDS - elapsedSeconds) / 60)
end

local function Reset()
  local wasActive = source ~= nil
  source = nil
  phase = "idle"
  scanProgress = nil
  scanWorker = nil
  workerGeneration = nil
  onItemDataLoaded = nil
  scanGeneration = scanGeneration + 1
  lastReportedCooldownMinutes = GetCooldownRemainingMinutes()
  if wasActive then
    ns.OpportunityPanel.RefreshScanStatus()
  end
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
  phase = "waiting"
  scanProgress = nil
  -- The throttle is account-wide and spends itself on refused requests too, so
  -- the cooldown has to count attempts rather than completed scans.
  ns.Database.RecordReplicateScan(time())
  ns.OpportunityPanel.RefreshScanStatus()
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
    if phase == "idle" and lastReportedCooldownMinutes ~= nil then
      local currentCooldown = GetCooldownRemainingMinutes()
      if currentCooldown ~= lastReportedCooldownMinutes then
        lastReportedCooldownMinutes = currentCooldown
        ns.OpportunityPanel.RefreshScanStatus()
      end
    end
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

---@param count number
---@param generation number
local function ProcessReplicateScan(count, generation)
  ---@type ArbitrageScanEntry[]
  local entries = {}
  ---@type ArbitragePendingReplicateEntry[]
  local pendingRows = {}
  local pendingItems = {}
  local pendingItemIDs = {}
  local loadedItems = {}
  local retryReady = false
  local retryScheduled = false
  local itemLinkTimedOut = false

  ---@param completedRows number
  local function UpdateReadingProgress(completedRows)
    local nextProgress = count > 0 and math.floor((completedRows / count) * 100) or 100
    if nextProgress ~= scanProgress then
      scanProgress = nextProgress
      ns.OpportunityPanel.RefreshScanStatus()
    end
  end

  local function ScheduleRetry()
    if retryScheduled then
      return
    end

    retryScheduled = true
    C_Timer.After(ITEM_LINK_RETRY_SECONDS, function()
      if generation ~= scanGeneration or source == nil then
        return
      end

      retryScheduled = false
      for _, itemID in ipairs(pendingItemIDs) do
        if not loadedItems[itemID] then
          C_Item.RequestLoadItemDataByID(itemID)
        end
      end
      retryReady = true
    end)
  end

  onItemDataLoaded = function(itemID, success)
    if pendingItems[itemID] then
      if success then
        loadedItems[itemID] = true
      end
      retryReady = true
    end
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
            pendingItemIDs[#pendingItemIDs + 1] = itemID
            C_Item.RequestLoadItemDataByID(itemID)
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
    UpdateReadingProgress(index + 1 - #pendingRows)
    ReplicateCheckpoint()
  end

  if #pendingRows > 0 then
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
      loadedItems = {}
      ---@type ArbitragePendingReplicateEntry[]
      local unresolvedRows = {}
      local unresolvedItems = {}
      local unresolvedItemIDs = {}

      for _, pendingRow in ipairs(pendingRows) do
        local _, _, currentItemID = GetReplicateValues(pendingRow.index)
        if currentItemID == pendingRow.itemID then
          local itemLink = C_AuctionHouse.GetReplicateItemLink(pendingRow.index)
          if type(itemLink) == "string" then
            entries[#entries + 1] = {
              itemLink = itemLink,
              quantity = pendingRow.quantity,
              buyout = pendingRow.buyout,
            }
          else
            unresolvedRows[#unresolvedRows + 1] = pendingRow
            if not unresolvedItems[pendingRow.itemID] then
              unresolvedItems[pendingRow.itemID] = true
              unresolvedItemIDs[#unresolvedItemIDs + 1] = pendingRow.itemID
            end
          end
        end

        ReplicateCheckpoint()
      end

      pendingRows = unresolvedRows
      pendingItems = unresolvedItems
      pendingItemIDs = unresolvedItemIDs
      UpdateReadingProgress(count - #pendingRows)
    end
  end

  onItemDataLoaded = nil
  phase = "pricing"
  scanProgress = nil
  ns.OpportunityPanel.RefreshScanStatus()
  processFullScan(entries, count, Checkpoint)
end

local function CaptureResponse()
  if source == nil or phase ~= "waiting" then
    return
  end

  phase = "reading"
  ns.Database.RecordReplicateScan(time())
  local count = C_AuctionHouse.GetNumReplicateItems()
  scanProgress = count > 0 and 0 or 100
  ns.OpportunityPanel.RefreshScanStatus()

  local generation = scanGeneration
  StartWorker(function()
    ProcessReplicateScan(count, generation)
  end)
end

---@return ArbitrageScanStatus
function ns.Scan.GetStatus()
  local cooldownRemainingMinutes = phase == "idle" and GetCooldownRemainingMinutes() or nil
  lastReportedCooldownMinutes = cooldownRemainingMinutes
  return {
    phase = phase,
    progress = scanProgress,
    cooldownRemainingMinutes = cooldownRemainingMinutes,
  }
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

  local remainingMinutes = GetCooldownRemainingMinutes()
  if remainingMinutes then
    local minuteLabel = remainingMinutes == 1 and "minute" or "minutes"
    Print("Full scans are unavailable; best guess: try again in " .. remainingMinutes .. " " .. minuteLabel)
    return
  end

  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    Print("The Auction House is busy; try again shortly")
    return
  end

  SelectAuctionHouseMarket()
  BeginScan("arbitrage")
  C_AuctionHouse.ReplicateItems()
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: fun())
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  -- Registering an event the client does not know throws, which would abort the
  -- rest of this file and leave the addon unable to scan at all.
  pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      SelectAuctionHouseMarket()
    elseif eventName == "REPLICATE_ITEM_LIST_UPDATE" then
      CaptureResponse()
    elseif eventName == "ITEM_DATA_LOAD_RESULT" and onItemDataLoaded then
      onItemDataLoaded(itemID, success)
    elseif eventName == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and phase == "waiting" then
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

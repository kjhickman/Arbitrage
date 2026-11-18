local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"external"
---@alias ArbitrageScanPhase "idle"|"waiting"|"reading"|"pricing"
---@alias ArbitrageScanCheckpoint fun(progress: number?)

---@class ArbitrageScanStatus
---@field phase ArbitrageScanPhase
---@field progress number?
---@field elapsedSeconds number? time spent waiting for the server
---@field cooldownRemainingMinutes number?

---@class ArbitrageScanEntry
---@field itemLink string? present when the row's key needs the link's suffix
---@field itemID number? present when the row is keyed by item ID alone
---@field quantity number
---@field buyout number

---@class ArbitrageScanOutcome
---@field message string what chat was told
---@field at number

---@class ArbitragePendingReplicateEntry
---@field index number
---@field itemID number
---@field quantity number
---@field buyout number

local frame = CreateFrame("Frame")
---@type fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: ArbitrageScanCheckpoint): string
local processFullScan
---@type ArbitrageScanOutcome?
local lastOutcome
---@type ArbitrageScanSource?
local source
---@type ArbitrageScanPhase
local phase = "idle"
---@type number?
local scanProgress
---@type number?
local lastReportedElapsedSeconds
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
-- Zones whose only Auction House is a neutral one.
local NEUTRAL_AUCTION_HOUSE_MAPS = {
  [1434] = true, -- Stranglethorn Vale
  [1446] = true, -- Tanaris
  [1452] = true, -- Winterspring
}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

-- Arbitrage prices only the player's faction Auction House: neutral ones keep separate prices,
-- take a larger cut, and are missing from TradeSkillMaster's data. Scanning one would mix its
-- prices into the faction's, so it is refused instead.
---@return boolean
function ns.Scan.IsAtNeutralAuctionHouse()
  local mapID = C_Map.GetBestMapForUnit("player")
  return mapID ~= nil and NEUTRAL_AUCTION_HOUSE_MAPS[mapID] == true
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

---@return number?
local function GetElapsedWaitingSeconds()
  local startedAt = phase == "waiting" and ns.Database.GetLastReplicateScan()
  return startedAt and math.max(0, time() - startedAt) or nil
end

local function Reset()
  local wasActive = source ~= nil
  source = nil
  phase = "idle"
  scanProgress = nil
  lastReportedElapsedSeconds = nil
  scanWorker = nil
  workerGeneration = nil
  onItemDataLoaded = nil
  scanGeneration = scanGeneration + 1
  lastReportedCooldownMinutes = GetCooldownRemainingMinutes()
  if wasActive then
    ns.OpportunityPanel.RefreshScanStatus()
  end
end

-- Tells chat how a scan ended and keeps it for the scan button's tooltip.
---@param message string
local function Report(message)
  lastOutcome = { message = message, at = time() }
  Print(message)
end

-- Both report scans another addon started too: its players are told to wait for Arbitrage in chat.
---@param reason string
local function CancelScan(reason)
  Reset()
  Report("Full scan cancelled: " .. reason)
end

---@param reason string
local function FailScan(reason)
  Reset()
  Report("Full scan incomplete: " .. reason .. "; previous data kept")
end

---@param newSource ArbitrageScanSource
local function BeginScan(newSource)
  source = newSource
  phase = "waiting"
  scanProgress = nil
  lastReportedElapsedSeconds = 0
  -- The throttle is account-wide and spends itself on refused requests too, so
  -- the cooldown has to count attempts rather than completed scans.
  ns.Database.RecordReplicateScan(time())
  ns.OpportunityPanel.RefreshScanStatus()
end

---@param progress number
local function UpdateProgress(progress)
  local percent = math.floor(progress)
  if percent ~= scanProgress then
    scanProgress = percent
    ns.OpportunityPanel.RefreshScanStatus()
  end
end

---@param progress number?
local function Checkpoint(progress)
  if progress then
    UpdateProgress(progress)
  end
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
    if phase == "waiting" then
      local elapsedSeconds = GetElapsedWaitingSeconds()
      if elapsedSeconds ~= lastReportedElapsedSeconds then
        lastReportedElapsedSeconds = elapsedSeconds
        ns.OpportunityPanel.RefreshScanStatus()
      end
    elseif phase == "idle" and lastReportedCooldownMinutes ~= nil then
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
    UpdateProgress(count > 0 and completedRows / count * 100 or 100)
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
  scanProgress = 0
  ns.OpportunityPanel.RefreshScanStatus()
  Report(processFullScan(entries, count, Checkpoint))
end

local function CaptureResponse()
  if source == nil or phase ~= "waiting" then
    return
  end

  phase = "reading"
  lastReportedElapsedSeconds = nil
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
  local elapsedSeconds = GetElapsedWaitingSeconds()
  lastReportedCooldownMinutes = cooldownRemainingMinutes
  lastReportedElapsedSeconds = elapsedSeconds
  return {
    phase = phase,
    progress = scanProgress,
    elapsedSeconds = elapsedSeconds,
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

  if ns.Scan.IsAtNeutralAuctionHouse() then
    Print("Arbitrage only scans your faction's Auction House")
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

  BeginScan("arbitrage")
  C_AuctionHouse.ReplicateItems()
end

-- Stops waiting for a server that may never answer. Only the wait can be cancelled: reading is
-- quick, and pricing works from auctions already read. The request still counts toward the cooldown.
function ns.Scan.Cancel()
  if phase == "waiting" then
    CancelScan("stopped waiting for the server")
  end
end

-- How the latest scan this session ended, or nil before one has.
---@return ArbitrageScanOutcome?
function ns.Scan.GetLastOutcome()
  return lastOutcome
end

---@param process fun(scanEntries: ArbitrageScanEntry[]?, rawEntryCount: number?, checkpoint: ArbitrageScanCheckpoint): string
function ns.Scan.Init(process)
  processFullScan = process

  frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  -- Registering an event the client does not know throws, which would abort the
  -- rest of this file and leave the addon unable to scan at all.
  pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "REPLICATE_ITEM_LIST_UPDATE" then
      CaptureResponse()
    elseif eventName == "ITEM_DATA_LOAD_RESULT" and onItemDataLoaded then
      onItemDataLoaded(itemID, success)
    elseif eventName == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and phase == "waiting" then
      FailScan("the Auction House throttled the request")
    elseif eventName == "AUCTION_HOUSE_CLOSED" and source ~= nil and phase ~= "pricing" then
      -- Pricing works from auctions already read, so only waiting and reading need the window.
      CancelScan("Auction House closed")
    end
  end)
  frame:SetScript("OnUpdate", ResumeWorker)

  hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
    if source ~= nil then
      return
    end

    if ns.Scan.IsAtNeutralAuctionHouse() then
      -- The request still spends the account-wide throttle, so the cooldown counts it.
      ns.Database.RecordReplicateScan(time())
      ns.OpportunityPanel.RefreshScanStatus()
      Print("Ignoring another addon's full scan: Arbitrage only prices your faction's Auction House")
      return
    end

    BeginScan("external")
    -- The scan runs from the other addon's tab, so chat is the only place to say Arbitrage is pricing it.
    Print("Another addon started a full scan; keep the Auction House open until Arbitrage reports it's done")
  end)
end

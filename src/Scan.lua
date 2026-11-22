local _, ns = ...

ns.Scan = {}

---@alias ArbitrageScanSource "arbitrage"|"external"
---@alias ArbitrageScanKind "full"|"quick"
---@alias ArbitrageScanPhase "idle"|"waiting"|"reading"|"pricing"
---@alias ArbitrageScanCheckpoint fun(progress: number?)

---@class ArbitrageScanStatus
---@field phase ArbitrageScanPhase
---@field kind ArbitrageScanKind?
---@field progress number?
---@field elapsedSeconds number? time spent waiting for the server
---@field cooldownRemainingMinutes number?

---@class ArbitrageScanEntry
---@field itemLink string? present when the row's key needs the link's suffix
---@field itemID number? present when the row is keyed by item ID alone, as is gear whose link never loaded
---@field quantity number
---@field buyout number

-- Prices one full scan: the scan adds each auction as it reads it, then finishes once reading ends.
---@class ArbitrageFullScanPricing
---@field Add fun(entry: ArbitrageScanEntry)
---@field Finish fun(rawEntryCount: number, checkpoint: ArbitrageScanCheckpoint): string outcome to report

---@class ArbitrageScanOutcome
---@field message string what chat was told
---@field at number

---@class ArbitragePendingReplicateEntry
---@field index number
---@field itemID number
---@field quantity number
---@field buyout number
---@field quality number? the last quality seen, kept in case the game drops the item's data again

---@class ArbitrageQuickScan
---@field query AuctionHouseBrowseQuery
---@field startedAt number
---@field lastActivityAt number
---@field sent boolean whether the query reached the game's API
---@field sawFirstPage boolean
---@field needsPage boolean?
---@field observedAt number? when Auctionator received the final page

local frame = CreateFrame("Frame")
---@type fun(): ArbitrageFullScanPricing
local startFullScan
---@type fun(buyouts: table<string, number>, observedAt: number): boolean
local processQuickScan
---@type table<ArbitrageScanKind, ArbitrageScanOutcome>
local lastOutcomes = {}
---@type ArbitrageScanSource?
local source
---@type ArbitrageQuickScan?
local quick
---@type AuctionHouseBrowseQuery?
local lastBrowseQuery
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
-- How long to keep waiting for item data after the last load that priced an auction.
local ITEM_DATA_TIMEOUT_SECONDS = 2
-- An item that loads this often with its auctions still incomplete isn't requested again.
local MAX_INCOMPLETE_ITEM_LOADS = 3
-- How long to wait before requesting such an item again, since gear's link can follow its data.
local INCOMPLETE_ITEM_RETRY_SECONDS = 0.4
-- Items loading or waiting to be read at once, well under the couple of thousand the game holds.
local MAX_ITEMS_LOADING = 500
-- The most auctions read in a frame, a safety net under the work budget: at about 15 µs an auction,
-- even the largest budget stops near 1,400.
local MAX_REPLICATE_ROWS_PER_FRAME = 2000
-- Enough names to spot-check without flooding chat when hundreds of links fail.
local MAX_LISTED_ITEMS = 5
local FULL_SCAN_COOLDOWN_SECONDS = 15 * 60
local BROWSE_TIMEOUT_SECONDS = 60
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
  local startedAt = phase == "waiting" and (quick and quick.startedAt or ns.Database.GetLastReplicateScan())
  return startedAt and math.max(0, time() - startedAt) or nil
end

local function Reset()
  local wasActive = source ~= nil
  source = nil
  quick = nil
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
---@param isQuick boolean?
local function Report(message, isQuick)
  lastOutcomes[isQuick and "quick" or "full"] = { message = message, at = time() }
  Print(message)
end

-- Both report scans another addon started too: its players are told to wait for Arbitrage in chat.
---@param reason string
local function CancelScan(reason)
  local isQuick = quick ~= nil
  Reset()
  Report((isQuick and "Quick scan" or "Full scan") .. " cancelled: " .. reason, isQuick)
end

---@param reason string
local function FailScan(reason)
  local isQuick = quick ~= nil
  Reset()
  Report((isQuick and "Quick scan" or "Full scan") .. " incomplete: " .. reason .. "; previous data kept", isQuick)
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
      if quick then
        if time() - quick.lastActivityAt >= BROWSE_TIMEOUT_SECONDS then
          FailScan("timed out waiting for browse results")
          return
        elseif quick.needsPage and C_AuctionHouse.IsThrottledMessageSystemReady() then
          quick.needsPage = false
          C_AuctionHouse.RequestMoreBrowseResults()
        end
      end
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

  workerDeadline = debugprofilestop() + ns.Config.Get("scanWorkBudget")
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
---@return number? quantity, number? buyout, number? itemID, number? quality
local function GetReplicateValues(index)
  local _, _, quantity, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
    C_AuctionHouse.GetReplicateItemInfo(index)
  return quantity, buyout, itemID, quality
end

---@param itemID number
---@param quality number?
---@return number?
local function ResolveQuality(itemID, quality)
  if (quality == nil or quality < 0) and C_Item.IsItemDataCachedByID(itemID) then
    quality = select(3, C_Item.GetItemInfo(itemID))
  end
  return quality and quality >= 0 and quality or nil
end

-- Names the gear a full scan priced by item ID, a few at a time so hundreds stay one chat line.
-- Their links never loaded, so some names may still be unknown.
---@param itemIDs number[]
---@return string
local function DescribeUnlinkedGear(itemIDs)
  local names = {}
  for index, itemID in ipairs(itemIDs) do
    names[index] = C_Item.GetItemInfo(itemID) or ("Item #" .. itemID)
  end
  table.sort(names)
  local list = table.concat(names, ", ", 1, math.min(#names, MAX_LISTED_ITEMS))
  if #names > MAX_LISTED_ITEMS then
    list = list .. " and " .. (#names - MAX_LISTED_ITEMS) .. " more"
  end
  local items = #names == 1 and "1 gear item" or #names .. " gear items"
  return "Priced " .. items .. " without their random enchants because their item links didn't load: " .. list
end

-- Auctions read before their item's data loaded wait under their item. The game keeps only a couple
-- of thousand such items loaded at once, dropping the oldest for each new one, and an item's
-- auctions are spread across the whole list, so an item loaded early would be dropped before its
-- later auctions come up. Waiting items are therefore requested once reading ends, each once, and
-- each item's auctions are read as soon as its data arrives, rather than on a timer.
---@param count number
---@param generation number
local function ProcessReplicateScan(count, generation)
  local pricing = startFullScan()
  ---@type table<number, ArbitragePendingReplicateEntry[]>
  local waitingByItem = {}
  -- Items in the order their auctions began waiting.
  ---@type number[]
  local waitingItemIDs = {}
  local waitingCount = 0
  -- Items to request, in order: every waiting item, then any that loaded with auctions incomplete.
  ---@type number[]
  local requestQueue = {}
  local nextRequest = 1
  -- Items requested and not yet read since, which the game must still be holding.
  local requestedItems = {}
  local outstandingRequests = 0
  -- How often each item has loaded with its auctions still incomplete.
  local incompleteLoads = {}
  -- Such items waiting out the retry delay before they're queued again.
  local retriesPending = 0
  ---@type number[]
  local loadedItemIDs = {}
  local loadedItems = {}
  local timeoutToken = 0
  local timedOut = false
  local unlinkedItemIDs, unlinked = {}, {}

  ---@param completedRows number
  local function UpdateReadingProgress(completedRows)
    UpdateProgress(count > 0 and completedRows / count * 100 or 100)
  end

  local function RequestQueued()
    while nextRequest <= #requestQueue and outstandingRequests < MAX_ITEMS_LOADING do
      local itemID = requestQueue[nextRequest]
      nextRequest = nextRequest + 1
      requestedItems[itemID] = true
      outstandingRequests = outstandingRequests + 1
      C_Item.RequestLoadItemDataByID(itemID)
    end
  end

  ---@param row ArbitragePendingReplicateEntry
  local function Wait(row)
    local rows = waitingByItem[row.itemID]
    if not rows then
      rows = {}
      waitingByItem[row.itemID] = rows
      waitingItemIDs[#waitingItemIDs + 1] = row.itemID
      requestQueue[#requestQueue + 1] = row.itemID
    end
    rows[#rows + 1] = row
    waitingCount = waitingCount + 1
  end

  -- Prices a waiting auction once its quality and, for gear, its link are known. When giving up,
  -- gear whose link never loaded is priced by item ID and an unknown quality is dropped.
  ---@param row ArbitragePendingReplicateEntry
  ---@param givingUp boolean?
  ---@return boolean done
  local function Resolve(row, givingUp)
    local _, _, currentItemID, quality = GetReplicateValues(row.index)
    if currentItemID ~= row.itemID then
      return true
    end
    quality = ResolveQuality(row.itemID, quality) or row.quality
    row.quality = quality
    if quality == Enum.ItemQuality.Poor then
      return true
    end

    local itemLink = C_AuctionHouse.GetReplicateItemLink(row.index)
    itemLink = type(itemLink) == "string" and itemLink or nil
    if quality and (itemLink or not ns.Keys.NeedsLink(row.itemID)) then
      pricing.Add({
        itemID = row.itemID,
        itemLink = itemLink,
        quantity = row.quantity,
        buyout = row.buyout,
      })
    elseif not givingUp then
      return false
    elseif quality then
      pricing.Add({
        itemID = row.itemID,
        quantity = row.quantity,
        buyout = row.buyout,
      })
      if not unlinked[row.itemID] then
        unlinked[row.itemID] = true
        unlinkedItemIDs[#unlinkedItemIDs + 1] = row.itemID
      end
    end
    return true
  end

  -- Reads the waiting auctions of items whose data just loaded, while the game still holds it.
  ---@return boolean progressed
  local function ResolveLoaded()
    local progressed = false
    local position = 1
    -- Loads that arrive while this pauses join the end of the list.
    while position <= #loadedItemIDs do
      local itemID = loadedItemIDs[position]
      position = position + 1
      loadedItems[itemID] = nil
      requestedItems[itemID] = nil
      outstandingRequests = outstandingRequests - 1

      local rows = waitingByItem[itemID]
      if rows then
        ---@type ArbitragePendingReplicateEntry[]
        local stillWaiting = {}
        for _, row in ipairs(rows) do
          if Resolve(row) then
            waitingCount = waitingCount - 1
            progressed = true
          else
            stillWaiting[#stillWaiting + 1] = row
          end
          ReplicateCheckpoint()
        end

        if #stillWaiting > 0 then
          waitingByItem[itemID] = stillWaiting
          incompleteLoads[itemID] = (incompleteLoads[itemID] or 0) + 1
          if incompleteLoads[itemID] < MAX_INCOMPLETE_ITEM_LOADS then
            retriesPending = retriesPending + 1
            C_Timer.After(INCOMPLETE_ITEM_RETRY_SECONDS, function()
              retriesPending = retriesPending - 1
              requestQueue[#requestQueue + 1] = itemID
            end)
          end
        else
          waitingByItem[itemID] = nil
        end
      end
      -- Keep the next items loading while these are read.
      RequestQueued()
    end
    loadedItemIDs = {}
    return progressed
  end

  onItemDataLoaded = function(itemID)
    if requestedItems[itemID] and not loadedItems[itemID] then
      loadedItems[itemID] = true
      loadedItemIDs[#loadedItemIDs + 1] = itemID
    end
  end

  for index = 0, count - 1 do
    local quantity, buyout, itemID, quality = GetReplicateValues(index)
    if
      IsPositiveNumber(quantity)
      and IsPositiveNumber(buyout)
      and IsPositiveNumber(itemID)
      and C_Item.DoesItemExistByID(itemID)
    then
      ---@cast itemID number
      quality = ResolveQuality(itemID, quality)
      local itemLink = quality ~= Enum.ItemQuality.Poor and C_AuctionHouse.GetReplicateItemLink(index)
      if quality and type(itemLink) == "string" then
        pricing.Add({
          itemLink = itemLink,
          quantity = quantity,
          buyout = buyout,
        })
      elseif quality ~= Enum.ItemQuality.Poor then
        -- Wait on quality if it isn't known yet, or on a missing link for gear.
        if quality == nil or ns.Keys.NeedsLink(itemID) then
          Wait({
            index = index,
            itemID = itemID,
            quantity = quantity,
            buyout = buyout,
            quality = quality,
          })
        else
          pricing.Add({
            itemID = itemID,
            quantity = quantity,
            buyout = buyout,
          })
        end
      end
    end

    if generation ~= scanGeneration then
      return
    end
    UpdateReadingProgress(index + 1 - waitingCount)
    ReplicateCheckpoint()
  end

  -- Waits while loads keep resolving auctions, until a quiet spell or until nothing is left to load.
  local function RestartTimeout()
    timeoutToken = timeoutToken + 1
    local token = timeoutToken
    C_Timer.After(ITEM_DATA_TIMEOUT_SECONDS, function()
      if token == timeoutToken and generation == scanGeneration and source ~= nil then
        timedOut = true
      end
    end)
  end
  RequestQueued()
  if waitingCount > 0 then
    RestartTimeout()
  end
  while waitingCount > 0 and not timedOut do
    if #loadedItemIDs > 0 then
      if ResolveLoaded() then
        RestartTimeout()
      end
      UpdateReadingProgress(count - waitingCount)
    elseif outstandingRequests == 0 and retriesPending == 0 and nextRequest > #requestQueue then
      break
    else
      -- Retries join the queue between frames.
      RequestQueued()
      coroutine.yield()
    end
  end

  for _, itemID in ipairs(waitingItemIDs) do
    local rows = waitingByItem[itemID]
    if rows then
      waitingByItem[itemID] = nil
      for _, row in ipairs(rows) do
        Resolve(row, true)
        ReplicateCheckpoint()
      end
    end
  end

  onItemDataLoaded = nil
  phase = "pricing"
  scanProgress = 0
  ns.OpportunityPanel.RefreshScanStatus()
  Report(pricing.Finish(count, Checkpoint))
  if #unlinkedItemIDs > 0 then
    Print(DescribeUnlinkedGear(unlinkedItemIDs))
  end
end

local function CaptureResponse()
  if source == nil or quick or phase ~= "waiting" then
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

---@param newSource ArbitrageScanSource
---@param query AuctionHouseBrowseQuery
local function BeginQuickScan(newSource, query)
  local now = time()
  source = newSource
  quick = {
    query = query,
    startedAt = now,
    lastActivityAt = now,
    sent = lastBrowseQuery == query,
    sawFirstPage = false,
  }
  phase = "waiting"
  lastReportedElapsedSeconds = 0
  ns.OpportunityPanel.RefreshScanStatus()
end

---@param results BrowseResultInfo[]
---@param observedAt number
local function CaptureQuickResponse(results, observedAt)
  phase = "pricing"
  scanProgress = 0
  ns.OpportunityPanel.RefreshScanStatus()

  StartWorker(function()
    local buyouts = {}
    local count = 0
    for index, row in ipairs(results) do
      local itemKey = row.itemKey
      if
        itemKey
        and (itemKey.battlePetSpeciesID or 0) == 0
        and IsPositiveNumber(row.totalQuantity)
        and IsPositiveNumber(row.minPrice)
        and IsPositiveNumber(itemKey.itemID)
        and C_Item.DoesItemExistByID(itemKey.itemID)
      then
        -- Browse rows don't name a gear variant, so gear refreshes only the price keyed by its
        -- item ID: the cheapest listing of any variant, as a full scan records it.
        local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
        local quality = ResolveQuality(itemKey.itemID, info and info.quality)
        if quality and quality > Enum.ItemQuality.Poor then
          local key = tostring(itemKey.itemID)
          if buyouts[key] == nil then
            count = count + 1
          end
          buyouts[key] = math.min(buyouts[key] or row.minPrice, row.minPrice)
        end
      end
      Checkpoint(index / #results * 99)
    end
    if #results > 0 and count == 0 then
      Report("Quick scan contained no usable Buyouts; previous data kept", true)
    elseif processQuickScan(buyouts, observedAt) then
      Report("Quick scan done: refreshed Buyouts for " .. count .. " items", true)
    else
      Report("Quick scan skipped: newer Buyouts already stored", true)
    end
  end)
end

---@param added boolean false for the initial results event
local function ReadBrowsePage(added)
  if not quick or not quick.sent or phase ~= "waiting" then
    return
  end
  quick.lastActivityAt = time()

  if added and not quick.sawFirstPage then
    return
  elseif not added and quick.sawFirstPage then
    -- UPDATED also fires for item searches. Do not mix a new list into a partially read one.
    FailScan("browse results were replaced")
    return
  end
  quick.sawFirstPage = true

  if not C_AuctionHouse.HasFullBrowseResults() then
    quick.needsPage = source == "arbitrage"
  elseif source == "arbitrage" then
    CaptureQuickResponse(C_AuctionHouse.GetBrowseResults(), quick.lastActivityAt)
  else
    -- Auctionator owns this query and will pass us its completed result array.
    quick.observedAt = quick.lastActivityAt
  end
end

local function WatchAuctionator()
  local auctionator = _G.Auctionator
  local events = auctionator and auctionator.IncrementalScan and auctionator.IncrementalScan.Events
  local bus = auctionator and auctionator.EventBus
  local ah = auctionator and auctionator.AH
  if
    not events
    or not events.ScanStart
    or not events.ScanComplete
    or not events.ScanFailed
    or not bus
    or type(bus.Register) ~= "function"
    or not ah
    or type(ah.SendBrowseQuery) ~= "function"
  then
    return
  end

  -- Auctionator may queue the query. Track the exact argument so other browse searches can't
  -- supply pages for it. ScanStart follows the wrapper call whether or not it was queued.
  local auctionatorQuery
  hooksecurefunc(ah, "SendBrowseQuery", function(query)
    auctionatorQuery = query
  end)
  bus:Register({
    ReceiveEvent = function(_, event, results)
      if event == events.ScanStart then
        local query = auctionatorQuery
        auctionatorQuery = nil
        if source == nil and query and not ns.Scan.IsAtNeutralAuctionHouse() then
          BeginQuickScan("external", query)
        end
      elseif quick and source == "external" and phase == "waiting" then
        if event == events.ScanFailed then
          FailScan("Auctionator's summary scan did not finish")
        elseif quick.observedAt and event == events.ScanComplete and type(results) == "table" then
          CaptureQuickResponse(results, quick.observedAt)
        end
      end
    end,
  }, { events.ScanStart, events.ScanComplete, events.ScanFailed })
end

---@return ArbitrageScanStatus
function ns.Scan.GetStatus()
  local cooldownRemainingMinutes = phase == "idle" and GetCooldownRemainingMinutes() or nil
  local elapsedSeconds = GetElapsedWaitingSeconds()
  lastReportedCooldownMinutes = cooldownRemainingMinutes
  lastReportedElapsedSeconds = elapsedSeconds
  return {
    phase = phase,
    kind = source and (quick and "quick" or "full") or nil,
    progress = scanProgress,
    elapsedSeconds = elapsedSeconds,
    cooldownRemainingMinutes = cooldownRemainingMinutes,
  }
end

---@param kind ArbitrageScanKind
local function StartScan(kind)
  if source ~= nil then
    Print("A " .. (quick and "quick" or "full") .. " scan is already in progress")
    return
  elseif not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Print("Open the Auction House before starting a " .. kind .. " scan")
    return
  elseif ns.Scan.IsAtNeutralAuctionHouse() then
    Print("Arbitrage only scans your faction's Auction House")
    return
  end

  local remainingMinutes = kind == "full" and GetCooldownRemainingMinutes()
  if remainingMinutes then
    local minuteLabel = remainingMinutes == 1 and "minute" or "minutes"
    Print("Full scans are unavailable; best guess: try again in " .. remainingMinutes .. " " .. minuteLabel)
  elseif not C_AuctionHouse.IsThrottledMessageSystemReady() then
    Print("The Auction House is busy; try again shortly")
  elseif kind == "quick" then
    local query = { searchString = "", sorts = {}, filters = {}, itemClassFilters = {} }
    BeginQuickScan("arbitrage", query)
    C_AuctionHouse.SendBrowseQuery(query)
  else
    BeginScan("arbitrage")
    C_AuctionHouse.ReplicateItems()
  end
end

function ns.Scan.StartQuick()
  StartScan("quick")
end

function ns.Scan.Start()
  StartScan("full")
end

-- Stops waiting for a server that may never answer. Only the wait can be cancelled: reading is
-- quick, and pricing works from auctions already read. The request still counts toward the cooldown.
function ns.Scan.Cancel()
  if phase == "waiting" then
    CancelScan("stopped waiting for the server")
  end
end

-- How the latest scan of this kind ended this session, or nil before one has.
---@param kind ArbitrageScanKind?
---@return ArbitrageScanOutcome?
function ns.Scan.GetLastOutcome(kind)
  return lastOutcomes[kind or "full"]
end

---@param startPricing fun(): ArbitrageFullScanPricing
---@param processBuyouts fun(buyouts: table<string, number>, observedAt: number): boolean
function ns.Scan.Init(startPricing, processBuyouts)
  startFullScan = startPricing
  processQuickScan = processBuyouts

  frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
  frame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
  -- Registering an event the client does not know throws, which would abort the
  -- rest of this file and leave the addon unable to scan at all.
  pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  frame:SetScript("OnEvent", function(_, eventName, firstArg, success)
    if eventName == "REPLICATE_ITEM_LIST_UPDATE" then
      CaptureResponse()
    elseif eventName == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or eventName == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
      ReadBrowsePage(eventName == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    elseif eventName == "AUCTION_HOUSE_BROWSE_FAILURE" and quick and phase == "waiting" then
      FailScan("the Auction House rejected the browse query")
    elseif eventName == "ITEM_DATA_LOAD_RESULT" and onItemDataLoaded then
      onItemDataLoaded(firstArg, success)
    elseif eventName == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and phase == "waiting" then
      FailScan("the Auction House throttled the request")
    elseif eventName == "AUCTION_HOUSE_CLOSED" and source ~= nil and phase ~= "pricing" then
      -- Pricing works from auctions already read, so only waiting and reading need the window.
      CancelScan("Auction House closed")
    end
  end)
  frame:SetScript("OnUpdate", ResumeWorker)

  hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function(query)
    lastBrowseQuery = query
    if quick and phase == "waiting" then
      if quick.query == query and not quick.sent then
        quick.sent = true
      else
        CancelScan("a new browse query started")
      end
    end
  end)
  local function OnOtherSearch()
    lastBrowseQuery = nil
    if quick and phase == "waiting" then
      CancelScan("another Auction House search started")
    end
  end
  hooksecurefunc(C_AuctionHouse, "SendSearchQuery", OnOtherSearch)
  hooksecurefunc(C_AuctionHouse, "SendSellSearchQuery", OnOtherSearch)
  hooksecurefunc(C_AuctionHouse, "SearchForFavorites", OnOtherSearch)
  WatchAuctionator()

  hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
    if quick then
      CancelScan("a full scan started")
    end
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

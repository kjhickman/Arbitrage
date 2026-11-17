local _, ns = ...

ns.DatabaseIndex = {}

---@class ArbitrageDatabaseRow : ArbitrageItemTableItem
---@field dbKey string
---@field itemID number
---@field link string
---@field classID number?
---@field searchName string? lowercase item name, once the client has it
---@field vendorSellPrice number?
---@field marketValue number?
---@field marketIsUncertain boolean
---@field reasons string[]?
---@field scanCount number scans in the market value window
---@field latestBuyout number?
---@field lastSeen number? timestamp of the newest stored scan

---@class ArbitrageDatabaseIndexResult
---@field rows ArbitrageDatabaseRow[]? nil until the first build finishes
---@field isBuilding boolean
---@field latestScan number?
---@field unnamedCount number items whose names the client has not loaded yet

-- A large import holds thousands of items with weeks of scans each, too much to price in one
-- frame, so rows are built a few milliseconds at a time.
local WORK_BUDGET_MILLISECONDS = 4
-- Uncached names are requested gradually rather than all at once when the index is built.
local NAME_REQUESTS_PER_FRAME = 50

---@type ArbitrageDatabaseRow[]?
local rows
---@type number?
local latestScan
local isStale = true
---@type thread?
local worker
local workerDeadline = 0
local tickScheduled = false
-- Rows waiting for item names, by item ID, for the published rows and for a build in progress.
---@type table<number, ArbitrageDatabaseRow[]>
local unnamed = {}
---@type table<number, ArbitrageDatabaseRow[]>?
local buildingUnnamed
---@type number[]
local requestQueue = {}
local requestIndex = 1

---@param dbKey string
---@return number? itemID, string? link
local function ParseKey(dbKey)
  local itemID = tonumber(dbKey)
  if itemID then
    return itemID, "item:" .. dbKey
  end

  local equipID, suffixID = dbKey:match("^equip:(%d+):(%-?%d+)$")
  if equipID then
    -- The suffix is the seventh field of an item string, after the enchant and four gems.
    return tonumber(equipID), "item:" .. equipID .. "::::::" .. suffixID
  end
  return nil
end

---@param row ArbitrageDatabaseRow
---@return boolean
local function ApplyItemInfo(row)
  local itemName, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(row.link)
  if itemName == nil then
    return false
  end

  row.searchName = string.lower(itemName)
  row.vendorSellPrice = type(sellPrice) == "number" and sellPrice > 0 and sellPrice or nil
  return true
end

---@param waiting table<number, ArbitrageDatabaseRow[]>
---@param row ArbitrageDatabaseRow
---@return boolean added whether this is the first row waiting on the item
local function AddUnnamed(waiting, row)
  local list = waiting[row.itemID]
  if list then
    list[#list + 1] = row
    return false
  end
  waiting[row.itemID] = { row }
  return true
end

---@param scans table<number|string, number>
---@return number?
local function GetNewestScan(scans)
  local newest
  for scanKey in pairs(scans) do
    local timestamp = tonumber(scanKey)
    if timestamp and (newest == nil or timestamp > newest) then
      newest = timestamp
    end
  end
  return newest
end

local function Checkpoint()
  if debugprofilestop() >= workerDeadline then
    coroutine.yield()
  end
end

---@param dbKey string
---@param itemID number
---@param link string
---@return ArbitrageDatabaseRow?
local function BuildRow(dbKey, itemID, link)
  local item = ns.Database.Get(dbKey)
  if item == nil then
    return nil
  end

  local market = ns.RollingMarketValue.Get({ dbKey })
  local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
  return {
    dbKey = dbKey,
    itemID = itemID,
    link = link,
    classID = classID,
    marketValue = market and market.value,
    marketIsUncertain = market ~= nil and market.isUncertain,
    reasons = market and market.reasons,
    scanCount = market and market.scanCount or 0,
    latestBuyout = ns.Database.GetLatestBuyout(dbKey),
    lastSeen = GetNewestScan(item.scans),
  }
end

---@return ArbitrageDatabaseRow[] built, number? newestScan
local function BuildRows()
  local built = {}
  local newestScan
  local waiting = buildingUnnamed --[[@as table<number, ArbitrageDatabaseRow[]>]]

  for _, dbKey in ipairs(ns.Database.GetItemKeys()) do
    local itemID, link = ParseKey(dbKey)
    local row = itemID and BuildRow(dbKey, itemID, link --[[@as string]])
    if row then
      built[#built + 1] = row
      if row.lastSeen and (newestScan == nil or row.lastSeen > newestScan) then
        newestScan = row.lastSeen
      end
      -- Only cached items are read here; reading an uncached one would request it immediately.
      local isCached = C_Item.IsItemDataCachedByID(itemID) and ApplyItemInfo(row)
      if not isCached and AddUnnamed(waiting, row) then
        requestQueue[#requestQueue + 1] = itemID
      end
    end
    Checkpoint()
  end

  return built, newestScan
end

local function RequestNames()
  local last = math.min(#requestQueue, requestIndex + NAME_REQUESTS_PER_FRAME - 1)
  for index = requestIndex, last do
    local itemID = requestQueue[index]
    if unnamed[itemID] or (buildingUnnamed and buildingUnnamed[itemID]) then
      C_Item.RequestLoadItemDataByID(itemID)
    end
  end
  requestIndex = last + 1
end

local ScheduleTick

local function Tick()
  tickScheduled = false

  local activeWorker = worker
  if activeWorker then
    workerDeadline = debugprofilestop() + WORK_BUDGET_MILLISECONDS
    local success, built, newestScan = coroutine.resume(activeWorker)
    if worker == activeWorker then
      if not success then
        worker = nil
        buildingUnnamed = nil
        error(built, 0)
      elseif coroutine.status(activeWorker) == "dead" then
        worker = nil
        rows = built
        latestScan = newestScan
        unnamed = buildingUnnamed --[[@as table]]
        buildingUnnamed = nil
        ns.DatabasePanel.Refresh(true)
      end
    end
  end

  RequestNames()
  if worker or requestIndex <= #requestQueue then
    ScheduleTick()
  end
end

function ScheduleTick()
  if not tickScheduled then
    tickScheduled = true
    C_Timer.After(0, Tick)
  end
end

local function StartBuild()
  isStale = false
  buildingUnnamed = {}
  requestQueue = {}
  requestIndex = 1
  worker = coroutine.create(BuildRows)
  ScheduleTick()
end

-- Returns the latest rows, rebuilding them in the background when the database has changed since.
---@return ArbitrageDatabaseIndexResult
function ns.DatabaseIndex.Get()
  if isStale then
    StartBuild()
  end

  local unnamedCount = 0
  for _ in pairs(unnamed) do
    unnamedCount = unnamedCount + 1
  end

  return {
    rows = rows,
    isBuilding = worker ~= nil,
    latestScan = latestScan,
    unnamedCount = unnamedCount,
  }
end

-- Marks the rows out of date after the database changes; a showing panel rebuilds them.
function ns.DatabaseIndex.Invalidate()
  isStale = true
  worker = nil
  buildingUnnamed = nil
  ns.DatabasePanel.Refresh(true)
end

---@param itemID number
---@param success boolean
---@return boolean named whether a row learned its name
function ns.DatabaseIndex.HandleItemInfoReceived(itemID, success)
  local named = false
  for _, waiting in ipairs({ unnamed, buildingUnnamed or {} }) do
    local list = waiting[itemID]
    if list then
      -- An item the server cannot find will never have a name; it stays listed by ID.
      waiting[itemID] = nil
      if success then
        for _, row in ipairs(list) do
          named = ApplyItemInfo(row) or named
        end
      end
    end
  end
  return named
end

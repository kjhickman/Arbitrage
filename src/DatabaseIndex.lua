local _, ns = ...

ns.DatabaseIndex = {}

---@class ArbitrageDatabaseRow : ArbitrageItemTableItem
---@field dbKey string
---@field itemID number
---@field link string
---@field classID number?
---@field subClassID number?
---@field slot string? localized equip slot, such as Head
---@field searchName string? lowercase item name, once the client has loaded the item
---@field quality number? once loaded
---@field itemLevel number? once loaded
---@field requiredLevel number? once loaded
---@field stats table<string, number>? weapon and armor stats by GetItemStats key, once loaded
---@field marketValue number?
---@field marketIsUncertain boolean
---@field reasons string[]?
---@field latestBuyout number?
---@field craftCost number? per item, for items a known recipe can make
---@field craftCostIsUnknown boolean a known recipe makes it but some material has no price
---@field craftCostIsUncertain boolean
---@field craftReasons string[]?
---@field lastSeen number? when a scan last listed the item, for its Market Value or its Buyout
---@field isIgnored boolean? the item loaded as grey after its row was built

-- The values found across the rows, for the filter menu to offer.
---@class ArbitrageDatabaseFacets
---@field subclasses table<number, table<number, true>> subclass IDs by class ID
---@field slots table<string, true>
---@field qualities table<number, true>
---@field stats table<string, true>

---@class ArbitrageDatabaseIndexResult
---@field rows ArbitrageDatabaseRow[]? nil until the first build finishes
---@field facets ArbitrageDatabaseFacets? nil until the first build finishes

-- A large import holds thousands of items with weeks of scans each, too much to price in one
-- frame, so rows are built a few milliseconds at a time: as long each frame as a scan may work.
-- Uncached items are requested gradually rather than all at once when the index is built.
local NAME_REQUESTS_PER_FRAME = 50

---@type ArbitrageDatabaseRow[]?
local rows
---@type ArbitrageDatabaseFacets?
local facets
-- The latest build's facets, which become the published ones when it finishes.
---@type ArbitrageDatabaseFacets
local buildingFacets
local isStale = true
-- Reads the rows, hands them over to be shown, then reads their gear stats.
---@type thread?
local worker
local workerDeadline = 0
local tickScheduled = false
-- The latest build's rows still waiting for item data, by item ID.
---@type table<number, ArbitrageDatabaseRow[]>
local unloaded = {}
---@type number[]
local requestQueue = {}
local requestIndex = 1

---@param row ArbitrageDatabaseRow
---@return boolean
local function IsGear(row)
  return row.classID == Enum.ItemClass.Weapon or row.classID == Enum.ItemClass.Armor
end

---@param row ArbitrageDatabaseRow
local function ApplyStats(row)
  row.stats = C_Item.GetItemStats(row.link)
  for key in pairs(row.stats or {}) do
    buildingFacets.stats[key] = true
  end
end

---@param row ArbitrageDatabaseRow
---@param withStats boolean whether to read gear stats too, which a read leaves for after its rows show
---@return boolean
local function ApplyItemInfo(row, withStats)
  local itemName, _, quality, itemLevel, requiredLevel = C_Item.GetItemInfo(row.link)
  if itemName == nil then
    return false
  end

  row.searchName = string.lower(itemName)
  row.quality, row.itemLevel, row.requiredLevel = quality, itemLevel, requiredLevel
  if quality then
    buildingFacets.qualities[quality] = true
  end
  if withStats and IsGear(row) then
    ApplyStats(row)
  end
  return true
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
  -- Items no recorded recipe makes return after one lookup, so only craftable rows cost more.
  local craft = ns.Crafting.GetCostForItemID(itemID)
  local craftIsKnown = craft ~= nil and not craft.isUnknown
  ---@cast craft ArbitrageCraftingPlan?
  local _, _, _, equipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
  local isEquippable = equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
  return {
    dbKey = dbKey,
    itemID = itemID,
    link = link,
    classID = classID,
    subClassID = subClassID,
    -- Robes and chest pieces share the name Chest, so filtering by name groups them.
    slot = isEquippable and _G[equipLoc] or nil,
    marketValue = market and market.value,
    marketIsUncertain = market ~= nil and market.isUncertain,
    reasons = market and market.reasons,
    latestBuyout = ns.Database.GetLatestBuyout(dbKey),
    craftCost = craftIsKnown and math.floor(craft.cost + 0.5) or nil,
    craftCostIsUnknown = craft ~= nil and not craftIsKnown,
    craftCostIsUncertain = craftIsKnown and craft.isUncertain,
    craftReasons = craftIsKnown and craft.reasons or nil,
    lastSeen = ns.Database.GetLastSeen(dbKey),
  }
end

---@return ArbitrageDatabaseRow[]
local function BuildRows()
  local built = {}
  local keys = ns.Database.GetItemKeys()
  -- Gear priced per random suffix lists its variants, not the base key that blends them all.
  local hasVariants = {}
  for _, dbKey in ipairs(keys) do
    local itemID = dbKey:match("^equip:(%d+):")
    if itemID then
      hasVariants[itemID] = true
    end
  end

  for _, dbKey in ipairs(keys) do
    local itemID, link = ns.Keys.ToLink(dbKey)
    local row = itemID and not hasVariants[dbKey] and BuildRow(dbKey, itemID, link --[[@as string]])
    if row then
      built[#built + 1] = row
      if row.classID then
        local subclasses = buildingFacets.subclasses[row.classID] or {}
        buildingFacets.subclasses[row.classID] = subclasses
        if row.subClassID then
          subclasses[row.subClassID] = true
        end
      end
      if row.slot then
        buildingFacets.slots[row.slot] = true
      end
      -- Only cached items are read here; reading an uncached one would request it immediately.
      if not (C_Item.IsItemDataCachedByID(itemID) and ApplyItemInfo(row, false)) then
        if not unloaded[itemID] then
          unloaded[itemID] = {}
          requestQueue[#requestQueue + 1] = itemID
        end
        table.insert(unloaded[itemID], row)
      end
    end
    Checkpoint()
  end

  return built
end

-- Gear stats only serve the Stats filter, yet took two fifths of a read, so they are read once the
-- rows show. Rows loading later read their own.
---@param list ArbitrageDatabaseRow[]
local function ReadStats(list)
  for _, row in ipairs(list) do
    if row.searchName and row.stats == nil and not row.isIgnored and IsGear(row) then
      ApplyStats(row)
    end
    Checkpoint()
  end
end

local function Read()
  local built = BuildRows()
  coroutine.yield(built)
  ReadStats(built)
end

local function RequestNames()
  local last = math.min(#requestQueue, requestIndex + NAME_REQUESTS_PER_FRAME - 1)
  for index = requestIndex, last do
    local itemID = requestQueue[index]
    if unloaded[itemID] then
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
    workerDeadline = debugprofilestop() + ns.Config.Get("scanWorkBudget")
    local success, built = coroutine.resume(activeWorker)
    if worker == activeWorker then
      if not success then
        worker = nil
        error(built, 0)
      elseif built then
        rows = built
        facets = buildingFacets
        ns.DatabasePanel.Refresh(true)
      elseif coroutine.status(activeWorker) == "dead" then
        worker = nil
        -- Stats only change what the Stats filter matches. Refreshing anyway would redraw every
        -- row just to drop grey items found meanwhile, which sit off screen.
        if ns.DatabaseFilters.FiltersByStats() then
          ns.DatabasePanel.Refresh(true)
        end
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
  unloaded = {}
  buildingFacets = { subclasses = {}, slots = {}, qualities = {}, stats = {} }
  requestQueue = {}
  requestIndex = 1
  worker = coroutine.create(Read)
  ScheduleTick()
end

-- Returns the latest rows, rebuilding them in the background when the database has changed since.
---@return ArbitrageDatabaseIndexResult
function ns.DatabaseIndex.Get()
  if isStale then
    StartBuild()
  end

  return {
    rows = rows,
    facets = facets,
  }
end

-- Marks the rows out of date after scans, recipes, or vendor prices change; a showing panel
-- rebuilds them.
function ns.DatabaseIndex.Invalidate()
  isStale = true
  worker = nil
  ns.DatabasePanel.Refresh(true)
end

---@param itemID number
---@param success boolean
---@return boolean loaded whether a row learned its item data
function ns.DatabaseIndex.HandleItemInfoReceived(itemID, success)
  local list = unloaded[itemID]
  if not list or not success then
    return false
  end

  unloaded[itemID] = nil
  -- Rebuilding instead would start the read over for each grey item, so it might never finish.
  if ns.Database.IsIgnoredItem(itemID) then
    for _, row in ipairs(list) do
      row.isIgnored = true
    end
    -- The panel's filter hides them at its next refresh.
    return false
  end

  local loaded, stillWaiting = false, false
  for _, row in ipairs(list) do
    if not row.searchName then
      if ApplyItemInfo(row, true) then
        loaded = true
      else
        stillWaiting = true
      end
    end
  end
  -- If the name is not readable yet, let a later notification finish indexing it.
  if stillWaiting then
    unloaded[itemID] = list
  end
  return loaded
end

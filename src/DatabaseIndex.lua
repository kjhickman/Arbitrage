local _, ns = ...

ns.DatabaseIndex = {}

-- A row names the fields the item table reads, and numbers the rest, read as row[Field.name]. Lua
-- keeps numbered fields in a list a sixth the size of named ones, and named fields in a table that
-- doubles in size past each power of two; tens of thousands of rows with 19 named fields took 70
-- MB. Numbered, a row costs the same for each field it has, so another column adds 16 bytes a row.
---@class ArbitrageDatabaseRow : ArbitrageItemTableItem
---@field dbKey string
---@field itemID number
---@field link string? a random-enchant variant's link; nil for an item ID, which is its own link

-- Where each of a row's numbered fields sits. Every one may be nil.
ns.DatabaseIndex.Field = {
  classID = 1,
  subClassID = 2,
  -- The localized equip slot, such as Head.
  slot = 3,
  marketValue = 4,
  -- True when the Market Value is uncertain, nil otherwise.
  marketIsUncertain = 5,
  latestBuyout = 6,
  -- Per item, for items a known recipe can make.
  craftCost = 7,
  -- True when a known recipe makes it but some material has no price.
  craftCostIsUnknown = 8,
  craftCostIsUncertain = 9,
  -- When a scan last listed the item, for its Market Value or its Buyout.
  lastSeen = 10,
  -- The lowercase name, quality, and levels, once the client has loaded the item.
  searchName = 11,
  quality = 12,
  itemLevel = 13,
  requiredLevel = 14,
  -- Gear's stats as a set of GetItemStats keys, shared by every row with the same stats.
  stats = 15,
  -- True when the item loaded as grey after its row was built.
  isIgnored = 16,
}
local Field = ns.DatabaseIndex.Field

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
-- What /arb profile times the reading under.
local JOB = "Database Index"

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
-- Gear comes in a few hundred combinations of stats, so rows share one set per combination, found
-- by the sum of a bit for each stat. Sets are never changed, so they're kept from read to read.
---@type table<string, number>
local statBits = {}
local statCount = 0
---@type table<number, table<string, true>>
local statSets = {}
-- Distinct bits a number holds exactly; stats past them keep sets of their own.
local MAX_STAT_BITS = 52
-- Rows are numbered by item ID, then variant, this far apart, with variants from either side of
-- the middle. A variant past it keeps its key's place.
local VARIANT_SPAN = 2 ^ 21
local VARIANT_MIDDLE = 2 ^ 20
-- Numbers sorted in one call; about a millisecond's worth.
local SORT_RUN = 2048
-- The row lists with rows found to be grey after they were read, which the panel filters out.
---@type table<ArbitrageDatabaseRow[], true>
local listsWithGrey = setmetatable({}, { __mode = "k" })
-- The rows the latest read builds; rows still waiting for item data belong to it.
---@type ArbitrageDatabaseRow[]
local building = {}

---@param row ArbitrageDatabaseRow
---@return boolean
local function IsGear(row)
  local classID = row[Field.classID]
  return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

---@param row ArbitrageDatabaseRow
---@return string
local function LinkOf(row)
  return row.link or ("item:" .. row.itemID)
end

---@param stats table<string, number>?
---@return table<string, true>?
local function ShareStats(stats)
  if stats == nil then
    return nil
  end
  local mask = 0
  for key in pairs(stats) do
    local bit = statBits[key]
    if not bit then
      if statCount >= MAX_STAT_BITS then
        return stats
      end
      bit = 2 ^ statCount
      statCount = statCount + 1
      statBits[key] = bit
    end
    mask = mask + bit
  end
  local set = statSets[mask]
  if not set then
    set = {}
    for key in pairs(stats) do
      set[key] = true
    end
    statSets[mask] = set
  end
  return set
end

---@param row ArbitrageDatabaseRow
local function ApplyStats(row)
  local stats = ShareStats(C_Item.GetItemStats(LinkOf(row)))
  row[Field.stats] = stats
  for key in pairs(stats or {}) do
    buildingFacets.stats[key] = true
  end
end

---@param row ArbitrageDatabaseRow
---@param withStats boolean whether to read gear stats too, which a read leaves for after its rows show
---@return boolean
local function ApplyItemInfo(row, withStats)
  local itemName, _, quality, itemLevel, requiredLevel = C_Item.GetItemInfo(row.link or row.itemID)
  if itemName == nil then
    return false
  end

  row[Field.searchName] = string.lower(itemName)
  row[Field.quality], row[Field.itemLevel], row[Field.requiredLevel] = quality, itemLevel, requiredLevel
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

-- Reasons a price is uncertain aren't kept: a tooltip asks for them again.
---@param dbKey string
---@param itemID number
---@param link string? nil for an item ID
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
  -- Listed in Field order, so the row's list has room for every field, loaded or not.
  return {
    dbKey = dbKey,
    itemID = itemID,
    link = link,
    classID,
    subClassID,
    -- Robes and chest pieces share the name Chest, so filtering by name groups them.
    isEquippable and _G[equipLoc] or nil,
    market and market.value,
    market and market.isUncertain or nil,
    ns.Database.GetLatestBuyout(dbKey),
    craftIsKnown and math.floor(craft.cost + 0.5) or nil,
    craft ~= nil and not craftIsKnown or nil,
    craftIsKnown and craft.isUncertain or nil,
    ns.Database.GetLastSeen(dbKey),
    nil, -- searchName
    nil, -- quality
    nil, -- itemLevel
    nil, -- requiredLevel
    nil, -- stats
    nil, -- isIgnored
  }
end

-- Sorts numbers a run at a time, then merges the runs, pausing between runs and while merging: one
-- sort of every key can't pause, and took a frame of its own.
---@param numbers number[]
---@return number[]
local function SortInRuns(numbers)
  local runs = {}
  for first = 1, #numbers, SORT_RUN do
    local run = {}
    for index = first, math.min(first + SORT_RUN - 1, #numbers) do
      run[#run + 1] = numbers[index]
    end
    table.sort(run)
    runs[#runs + 1] = run
    Checkpoint()
  end
  while #runs > 1 do
    local merged = {}
    for index = 1, #runs, 2 do
      local left, right = runs[index], runs[index + 1]
      if right then
        local run, leftAt, rightAt = {}, 1, 1
        local leftCount, rightCount = #left, #right
        for position = 1, leftCount + rightCount do
          local leftValue, rightValue = left[leftAt], right[rightAt]
          if rightValue == nil or (leftValue ~= nil and leftValue <= rightValue) then
            run[position], leftAt = leftValue, leftAt + 1
          else
            run[position], rightAt = rightValue, rightAt + 1
          end
          if position % SORT_RUN == 0 then
            Checkpoint()
          end
        end
        left = run
      end
      merged[#merged + 1] = left
    end
    runs = merged
  end
  return runs[1] or {}
end

-- Orders keys by item ID, then variant, so rows come out in the order the table breaks ties in and
-- it needn't sort them for that. Also names the items priced per variant, by item ID.
---@param keys string[]
---@return string[] ordered, table<string, true> hasVariants
local function IdentityOrder(keys)
  local identities, keyOf, unordered, hasVariants = {}, {}, {}, {}
  for _, dbKey in ipairs(keys) do
    local itemID, variant = tonumber(dbKey), nil
    if not itemID then
      -- Any variant hides its base item, though only ones the client can link get rows.
      local variantItemID, variantID = dbKey:match("^equip:(%d+):(.*)$")
      if variantItemID then
        hasVariants[variantItemID] = true
        variant = variantID:match("^%d+$") and tonumber(variantID)
        itemID = variant and tonumber(variantItemID)
      end
    end
    local identity = itemID and itemID * VARIANT_SPAN + (variant and variant - VARIANT_MIDDLE + 1 or -VARIANT_MIDDLE)
    if identity and (variant or 0) < VARIANT_MIDDLE and not keyOf[identity] then
      identities[#identities + 1] = identity
      keyOf[identity] = dbKey
    else
      unordered[#unordered + 1] = dbKey
    end
    Checkpoint()
  end
  identities = SortInRuns(identities)
  local ordered = {}
  for index, identity in ipairs(identities) do
    ordered[index] = keyOf[identity]
    Checkpoint()
  end
  for _, dbKey in ipairs(unordered) do
    ordered[#ordered + 1] = dbKey
  end
  return ordered, hasVariants
end

---@return ArbitrageDatabaseRow[]
local function BuildRows()
  local built = building
  local keys = ns.Database.GetItemKeys()
  ns.Profile.Size(JOB, #keys, "keys")
  -- Gear priced per random suffix lists its variants, not the base key that blends them all.
  local hasVariants
  keys, hasVariants = IdentityOrder(keys)

  for _, dbKey in ipairs(keys) do
    local itemID, link = ns.Keys.ToLink(dbKey)
    -- An item ID's link is its item ID, so only variants keep one.
    local isVariant = tonumber(dbKey) == nil
    local row = itemID and not hasVariants[dbKey] and BuildRow(dbKey, itemID, isVariant and link or nil)
    if row then
      built[#built + 1] = row
      local classID, subClassID, slot = row[Field.classID], row[Field.subClassID], row[Field.slot]
      if classID then
        local subclasses = buildingFacets.subclasses[classID] or {}
        buildingFacets.subclasses[classID] = subclasses
        if subClassID then
          subclasses[subClassID] = true
        end
      end
      if slot then
        buildingFacets.slots[slot] = true
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
    if row[Field.searchName] and row[Field.stats] == nil and not row[Field.isIgnored] and IsGear(row) then
      ApplyStats(row)
    end
    Checkpoint()
  end
end

local function Read()
  local built = BuildRows()
  coroutine.yield(built)
  ns.Profile.Stage(JOB, "Reading stats")
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
    local now = debugprofilestop()
    workerDeadline = now + ns.Config.Get("scanWorkBudget")
    ns.Profile.Resume(JOB, now)
    local success, built = coroutine.resume(activeWorker)
    if worker == activeWorker then
      if not success then
        worker = nil
        ns.Profile.Pause(JOB)
        error(built, 0)
      elseif built then
        rows = built
        facets = buildingFacets
        ns.Profile.Stage(JOB, "Showing rows")
        ns.DatabasePanel.Refresh(true)
      elseif coroutine.status(activeWorker) == "dead" then
        worker = nil
        -- Stats only change what the Stats filter matches. Refreshing anyway would redraw every
        -- row just to drop grey items found meanwhile, which sit off screen.
        if ns.DatabaseFilters.FiltersByStats() then
          ns.DatabasePanel.Refresh(true)
        end
        ns.Profile.Finish(JOB)
      end
    end
    ns.Profile.Pause(JOB)
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
  ns.Profile.Start(JOB, "Reading rows")
  isStale = false
  unloaded = {}
  buildingFacets = { subclasses = {}, slots = {}, qualities = {}, stats = {} }
  building = {}
  requestQueue = {}
  requestIndex = 1
  worker = coroutine.create(Read)
  ScheduleTick()
  ns.Profile.Pause(JOB)
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

-- The latest rows as they are, without reading the database again when it has changed.
---@return ArbitrageDatabaseRow[]?
function ns.DatabaseIndex.Peek()
  return rows
end

-- Whether any of a list's rows loaded as grey after the list was read.
---@param list ArbitrageDatabaseRow[]
---@return boolean
function ns.DatabaseIndex.HasGrey(list)
  return listsWithGrey[list] == true
end

-- Marks the rows out of date after scans, recipes, or vendor prices change. A showing panel
-- rebuilds them and shows the old rows meanwhile; a hidden one shows nothing, so they're let go
-- and read again when it shows.
function ns.DatabaseIndex.Invalidate()
  isStale = true
  worker = nil
  if not ns.DatabasePanel.IsShown() then
    rows, facets, building = nil, nil, {}
    unloaded, requestQueue, requestIndex = {}, {}, 1
  end
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
      row[Field.isIgnored] = true
    end
    listsWithGrey[building] = true
    -- The panel's filter hides them at its next refresh.
    return false
  end

  local loaded, stillWaiting = false, false
  for _, row in ipairs(list) do
    if not row[Field.searchName] then
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

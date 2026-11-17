local _, ns = ...

ns.DatabaseFilters = {}

---@class ArbitrageDatabaseRange
---@field label string menu title
---@field field string row field the range bounds
---@field prefix string summary text before the bounds
---@field suffix string? summary text after each bound
---@field scale number? row units per typed unit
---@field letters number digits each input accepts
---@field width number pixels per input

---@class ArbitrageDatabaseFilterState
---@field classID number?
---@field subClassID number?
---@field slots table<string, true>
---@field qualities table<number, true>
---@field ranges table<string, { min: number, max: number }> zero leaves a bound open
---@field craftable boolean
---@field profitable boolean
---@field freshness number index into FRESHNESS
---@field hideUncertain boolean

local DAY = 24 * 60 * 60

---@type table<string, ArbitrageDatabaseRange>
local RANGES = {
  requiredLevel = {
    label = "Required Level",
    field = "requiredLevel",
    prefix = "Req. level ",
    letters = 3,
    width = 28,
  },
  itemLevel = { label = "Item Level", field = "itemLevel", prefix = "Item level ", letters = 3, width = 28 },
  price = {
    label = "Market Value (gold)",
    field = "marketValue",
    prefix = "Market Value ",
    suffix = "g",
    scale = 10000,
    letters = 5,
    width = 44,
  },
}
local RANGE_ORDER = { "requiredLevel", "itemLevel", "price" }

local FRESHNESS = {
  { label = "Any time" },
  { label = "In the latest scan", latest = true },
  { label = "Seen in the last day", days = 1 },
  { label = "Seen in the last 3 days", days = 3 },
  { label = "Seen in the last 7 days", days = 7 },
  { label = "Seen in the last 14 days", days = 14 },
}

---@return ArbitrageDatabaseFilterState
local function NewFilters()
  local ranges = {}
  for key in pairs(RANGES) do
    ranges[key] = { min = 0, max = 0 }
  end
  return {
    slots = {},
    qualities = {},
    ranges = ranges,
    craftable = false,
    profitable = false,
    freshness = 1,
    hideUncertain = false,
  }
end

-- Filters last for the session.
local filters = NewFilters()

---@param quality number
---@return string
local function QualityName(quality)
  local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or tostring(quality)
  local _, _, _, hex = C_Item.GetItemQualityColor(quality)
  return hex and ("|c" .. hex .. name .. "|r") or name
end

---@param set table
---@return any[]
local function SortedKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---@param range ArbitrageDatabaseRange
---@param bounds { min: number, max: number }
---@return string
local function DescribeRange(range, bounds)
  local suffix = range.suffix or ""
  if bounds.min > 0 and bounds.max > 0 then
    return range.prefix .. bounds.min .. suffix .. "-" .. bounds.max .. suffix
  end
  if bounds.min > 0 then
    return range.prefix .. bounds.min .. suffix .. "+"
  end
  return range.prefix .. "up to " .. bounds.max .. suffix
end

---@return string[]
local function DescribeParts()
  local parts = {}
  if filters.classID then
    local category = C_Item.GetItemClassInfo(filters.classID) or tostring(filters.classID)
    if filters.subClassID then
      category = category .. " > " .. (C_Item.GetItemSubClassInfo(filters.classID, filters.subClassID) or "?")
    end
    parts[#parts + 1] = category
  end
  if next(filters.slots) then
    parts[#parts + 1] = table.concat(SortedKeys(filters.slots), ", ")
  end
  if next(filters.qualities) then
    local names = {}
    for _, quality in ipairs(SortedKeys(filters.qualities)) do
      names[#names + 1] = QualityName(quality)
    end
    parts[#parts + 1] = table.concat(names, ", ")
  end
  for _, key in ipairs(RANGE_ORDER) do
    local bounds = filters.ranges[key]
    if bounds.min > 0 or bounds.max > 0 then
      parts[#parts + 1] = DescribeRange(RANGES[key], bounds)
    end
  end
  if filters.profitable then
    parts[#parts + 1] = "Profitable crafts"
  elseif filters.craftable then
    parts[#parts + 1] = "Craftable"
  end
  if filters.freshness ~= 1 then
    parts[#parts + 1] = FRESHNESS[filters.freshness].label
  end
  if filters.hideUncertain then
    parts[#parts + 1] = "Certain prices"
  end
  return parts
end

-- The active filters as one line, or nil when nothing is filtered.
---@return string?
function ns.DatabaseFilters.Describe()
  local parts = DescribeParts()
  return #parts > 0 and table.concat(parts, " · ") or nil
end

---@return boolean
function ns.DatabaseFilters.IsDefault()
  return #DescribeParts() == 0
end

function ns.DatabaseFilters.Reset()
  filters = NewFilters()
end

-- Rarity and levels come from item data the client may still be loading.
---@return boolean
function ns.DatabaseFilters.NeedsItemInfo()
  local ranges = filters.ranges
  return next(filters.qualities) ~= nil
    or ranges.requiredLevel.min > 0
    or ranges.requiredLevel.max > 0
    or ranges.itemLevel.min > 0
    or ranges.itemLevel.max > 0
end

---@param row ArbitrageDatabaseRow
---@param now number
---@return boolean
function ns.DatabaseFilters.Matches(row, now)
  if
    filters.classID
    and (row.classID ~= filters.classID or (filters.subClassID and row.subClassID ~= filters.subClassID))
  then
    return false
  end
  if next(filters.slots) and not (row.slot and filters.slots[row.slot]) then
    return false
  end
  if next(filters.qualities) and not (row.quality and filters.qualities[row.quality]) then
    return false
  end
  for _, key in ipairs(RANGE_ORDER) do
    local range = RANGES[key]
    local bounds = filters.ranges[key]
    local value = row[range.field]
    local scale = range.scale or 1
    if bounds.min > 0 and (value == nil or value < bounds.min * scale) then
      return false
    end
    if bounds.max > 0 and (value == nil or value > bounds.max * scale) then
      return false
    end
  end
  if filters.craftable and row.craftCost == nil and not row.craftCostIsUnknown then
    return false
  end
  if filters.profitable and not (row.craftCost and row.marketValue and row.marketValue > row.craftCost) then
    return false
  end
  local freshness = FRESHNESS[filters.freshness]
  if freshness.latest and row.latestBuyout == nil then
    return false
  end
  if freshness.days and (row.lastSeen == nil or row.lastSeen < now - freshness.days * DAY) then
    return false
  end
  if filters.hideUncertain and (row.marketValue == nil or row.marketIsUncertain) then
    return false
  end
  return true
end

---@param ids table<number, any>
---@param name fun(id: number): string?
---@return { id: number, name: string }[]
local function ByName(ids, name)
  local entries = {}
  for id in pairs(ids) do
    entries[#entries + 1] = { id = id, name = name(id) or tostring(id) }
  end
  table.sort(entries, function(left, right)
    return left.name < right.name
  end)
  return entries
end

-- Lists only the categories, slots, and rarities that appear in the database.
---@param rootDescription table
---@param rows ArbitrageDatabaseRow[]
---@param onChange fun()
function ns.DatabaseFilters.SetupMenu(rootDescription, rows, onChange)
  local subclasses, slots, qualities = {}, {}, {}
  for _, row in ipairs(rows) do
    if row.classID then
      subclasses[row.classID] = subclasses[row.classID] or {}
      if row.subClassID then
        subclasses[row.classID][row.subClassID] = true
      end
    end
    if row.slot then
      slots[row.slot] = true
    end
    if row.quality then
      qualities[row.quality] = true
    end
  end

  -- Selecting keeps the menu open so filters can be combined in one visit.
  local function Changed()
    onChange()
    return MenuResponse.Refresh
  end
  local function IsCategory(data)
    return filters.classID == data.classID and filters.subClassID == data.subClassID
  end
  local function SetCategory(data)
    filters.classID, filters.subClassID = data.classID, data.subClassID
    return Changed()
  end
  local function IsInSet(data)
    return filters[data.set][data.value] == true
  end
  local function ToggleInSet(data)
    filters[data.set][data.value] = not filters[data.set][data.value] or nil
    return Changed()
  end
  local function IsFlag(key)
    return filters[key]
  end
  local function ToggleFlag(key)
    filters[key] = not filters[key]
    return Changed()
  end
  local function IsFreshness(index)
    return filters.freshness == index
  end
  local function SetFreshness(index)
    filters.freshness = index
    return Changed()
  end

  local categoryMenu = rootDescription:CreateButton("Category")
  categoryMenu:CreateRadio("All categories", IsCategory, SetCategory, {})
  for _, class in ipairs(ByName(subclasses, C_Item.GetItemClassInfo)) do
    local classMenu = categoryMenu:CreateButton(class.name)
    classMenu:CreateRadio("All " .. class.name, IsCategory, SetCategory, { classID = class.id })
    local function SubClassName(subClassID)
      return C_Item.GetItemSubClassInfo(class.id, subClassID)
    end
    for _, subclass in ipairs(ByName(subclasses[class.id], SubClassName)) do
      classMenu:CreateRadio(subclass.name, IsCategory, SetCategory, { classID = class.id, subClassID = subclass.id })
    end
  end

  local slotMenu = rootDescription:CreateButton("Slot")
  for _, slot in ipairs(SortedKeys(slots)) do
    slotMenu:CreateCheckbox(slot, IsInSet, ToggleInSet, { set = "slots", value = slot })
  end

  local rarityMenu = rootDescription:CreateButton("Rarity")
  for _, quality in ipairs(SortedKeys(qualities)) do
    rarityMenu:CreateCheckbox(QualityName(quality), IsInSet, ToggleInSet, { set = "qualities", value = quality })
  end

  for _, key in ipairs(RANGE_ORDER) do
    local range = RANGES[key]
    rootDescription:CreateTitle(range.label)
    rootDescription:CreateTemplate("LevelRangeFrameTemplate"):AddInitializer(function(frame)
      -- Menu frames are pooled, so a frame may still carry another range's callback; resetting
      -- the inputs would fire it and clear that range.
      frame:SetLevelRangeChangedCallback(nil)
      frame:Reset()
      frame:SetWidth(range.width * 2 + 24)
      for _, input in ipairs({ frame.MinLevel, frame.MaxLevel }) do
        input:SetMaxLetters(range.letters)
        input:SetWidth(range.width)
      end
      local bounds = filters.ranges[key]
      if bounds.min > 0 then
        frame:SetMinLevel(bounds.min)
      end
      if bounds.max > 0 then
        frame:SetMaxLevel(bounds.max)
      end
      frame:SetLevelRangeChangedCallback(function(min, max)
        filters.ranges[key] = { min = min, max = max }
        onChange()
      end)
    end)
  end

  local craftingMenu = rootDescription:CreateButton("Crafting")
  craftingMenu:CreateCheckbox("Only items I can craft", IsFlag, ToggleFlag, "craftable")
  craftingMenu:CreateCheckbox("Only profitable crafts", IsFlag, ToggleFlag, "profitable"):SetTitleAndTextTooltip(
    "Only profitable crafts",
    "Items whose Market Value is above their Craft Cost, before the Auction House cut."
  )

  local freshnessMenu = rootDescription:CreateButton("Last Seen")
  for index, choice in ipairs(FRESHNESS) do
    freshnessMenu:CreateRadio(choice.label, IsFreshness, SetFreshness, index)
  end

  rootDescription:CreateCheckbox("Hide uncertain prices", IsFlag, ToggleFlag, "hideUncertain"):SetTitleAndTextTooltip(
    "Hide uncertain prices",
    "Hides items whose Market Value is uncertain or missing because they have no scans in the last 14 days."
  )
end

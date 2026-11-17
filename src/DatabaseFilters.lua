local _, ns = ...

ns.DatabaseFilters = {}

---@class ArbitrageDatabaseRange
---@field key string row field the range bounds
---@field label string menu title
---@field prefix string summary text before the bounds
---@field suffix string? summary text after each bound
---@field scale number? row units per typed unit
---@field letters number digits each input accepts
---@field width number pixels per input

-- A category menu choice: a whole class, a group of its subclasses, or one subclass.
---@class ArbitrageDatabaseCategory
---@field key string
---@field classID number
---@field subClassIDs table<number, true>? nil for the whole class
---@field path string summary text, such as Weapon > One-Handed

---@class ArbitrageDatabaseFilterState
---@field category ArbitrageDatabaseCategory?
---@field slots table<string, true>
---@field qualities table<number, true>
---@field stats table<string, true> GetItemStats keys an item must all have
---@field ranges table<string, { min: number, max: number }> zero leaves a bound open
---@field craftable boolean
---@field profitable boolean
---@field freshness number index into FRESHNESS
---@field hideUncertain boolean

local DAY = 24 * 60 * 60

---@type ArbitrageDatabaseRange[]
local RANGES = {
  { key = "requiredLevel", label = "Required Level", prefix = "Req. level ", letters = 3, width = 28 },
  { key = "itemLevel", label = "Item Level", prefix = "Item level ", letters = 3, width = 28 },
  {
    key = "marketValue",
    label = "Market Value (gold)",
    prefix = "Market Value ",
    suffix = "g",
    scale = 10000,
    letters = 5,
    width = 44,
  },
}

local Weapon = Enum.ItemWeaponSubclass
local Armor = Enum.ItemArmorSubclass

-- Subclass groups as Blizzard's Auction House arranges them; other subclasses stay listed directly.
local SUBCLASS_GROUPS = {
  [Enum.ItemClass.Weapon] = {
    {
      label = "One-Handed",
      subClassIDs = {
        Weapon.Axe1H,
        Weapon.Mace1H,
        Weapon.Sword1H,
        Weapon.Warglaive,
        Weapon.Dagger,
        Weapon.Unarmed,
        Weapon.Wand,
      },
    },
    {
      label = "Two-Handed",
      subClassIDs = { Weapon.Axe2H, Weapon.Mace2H, Weapon.Sword2H, Weapon.Polearm, Weapon.Staff },
    },
    { label = "Ranged", subClassIDs = { Weapon.Bows, Weapon.Crossbow, Weapon.Guns, Weapon.Thrown } },
    { label = "Miscellaneous", subClassIDs = { Weapon.Fishingpole, Weapon.Generic } },
  },
  [Enum.ItemClass.Armor] = {
    { label = "Relics", subClassIDs = { Armor.Idol, Armor.Libram, Armor.Totem, Armor.Sigil, Armor.Relic } },
  },
}

-- Equip slots grouped in character sheet order; any other slot is listed under Other.
local SLOT_GROUPS = {
  {
    label = "Armor",
    equipLocs = {
      "INVTYPE_HEAD",
      "INVTYPE_SHOULDER",
      "INVTYPE_CLOAK",
      "INVTYPE_CHEST",
      "INVTYPE_ROBE",
      "INVTYPE_WRIST",
      "INVTYPE_HAND",
      "INVTYPE_WAIST",
      "INVTYPE_LEGS",
      "INVTYPE_FEET",
    },
  },
  { label = "Accessories", equipLocs = { "INVTYPE_NECK", "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_HOLDABLE" } },
  {
    label = "Weapons",
    equipLocs = {
      "INVTYPE_WEAPON",
      "INVTYPE_2HWEAPON",
      "INVTYPE_WEAPONMAINHAND",
      "INVTYPE_WEAPONOFFHAND",
      "INVTYPE_SHIELD",
      "INVTYPE_RANGED",
      "INVTYPE_RANGEDRIGHT",
      "INVTYPE_THROWN",
      "INVTYPE_RELIC",
    },
  },
}

-- Stats by GetItemStats key, grouped; any other stat is listed under Other. Base armor and weapon
-- damage per second are left out because every armor piece and weapon has them.
local STAT_GROUPS = {
  {
    label = "Attributes",
    values = {
      "ITEM_MOD_STRENGTH_SHORT",
      "ITEM_MOD_AGILITY_SHORT",
      "ITEM_MOD_STAMINA_SHORT",
      "ITEM_MOD_INTELLECT_SHORT",
      "ITEM_MOD_SPIRIT_SHORT",
    },
  },
  {
    label = "Offense",
    values = {
      "ITEM_MOD_ATTACK_POWER_SHORT",
      "ITEM_MOD_RANGED_ATTACK_POWER_SHORT",
      "ITEM_MOD_SPELL_POWER_SHORT",
      "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT",
      "ITEM_MOD_SPELL_HEALING_DONE_SHORT",
      "ITEM_MOD_CRIT_RATING_SHORT",
      "ITEM_MOD_CRIT_SPELL_RATING_SHORT",
      "ITEM_MOD_HIT_RATING_SHORT",
      "ITEM_MOD_HIT_SPELL_RATING_SHORT",
      "ITEM_MOD_HASTE_RATING_SHORT",
      "ITEM_MOD_SPELL_PENETRATION_SHORT",
      "ITEM_MOD_MANA_REGENERATION_SHORT",
    },
  },
  {
    label = "Defense",
    values = {
      "ITEM_MOD_EXTRA_ARMOR_SHORT",
      "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT",
      "ITEM_MOD_DODGE_RATING_SHORT",
      "ITEM_MOD_PARRY_RATING_SHORT",
      "ITEM_MOD_BLOCK_RATING_SHORT",
      "ITEM_MOD_BLOCK_VALUE_SHORT",
      "ITEM_MOD_HEALTH_REGENERATION_SHORT",
    },
  },
  {
    label = "Resistances",
    values = {
      "RESISTANCE6_NAME",
      "RESISTANCE2_NAME",
      "RESISTANCE4_NAME",
      "RESISTANCE1_NAME",
      "RESISTANCE3_NAME",
      "RESISTANCE5_NAME",
    },
  },
}
local IGNORED_STATS = { RESISTANCE0_NAME = true, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = true }

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
  for _, range in ipairs(RANGES) do
    ranges[range.key] = { min = 0, max = 0 }
  end
  return {
    slots = {},
    qualities = {},
    stats = {},
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
  return "|c" .. select(4, C_Item.GetItemQualityColor(quality)) .. _G["ITEM_QUALITY" .. quality .. "_DESC"] .. "|r"
end

---@param key string
---@return string
local function StatName(key)
  return _G[key] or key
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
  if filters.category then
    parts[#parts + 1] = filters.category.path
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
  if next(filters.stats) then
    local names = {}
    for key in pairs(filters.stats) do
      names[#names + 1] = StatName(key)
    end
    table.sort(names)
    parts[#parts + 1] = table.concat(names, " + ")
  end
  for _, range in ipairs(RANGES) do
    local bounds = filters.ranges[range.key]
    if bounds.min > 0 or bounds.max > 0 then
      parts[#parts + 1] = DescribeRange(range, bounds)
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

-- Rarity, stats, and levels come from item data the client may still be loading.
---@return boolean
function ns.DatabaseFilters.NeedsItemInfo()
  local ranges = filters.ranges
  return next(filters.qualities) ~= nil
    or next(filters.stats) ~= nil
    or ranges.requiredLevel.min > 0
    or ranges.requiredLevel.max > 0
    or ranges.itemLevel.min > 0
    or ranges.itemLevel.max > 0
end

---@param row ArbitrageDatabaseRow
---@param now number
---@return boolean
function ns.DatabaseFilters.Matches(row, now)
  local category = filters.category
  if
    category
    and (row.classID ~= category.classID or (category.subClassIDs and not category.subClassIDs[row.subClassID]))
  then
    return false
  end
  if next(filters.slots) and not (row.slot and filters.slots[row.slot]) then
    return false
  end
  if next(filters.qualities) and not (row.quality and filters.qualities[row.quality]) then
    return false
  end
  for key in pairs(filters.stats) do
    if not (row.stats and row.stats[key]) then
      return false
    end
  end
  for _, range in ipairs(RANGES) do
    local bounds = filters.ranges[range.key]
    local value = row[range.key]
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
  local subclasses, slots, qualities, stats = {}, {}, {}, {}
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
    for key in pairs(row.stats or {}) do
      stats[key] = not IGNORED_STATS[key] or nil
    end
  end

  -- Selecting keeps the menu open so filters can be combined in one visit.
  local function Changed()
    onChange()
    return MenuResponse.Refresh
  end
  local function IsCategory(category)
    return (filters.category and filters.category.key) == category.key
  end
  local function SetCategory(category)
    filters.category = category.key and category or nil
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
    classMenu:CreateRadio("All " .. class.name, IsCategory, SetCategory, {
      key = tostring(class.id),
      classID = class.id,
      path = class.name,
    })

    local function SubClassName(subClassID)
      return C_Item.GetItemSubClassInfo(class.id, subClassID)
    end
    local function AddSubclasses(menu, ids)
      for _, subclass in ipairs(ByName(ids, SubClassName)) do
        menu:CreateRadio(subclass.name, IsCategory, SetCategory, {
          key = class.id .. ":" .. subclass.id,
          classID = class.id,
          subClassIDs = { [subclass.id] = true },
          path = class.name .. " > " .. subclass.name,
        })
      end
    end

    local ungrouped = {}
    for subClassID in pairs(subclasses[class.id]) do
      ungrouped[subClassID] = true
    end
    for _, group in ipairs(SUBCLASS_GROUPS[class.id] or {}) do
      local present = {}
      for _, subClassID in ipairs(group.subClassIDs) do
        present[subClassID] = ungrouped[subClassID]
        ungrouped[subClassID] = nil
      end
      if next(present) then
        local groupMenu = classMenu:CreateButton(group.label)
        groupMenu:CreateRadio("All " .. group.label, IsCategory, SetCategory, {
          key = class.id .. ":" .. group.label,
          classID = class.id,
          subClassIDs = present,
          path = class.name .. " > " .. group.label,
        })
        AddSubclasses(groupMenu, present)
      end
    end
    AddSubclasses(classMenu, ungrouped)
  end

  -- Lists each group's values found in the database as a submenu, then the rest under Other.
  local function AddGroupedCheckboxes(menu, set, groups, present, label)
    local placed = {}
    local function AddGroup(groupLabel, values)
      if #values > 0 then
        local groupMenu = menu:CreateButton(groupLabel)
        for _, value in ipairs(values) do
          groupMenu:CreateCheckbox(label(value), IsInSet, ToggleInSet, { set = set, value = value })
        end
      end
    end
    for _, group in ipairs(groups) do
      local values = {}
      for _, value in ipairs(group.values) do
        if present[value] and not placed[value] then
          placed[value] = true
          values[#values + 1] = value
        end
      end
      AddGroup(group.label, values)
    end
    local others = {}
    for value in pairs(present) do
      if not placed[value] then
        others[#others + 1] = value
      end
    end
    table.sort(others, function(left, right)
      return label(left) < label(right)
    end)
    AddGroup("Other", others)
  end

  -- Slots are filtered by name, so robes and chest pieces, or shields and off-hand weapons, are one.
  local slotGroups = {}
  for _, group in ipairs(SLOT_GROUPS) do
    local names = {}
    for _, equipLoc in ipairs(group.equipLocs) do
      names[#names + 1] = _G[equipLoc]
    end
    slotGroups[#slotGroups + 1] = { label = group.label, values = names }
  end
  local function Same(value)
    return value
  end
  AddGroupedCheckboxes(rootDescription:CreateButton("Slot"), "slots", slotGroups, slots, Same)

  local rarityMenu = rootDescription:CreateButton("Rarity")
  for _, quality in ipairs(SortedKeys(qualities)) do
    rarityMenu:CreateCheckbox(QualityName(quality), IsInSet, ToggleInSet, { set = "qualities", value = quality })
  end

  AddGroupedCheckboxes(rootDescription:CreateButton("Stats"), "stats", STAT_GROUPS, stats, StatName)

  for _, range in ipairs(RANGES) do
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
      local bounds = filters.ranges[range.key]
      if bounds.min > 0 then
        frame:SetMinLevel(bounds.min)
      end
      if bounds.max > 0 then
        frame:SetMaxLevel(bounds.max)
      end
      frame:SetLevelRangeChangedCallback(function(min, max)
        filters.ranges[range.key] = { min = min, max = max }
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

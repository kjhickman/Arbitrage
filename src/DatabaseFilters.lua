local _, ns = ...

ns.DatabaseFilters = {}

---@class ArbitrageDatabaseRange
---@field key string row field the range bounds
---@field label string menu title
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
  { key = "requiredLevel", label = "Required Level", letters = 3, width = 28 },
  { key = "itemLevel", label = "Item Level", letters = 3, width = 28 },
  { key = "marketValue", label = "Market Value (gold)", scale = 10000, letters = 5, width = 44 },
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

-- The saved filters themselves, so each change is saved as it is made.
---@type ArbitrageDatabaseFilterState!
local filters

---@param saved any
---@param keyType type
---@return table<any, true>
local function LoadSet(saved, keyType)
  local set = {}
  if type(saved) == "table" then
    for key, value in pairs(saved) do
      if type(key) == keyType and value == true then
        set[key] = true
      end
    end
  end
  return set
end

---@param saved any
---@return ArbitrageDatabaseCategory?
local function LoadCategory(saved)
  if
    type(saved) ~= "table"
    or type(saved.key) ~= "string"
    or type(saved.classID) ~= "number"
    or type(saved.path) ~= "string"
  then
    return nil
  end
  local subClassIDs = saved.subClassIDs ~= nil and LoadSet(saved.subClassIDs, "number") or nil
  if subClassIDs and next(subClassIDs) == nil then
    return nil
  end
  return { key = saved.key, classID = saved.classID, subClassIDs = subClassIDs, path = saved.path }
end

---@param saved any
---@return number
local function LoadBound(saved)
  return type(saved) == "number" and saved >= 0 and saved or 0
end

-- Keeps only the valid parts of saved filters, so filters from an older version or edited by hand
-- fall back to their defaults rather than break the tab.
---@param saved table
---@return ArbitrageDatabaseFilterState
local function LoadFilters(saved)
  local loaded = NewFilters()
  loaded.category = LoadCategory(saved.category)
  loaded.slots = LoadSet(saved.slots, "string")
  loaded.qualities = LoadSet(saved.qualities, "number")
  loaded.stats = LoadSet(saved.stats, "string")
  local savedRanges = type(saved.ranges) == "table" and saved.ranges or {}
  for key, bounds in pairs(loaded.ranges) do
    local savedBounds = savedRanges[key]
    if type(savedBounds) == "table" then
      bounds.min, bounds.max = LoadBound(savedBounds.min), LoadBound(savedBounds.max)
    end
  end
  loaded.craftable = saved.craftable == true
  loaded.profitable = saved.profitable == true
  loaded.freshness = FRESHNESS[saved.freshness] and saved.freshness or 1
  loaded.hideUncertain = saved.hideUncertain == true
  return loaded
end

-- Reads the saved filters; call once saved variables have loaded.
function ns.DatabaseFilters.Init()
  local saved = ns.Config.Get("databaseFilters")
  ---@cast saved table
  filters = LoadFilters(saved)
  ns.Config.Set("databaseFilters", filters)
end

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

-- The active filters as one line, or nil when nothing is filtered.
---@return string?
function ns.DatabaseFilters.Describe()
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
      local text = bounds.max == 0 and bounds.min .. "+"
        or bounds.min == 0 and "up to " .. bounds.max
        or bounds.min .. "-" .. bounds.max
      parts[#parts + 1] = range.label .. " " .. text
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
  return #parts > 0 and table.concat(parts, " · ") or nil
end

---@return boolean
function ns.DatabaseFilters.IsDefault()
  return ns.DatabaseFilters.Describe() == nil
end

function ns.DatabaseFilters.Reset()
  filters = NewFilters()
  ns.Config.Set("databaseFilters", filters)
end

-- Gear stats are read after the Database tab's rows show, so only this filter waits on them.
---@return boolean
function ns.DatabaseFilters.FiltersByStats()
  return next(filters.stats) ~= nil
end

-- Rarity, stats, and levels come from item data the client may still be loading.
---@return boolean
function ns.DatabaseFilters.NeedsItemInfo()
  local ranges = filters.ranges
  return next(filters.qualities) ~= nil
    or ns.DatabaseFilters.FiltersByStats()
    or ranges.requiredLevel.min > 0
    or ranges.requiredLevel.max > 0
    or ranges.itemLevel.min > 0
    or ranges.itemLevel.max > 0
end

-- A test for the active filters, built once per refresh so each row only meets the filters in use;
-- nil when nothing is filtered.
---@param now number
---@return (fun(row: ArbitrageDatabaseRow): boolean)?
function ns.DatabaseFilters.Matcher(now)
  local checks = {}
  local function Check(check)
    checks[#checks + 1] = check
  end

  local category = filters.category
  if category then
    Check(function(row)
      return row.classID == category.classID
        and (category.subClassIDs == nil or category.subClassIDs[row.subClassID] == true)
    end)
  end
  local slots, qualities, stats = filters.slots, filters.qualities, filters.stats
  if next(slots) then
    Check(function(row)
      return row.slot ~= nil and slots[row.slot] == true
    end)
  end
  if next(qualities) then
    Check(function(row)
      return row.quality ~= nil and qualities[row.quality] == true
    end)
  end
  if next(stats) then
    Check(function(row)
      if not row.stats then
        return false
      end
      for key in pairs(stats) do
        if not row.stats[key] then
          return false
        end
      end
      return true
    end)
  end
  for _, range in ipairs(RANGES) do
    local bounds, scale = filters.ranges[range.key], range.scale or 1
    if bounds.min > 0 or bounds.max > 0 then
      local min, max = bounds.min * scale, bounds.max > 0 and bounds.max * scale or math.huge
      Check(function(row)
        local value = row[range.key]
        return value ~= nil and value >= min and value <= max
      end)
    end
  end
  if filters.profitable then
    -- An Auction House sale nets the Market Value less the cut, in whole copper, as on the
    -- Opportunities tab.
    local kept = 1 - ns.Opportunities.AUCTION_HOUSE_CUT_RATE
    Check(function(row)
      return row.craftCost ~= nil and row.marketValue ~= nil and math.floor(row.marketValue * kept) > row.craftCost
    end)
  elseif filters.craftable then
    Check(function(row)
      return row.craftCost ~= nil or row.craftCostIsUnknown
    end)
  end
  local freshness = FRESHNESS[filters.freshness]
  if freshness.latest then
    Check(function(row)
      return row.latestBuyout ~= nil
    end)
  elseif freshness.days then
    local cutoff = now - freshness.days * DAY
    Check(function(row)
      return row.lastSeen ~= nil and row.lastSeen >= cutoff
    end)
  end
  if filters.hideUncertain then
    Check(function(row)
      return row.marketValue ~= nil and not row.marketIsUncertain
    end)
  end

  if #checks == 0 then
    return nil
  end
  return function(row)
    for index = 1, #checks do
      if not checks[index](row) then
        return false
      end
    end
    return true
  end
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

-- Lists only the categories, slots, rarities, and stats found in the database.
---@param rootDescription table
---@param facets ArbitrageDatabaseFacets
---@param onChange fun()
function ns.DatabaseFilters.SetupMenu(rootDescription, facets, onChange)
  local subclasses, slots, qualities = facets.subclasses, facets.slots, facets.qualities
  local stats = {}
  for key in pairs(facets.stats) do
    stats[key] = not IGNORED_STATS[key] or nil
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
      local present, all = {}, {}
      for _, subClassID in ipairs(group.subClassIDs) do
        present[subClassID] = ungrouped[subClassID]
        ungrouped[subClassID] = nil
        all[subClassID] = true
      end
      if next(present) then
        local groupMenu = classMenu:CreateButton(group.label)
        groupMenu:CreateRadio("All " .. group.label, IsCategory, SetCategory, {
          key = class.id .. ":" .. group.label,
          classID = class.id,
          -- The whole group, so a saved choice keeps subclasses first scanned later.
          subClassIDs = all,
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
  AddGroupedCheckboxes(rootDescription:CreateButton("Slot"), "slots", slotGroups, slots, tostring)

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
    "Items whose Market Value, less the 5% Auction House cut, is above their Craft Cost."
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

local _, ns = ...

ns.Keys = {}

-- Forever rolls random stats ("of the Owl") as a bonus ID rather than the classic suffix field.
-- Numbering fields from the item ID, field 13 counts bonus IDs and field 14 holds the first:
-- Merciless Gauntlets of the Owl list as item:15653::::::::1:1485:::1:12720, and every item
-- "of the Owl" shares bonus ID 12720.
local VARIANT_LINK = "item:%d::::::::1:1485:::1:%d"
-- Skips fields 1 to 12, requires field 13 to be exactly 1, and captures field 14.
local SINGLE_BONUS_ID = "^" .. ("[^:]*:"):rep(12) .. "1:([^:]*)"

---@param itemLink string
---@return number?
local function GetVariantID(itemLink)
  local fields = itemLink:match("item:([^|]+)")
  -- An item with more than one bonus ID has no single variant to key it by.
  return fields and tonumber(fields:match(SINGLE_BONUS_ID)) or nil
end

-- Weapons and armor can carry random stats that only the item link spells
-- out, so their key cannot be derived from the item ID alone.
---@param itemID number?
---@return boolean
function ns.Keys.NeedsLink(itemID)
  if type(itemID) ~= "number" then
    return false
  end

  local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
  return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

---@param itemID number?
---@return string[]
function ns.Keys.FromItemID(itemID)
  if type(itemID) ~= "number" then
    return {}
  end

  local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
  if classID == nil then
    return {}
  end

  -- Gear keyed without its link counts only toward the item ID's price, which covers every
  -- random enchant.
  return { tostring(itemID) }
end

---@param itemLink string?
---@return string[]
function ns.Keys.FromLink(itemLink)
  if itemLink == nil then
    return {}
  end

  local itemID, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemLink)
  if itemID == nil then
    return {}
  end

  if classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor then
    local variantID = GetVariantID(itemLink)
    if variantID then
      return { "equip:" .. itemID .. ":" .. variantID, tostring(itemID) }
    end
  end

  return { tostring(itemID) }
end

-- The item a key prices, and a link that names its variant.
---@param dbKey string
---@return number? itemID, string? link
function ns.Keys.ToLink(dbKey)
  local itemID = tonumber(dbKey)
  if itemID then
    return itemID, "item:" .. dbKey
  end

  local variantItemID, variantID = dbKey:match("^equip:(%d+):(%d+)$")
  if variantItemID then
    return tonumber(variantItemID), VARIANT_LINK:format(variantItemID, variantID)
  end
  return nil
end

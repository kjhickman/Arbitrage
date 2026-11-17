local _, ns = ...

ns.Keys = {}

-- Forever rolls random stats ("of the Owl") as a bonus ID rather than the classic suffix field.
-- Numbering fields from the item ID, field 13 counts bonus IDs and field 14 holds the first:
-- Merciless Gauntlets of the Owl list as item:15653::::::::1:1485:::1:12720, and every item
-- "of the Owl" shares bonus ID 12720.
local VARIANT_LINK = "item:%d::::::::1:1485:::1:%d"

---@param itemLink string
---@return number?
local function GetVariantID(itemLink)
  local fields = {}
  for field in ((itemLink:match("item:([^|]+)") or "") .. ":"):gmatch("([^:]*):") do
    fields[#fields + 1] = field
  end
  -- An item with more than one bonus ID has no single variant to key it by.
  if fields[13] == "1" then
    return tonumber(fields[14])
  end
  return nil
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
  if classID == nil or classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor then
    return {}
  end

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

  local variantID = GetVariantID(itemLink)
  if variantID and (classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor) then
    return { "equip:" .. itemID .. ":" .. variantID, tostring(itemID) }
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

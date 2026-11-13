local _, ns = ...

ns.Keys = {}

---@param itemLink string
---@return number?
local function GetSuffixID(itemLink)
  return tonumber(itemLink:match("item:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:|]+)"))
end

-- Weapons and armor can carry a random suffix that only the item link spells
-- out, so their key cannot be derived from the item ID alone. An item the
-- client cannot classify at all is treated the same way rather than risk
-- pooling suffixed gear under one key.
---@param itemID number?
---@return boolean
function ns.Keys.NeedsLink(itemID)
  if type(itemID) ~= "number" then
    return true
  end

  local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
  if classID == nil then
    return true
  end

  return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

---@param itemID number?
---@return string[]
function ns.Keys.FromItemID(itemID)
  if ns.Keys.NeedsLink(itemID) then
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

  local suffixID = GetSuffixID(itemLink)
  if suffixID and suffixID ~= 0 and (classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor) then
    return { "equip:" .. itemID .. ":" .. suffixID, tostring(itemID) }
  end

  return { tostring(itemID) }
end

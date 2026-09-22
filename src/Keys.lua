local _, ns = ...

ns.Keys = {}

---@param itemLink string
---@return number?
local function GetSuffixID(itemLink)
  return tonumber(itemLink:match("item:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:|]+)"))
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

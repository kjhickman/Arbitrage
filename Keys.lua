local _, ns = ...

ns.Keys = {}

local function GetItemID(itemLink)
  return itemLink and tonumber(itemLink:match("item:(%d+)"))
end

local function GetSuffixID(itemLink)
  return itemLink and tonumber(itemLink:match("item:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:|]+)"))
end

local function IsEquipment(itemLink)
  local classID = select(6, C_Item.GetItemInfoInstant(itemLink))
  return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

function ns.Keys.FromLink(itemLink)
  local itemID = GetItemID(itemLink)
  if itemID == nil then
    return {}
  end

  local suffixID = GetSuffixID(itemLink)
  if suffixID and suffixID ~= 0 and IsEquipment(itemLink) then
    return { "equip:" .. itemID .. ":" .. suffixID, tostring(itemID) }
  end

  return { tostring(itemID) }
end

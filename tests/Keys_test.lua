Enum = {
  ItemClass = {
    Weapon = 2,
    Armor = 4,
  },
}
C_Item = {
  GetItemInfoInstant = function()
    return nil, nil, nil, nil, nil, Enum.ItemClass.Weapon
  end,
}

local ns = {}
assert(loadfile("src/Keys.lua"), "loads Keys.lua")("Arbitrage", ns)

local keys = ns.Keys.FromLink("|cff1eff00|Hitem:123:0:0:0:0:0:-35:0:0:0:0|h[Green Item of the Bear]|h|r")
assert(keys[1] == "equip:123:-35", "uses the numeric random-property suffix")
assert(keys[2] == "123", "keeps a generic item fallback")

C_Item.GetItemInfoInstant = function()
  return nil, nil, nil, nil, nil, 7
end
keys = ns.Keys.FromLink("|cff1eff00|Hitem:123:0:0:0:0:0:-35:0:0:0:0|h[Green Item]|h|r")
assert(keys[1] == "123" and keys[2] == nil, "does not suffix-key non-equipment")

local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Keys", function()
  local environment
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ns = {}
    Enum = {
      ItemClass = {
        Weapon = 2,
        Armor = 4,
      },
    }
    C_Item = {
      GetItemInfoInstant = function(itemLink)
        return tonumber(itemLink:match("item:(%d+)")), nil, nil, nil, nil, Enum.ItemClass.Weapon
      end,
    }
    assert(loadfile("src/Keys.lua"), "loads Keys.lua")("Arbitrage", ns)
  end)

  it("uses equipment suffix keys with a generic item fallback", function()
    setfenv(1, environment)
    local keys = ns.Keys.FromLink("|cff1eff00|Hitem:123:0:0:0:0:0:-35:0:0:0:0|h[Green Item of the Bear]|h|r")
    assert(keys[1] == "equip:123:-35", "uses the numeric random-property suffix")
    assert(keys[2] == "123", "keeps a generic item fallback")
  end)

  it("parses suffixes from full-length Forever links", function()
    setfenv(1, environment)
    local keys =
      ns.Keys.FromLink("|cff1eff00|Hitem:456:0:0:0:0:0:-42:70:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h[Forever Item]|h|r")
    assert(keys[1] == "equip:456:-42" and keys[2] == "456", "parses suffixes from full-length Forever links")
  end)

  it("does not suffix-key non-equipment", function()
    setfenv(1, environment)
    ns.Keys.FromLink("|cff1eff00|Hitem:123:0:0:0:0:0:-35:0:0:0:0|h[Green Item of the Bear]|h|r")
    C_Item.GetItemInfoInstant = function(itemLink)
      return tonumber(itemLink:match("item:(%d+)")), nil, nil, nil, nil, 7
    end
    local keys = ns.Keys.FromLink("|cff1eff00|Hitem:123:0:0:0:0:0:-35:0:0:0:0|h[Green Item]|h|r")
    assert(keys[1] == "123" and keys[2] == nil, "does not suffix-key non-equipment")
  end)
end)

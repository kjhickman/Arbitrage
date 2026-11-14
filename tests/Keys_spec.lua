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
      GetItemInfoInstant = function(itemInfo)
        if type(itemInfo) == "number" then
          return itemInfo, nil, nil, nil, nil, Enum.ItemClass.Weapon
        end
        return tonumber(itemInfo:match("item:(%d+)")), nil, nil, nil, nil, Enum.ItemClass.Weapon
      end,
    }
    assert(loadfile("src/Keys.lua"), "loads Keys.lua")("Arbitrage", ns)
  end)

  local function ClassifyAs(classID)
    environment.C_Item.GetItemInfoInstant = function(itemInfo)
      local itemID = type(itemInfo) == "number" and itemInfo or tonumber(itemInfo:match("item:(%d+)"))
      return itemID, nil, nil, nil, nil, classID
    end
  end

  it("keys non-equipment from the item ID alone", function()
    setfenv(1, environment)
    ClassifyAs(7)
    assert(ns.Keys.NeedsLink(2770) == false, "trade goods carry no suffix to recover")
    local keys = ns.Keys.FromItemID(2770)
    assert(keys[1] == "2770" and keys[2] == nil, "keys trade goods from the item ID")
  end)

  it("requires a link for gear that could carry a suffix", function()
    setfenv(1, environment)
    for _, classID in ipairs({ Enum.ItemClass.Weapon, Enum.ItemClass.Armor }) do
      ClassifyAs(classID)
      assert(ns.Keys.NeedsLink(123), "gear needs its link")
      assert(ns.Keys.FromItemID(123)[1] == nil, "refuses to key gear from the item ID")
    end
  end)

  it("ignores an item the client cannot classify", function()
    setfenv(1, environment)
    ClassifyAs(nil)
    assert(ns.Keys.NeedsLink(123) == false, "an unknown item has no link to wait for")
    assert(ns.Keys.NeedsLink(nil) == false, "a missing item ID has no link to wait for")
    assert(ns.Keys.FromItemID(123)[1] == nil, "refuses to key an unknown item ID")
    assert(ns.Keys.FromItemID(nil)[1] == nil, "refuses to key a missing item ID")
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

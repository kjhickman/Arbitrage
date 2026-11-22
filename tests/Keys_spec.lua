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
        Battlepet = 17,
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
      assert.are.same({ "123" }, ns.Keys.FromItemID(123), "keys gear without its link under the item ID alone")
    end
  end)

  it("keys every auction of an item by its item ID except gear, battle pets, and unknown items", function()
    setfenv(1, environment)
    ClassifyAs(7)
    assert.is_true(ns.Keys.KeyedByItemID(2770))
    for _, classID in ipairs({ Enum.ItemClass.Weapon, Enum.ItemClass.Armor, Enum.ItemClass.Battlepet }) do
      ClassifyAs(classID)
      assert.is_false(ns.Keys.KeyedByItemID(123))
    end
    ClassifyAs(nil)
    assert.is_false(ns.Keys.KeyedByItemID(123))
  end)

  it("ignores an item the client cannot classify", function()
    setfenv(1, environment)
    ClassifyAs(nil)
    assert(ns.Keys.NeedsLink(123) == false, "an unknown item has no link to wait for")
    assert(ns.Keys.NeedsLink(nil) == false, "a missing item ID has no link to wait for")
    assert(ns.Keys.FromItemID(123)[1] == nil, "refuses to key an unknown item ID")
    assert(ns.Keys.FromItemID(nil)[1] == nil, "refuses to key a missing item ID")
  end)

  -- Copied from Forever's Auction House.
  local OWL_GAUNTLETS = "|cnIQ2:|Hitem:15653::::::::1:1485:::1:12720::::::|h[Merciless Gauntlets of the Owl]|h|r"

  it("keys gear by the bonus ID Forever uses for its random stats, with a generic item fallback", function()
    setfenv(1, environment)
    assert.are.same({ "equip:15653:12720", "15653" }, ns.Keys.FromLink(OWL_GAUNTLETS))
    assert.are.same(
      { "equip:8178:12729", "8178" },
      ns.Keys.FromLink("|cnIQ2:|Hitem:8178::::::::1:1485:::1:12729::::::|h[Training Sword of Intellect]|h|r")
    )
  end)

  it("keys gear without exactly one bonus ID by its item ID alone", function()
    setfenv(1, environment)
    assert.are.same({ "123" }, ns.Keys.FromLink("|cnIQ2:|Hitem:123::::::::1:1485:::::::::|h[Plain Gear]|h|r"))
    assert.are.same({ "123" }, ns.Keys.FromLink("item:123::::::::1:1485:::2:12720:6000"))
    -- The classic suffix field is not where Forever keeps random stats.
    assert.are.same({ "123" }, ns.Keys.FromLink("item:123::::::-35"))
  end)

  it("does not split non-equipment by bonus ID", function()
    setfenv(1, environment)
    ClassifyAs(7)
    assert.are.same({ "15653" }, ns.Keys.FromLink(OWL_GAUNTLETS))
  end)

  it("turns keys back into links that name the variant", function()
    setfenv(1, environment)
    assert.are.same({ 2589, "item:2589" }, { ns.Keys.ToLink("2589") })
    local itemID, link = ns.Keys.ToLink("equip:15653:12720")
    assert.are.equal(15653, itemID)
    assert.are.equal("item:15653::::::::1:1485:::1:12720", link)
    assert.are.same({ "equip:15653:12720", "15653" }, ns.Keys.FromLink(link))
    assert.is_nil(ns.Keys.ToLink("equip:15653:"))
  end)
end)

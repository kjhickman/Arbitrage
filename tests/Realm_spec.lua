local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Realm", function()
  local environment
  local ns, regionalUniqueNames, activeRules, realmName, unitName, unmodifiedName, unmodifiedSurname

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    regionalUniqueNames = true
    activeRules = {}
    realmName = "CAMWOW US2 Realm 8 PvP"
    unitName = "Zug"
    unmodifiedName = "Zug"
    unmodifiedSurname = "Zugzwang"

    Enum = {
      GameRule = {
        HardcoreRuleset = 1,
        RPRuleset = 2,
        PvPRuleset = 3,
      },
    }

    C_GameRules = {
      IsGameRuleActive = function(rule)
        return activeRules[rule] == true
      end,
    }

    function RegionalUniqueNamesEnabled()
      return regionalUniqueNames
    end

    function GetRealmName()
      return realmName
    end

    function UnitName()
      return unitName
    end

    function UnitNameUnmodified()
      return unmodifiedName, unmodifiedSurname
    end

    ns = {}
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
  end)

  it("maps Forever rulesets instead of using the backend shard realm name", function()
    setfenv(1, environment)
    assert.are.equal("Normal", ns.Realm.GetName())

    activeRules[Enum.GameRule.PvPRuleset] = true
    assert.are.equal("PvP", ns.Realm.GetName())

    activeRules = { [Enum.GameRule.RPRuleset] = true }
    assert.are.equal("Roleplay", ns.Realm.GetName())

    activeRules = {
      [Enum.GameRule.RPRuleset] = true,
      [Enum.GameRule.PvPRuleset] = true,
    }
    assert.are.equal("Roleplay PvP", ns.Realm.GetName())

    activeRules = {
      [Enum.GameRule.HardcoreRuleset] = true,
      [Enum.GameRule.PvPRuleset] = true,
    }
    assert.are.equal("Hardcore", ns.Realm.GetName())
  end)

  it("falls back to GetRealmName when regional unique names are disabled", function()
    setfenv(1, environment)
    regionalUniqueNames = false
    activeRules[Enum.GameRule.PvPRuleset] = true
    assert.are.equal("CAMWOW US2 Realm 8 PvP", ns.Realm.GetName())
  end)

  it("joins Forever first names and surnames for character keys", function()
    setfenv(1, environment)
    assert.are.equal("Zug Zugzwang", ns.Realm.GetCharacterName())

    unmodifiedSurname = ""
    assert.are.equal("Zug", ns.Realm.GetCharacterName())

    unmodifiedSurname = nil
    assert.are.equal("Zug", ns.Realm.GetCharacterName())

    unmodifiedName = ""
    assert.is_nil(ns.Realm.GetCharacterName())

    regionalUniqueNames = false
    assert.are.equal("Zug", ns.Realm.GetCharacterName())
  end)
end)

local NewEnvironment = dofile("tests/support/Environment.lua")

describe("RecipeBook", function()
  local environment
  local ns, realm

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    realm = "Test Realm"

    function GetRealmName()
      return realm
    end

    function RegionalUniqueNamesEnabled()
      return false
    end

    function UnitName()
      return "Test Character"
    end

    strlower = string.lower

    ARBITRAGE_RECIPES = {
      __version = 1,
      [realm] = {
        characters = {
          Older = {
            professions = {
              Alchemy = {
                updatedAt = 1,
                recipes = {
                  shared = {
                    recipeKey = "shared",
                    outputItemID = 100,
                    outputQuantity = 2,
                    reagents = { { itemID = 200, quantity = 3 } },
                  },
                },
              },
            },
          },
          Newer = {
            professions = {
              Alchemy = {
                updatedAt = 2,
                recipes = {
                  shared = {
                    recipeKey = "shared",
                    outputItemID = 100,
                    outputQuantity = 5,
                    reagents = { { itemID = 201, quantity = 1 } },
                  },
                  alternative = {
                    recipeKey = "alternative",
                    outputItemID = 100,
                    outputQuantity = 1,
                    reagents = { { itemID = 202, quantity = 1 } },
                  },
                },
              },
            },
          },
        },
      },
    }
    ns = {}
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
    ns.RecipeBook.Init()
  end)

  it("resets an invalid persisted root", function()
    setfenv(1, environment)
    ARBITRAGE_RECIPES = "invalid"
    ns.RecipeBook.Init()
    local status = ns.RecipeBook.GetStatus()
    assert(status.characterCount == 0 and status.recipeCount == 0, "resets an invalid persisted root")
  end)

  it("indexes recipes across characters using the newest conflicting snapshot", function()
    setfenv(1, environment)
    local status = ns.RecipeBook.GetStatus()
    local recipes = ns.RecipeBook.GetRecipes(100)
    assert(status.characterCount == 2 and status.recipeCount == 2, "indexes recipes across characters")

    local byKey = {}
    for _, recipe in ipairs(recipes) do
      byKey[recipe.recipeKey] = recipe
    end
    assert(byKey.shared.outputQuantity == 5, "uses the newest conflicting recipe snapshot")
    assert(byKey.alternative.outputQuantity == 1, "keeps alternative recipes")
  end)

  it("enumerates each craftable output once with every recipe source", function()
    setfenv(1, environment)
    local outputs = ns.RecipeBook.GetCraftableOutputs()
    assert(#outputs == 1 and outputs[1].outputItemID == 100, "enumerates each craftable output once")
    assert(#outputs[1].sources == 3, "keeps every character and recipe source for an output")
  end)

  it("sorts recipe sources deterministically without losing characters", function()
    setfenv(1, environment)
    local outputs = ns.RecipeBook.GetCraftableOutputs()
    assert(
      outputs[1].sources[1].characterName == "Newer"
        and outputs[1].sources[1].professionName == "Alchemy"
        and outputs[1].sources[1].recipeKey == "alternative",
      "sorts recipe sources deterministically"
    )
    assert(
      outputs[1].sources[2].characterName == "Newer"
        and outputs[1].sources[2].recipeKey == "shared"
        and outputs[1].sources[3].characterName == "Older"
        and outputs[1].sources[3].recipeKey == "shared",
      "reports every character that knows the selected recipes"
    )
  end)

  it("resets a malformed realm and clears its recipe index", function()
    setfenv(1, environment)
    ARBITRAGE_RECIPES[realm] = "invalid"
    ns.RecipeBook.Init()
    local status = ns.RecipeBook.GetStatus()
    assert(status.characterCount == 0 and status.recipeCount == 0, "resets a malformed realm as a unit")
  end)

  it("stores Forever recipes under the ruleset and full character name", function()
    setfenv(1, environment)
    Enum = {
      GameRule = {
        HardcoreRuleset = 1,
        RPRuleset = 2,
        PvPRuleset = 3,
      },
    }
    C_GameRules = {
      IsGameRuleActive = function(rule)
        return rule == Enum.GameRule.RPRuleset
      end,
    }
    function RegionalUniqueNamesEnabled()
      return true
    end
    function UnitNameUnmodified()
      return "Zug", "Zugzwang"
    end
    function time()
      return 123
    end

    ARBITRAGE_RECIPES = nil
    realm = "CAMWOW US2 Realm 4 RP"
    ns.RecipeBook.Init()
    ns.RecipeBook.SaveProfession("Alchemy", {
      potion = {
        recipeKey = "potion",
        outputItemID = 118,
        outputQuantity = 1,
        reagents = { { itemID = 765, quantity = 1 } },
      },
    })

    realm = "CAMWOW US2 Realm 9 RP"
    function UnitNameUnmodified()
      return "Zug", "Otherclan"
    end
    ns.RecipeBook.Init()
    ns.RecipeBook.SaveProfession("Blacksmithing", {
      mace = {
        recipeKey = "mace",
        outputItemID = 2845,
        outputQuantity = 1,
        reagents = { { itemID = 2840, quantity = 6 } },
      },
    })

    local status = ns.RecipeBook.GetStatus()
    assert.are.equal(2, status.characterCount)
    assert.are.equal(2, status.recipeCount)
    assert.is_table(ARBITRAGE_RECIPES.Roleplay.characters["Zug Zugzwang"])
    assert.is_table(ARBITRAGE_RECIPES.Roleplay.characters["Zug Otherclan"])
  end)

  it("prunes unlearned professions on one character while keeping another character's shared profession", function()
    setfenv(1, environment)
    ARBITRAGE_RECIPES = {
      __version = 1,
      [realm] = {
        characters = {
          ["Char A"] = {
            professions = {
              Engineering = {
                updatedAt = 2,
                recipes = {
                  shared = {
                    recipeKey = "shared",
                    outputItemID = 4358,
                    outputQuantity = 1,
                    reagents = { { itemID = 4357, quantity = 2 } },
                  },
                  onlyA = {
                    recipeKey = "onlyA",
                    outputItemID = 4360,
                    outputQuantity = 1,
                    reagents = { { itemID = 4357, quantity = 1 } },
                  },
                },
              },
              Mining = {
                updatedAt = 2,
                recipes = {
                  copper = {
                    recipeKey = "copper",
                    outputItemID = 2840,
                    outputQuantity = 1,
                    reagents = { { itemID = 2770, quantity = 1 } },
                  },
                },
              },
            },
          },
          ["Char B"] = {
            professions = {
              Engineering = {
                updatedAt = 1,
                recipes = {
                  shared = {
                    recipeKey = "shared",
                    outputItemID = 4358,
                    outputQuantity = 1,
                    reagents = { { itemID = 4357, quantity = 2 } },
                  },
                },
              },
            },
          },
        },
      },
    }

    function UnitName()
      return "Char A"
    end
    ns.RecipeBook.Init()

    assert.is_true(ns.RecipeBook.PruneProfessions({ Mining = true }))
    assert.is_false(ns.RecipeBook.PruneProfessions({ Mining = true }))
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(4358))
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(4360))
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(2840))

    local byOutput = {}
    for _, output in ipairs(ns.RecipeBook.GetCraftableOutputs()) do
      byOutput[output.outputItemID] = output.sources
    end
    assert.are.equal(1, #byOutput[4358])
    assert.are.equal("Char B", byOutput[4358][1].characterName)

    assert.is_true(ns.RecipeBook.PruneProfessions({}))
    assert.is_nil(ARBITRAGE_RECIPES[realm].characters["Char A"])
    assert.are.equal(1, ns.RecipeBook.GetStatus().characterCount)
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(4358))
  end)

  it("forgets a character case-insensitively without removing other characters", function()
    setfenv(1, environment)
    ARBITRAGE_RECIPES[realm].characters["Zug Zugzwang"] = {
      professions = {
        Engineering = {
          updatedAt = 3,
          recipes = {
            exclusive = {
              recipeKey = "exclusive",
              outputItemID = 4360,
              outputQuantity = 1,
              reagents = { { itemID = 4357, quantity = 1 } },
            },
          },
        },
      },
    }
    ns.RecipeBook.Init()

    assert.are.same({ "Newer", "Older", "Zug Zugzwang" }, ns.RecipeBook.GetCharacterNames())
    assert.is_nil(ns.RecipeBook.ForgetCharacter("Nobody"))
    assert.are.equal("Zug Zugzwang", ns.RecipeBook.ForgetCharacter("zug zugzwang"))
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(4360))
    assert.are.equal(2, #ns.RecipeBook.GetRecipes(100))
    assert.are.same({ "Newer", "Older" }, ns.RecipeBook.GetCharacterNames())
  end)
end)

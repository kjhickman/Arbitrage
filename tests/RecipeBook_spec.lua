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

    function UnitName()
      return "Test Character"
    end

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
end)

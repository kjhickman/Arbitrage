local realm = "Test Realm"

function GetRealmName()
  return realm
end

function UnitName()
  return "Test Character"
end

ARBITRAGE_RECIPES = "invalid"

local ns = {}
assert(loadfile("RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
ns.RecipeBook.Init()

local status = ns.RecipeBook.GetStatus()
assert(status.characterCount == 0 and status.recipeCount == 0, "resets an invalid persisted root")

ARBITRAGE_RECIPES = {
  __version = 1,
  [realm] = {
    characters = {
      Broken = true,
      Empty = { professions = { Broken = true } },
      Valid = {
        professions = {
          Alchemy = {
            updatedAt = 1,
            recipes = {
              valid = {
                recipeKey = "valid",
                outputItemID = 100,
                outputQuantity = 2,
                reagents = { { itemID = 200, quantity = 3, name = "Reagent" } },
              },
              invalid = {
                recipeKey = "invalid",
                outputItemID = 300,
                outputQuantity = 0,
                reagents = {},
              },
              mismatched = {
                recipeKey = "different",
                outputItemID = 400,
                outputQuantity = 1,
                reagents = { { itemID = 200, quantity = 1 } },
              },
              sparse = {
                recipeKey = "sparse",
                outputItemID = 500,
                outputQuantity = 1,
                reagents = {
                  [2] = { itemID = 200, quantity = 1 },
                  [5] = { itemID = 201, quantity = 1 },
                },
              },
              nan = {
                recipeKey = "nan",
                outputItemID = 0 / 0,
                outputQuantity = 1,
                reagents = { { itemID = 200, quantity = 1 } },
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
              valid = {
                recipeKey = "valid",
                outputItemID = 100,
                outputQuantity = 5,
                reagents = { { itemID = 201, quantity = 1 } },
              },
              zeta = {
                recipeKey = "zeta",
                outputItemID = 600,
                outputQuantity = 1,
                reagents = { { itemID = 201, quantity = 1 } },
              },
              alpha = {
                recipeKey = "alpha",
                outputItemID = 600,
                outputQuantity = 1,
                reagents = { { itemID = 202, quantity = 1 } },
              },
            },
          },
        },
      },
      MalformedTimestamp = {
        professions = {
          Alchemy = {
            updatedAt = 0 / 0,
            recipes = {
              valid = {
                recipeKey = "valid",
                outputItemID = 100,
                outputQuantity = 7,
                reagents = { { itemID = 202, quantity = 1 } },
              },
            },
          },
        },
      },
    },
  },
}
ns.RecipeBook.Init()

status = ns.RecipeBook.GetStatus()
local recipes = ns.RecipeBook.GetRecipes(100)
assert(status.characterCount == 4, "discards malformed persisted characters")
assert(status.recipeCount == 3 and #recipes == 1, "indexes only valid persisted recipes")
assert(recipes[1].outputQuantity == 5, "uses the newest conflicting recipe snapshot")
assert(
  recipes[1].characters[1] == "MalformedTimestamp"
    and recipes[1].characters[2] == "Newer"
    and recipes[1].characters[3] == "Valid",
  "sorts recipe owners"
)
local orderedRecipes = ns.RecipeBook.GetRecipes(600)
assert(orderedRecipes[1].recipeKey == "alpha" and orderedRecipes[2].recipeKey == "zeta", "orders recipes by key")
assert(#ns.RecipeBook.GetRecipes(300) == 0, "discards malformed persisted recipes")

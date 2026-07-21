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
    },
  },
}
ns.RecipeBook.Init()

status = ns.RecipeBook.GetStatus()
local recipes = ns.RecipeBook.GetRecipes(100)
assert(status.characterCount == 2, "discards malformed persisted characters")
assert(status.recipeCount == 1 and #recipes == 1, "indexes only valid persisted recipes")
assert(recipes[1].outputQuantity == 2 and recipes[1].characters[1] == "Valid", "keeps valid recipe data")
assert(#ns.RecipeBook.GetRecipes(300) == 0, "discards malformed persisted recipes")

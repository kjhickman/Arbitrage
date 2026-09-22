local _, ns = ...

ns.RecipeBook = {}

---@class ArbitrageRecipeReagent
---@field itemID number
---@field quantity number
---@field name string?

---@class ArbitrageCraftingRecipe
---@field recipeKey string?
---@field outputQuantity number
---@field reagents ArbitrageRecipeReagent[]

---@class ArbitrageStoredRecipe : ArbitrageCraftingRecipe
---@field recipeKey string
---@field outputItemID number

---@class ArbitrageRecipeSource
---@field characterName string
---@field professionName string
---@field recipeKey string

---@class ArbitrageCraftableOutput
---@field outputItemID number
---@field sources ArbitrageRecipeSource[]

---@class ArbitrageRecipeProfession
---@field recipes table<string, ArbitrageStoredRecipe>
---@field updatedAt number?

---@class ArbitrageRecipeCharacter
---@field professions table<string, ArbitrageRecipeProfession>

---@class ArbitrageRecipeRealm
---@field characters table<string, ArbitrageRecipeCharacter>

local VERSION = 1
---@type table<string, ArbitrageStoredRecipe[]>
local recipesByOutput = {}
---@type table<string, ArbitrageRecipeSource[]>
local sourcesByOutput = {}
local realmKey

local function GetRealm()
  return realmKey or GetRealmName()
end

---@return string?
local function GetCharacterKey()
  return (UnitName("player"))
end

---@return ArbitrageRecipeRealm?
local function GetRecipeRealm()
  if type(ARBITRAGE_RECIPES) ~= "table" then
    return nil
  end

  local realm = rawget(ARBITRAGE_RECIPES, GetRealm())
  if type(realm) ~= "table" then
    return nil
  end

  ---@cast realm ArbitrageRecipeRealm
  return realm
end

local function RebuildIndex()
  recipesByOutput = {}
  sourcesByOutput = {}
  local realm = GetRecipeRealm()

  if realm == nil then
    return
  end

  local latestRecipes = {}
  for characterName, character in pairs(realm.characters) do
    for professionName, profession in pairs(character.professions) do
      for recipeKey, recipe in pairs(profession.recipes) do
        local updatedAt = profession.updatedAt or 0
        local latest = latestRecipes[recipeKey]
        if latest == nil or updatedAt > latest.updatedAt then
          latestRecipes[recipeKey] = { recipe = recipe, updatedAt = updatedAt }
        end

        local outputKey = tostring(recipe.outputItemID)
        sourcesByOutput[outputKey] = sourcesByOutput[outputKey] or {}
        sourcesByOutput[outputKey][#sourcesByOutput[outputKey] + 1] = {
          characterName = characterName,
          professionName = professionName,
          recipeKey = recipeKey,
        }
      end
    end
  end

  for _, latest in pairs(latestRecipes) do
    local recipe = latest.recipe
    local outputKey = tostring(recipe.outputItemID)
    local recipes = recipesByOutput[outputKey]
    if recipes == nil then
      recipes = {}
      recipesByOutput[outputKey] = recipes
    end
    recipes[#recipes + 1] = recipe
  end

  for _, sources in pairs(sourcesByOutput) do
    table.sort(sources, function(left, right)
      if left.characterName ~= right.characterName then
        return left.characterName < right.characterName
      end
      if left.professionName ~= right.professionName then
        return left.professionName < right.professionName
      end
      return left.recipeKey < right.recipeKey
    end)
  end
end

---@return ArbitrageRecipeCharacter?
local function GetCharacter()
  local realm = GetRecipeRealm()
  local characterKey = GetCharacterKey()
  if realm == nil or characterKey == nil then
    return nil
  end

  local character = realm.characters[characterKey]
  if character == nil then
    character = { professions = {} }
    realm.characters[characterKey] = character
  end

  ---@cast character ArbitrageRecipeCharacter
  return character
end

---@param name string
---@param recipes table<string, ArbitrageStoredRecipe>
function ns.RecipeBook.SaveProfession(name, recipes)
  local character = GetCharacter()
  if character == nil then
    return
  end

  character.professions[name] = {
    recipes = recipes,
    updatedAt = time(),
  }
  RebuildIndex()
end

function ns.RecipeBook.Init()
  if type(ARBITRAGE_RECIPES) ~= "table" or ARBITRAGE_RECIPES.__version ~= VERSION then
    ARBITRAGE_RECIPES = { __version = VERSION }
  end

  realmKey = GetRealm()
  local realm = rawget(ARBITRAGE_RECIPES, realmKey)
  if type(realm) ~= "table" or type(realm.characters) ~= "table" then
    realm = { characters = {} }
    ARBITRAGE_RECIPES[realmKey] = realm
  end
  RebuildIndex()
end

---@param itemID number
---@return ArbitrageStoredRecipe[]
function ns.RecipeBook.GetRecipes(itemID)
  return recipesByOutput[tostring(itemID)] or {}
end

---@return ArbitrageCraftableOutput[]
function ns.RecipeBook.GetCraftableOutputs()
  local outputs = {}
  for outputKey in pairs(recipesByOutput) do
    local outputItemID = tonumber(outputKey)
    if outputItemID then
      outputs[#outputs + 1] = {
        outputItemID = outputItemID,
        sources = sourcesByOutput[outputKey] or {},
      }
    end
  end
  return outputs
end

---@return {characterCount: number, recipeCount: number}
function ns.RecipeBook.GetStatus()
  local characterCount = 0
  local recipeCount = 0
  local realm = GetRecipeRealm()

  if realm then
    for _ in pairs(realm.characters) do
      characterCount = characterCount + 1
    end
  end

  for _, recipes in pairs(recipesByOutput) do
    recipeCount = recipeCount + #recipes
  end

  return {
    characterCount = characterCount,
    recipeCount = recipeCount,
  }
end

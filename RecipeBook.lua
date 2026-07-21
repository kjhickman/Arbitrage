local _, ns = ...

ns.RecipeBook = {}

---@class ArbitrageRecipeReagent
---@field itemID number
---@field quantity number
---@field name string?

---@class ArbitrageCraftingRecipe
---@field outputQuantity number
---@field reagents ArbitrageRecipeReagent[]

---@class ArbitrageStoredRecipe : ArbitrageCraftingRecipe
---@field recipeKey string
---@field outputItemID number

---@class ArbitrageKnownRecipe : ArbitrageStoredRecipe
---@field characters string[]

---@class ArbitrageRecipeProfession
---@field recipes table<string, ArbitrageStoredRecipe>
---@field updatedAt number?

---@class ArbitrageRecipeCharacter
---@field professions table<string, ArbitrageRecipeProfession>

---@class ArbitrageRecipeRealm
---@field characters table<string, ArbitrageRecipeCharacter>

local VERSION = 1
---@type table<string, ArbitrageKnownRecipe[]>
local recipesByOutput = {}
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
  if type(realm) ~= "table" or type(realm.characters) ~= "table" then
    return nil
  end

  ---@cast realm ArbitrageRecipeRealm
  return realm
end

---@param value any
---@return boolean
local function IsPositiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

---@param recipe any
---@return boolean
local function IsValidStoredRecipe(recipe)
  if
    type(recipe) ~= "table"
    or type(recipe.recipeKey) ~= "string"
    or not IsPositiveInteger(recipe.outputItemID)
    or not IsPositiveInteger(recipe.outputQuantity)
    or type(recipe.reagents) ~= "table"
  then
    return false
  end

  local reagentCount = 0
  local maximumReagentIndex = 0
  for reagentIndex, reagent in pairs(recipe.reagents) do
    if
      not IsPositiveInteger(reagentIndex)
      or type(reagent) ~= "table"
      or not IsPositiveInteger(reagent.itemID)
      or not IsPositiveInteger(reagent.quantity)
      or (reagent.name ~= nil and type(reagent.name) ~= "string")
    then
      return false
    end
    reagentCount = reagentCount + 1
    maximumReagentIndex = math.max(maximumReagentIndex, reagentIndex)
  end
  if reagentCount == 0 or maximumReagentIndex ~= reagentCount then
    return false
  end
  return true
end

local function RebuildIndex()
  recipesByOutput = {}
  local realm = GetRecipeRealm()

  if realm == nil then
    return
  end

  local latestRecipes = {}
  for characterKey, character in pairs(realm.characters) do
    if type(characterKey) ~= "string" or type(character) ~= "table" or type(character.professions) ~= "table" then
      realm.characters[characterKey] = nil
    else
      for professionName, profession in pairs(character.professions) do
        if type(professionName) ~= "string" or type(profession) ~= "table" or type(profession.recipes) ~= "table" then
          character.professions[professionName] = nil
        else
          for recipeKey, recipe in pairs(profession.recipes) do
            if type(recipeKey) ~= "string" or not IsValidStoredRecipe(recipe) or recipe.recipeKey ~= recipeKey then
              profession.recipes[recipeKey] = nil
            else
              local updatedAt = IsPositiveInteger(profession.updatedAt) and profession.updatedAt or 0
              local source = characterKey .. "\0" .. professionName
              local latest = latestRecipes[recipeKey]
              if latest == nil then
                latest = { characters = {}, characterSet = {} }
                latestRecipes[recipeKey] = latest
              end
              if not latest.characterSet[characterKey] then
                latest.characterSet[characterKey] = true
                latest.characters[#latest.characters + 1] = characterKey
              end
              if
                latest.recipe == nil
                or updatedAt > latest.updatedAt
                or (updatedAt == latest.updatedAt and source < latest.source)
              then
                latest.recipe = recipe
                latest.updatedAt = updatedAt
                latest.source = source
              end
            end
          end
        end
      end
    end
  end

  for recipeKey, latest in pairs(latestRecipes) do
    local recipe = latest.recipe
    table.sort(latest.characters)
    local outputKey = tostring(recipe.outputItemID)
    local recipes = recipesByOutput[outputKey]
    if recipes == nil then
      recipes = {}
      recipesByOutput[outputKey] = recipes
    end
    recipes[#recipes + 1] = {
      recipeKey = recipeKey,
      outputItemID = recipe.outputItemID,
      outputQuantity = recipe.outputQuantity,
      reagents = recipe.reagents,
      characters = latest.characters,
    }
  end
  for _, recipes in pairs(recipesByOutput) do
    table.sort(recipes, function(left, right)
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
  if type(character) ~= "table" then
    character = { professions = {} }
    realm.characters[characterKey] = character
  elseif type(character.professions) ~= "table" then
    character.professions = {}
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
  if type(realm) ~= "table" then
    realm = {}
    ARBITRAGE_RECIPES[realmKey] = realm
  end
  if type(realm.characters) ~= "table" then
    realm.characters = {}
  end
  RebuildIndex()
end

---@param itemID number
---@return ArbitrageKnownRecipe[]
function ns.RecipeBook.GetRecipes(itemID)
  return recipesByOutput[tostring(itemID)] or {}
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

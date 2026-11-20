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

---@class ArbitrageRecipeSkillUp
---@field points number per craft at the last profession capture
---@field guaranteed boolean
---@field lowChance true? nil for guaranteed or other chances

---@class ArbitrageStoredRecipe : ArbitrageCraftingRecipe
---@field recipeKey string
---@field outputItemID number
---@field skillUp ArbitrageRecipeSkillUp?

---@class ArbitrageRecipeSource
---@field characterName string
---@field professionName string
---@field recipeKey string
---@field skillUp ArbitrageRecipeSkillUp?

---@class ArbitrageCraftableOutput
---@field outputItemID number
---@field sources ArbitrageRecipeSource[]

---@class ArbitrageRecipeProfession
---@field recipes table<string, ArbitrageStoredRecipe>
---@field unlearned table<number, number>? recipe ID to the item it makes; nil in snapshots saved before it was tracked
---@field updatedAt number?
---@field unsupportedCount number? nil in snapshots saved before it was tracked

---@class ArbitrageRecipeCharacter
---@field professions table<string, ArbitrageRecipeProfession>

---@class ArbitrageRecipeRealm
---@field characters table<string, ArbitrageRecipeCharacter>

local VERSION = 1
---@type table<string, ArbitrageStoredRecipe[]>
local recipesByOutput = {}
---@type table<string, ArbitrageRecipeSource[]>
local sourcesByOutput = {}
-- Learned or not, so a recipe item can be priced by the item it teaches to make.
---@type table<string, table<number, true>>
local recipeIDsByOutput = {}
local realmKey

local function GetRealm()
  return realmKey or ns.Realm.GetName()
end

---@return string?
local function GetCharacterKey()
  return ns.Realm.GetCharacterName()
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

---@param outputItemID number
---@param recipeID number?
local function AddRecipeID(outputItemID, recipeID)
  if recipeID == nil then
    return
  end
  local outputKey = tostring(outputItemID)
  recipeIDsByOutput[outputKey] = recipeIDsByOutput[outputKey] or {}
  recipeIDsByOutput[outputKey][recipeID] = true
end

local function RebuildIndex()
  recipesByOutput = {}
  sourcesByOutput = {}
  recipeIDsByOutput = {}
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
          skillUp = recipe.skillUp,
        }
        AddRecipeID(recipe.outputItemID, ns.RecipeParser.GetRecipeID(recipeKey))
      end
      for recipeID, outputItemID in pairs(profession.unlearned or {}) do
        AddRecipeID(outputItemID, recipeID)
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
---@param unsupportedCount number
---@param unlearned table<number, number>? recipe ID to the item it makes
---@return ArbitrageRecipeProfession? previous the snapshot this replaced
function ns.RecipeBook.SaveProfession(name, recipes, unsupportedCount, unlearned)
  local character = GetCharacter()
  if character == nil then
    return nil
  end

  local previous = character.professions[name]
  character.professions[name] = {
    recipes = recipes,
    unlearned = unlearned,
    updatedAt = time(),
    unsupportedCount = unsupportedCount,
  }
  RebuildIndex()
  return previous
end

---@param activeProfessions table<string, boolean>
---@return boolean
function ns.RecipeBook.PruneProfessions(activeProfessions)
  local realm = GetRecipeRealm()
  local characterKey = GetCharacterKey()
  if realm == nil or characterKey == nil then
    return false
  end

  local character = realm.characters[characterKey]
  if type(character) ~= "table" or type(character.professions) ~= "table" then
    return false
  end

  local removed = false
  for professionName in pairs(character.professions) do
    if not activeProfessions[professionName] then
      character.professions[professionName] = nil
      removed = true
    end
  end

  if next(character.professions) == nil then
    realm.characters[characterKey] = nil
  end

  if removed then
    RebuildIndex()
  end
  return removed
end

---@param targetName string
---@return string?
function ns.RecipeBook.ForgetCharacter(targetName)
  local realm = GetRecipeRealm()
  if realm == nil or type(targetName) ~= "string" or targetName == "" then
    return nil
  end

  local matchedKey
  if realm.characters[targetName] ~= nil then
    matchedKey = targetName
  else
    local loweredTarget = strlower(targetName)
    for characterName in pairs(realm.characters) do
      if type(characterName) == "string" and strlower(characterName) == loweredTarget then
        if matchedKey == nil or characterName < matchedKey then
          matchedKey = characterName
        end
      end
    end
  end

  if matchedKey == nil then
    return nil
  end

  realm.characters[matchedKey] = nil
  RebuildIndex()
  return matchedKey
end

---@return string[]
function ns.RecipeBook.GetCharacterNames()
  local names = {}
  local realm = GetRecipeRealm()
  if realm then
    for characterName, character in pairs(realm.characters) do
      if type(characterName) == "string" and type(character) == "table" and type(character.professions) == "table" then
        if next(character.professions) ~= nil then
          names[#names + 1] = characterName
        end
      end
    end
  end
  table.sort(names)
  return names
end

---@return string[]
function ns.RecipeBook.GetProfessionNames()
  local seen = {}
  local names = {}
  local realm = GetRecipeRealm()
  if realm then
    for _, character in pairs(realm.characters) do
      for professionName in pairs(character.professions) do
        if not seen[professionName] then
          seen[professionName] = true
          names[#names + 1] = professionName
        end
      end
    end
  end
  table.sort(names)
  return names
end

function ns.RecipeBook.Init()
  if type(ARBITRAGE_RECIPES) ~= "table" or ARBITRAGE_RECIPES.__version ~= VERSION then
    ARBITRAGE_RECIPES = { __version = VERSION }
  end

  realmKey = ns.Realm.GetName()
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

-- Every recipe a character on this realm has seen in a profession window that makes the item,
-- including ones nobody has learned.
---@param itemID number
---@return number[]
function ns.RecipeBook.GetRecipeIDs(itemID)
  local recipeIDs = {}
  for recipeID in pairs(recipeIDsByOutput[tostring(itemID)] or {}) do
    recipeIDs[#recipeIDs + 1] = recipeID
  end
  table.sort(recipeIDs)
  return recipeIDs
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

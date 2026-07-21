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
local scanning = false
local realmKey

local function GetRealm()
  return realmKey or GetRealmName()
end

---@return string?
local function GetCharacterKey()
  return (UnitName("player"))
end

---@param itemLink string?
local function GetItemID(itemLink)
  return itemLink and tonumber(itemLink:match("item:(%d+)"))
end

---@param outputItemID number
---@param outputQuantity number
---@param reagents ArbitrageRecipeReagent[]
---@param recipeLink string?
---@return string
local function GetRecipeKey(outputItemID, outputQuantity, reagents, recipeLink)
  local recipeID = recipeLink and (recipeLink:match("Hspell:(%d+)") or recipeLink:match("Hitem:(%d+)"))
  if recipeID then
    return "recipe:" .. recipeID
  end

  local parts = { tostring(outputItemID), tostring(outputQuantity) }
  for _, reagent in ipairs(reagents) do
    parts[#parts + 1] = reagent.itemID .. "x" .. reagent.quantity
  end
  return table.concat(parts, ":")
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
  for reagentIndex = 1, reagentCount do
    if recipe.reagents[reagentIndex] == nil then
      return false
    end
  end
  return true
end

---@param characterKey string
---@param recipeKey string
---@param recipe ArbitrageStoredRecipe
local function AddToIndex(characterKey, recipeKey, recipe)
  local outputKey = tostring(recipe.outputItemID)
  local recipes = recipesByOutput[outputKey]
  if recipes == nil then
    recipes = {}
    recipesByOutput[outputKey] = recipes
  end

  for _, candidate in ipairs(recipes) do
    if candidate.recipeKey == recipeKey then
      candidate.characters[#candidate.characters + 1] = characterKey
      return
    end
  end

  recipes[#recipes + 1] = {
    recipeKey = recipeKey,
    outputItemID = recipe.outputItemID,
    outputQuantity = recipe.outputQuantity,
    reagents = recipe.reagents,
    characters = { characterKey },
  }
end

local function RebuildIndex()
  recipesByOutput = {}
  local realm = GetRecipeRealm()

  if realm == nil then
    return
  end

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
              AddToIndex(characterKey, recipeKey, recipe)
            end
          end
        end
      end
    end
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
local function SaveProfession(name, recipes)
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

---@param outputLink string?
---@param outputQuantity number?
---@param reagentCount number
---@param getReagent fun(reagentIndex: number): string?, number?, string?
---@param recipeLink string?
---@return (ArbitrageStoredRecipe recipe) | (nil, "skip"|"incomplete" state)
local function CaptureRecipe(outputLink, outputQuantity, reagentCount, getReagent, recipeLink)
  if outputLink and outputLink:match("enchant:") then
    return nil, "skip"
  end

  local outputItemID = GetItemID(outputLink)
  if outputItemID == nil then
    return nil, "incomplete"
  end

  if outputQuantity == nil or outputQuantity <= 0 or reagentCount <= 0 then
    return nil, "skip"
  end

  ---@type ArbitrageRecipeReagent[]
  local reagents = {}
  for reagentIndex = 1, reagentCount do
    local reagentLink, quantity, name = getReagent(reagentIndex)
    local reagentItemID = GetItemID(reagentLink)
    if reagentItemID == nil or quantity == nil or quantity <= 0 then
      return nil, "incomplete"
    end

    reagents[#reagents + 1] = {
      itemID = reagentItemID,
      quantity = quantity,
      name = name,
    }
  end

  local recipeKey = GetRecipeKey(outputItemID, outputQuantity, reagents, recipeLink)
  return {
    recipeKey = recipeKey,
    outputItemID = outputItemID,
    outputQuantity = outputQuantity,
    reagents = reagents,
  }
end

local function SaveTradeSkillFilters()
  local subclassFilters = {}
  for index = 0, #{ GetTradeSkillSubClasses() } do
    subclassFilters[index] = GetTradeSkillSubClassFilter(index) == 1
  end

  local invSlotFilters = {}
  for index = 0, #{ GetTradeSkillInvSlots() } do
    invSlotFilters[index] = GetTradeSkillInvSlotFilter(index) == 1
  end

  local minimumItemLevel, maximumItemLevel = GetTradeSkillItemLevelFilter()
  return subclassFilters,
    invSlotFilters,
    {
      onlyMakeable = GetOnlyShowMakeable(),
      onlySkillUps = GetOnlyShowSkillUps(),
      itemName = GetTradeSkillItemNameFilter(),
      minimumItemLevel = minimumItemLevel,
      maximumItemLevel = maximumItemLevel,
    }
end

local function ClearTradeSkillFilters()
  TradeSkillOnlyShowMakeable(false)
  TradeSkillOnlyShowSkillUps(false)
  SetTradeSkillItemNameFilter("")
  SetTradeSkillItemLevelFilter(0, 0)
  SetTradeSkillSubClassFilter(0, 1, 1)
  SetTradeSkillInvSlotFilter(0, 1, 1)
end

local function TryCleanup(callback, ...)
  local args = { ... }
  return xpcall(function()
    callback(unpack(args))
  end, geterrorhandler())
end

local function RestoreTradeSkillFilters(subclassFilters, invSlotFilters, filters)
  local succeeded = true
  if subclassFilters[0] then
    if not TryCleanup(SetTradeSkillSubClassFilter, 0, 1, 1) then
      succeeded = false
    end
  else
    for index, enabled in pairs(subclassFilters) do
      if index > 0 and not TryCleanup(SetTradeSkillSubClassFilter, index, enabled and 1 or 0, 0) then
        succeeded = false
      end
    end
  end

  if invSlotFilters[0] then
    if not TryCleanup(SetTradeSkillInvSlotFilter, 0, 1, 1) then
      succeeded = false
    end
  else
    for index, enabled in pairs(invSlotFilters) do
      if index > 0 and not TryCleanup(SetTradeSkillInvSlotFilter, index, enabled and 1 or 0, 0) then
        succeeded = false
      end
    end
  end

  if not TryCleanup(TradeSkillOnlyShowMakeable, filters.onlyMakeable) then
    succeeded = false
  end
  if not TryCleanup(TradeSkillOnlyShowSkillUps, filters.onlySkillUps) then
    succeeded = false
  end
  if not TryCleanup(SetTradeSkillItemNameFilter, filters.itemName or "") then
    succeeded = false
  end
  if not TryCleanup(SetTradeSkillItemLevelFilter, filters.minimumItemLevel or 0, filters.maximumItemLevel or 0) then
    succeeded = false
  end
  return succeeded
end

---@param count fun(): number
---@param getInfo fun(index: number): string?, boolean?
---@param expand fun(index: number)
---@param expanded number[]
local function ExpandCollapsedHeaders(count, getInfo, expand, expanded)
  while true do
    local collapsedIndex
    for index = count(), 1, -1 do
      local skillType, isExpanded = getInfo(index)
      if (skillType == "header" or skillType == "subheader") and not isExpanded then
        collapsedIndex = index
        break
      end
    end

    if collapsedIndex == nil then
      return expanded
    end

    expanded[#expanded + 1] = collapsedIndex
    expand(collapsedIndex)
  end
end

local function RestoreHeaders(expanded, collapse)
  local succeeded = true
  for index = #expanded, 1, -1 do
    if not TryCleanup(collapse, expanded[index]) then
      succeeded = false
    end
  end
  return succeeded
end

---@param capture function
---@param ... function
---@return boolean
local function RunCapture(capture, ...)
  scanning = true
  local errorHandler = geterrorhandler()
  local succeeded = xpcall(capture, errorHandler)
  for cleanupIndex = 1, select("#", ...) do
    local cleanupCompleted, cleanupSucceeded = xpcall(select(cleanupIndex, ...), errorHandler)
    if not cleanupCompleted or cleanupSucceeded == false then
      succeeded = false
    end
  end
  scanning = false
  return succeeded
end

local function CaptureTradeSkill()
  if scanning or (IsTradeSkillLinked and IsTradeSkillLinked()) or GetNumTradeSkills() == 0 then
    return
  end

  local subclassFilters, invSlotFilters, filters
  local expandedHeaders = {}
  ---@type table<string, ArbitrageStoredRecipe>
  local recipes = {}
  local complete = true
  local succeeded = RunCapture(function()
    subclassFilters, invSlotFilters, filters = SaveTradeSkillFilters()
    ClearTradeSkillFilters()
    ExpandCollapsedHeaders(GetNumTradeSkills, function(index)
      local _, skillType, _, isExpanded = GetTradeSkillInfo(index)
      return skillType, isExpanded
    end, ExpandTradeSkillSubClass, expandedHeaders)

    for index = 1, GetNumTradeSkills() do
      local _, skillType, _, _, serviceType = GetTradeSkillInfo(index)
      if skillType ~= "header" and skillType ~= "subheader" and serviceType == nil then
        local recipe, state = CaptureRecipe(
          GetTradeSkillItemLink(index),
          GetTradeSkillNumMade(index),
          GetTradeSkillNumReagents(index),
          function(reagentIndex)
            local name, _, quantity = GetTradeSkillReagentInfo(index, reagentIndex)
            return GetTradeSkillReagentItemLink(index, reagentIndex), quantity, name
          end,
          GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index)
        )

        if recipe then
          recipes[recipe.recipeKey] = recipe
        elseif state == "incomplete" then
          complete = false
        end
      end
    end
  end, function()
    return RestoreHeaders(expandedHeaders, CollapseTradeSkillSubClass)
  end, function()
    if filters then
      return RestoreTradeSkillFilters(subclassFilters, invSlotFilters, filters)
    end
    return true
  end)
  if not succeeded then
    return
  end

  local professionName = GetTradeSkillLine()
  if complete and professionName and professionName ~= UNKNOWN then
    SaveProfession(professionName, recipes)
  end
end

local function CaptureCraft()
  if scanning or GetNumCrafts() == 0 then
    return
  end

  local expandedHeaders = {}
  ---@type table<string, ArbitrageStoredRecipe>
  local recipes = {}
  local complete = true
  local succeeded = RunCapture(function()
    ExpandCollapsedHeaders(GetNumCrafts, function(index)
      local _, _, craftType, _, isExpanded = GetCraftInfo(index)
      return craftType, isExpanded
    end, ExpandCraftSkillLine, expandedHeaders)

    for index = 1, GetNumCrafts() do
      local _, _, craftType = GetCraftInfo(index)
      if craftType ~= "header" then
        local recipe, state = CaptureRecipe(
          GetCraftItemLink(index),
          GetCraftNumMade(index),
          GetCraftNumReagents(index),
          function(reagentIndex)
            local name, _, quantity = GetCraftReagentInfo(index, reagentIndex)
            return GetCraftReagentItemLink(index, reagentIndex), quantity, name
          end,
          GetCraftRecipeLink and GetCraftRecipeLink(index)
        )

        if recipe then
          recipes[recipe.recipeKey] = recipe
        elseif state == "incomplete" then
          complete = false
        end
      end
    end
  end, function()
    return RestoreHeaders(expandedHeaders, CollapseCraftSkillLine)
  end)
  if not succeeded then
    return
  end

  local professionName = GetCraftName()
  if complete and professionName and professionName ~= UNKNOWN then
    SaveProfession(professionName, recipes)
  end
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

function ns.RecipeBook.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("TRADE_SKILL_SHOW")
  frame:RegisterEvent("TRADE_SKILL_UPDATE")
  frame:RegisterEvent("CRAFT_SHOW")
  frame:RegisterEvent("CRAFT_UPDATE")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "TRADE_SKILL_SHOW" or eventName == "TRADE_SKILL_UPDATE" then
      CaptureTradeSkill()
    else
      CaptureCraft()
    end
  end)
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

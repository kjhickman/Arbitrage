local _, ns = ...

ns.RecipeCapture = {}

local MAX_LISTED_RECIPES = 5

local scanning = false
local incompleteWarnings = {}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

---@param value any
---@return boolean
local function IsPositiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

---@return string? professionName, table<string, ArbitrageStoredRecipe>? recipes, boolean complete, number unsupportedCount, table<string, ArbitrageStoredRecipe>? unlearnedRecipes
local function BuildProfessionSnapshot()
  local professionInfo = C_TradeSkillUI.GetBaseProfessionInfo()
  if
    type(professionInfo) ~= "table"
    or not IsPositiveInteger(professionInfo.professionID)
    or type(professionInfo.professionName) ~= "string"
    or professionInfo.professionName == ""
  then
    return nil, nil, false, 0
  end
  local allRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
  if type(allRecipeIDs) ~= "table" or #allRecipeIDs == 0 then
    return professionInfo.professionName, nil, false, 0
  end

  local seenRecipeIDs = {}
  ---@type table<string, ArbitrageStoredRecipe>
  local recipes = {}
  ---@type table<string, ArbitrageStoredRecipe>
  local unlearnedRecipes = {}
  local complete = true
  local unsupportedCount = 0
  for _, recipeID in ipairs(allRecipeIDs) do
    if IsPositiveInteger(recipeID) and not seenRecipeIDs[recipeID] then
      seenRecipeIDs[recipeID] = true
      local capturedRecipes, state = ns.RecipeParser.Capture(recipeID)
      if capturedRecipes then
        for _, recipe in ipairs(capturedRecipes) do
          recipes[recipe.recipeKey] = recipe
        end
      elseif state == "incomplete" then
        complete = false
      elseif state == "skip" then
        unsupportedCount = unsupportedCount + 1
      elseif not C_TradeSkillUI.GetRecipeInfo(recipeID).learned then
        -- Kept whole to price the crafts characters could learn, and the recipe items that teach
        -- them, whose tooltips name only the item they make.
        for _, recipe in ipairs(ns.RecipeParser.Preview(recipeID) or {}) do
          unlearnedRecipes[recipe.recipeKey] = recipe
        end
      end
    end
  end

  if next(seenRecipeIDs) == nil then
    return professionInfo.professionName, nil, false, 0
  end

  return professionInfo.professionName, recipes, complete, unsupportedCount, unlearnedRecipes
end

-- Recipes with alternative reagents are stored once per reagent choice, so the player's
-- recipes are counted by the recipe ID inside each stored key.
---@param recipes table<string, ArbitrageStoredRecipe>
---@return table<number, true>
local function GetRecipeIDs(recipes)
  local recipeIDs = {}
  for recipeKey in pairs(recipes) do
    local recipeID = ns.RecipeParser.GetRecipeID(recipeKey)
    if recipeID then
      recipeIDs[recipeID] = true
    end
  end
  return recipeIDs
end

---@param count number
---@param professionName string
---@return string
local function FormatRecipeCount(count, professionName)
  return count .. " " .. professionName .. (count == 1 and " recipe" or " recipes")
end

---@param characterName string
---@param professionName string
---@param previousRecipes table<string, ArbitrageStoredRecipe>?
---@param recipes table<string, ArbitrageStoredRecipe>
local function ReportNewRecipes(characterName, professionName, previousRecipes, recipes)
  local knownRecipeIDs = previousRecipes and GetRecipeIDs(previousRecipes) or {}
  local newRecipeIDs = {}
  for recipeID in pairs(GetRecipeIDs(recipes)) do
    if not knownRecipeIDs[recipeID] then
      newRecipeIDs[#newRecipeIDs + 1] = recipeID
    end
  end

  if #newRecipeIDs == 0 then
    return
  end
  if previousRecipes == nil then
    Print("Recorded " .. FormatRecipeCount(#newRecipeIDs, professionName) .. " for " .. characterName)
    return
  end

  local names = {}
  for _, recipeID in ipairs(newRecipeIDs) do
    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
    names[#names + 1] = recipeInfo and recipeInfo.name or UNKNOWN
  end
  table.sort(names)
  if #names == 1 then
    Print(characterName .. " learned " .. names[1])
    return
  end

  local list = table.concat(names, ", ", 1, math.min(#names, MAX_LISTED_RECIPES))
  if #names > MAX_LISTED_RECIPES then
    list = list .. " and " .. (#names - MAX_LISTED_RECIPES) .. " more"
  end
  Print(characterName .. " learned " .. FormatRecipeCount(#names, professionName) .. ": " .. list)
end

local function CaptureProfession()
  local characterName = ns.Realm.GetCharacterName()
  if
    scanning
    or characterName == nil
    or C_TradeSkillUI.IsDataSourceChanging()
    or C_TradeSkillUI.IsNPCCrafting()
    or C_TradeSkillUI.IsRuneforging()
    or C_TradeSkillUI.IsTradeSkillLinked()
    or C_TradeSkillUI.IsTradeSkillGuild()
  then
    return
  end

  local professionName
  local recipes
  local complete
  local unsupportedCount
  local unlearnedRecipes
  scanning = true
  local succeeded = xpcall(function()
    professionName, recipes, complete, unsupportedCount, unlearnedRecipes = BuildProfessionSnapshot()
  end, geterrorhandler())
  scanning = false

  if not succeeded or professionName == nil then
    return
  end

  if not complete or recipes == nil then
    if not incompleteWarnings[professionName] then
      incompleteWarnings[professionName] = true
      Print(professionName .. " recipe data was incomplete; keeping the previous snapshot")
    end
    return
  end

  incompleteWarnings[professionName] = nil
  unsupportedCount = unsupportedCount or 0
  local previous = ns.RecipeBook.SaveProfession(professionName, recipes, unsupportedCount, unlearnedRecipes)
  ns.OpportunityPanel.Refresh()
  ns.CraftingWindow.Refresh()
  ns.DatabaseIndex.Invalidate()

  ReportNewRecipes(characterName, professionName, previous and previous.recipes, recipes)

  -- Only a rise is news: the player can't act on the same skipped recipes again every session.
  if unsupportedCount > (previous and previous.unsupportedCount or 0) then
    local recipeLabel = unsupportedCount == 1 and "recipe" or "recipes"
    Print(professionName .. " skipped " .. unsupportedCount .. " unsupported " .. recipeLabel)
  end
end

---@return number, table<number, any>
local function PackSlots(...)
  return select("#", ...), { ... }
end

---@return table<string, boolean>?
local function CollectActiveProfessions()
  local active = {}
  local count, slots = PackSlots(GetProfessions())
  for slot = 1, count do
    local skillIndex = slots[slot]
    if skillIndex ~= nil then
      if not IsPositiveInteger(skillIndex) then
        return nil
      end
      local name, _, _, _, _, _, skillLine = GetProfessionInfo(skillIndex)
      if type(name) ~= "string" or name == "" then
        return nil
      end
      active[name] = true

      if IsPositiveInteger(skillLine) then
        ---@cast skillLine number
        local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)
        if type(info) == "table" then
          if type(info.professionName) == "string" and info.professionName ~= "" then
            active[info.professionName] = true
          end
          if type(info.parentProfessionName) == "string" and info.parentProfessionName ~= "" then
            active[info.parentProfessionName] = true
          end
        end
      end
    end
  end
  return active
end

local function PruneLearnedProfessions()
  local active = CollectActiveProfessions()
  if active == nil then
    return
  end

  for professionName in pairs(incompleteWarnings) do
    if not active[professionName] then
      incompleteWarnings[professionName] = nil
    end
  end

  if ns.RecipeBook.PruneProfessions(active) then
    ns.OpportunityPanel.Refresh()
    ns.CraftingWindow.Refresh()
    ns.DatabaseIndex.Invalidate()
  end
end

function ns.RecipeCapture.Register()
  local enteredWorld = false
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  frame:RegisterEvent("SKILL_LINES_CHANGED")
  frame:RegisterEvent("TRADE_SKILL_SHOW")
  frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  frame:SetScript("OnEvent", function(_, eventName)
    if eventName == "PLAYER_ENTERING_WORLD" then
      enteredWorld = true
      PruneLearnedProfessions()
    elseif eventName == "SKILL_LINES_CHANGED" then
      if enteredWorld then
        PruneLearnedProfessions()
      end
    else
      CaptureProfession()
    end
  end)
end

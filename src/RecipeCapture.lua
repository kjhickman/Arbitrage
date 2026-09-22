local _, ns = ...

ns.RecipeCapture = {}

local scanning = false
local incompleteWarnings = {}
local unsupportedWarnings = {}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

---@param value any
---@return boolean
local function IsPositiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

---@return string? professionName, table<string, ArbitrageStoredRecipe>? recipes, boolean complete, number unsupportedCount
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
      end
    end
  end

  if next(seenRecipeIDs) == nil then
    return professionInfo.professionName, nil, false, 0
  end

  return professionInfo.professionName, recipes, complete, unsupportedCount
end

local function CaptureProfession()
  if
    scanning
    or C_TradeSkillUI.IsDataSourceChanging()
    or C_TradeSkillUI.IsNPCCrafting()
    or C_TradeSkillUI.IsRuneforging()
  then
    return
  end

  local professionName
  local recipes
  local complete
  local unsupportedCount
  scanning = true
  local succeeded = xpcall(function()
    professionName, recipes, complete, unsupportedCount = BuildProfessionSnapshot()
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
  ns.RecipeBook.SaveProfession(professionName, recipes)

  unsupportedCount = unsupportedCount or 0
  if unsupportedCount > 0 and not unsupportedWarnings[professionName] then
    unsupportedWarnings[professionName] = true
    local recipeLabel = unsupportedCount == 1 and "recipe" or "recipes"
    Print(professionName .. " skipped " .. unsupportedCount .. " unsupported " .. recipeLabel)
  elseif unsupportedCount == 0 then
    unsupportedWarnings[professionName] = nil
  end
end

function ns.RecipeCapture.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("TRADE_SKILL_SHOW")
  frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  frame:SetScript("OnEvent", CaptureProfession)
end

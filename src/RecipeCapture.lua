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
    or C_TradeSkillUI.IsTradeSkillLinked()
    or C_TradeSkillUI.IsTradeSkillGuild()
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
  ns.AuctionHouse.Refresh()
  ns.CraftingWindow.Refresh()

  unsupportedCount = unsupportedCount or 0
  if unsupportedCount > 0 and not unsupportedWarnings[professionName] then
    unsupportedWarnings[professionName] = true
    local recipeLabel = unsupportedCount == 1 and "recipe" or "recipes"
    Print(professionName .. " skipped " .. unsupportedCount .. " unsupported " .. recipeLabel)
  elseif unsupportedCount == 0 then
    unsupportedWarnings[professionName] = nil
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
  for professionName in pairs(unsupportedWarnings) do
    if not active[professionName] then
      unsupportedWarnings[professionName] = nil
    end
  end

  if ns.RecipeBook.PruneProfessions(active) then
    ns.AuctionHouse.Refresh()
    ns.CraftingWindow.Refresh()
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

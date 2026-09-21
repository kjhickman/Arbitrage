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

---@param reagentSlot CraftingReagentSlotSchematic
---@param reagent CraftingReagent
---@return number?
local function GetReagentQuantity(reagentSlot, reagent)
  for _, variableQuantity in ipairs(reagentSlot.variableQuantities) do
    local variableReagent = variableQuantity.reagent
    if
      type(variableReagent) == "table"
      and variableReagent.itemID == reagent.itemID
      and variableReagent.currencyID == reagent.currencyID
    then
      return variableQuantity.quantity
    end
  end

  return reagentSlot.quantityRequired
end

---@param outputItemID number
---@param recipeID number
---@param reagents ArbitrageRecipeReagent[]
---@return string
local function GetRecipeKey(outputItemID, recipeID, reagents)
  local parts = { "recipe", tostring(recipeID), tostring(outputItemID) }
  for _, reagent in ipairs(reagents) do
    parts[#parts + 1] = reagent.itemID .. "x" .. reagent.quantity
  end
  return table.concat(parts, ":")
end

---@param reagentChoices ArbitrageRecipeReagent[][]
---@return ArbitrageRecipeReagent[][]
local function ExpandReagentChoices(reagentChoices)
  local variants = { {} }

  for _, choices in ipairs(reagentChoices) do
    local nextVariants = {}
    for _, variant in ipairs(variants) do
      for _, choice in ipairs(choices) do
        local nextVariant = {}
        for _, reagent in ipairs(variant) do
          nextVariant[#nextVariant + 1] = reagent
        end
        nextVariant[#nextVariant + 1] = choice
        nextVariants[#nextVariants + 1] = nextVariant
      end
    end
    variants = nextVariants
  end

  return variants
end

---@param reagents ArbitrageRecipeReagent[]
---@return ArbitrageRecipeReagent[]
local function NormalizeReagents(reagents)
  local byItemID = {}
  for _, reagent in ipairs(reagents) do
    local stored = byItemID[reagent.itemID]
    if stored then
      stored.quantity = stored.quantity + reagent.quantity
    else
      byItemID[reagent.itemID] = {
        itemID = reagent.itemID,
        quantity = reagent.quantity,
        name = reagent.name,
      }
    end
  end

  local normalized = {}
  for _, reagent in pairs(byItemID) do
    normalized[#normalized + 1] = reagent
  end
  table.sort(normalized, function(left, right)
    return left.itemID < right.itemID
  end)
  return normalized
end

---@param recipeID number
---@param recipeInfo TradeSkillRecipeInfo
---@param schematic CraftingRecipeSchematic
---@return number?, "skip"|"incomplete"?
local function GetOutputItemID(recipeID, recipeInfo, schematic)
  ---@type table<number, boolean>
  local outputIDs = {}
  local outputCount = 0

  local function AddOutput(itemID)
    if IsPositiveInteger(itemID) then
      ---@cast itemID number
      if outputIDs[itemID] then
        return
      end
      outputIDs[itemID] = true
      outputCount = outputCount + 1
    end
  end

  local outputInfo = C_TradeSkillUI.GetRecipeOutputItemData(recipeID)
  if type(outputInfo) ~= "table" then
    return nil, "incomplete"
  end
  AddOutput(outputInfo.itemID)
  AddOutput(schematic.outputItemID)

  local qualityItemIDs = C_TradeSkillUI.GetRecipeQualityItemIDs(recipeID) or recipeInfo.qualityItemIDs
  if type(qualityItemIDs) == "table" then
    for _, itemID in ipairs(qualityItemIDs) do
      AddOutput(itemID)
    end
  end

  if outputCount > 1 then
    return nil, "skip"
  end
  if outputCount == 0 then
    if
      recipeInfo.isEnchantingRecipe
      or recipeInfo.isGatheringRecipe
      or recipeInfo.isSalvageRecipe
      or schematic.recipeType ~= Enum.TradeskillRecipeType.Item
    then
      return nil, "skip"
    end
    return nil, "incomplete"
  end

  local outputItemID = next(outputIDs)
  return outputItemID
end

---@param recipeID number
---@return ArbitrageStoredRecipe[]?, "ignore"|"skip"|"incomplete"?
local function CaptureRecipe(recipeID)
  local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
  if type(recipeInfo) ~= "table" then
    return nil, "incomplete"
  end
  if not recipeInfo.learned then
    return nil, "ignore"
  end
  if recipeInfo.isDummyRecipe or recipeInfo.isGatheringRecipe or recipeInfo.isSalvageRecipe or recipeInfo.isRecraft then
    return nil, "skip"
  end

  local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
  if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
    return nil, "incomplete"
  end

  local outputItemID, outputState = GetOutputItemID(recipeID, recipeInfo, schematic)
  if outputItemID == nil then
    return nil, outputState
  end

  if
    not IsPositiveInteger(schematic.quantityMin)
    or not IsPositiveInteger(schematic.quantityMax)
    or schematic.quantityMin > schematic.quantityMax
  then
    return nil, "incomplete"
  end
  local outputQuantity = schematic.quantityMin

  ---@type ArbitrageRecipeReagent[][]
  local reagentChoices = {}
  for _, reagentSlot in ipairs(schematic.reagentSlotSchematics) do
    if reagentSlot.required then
      if type(reagentSlot.reagents) ~= "table" or type(reagentSlot.variableQuantities) ~= "table" then
        return nil, "incomplete"
      end

      ---@type ArbitrageRecipeReagent[]
      local choices = {}
      local seenChoices = {}
      for _, reagent in ipairs(reagentSlot.reagents) do
        if type(reagent) ~= "table" then
          return nil, "incomplete"
        end
        local itemID = reagent.itemID
        if IsPositiveInteger(itemID) then
          ---@cast itemID number
          local quantity = GetReagentQuantity(reagentSlot, reagent)
          if not IsPositiveInteger(quantity) then
            return nil, "incomplete"
          end
          ---@cast quantity number

          local choiceKey = tostring(itemID) .. ":" .. tostring(quantity)
          if not seenChoices[choiceKey] then
            seenChoices[choiceKey] = true
            choices[#choices + 1] = {
              itemID = itemID,
              quantity = quantity,
              name = C_Item.GetItemInfo(itemID),
            }
          end
        end
      end

      if #choices == 0 then
        return nil, "skip"
      end
      reagentChoices[#reagentChoices + 1] = choices
    end
  end

  if #reagentChoices == 0 then
    return nil, "skip"
  end

  local recipes = {}
  for _, variant in ipairs(ExpandReagentChoices(reagentChoices)) do
    local reagents = NormalizeReagents(variant)
    recipes[#recipes + 1] = {
      recipeKey = GetRecipeKey(outputItemID, recipeID, reagents),
      outputItemID = outputItemID,
      outputQuantity = outputQuantity,
      reagents = reagents,
    }
  end
  return recipes
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
      local capturedRecipes, state = CaptureRecipe(recipeID)
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

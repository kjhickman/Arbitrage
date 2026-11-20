local _, ns = ...

ns.RecipeParser = {}

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

---@param recipeKey string
---@return number?
function ns.RecipeParser.GetRecipeID(recipeKey)
  return tonumber(recipeKey:match("^recipe:(%d+):"))
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
---@param preview boolean?
---@return number?, "ignore"|"skip"|"incomplete"?
local function GetOutputItemID(recipeID, recipeInfo, schematic, preview)
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
  if type(outputInfo) == "table" then
    AddOutput(outputInfo.itemID)
  elseif not preview then
    return nil, "incomplete"
  end
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
      return nil, "ignore"
    end
    return nil, "incomplete"
  end

  local outputItemID = next(outputIDs)
  return outputItemID
end

-- "ignore" means there is nothing to record: the recipe is unlearned or intentionally makes no item.
-- "skip" means it makes an item in a form that can't be recorded, such as several possible outputs or no usable reagents.
---@param recipeID number
---@param preview boolean?
---@return ArbitrageStoredRecipe[]?, "ignore"|"skip"|"incomplete"?
function ns.RecipeParser.Capture(recipeID, preview)
  local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
  if type(recipeInfo) ~= "table" then
    if not preview then
      return nil, "incomplete"
    end
    recipeInfo = {}
  end
  if not preview and not recipeInfo.learned then
    return nil, "ignore"
  end
  if recipeInfo.isDummyRecipe or recipeInfo.isGatheringRecipe or recipeInfo.isSalvageRecipe or recipeInfo.isRecraft then
    return nil, "ignore"
  end

  local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
  if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
    return nil, "incomplete"
  end
  if preview and (schematic.recipeID ~= recipeID or schematic.recipeType ~= Enum.TradeskillRecipeType.Item) then
    return nil, "skip"
  end

  local outputItemID, outputState = GetOutputItemID(recipeID, recipeInfo, schematic, preview)
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

  local skillUp
  if not preview and recipeInfo.canSkillUp and IsPositiveInteger(recipeInfo.numSkillUps) then
    skillUp = {
      points = recipeInfo.numSkillUps,
      guaranteed = recipeInfo.relativeDifficulty == Enum.TradeskillRelativeDifficulty.Optimal,
      lowChance = recipeInfo.relativeDifficulty == Enum.TradeskillRelativeDifficulty.Easy or nil,
    }
  end

  local recipes = {}
  for _, variant in ipairs(ExpandReagentChoices(reagentChoices)) do
    local reagents = NormalizeReagents(variant)
    recipes[#recipes + 1] = {
      recipeKey = GetRecipeKey(outputItemID, recipeID, reagents),
      outputItemID = outputItemID,
      outputQuantity = outputQuantity,
      reagents = reagents,
      skillUp = skillUp,
    }
  end
  return recipes
end

-- Trainer previews use the live schematic but never add unlearned crafts to the recipe book.
function ns.RecipeParser.Preview(recipeID)
  return ns.RecipeParser.Capture(recipeID, true)
end

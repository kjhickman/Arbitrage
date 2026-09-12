local _, ns = ...

ns.RecipeCapture = {}

local scanning = false
local incompleteWarnings = {}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

---@param itemLink string?
local function GetItemID(itemLink)
  return itemLink and tonumber(itemLink:match("item:(%d+)"))
end

local function IsPositiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

---@param outputItemID number
---@param outputQuantity number
---@param reagents ArbitrageRecipeReagent[]
---@param recipeLink string?
---@return string
local function GetRecipeKey(outputItemID, outputQuantity, reagents, recipeLink)
  local recipeID = recipeLink
    and (recipeLink:match("Henchant:(%d+)") or recipeLink:match("Hspell:(%d+)") or recipeLink:match("Hitem:(%d+)"))
  if recipeID then
    return "recipe:" .. recipeID
  end

  local parts = { tostring(outputItemID), tostring(outputQuantity) }
  for _, reagent in ipairs(reagents) do
    parts[#parts + 1] = reagent.itemID .. "x" .. reagent.quantity
  end
  return table.concat(parts, ":")
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

  if type(outputQuantity) ~= "number" then
    return nil, "incomplete"
  end
  if
    outputQuantity <= 0
    or outputQuantity >= math.huge
    or outputQuantity % 1 ~= 0
    or not IsPositiveInteger(reagentCount)
  then
    return nil, "incomplete"
  end

  ---@type ArbitrageRecipeReagent[]
  local reagents = {}
  for reagentIndex = 1, reagentCount do
    local reagentLink, quantity, name = getReagent(reagentIndex)
    local reagentItemID = GetItemID(reagentLink)
    if reagentItemID == nil or not IsPositiveInteger(quantity) then
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

local function RestoreTradeSkillFilters(subclassFilters, invSlotFilters, filters)
  if subclassFilters[0] then
    SetTradeSkillSubClassFilter(0, 1, 1)
  else
    for index, enabled in pairs(subclassFilters) do
      if index > 0 then
        SetTradeSkillSubClassFilter(index, enabled and 1 or 0, 0)
      end
    end
  end

  if invSlotFilters[0] then
    SetTradeSkillInvSlotFilter(0, 1, 1)
  else
    for index, enabled in pairs(invSlotFilters) do
      if index > 0 then
        SetTradeSkillInvSlotFilter(index, enabled and 1 or 0, 0)
      end
    end
  end

  TradeSkillOnlyShowMakeable(filters.onlyMakeable)
  TradeSkillOnlyShowSkillUps(filters.onlySkillUps)
  SetTradeSkillItemNameFilter(filters.itemName or "")
  SetTradeSkillItemLevelFilter(filters.minimumItemLevel or 0, filters.maximumItemLevel or 0)
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
  for index = #expanded, 1, -1 do
    collapse(expanded[index])
  end
end

---@param capture function
---@param cleanup function
---@return boolean
local function RunCapture(capture, cleanup)
  scanning = true
  local succeeded = xpcall(capture, geterrorhandler())
  cleanup()
  scanning = false
  return succeeded
end

local function SaveCompleteProfession(professionName, recipes, complete)
  if professionName == nil or professionName == UNKNOWN then
    return
  end

  if complete then
    incompleteWarnings[professionName] = nil
    ns.RecipeBook.SaveProfession(professionName, recipes)
  elseif not incompleteWarnings[professionName] then
    incompleteWarnings[professionName] = true
    Print(professionName .. " recipe data was incomplete; keeping the previous snapshot")
  end
end

local function CaptureTradeSkill()
  if scanning or IsTradeSkillLinked() or GetNumTradeSkills() == 0 then
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
          GetTradeSkillRecipeLink(index)
        )

        if recipe then
          recipes[recipe.recipeKey] = recipe
        elseif state == "incomplete" then
          complete = false
        end
      end
    end
  end, function()
    RestoreHeaders(expandedHeaders, CollapseTradeSkillSubClass)
    if filters then
      RestoreTradeSkillFilters(subclassFilters, invSlotFilters, filters)
    end
  end)
  if succeeded then
    SaveCompleteProfession(GetTradeSkillLine(), recipes, complete)
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
          GetCraftRecipeLink(index)
        )

        if recipe then
          recipes[recipe.recipeKey] = recipe
        elseif state == "incomplete" then
          complete = false
        end
      end
    end
  end, function()
    RestoreHeaders(expandedHeaders, CollapseCraftSkillLine)
  end)
  if succeeded then
    SaveCompleteProfession(GetCraftName(), recipes, complete)
  end
end

function ns.RecipeCapture.Register()
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

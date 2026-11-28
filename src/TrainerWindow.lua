local _, ns = ...

ns.TrainerWindow = {}

local scrollBox
local refreshPending = false

local function GetEstimate(index)
  if not IsTradeskillTrainer() then
    return nil
  end
  local _, serviceType = GetTrainerServiceInfo(index)
  if serviceType ~= "available" and serviceType ~= "unavailable" then
    return nil
  end
  -- The cost API's second return identifies profession rank training, not a recipe.
  local _, isProfession = GetTrainerServiceCost(index)
  if isProfession then
    return nil
  end

  local data = C_TooltipInfo.GetTrainerService(index)
  local recipeID = data and data.type == Enum.TooltipDataType.Spell and data.id
  if type(recipeID) ~= "number" or recipeID <= 0 then
    return nil
  end
  local best
  for _, recipe in ipairs(ns.RecipeParser.Preview(recipeID) or {}) do
    local opportunity = ns.Opportunities.GetForRecipe(recipe)
    if opportunity and (not best or opportunity.perCraft.profit > best.perCraft.profit) then
      best = opportunity
    end
  end
  return best
end

local function AddProfitTooltip(row)
  local opportunity = row.arbitrageTrainerEstimate
  if not opportunity or not GameTooltip:IsOwned(row) then
    return
  end
  local saleMethod = opportunity.saleMethod == "vendor" and "Vendor" or "AH"
  GameTooltip:AddDoubleLine(
    ("%s per craft (%s)"):format(ns.Terminology.typicalProfit.label, saleMethod),
    ns.CraftingWindow.FormatProfit(opportunity.perCraft.profit)
  )
  GameTooltip:AddDoubleLine(
    "Materials per craft",
    C_CurrencyInfo.GetCoinTextureString(opportunity.perCraft.craftCost, 10)
  )
  if opportunity.isUncertain then
    GameTooltip:AddLine(table.concat(opportunity.reasons, ", "), 1, 0.82, 0, true)
  end
  GameTooltip:Show()
end

local function UpdateRow(row, node)
  local label = row.arbitrageTrainerProfit
  if label then
    label:Hide()
  end
  local index = node:GetData().skillIndex
  local opportunity = index and GetEstimate(index)
  row.arbitrageTrainerEstimate = opportunity
  if not opportunity then
    return
  end
  if not label then
    label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("RIGHT", row, "RIGHT", -8, -8)
    row.arbitrageTrainerProfit = label
    row:HookScript("OnEnter", AddProfitTooltip)
  end

  ns.CraftingWindow.SetProfitText(label, opportunity.perCraft.profit)

  -- Keep the training fee and requirements intact; crowded rows still show profit on hover.
  local left, right = row.subText:GetLeft(), row:GetRight()
  if left and right and left + row.subText:GetUnboundedStringWidth() + label:GetStringWidth() + 16 <= right then
    label:Show()
  end
end

function ns.TrainerWindow.Refresh()
  if scrollBox and scrollBox:IsVisible() then
    scrollBox:ForEachFrame(UpdateRow)
  end
end

local function QueueRefresh()
  if refreshPending then
    return
  end
  refreshPending = true
  C_Timer.After(0, function()
    refreshPending = false
    ns.TrainerWindow.Refresh()
  end)
end

local function Attach()
  if scrollBox or not ClassTrainerFrame or not ClassTrainerFrame.ScrollBox then
    return
  end
  scrollBox = ClassTrainerFrame.ScrollBox
  ScrollUtil.AddInitializedFrameCallback(scrollBox, function(_, row, node)
    UpdateRow(row, node)
  end, ns.TrainerWindow)
  scrollBox:HookScript("OnShow", QueueRefresh)
  ns.TrainerWindow.Refresh()
end

function ns.TrainerWindow.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("TRAINER_UPDATE")
  frame:RegisterEvent("TRAINER_SERVICE_INFO_NAME_UPDATE")
  frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  frame:SetScript("OnEvent", function(_, event, arg1, success)
    if event == "ADDON_LOADED" then
      if arg1 == "Blizzard_TrainerUI" then
        Attach()
      end
    elseif scrollBox and scrollBox:IsVisible() and (event ~= "ITEM_DATA_LOAD_RESULT" or success) then
      QueueRefresh()
    end
  end)
  Attach()
end

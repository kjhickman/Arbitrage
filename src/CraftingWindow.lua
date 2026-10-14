local _, ns = ...

ns.CraftingWindow = {}

local scrollBox
local estimates = {}
local refreshPending = false

local function FormatProfit(value)
  return (value >= 0 and "+" or "-") .. C_CurrencyInfo.GetCoinTextureString(math.abs(value), 10)
end

local function GetEstimate(recipeInfo)
  if not recipeInfo.learned then
    return nil
  end
  local recipeID = recipeInfo.recipeID
  if estimates[recipeID] ~= nil then
    return estimates[recipeID] or nil
  end

  local recipes, state = ns.RecipeParser.Capture(recipeID)
  if recipes == nil and state ~= "incomplete" then
    estimates[recipeID] = false
    return nil
  end

  local estimate = {}
  for _, recipe in ipairs(recipes or {}) do
    local opportunity = ns.Opportunities.GetForRecipe(recipe)
    if opportunity and (estimate.opportunity == nil or opportunity.profit > estimate.opportunity.profit) then
      estimate.opportunity = opportunity
    end
  end
  estimates[recipeID] = estimate
  return estimate
end

local function ShowProfitTooltip(row)
  local estimate = row.arbitrageEstimate
  if estimate == nil then
    return
  end
  local data = row:GetElementData():GetData()
  local recipeInfo = Professions.GetHighestLearnedRecipe(data.recipeInfo) or data.recipeInfo
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(recipeInfo.name, 1, 1, 1)
  local opportunity = estimate.opportunity
  if opportunity then
    local method = opportunity.saleMethod == "vendor" and "Vendor" or "AH"
    GameTooltip:AddDoubleLine(
      "Crafting Cost (per craft)",
      C_CurrencyInfo.GetCoinTextureString(opportunity.craftCost, 10)
    )
    GameTooltip:AddDoubleLine("Estimated Profit (" .. method .. ", per craft)", FormatProfit(opportunity.profit))
    if opportunity.minimumProfit then
      GameTooltip:AddDoubleLine("Best-case Profit", FormatProfit(opportunity.minimumProfit))
    end
    if opportunity.isUncertain then
      GameTooltip:AddLine(table.concat(opportunity.reasons, ", "), 1, 0.82, 0, true)
    end
    GameTooltip:AddLine("AH cut included; excludes deposits, inventory, sale rate, and cooldowns.", nil, nil, nil, true)
  else
    GameTooltip:AddLine(
      "Profit unknown. Scan the Auction House and visit reagent vendors for prices.",
      nil,
      nil,
      nil,
      true
    )
  end
  GameTooltip:Show()
end

local function UpdateRow(row, node)
  local data = node:GetData()
  if data.recipeInfo == nil then
    return
  end
  row.arbitrageEstimate = nil
  if row.arbitrageProfit then
    row.arbitrageProfit:Hide()
  end

  local estimate
  if
    not C_TradeSkillUI.IsDataSourceChanging()
    and not C_TradeSkillUI.IsNPCCrafting()
    and not C_TradeSkillUI.IsRuneforging()
  then
    local recipeInfo = Professions.GetHighestLearnedRecipe(data.recipeInfo) or data.recipeInfo
    estimate = GetEstimate(recipeInfo)
  end
  local lockedWidth = row.LockedIcon:IsShown() and row.LockedIcon:GetWidth() or 0
  local profitWidth = 0
  if estimate then
    if row.arbitrageProfit == nil then
      row.arbitrageProfit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.arbitrageProfit:SetJustifyH("RIGHT")
      row:HookScript("OnEnter", ShowProfitTooltip)
    end
    local profit = row.arbitrageProfit
    row.arbitrageEstimate = estimate
    profit:ClearAllPoints()
    profit:SetPoint("RIGHT", row, "RIGHT", -lockedWidth - 4, 0)
    local opportunity = estimate.opportunity
    if opportunity then
      profit:SetText(FormatProfit(opportunity.profit))
      if opportunity.isUncertain then
        profit:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
      elseif opportunity.profit > 0 then
        profit:SetTextColor(0.2, 1, 0.2)
      elseif opportunity.profit < 0 then
        profit:SetTextColor(1, 0.2, 0.2)
      else
        profit:SetTextColor(WHITE_FONT_COLOR:GetRGB())
      end
    else
      profit:SetText("?")
      profit:SetTextColor(WHITE_FONT_COLOR:GetRGB())
    end
    profit:Show()
    profitWidth = profit:GetStringWidth() + 8
  end

  local countWidth = row.Count:IsShown() and row.Count:GetStringWidth() or 0
  local available = row:GetWidth() - row.SkillUps:GetWidth() - lockedWidth - countWidth - 10 - profitWidth
  row.Label:SetWidth(row:GetWidth())
  row.Label:SetWidth(math.max(1, math.min(available, row.Label:GetStringWidth())))
end

function ns.CraftingWindow.Refresh()
  estimates = {}
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
    ns.CraftingWindow.Refresh()
  end)
end

local function Attach()
  if scrollBox or not ProfessionsFrame or not ProfessionsFrame.CraftingPage then
    return
  end
  scrollBox = ProfessionsFrame.CraftingPage.RecipeList.ScrollBox
  ScrollUtil.AddInitializedFrameCallback(scrollBox, function(_, row, node)
    UpdateRow(row, node)
  end, ns.CraftingWindow)
  scrollBox:HookScript("OnShow", QueueRefresh)
  scrollBox:ForEachFrame(UpdateRow)
end

function ns.CraftingWindow.Register()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("TRADE_SKILL_SHOW")
  frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  frame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:RegisterEvent("MERCHANT_SHOW")
  frame:RegisterEvent("MERCHANT_UPDATE")
  frame:SetScript("OnEvent", function(_, event, arg1, success)
    if event == "ADDON_LOADED" and arg1 ~= "Blizzard_Professions" then
      return
    end
    if event == "GET_ITEM_INFO_RECEIVED" and not success then
      return
    end
    Attach()
    QueueRefresh()
  end)
  Attach()
end

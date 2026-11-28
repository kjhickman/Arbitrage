local _, ns = ...

-- Profits beside the recipes on What's Training's tab in the professions window, which lists the
-- recipes a character hasn't learned yet. That addon offers no hook for its rows, so this reads the
-- fields its rows keep, and leaves alone any row it doesn't recognize and the tab when it's missing.
ns.WhatsTraining = {}

local scrollBox
-- Each recipe's estimate until prices change; false when it makes no item Arbitrage can price.
---@type table<number, ArbitrageRecipeEstimate|false>
local estimates = {}

-- Priced from the live recipe, as the trainer window does, since the tab lists recipes from every
-- profession whether or not its window has shown them to Arbitrage.
---@param recipeID number
---@return ArbitrageRecipeEstimate?
local function GetEstimate(recipeID)
  if estimates[recipeID] == nil then
    estimates[recipeID] = ns.CraftingWindow.Estimate(ns.RecipeParser.Preview(recipeID))
  end
  return estimates[recipeID] or nil
end

-- Below What's Training's own lines for the recipe.
local function ShowProfitTooltip(row)
  local estimate = row.arbitrageEstimate
  if estimate == nil or not GameTooltip:IsOwned(row) then
    return
  end
  GameTooltip:AddLine(" ")
  ns.CraftingWindow.AddProfitLines(estimate.opportunity)
  GameTooltip:Show()
end

-- What's Training's recipe rows keep the recipe they show as data.recipe, whose spell is the
-- recipe's ID and creates the item it makes, and show its name in their first cell, a font string.
-- A row shaped any other way, as after an update to What's Training, gets no profit rather than an
-- error.
local function UpdateRow(row)
  local label = row.arbitrageProfit
  if label then
    label:Hide()
  end
  row.arbitrageEstimate = nil
  local data = row.data
  local recipe = type(data) == "table" and data.recipe
  local name = type(row.cells) == "table" and row.cells[1]
  if
    not ns.Config.Get("showCraftingWindowProfits")
    or type(recipe) ~= "table"
    or type(recipe.spell) ~= "number"
    or recipe.creates == nil
    or type(name) ~= "table"
    or type(name.GetObjectType) ~= "function"
    or name:GetObjectType() ~= "FontString"
  then
    return
  end
  local estimate = GetEstimate(recipe.spell)
  if estimate == nil then
    return
  end
  row.arbitrageEstimate = estimate
  if label == nil then
    label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("RIGHT", name, "RIGHT")
    label:Hide()
    row.arbitrageProfit = label
    row:HookScript("OnEnter", ShowProfitTooltip)
    -- What's Training lays the row out again as it resizes, which can leave the name less room.
    row:HookScript("OnSizeChanged", UpdateRow)
  end

  -- As in the crafting window, a profit below the minimum is blank but keeps its tooltip.
  local opportunity = estimate.opportunity
  local minimumProfit = ns.Config.Get("craftingWindowMinimumProfit")
  if opportunity and minimumProfit > 0 and opportunity.profit < minimumProfit then
    return
  end
  ns.CraftingWindow.SetProfitText(label, opportunity and opportunity.profit)
  -- The name keeps its room; a crowded row still shows its profit on hover.
  if name:GetUnboundedStringWidth() + label:GetStringWidth() + 8 <= name:GetWidth() then
    label:Show()
  end
end

function ns.WhatsTraining.Refresh()
  estimates = {}
  if scrollBox and scrollBox:IsVisible() then
    scrollBox:ForEachFrame(UpdateRow)
  end
end

local function Attach()
  local box = _G.WhatsTrainingCraftingScrollBox
  -- Only Blizzard's scroll lists have ForEachFrame, and only they take the row callback.
  if type(box) ~= "table" or type(box.ForEachFrame) ~= "function" then
    return
  end
  scrollBox = box
  ScrollUtil.AddInitializedFrameCallback(scrollBox, function(_, row)
    UpdateRow(row)
  end, ns.WhatsTraining)
  -- Vendor visits and newly learned recipes change costs while the tab is closed.
  scrollBox:HookScript("OnShow", ns.WhatsTraining.Refresh)
  ns.WhatsTraining.Refresh()
end

function ns.WhatsTraining.Register()
  -- What's Training builds its tab as Blizzard_Professions loads, which can be after this hears of it.
  EventUtil.ContinueOnAddOnLoaded("Blizzard_Professions", function()
    C_Timer.After(0, Attach)
  end)
end

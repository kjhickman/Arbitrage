local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : ArbitrageItemTableRow
---@field saleMethod FontString
---@field skillUp Texture
---@field nameWidth number how wide the name is without a skill-up icon beside it
---@field marketValue FontString? each column's cell, once the column shows
---@field craftCost FontString?
---@field profit FontString?
---@field roi FontString?
---@field buyout FontString?
---@field buyoutCraftCost FontString?
---@field buyoutProfit FontString?
---@field buyoutRoi FontString?
---@field saleRate FontString?

local FormatMoney = ns.ItemTable.FormatMoney
local OptionalMoney = ns.ItemTable.FormatOptionalMoney
local FormatSignedMoney = ns.ItemTable.FormatSignedMoney
local FormatQuantity = ns.ItemTable.FormatQuantity
local FormatPercent = ns.ItemTable.FormatPercent
local FormatCount = ns.ItemTable.FormatCount

-- In a row the name starts 18 pixels in, past the icon, and stops 4 pixels short of the sale method
-- at the Item column's right edge. The Item column keeps room for a short name beside it.
local NAME_X = 18
local SALE_METHOD_WIDTH = 44
local SKILL_UP_WIDTH = 26
local MIN_ITEM_WIDTH = 170
-- The same green, yellow, and orange skill-up icons Blizzard uses in the profession recipe list,
-- ranked so the best chance among the crafters wins.
---@type table<ArbitrageSkillUpDifficulty, number>
local SKILL_UP_RANKS = { easy = 1, medium = 2, optimal = 3 }
local SKILL_UP_ATLASES = {
  "Professions-Icon-Skill-Low",
  "Professions-Icon-Skill-Medium",
  "Professions-Icon-Skill-High",
}
---@type table<ArbitrageSkillUpDifficulty, string>
local SKILL_UP_CHANCES = { easy = "Low chance at +", medium = "Chance at +", optimal = "+" }
-- Marks a craft no character knows the recipe for, in the skill-up icon's place, since nobody gains
-- skill from a recipe they haven't learned.
local UNLEARNED_ATLAS = "talents-lock-c60"

-- A return as a signed whole percent, such as +38% or -1,250%.
---@param share number
---@return string
local function FormatReturn(share)
  local percent = math.floor(share * 100 + 0.5)
  return (percent < 0 and "-" or "+") .. FormatCount(math.abs(percent)) .. "%"
end

---@param value number?
---@return string?
local function OptionalSignedMoney(value)
  return value and FormatSignedMoney(value)
end

-- Money columns fit "+9999g 99s": a sign and six digits of about 7 pixels, two coin icons of 14
-- and a space come to about 81 pixels, so 96 leaves slack. The Craft Cost columns are wider for
-- their labels. Typical, Typical ROI, Current, and Current ROI show once chosen, beside the columns
-- they explain; Sale Rate shows last, and only when the Companion brought sales. Gray marks a
-- profit, and its ROI, that misses the filters the craft passes on its other profit.
---@param withSales boolean
---@return ArbitrageItemTableColumn[]
local function Columns(withSales)
  local Terminology = ns.Terminology
  return {
    {
      key = "marketValue",
      label = Terminology.typical.label,
      width = 96,
      hidden = true,
      explanation = Terminology.typical.definition,
      format = function(opportunity)
        return OptionalMoney(opportunity.marketValue), opportunity.marketValueIsUncertain
      end,
    },
    {
      key = "craftCost",
      label = Terminology.typicalCraftCost.label,
      width = 120,
      explanation = Terminology.typicalCraftCost.definition,
      format = function(opportunity)
        return OptionalMoney(opportunity.craftCost), opportunity.craftCostIsUncertain
      end,
    },
    {
      key = "profit",
      label = Terminology.typicalProfit.label,
      width = 96,
      explanation = Terminology.typicalProfit.definition,
      format = function(opportunity)
        return OptionalSignedMoney(opportunity.profit), opportunity.isUncertain, opportunity.profitMissesFilters
      end,
    },
    {
      key = "roi",
      label = Terminology.typicalRoi.label,
      width = 84,
      hidden = true,
      explanation = Terminology.typicalRoi.definition,
      format = function(opportunity)
        local roi = opportunity.roi
        return roi and FormatReturn(roi), opportunity.isUncertain, opportunity.profitMissesFilters
      end,
    },
    {
      key = "buyout",
      label = Terminology.current.label,
      width = 96,
      hidden = true,
      explanation = Terminology.current.definition,
      format = function(opportunity)
        return OptionalMoney(opportunity.buyout)
      end,
    },
    {
      key = "buyoutCraftCost",
      label = Terminology.currentCraftCost.label,
      width = 120,
      explanation = Terminology.currentCraftCost.definition,
      format = function(opportunity)
        return OptionalMoney(opportunity.buyoutCraftCost)
      end,
    },
    {
      key = "buyoutProfit",
      label = Terminology.currentProfit.label,
      width = 96,
      explanation = Terminology.currentProfit.definition,
      format = function(opportunity)
        return OptionalSignedMoney(opportunity.buyoutProfit), false, opportunity.buyoutProfitMissesFilters
      end,
    },
    {
      key = "buyoutRoi",
      label = Terminology.currentRoi.label,
      width = 84,
      hidden = true,
      explanation = Terminology.currentRoi.definition,
      format = function(opportunity)
        local buyoutRoi = opportunity.buyoutRoi
        return buyoutRoi and FormatReturn(buyoutRoi), false, opportunity.buyoutProfitMissesFilters
      end,
    },
    {
      key = "saleRate",
      label = "Sale Rate",
      width = 72,
      unavailable = not withSales,
      explanation = "Share of this item's auctions that sell across your region, from TradeSkillMaster through Arbitrage Companion. Blank when TradeSkillMaster has none for it.",
      format = function(opportunity)
        local saleRate = opportunity.saleRate
        return saleRate and FormatPercent(saleRate)
      end,
    },
  }
end

-- "Alchemy - Alt, Main": every profession, then every character, each once.
---@param sources ArbitrageRecipeSource[]
---@return string
function ns.OpportunityTable.FormatSources(sources)
  local professions = {}
  local characters = {}
  local seenProfessions = {}
  local seenCharacters = {}

  for _, source in ipairs(sources) do
    if not seenProfessions[source.professionName] then
      seenProfessions[source.professionName] = true
      professions[#professions + 1] = source.professionName
    end
    if not seenCharacters[source.characterName] then
      seenCharacters[source.characterName] = true
      characters[#characters + 1] = source.characterName
    end
  end

  if #professions == 0 or #characters == 0 then
    return "Known recipe"
  end
  return table.concat(professions, ", ") .. " - " .. table.concat(characters, ", ")
end

---@param sources ArbitrageRecipeSource[]
local function AddSkillUps(sources)
  local hasSkillUp = false
  for _, source in ipairs(sources) do
    local skillUp = source.skillUp
    if skillUp then
      hasSkillUp = true
      local gain = SKILL_UP_CHANCES[skillUp.difficulty] .. skillUp.points .. " skill per craft"
      GameTooltip:AddLine(source.characterName .. " (" .. source.professionName .. "): " .. gain, 1, 1, 1, true)
    end
  end
  if hasSkillUp then
    GameTooltip:AddLine("Skill gains are based on each crafter's last profession window update.", 0.7, 0.7, 0.7, true)
  end
end

---@param method ("auction"|"vendor")?
---@return string
local function SaleLabel(method)
  return method == "vendor" and "Vendor" or "AH"
end

---@param opportunity ArbitrageCraftOpportunity
local function AddMaterials(opportunity)
  local priced, materials = ns.ItemDetails.ListMaterials(opportunity)
  if not priced then
    return
  end

  local perCraft = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
  GameTooltip:AddLine("Materials to buy per craft" .. perCraft .. " at " .. priced .. ":")
  for _, material in ipairs(materials) do
    GameTooltip:AddDoubleLine(
      "  " .. material.name .. " x" .. FormatQuantity(material.quantity) .. " (" .. material.source .. ")",
      FormatMoney(material.cost)
    )
  end
end

-- The row shows the prices, so its tooltip covers the recipe: who makes it and what to buy. The
-- item's own Arbitrage pricing lines are left out too.
---@param opportunity ArbitrageCraftOpportunity
local function AddOpportunityTooltipLines(opportunity)
  GameTooltip:AddLine(" ")
  if opportunity.isUnlearned then
    GameTooltip:AddLine("Recipe not learned", 1, 0.82, 0)
    GameTooltip:AddLine(
      "Could be learned by: " .. ns.OpportunityTable.FormatSources(opportunity.sources),
      1,
      1,
      1,
      true
    )
  else
    GameTooltip:AddLine("Crafted by: " .. ns.OpportunityTable.FormatSources(opportunity.sources), 1, 1, 1, true)
    AddSkillUps(opportunity.sources)
  end
  AddMaterials(opportunity)
end

---@param row ArbitrageOpportunityRow
local function InitializeRow(row)
  row.saleMethod = row:CreateFontString(nil, "ARTWORK", "Number13FontGray")
  row.saleMethod:SetWidth(SALE_METHOD_WIDTH)
  row.saleMethod:SetJustifyH("LEFT")
  row.saleMethod:SetWordWrap(false)
  row.saleMethod:SetMaxLines(1)

  row.skillUp = row:CreateTexture(nil, "ARTWORK")
end

-- The sale method sits at the Item column's right edge, with the skill-up icon before it.
---@param row ArbitrageOpportunityRow
---@param itemWidth number
local function LayoutItem(row, itemWidth)
  local saleMethodX = itemWidth - SALE_METHOD_WIDTH - 1
  row.saleMethod:SetPoint("LEFT", row, "LEFT", saleMethodX, 0)
  row.skillUp:SetPoint("RIGHT", row, "LEFT", saleMethodX - 4, 0)
  row.nameWidth = saleMethodX - 4 - NAME_X
end

---@param row ArbitrageOpportunityRow
---@param opportunity ArbitrageCraftOpportunity
local function PopulateSkillUp(row, opportunity)
  local best = 0
  if ns.Config.Get("showOpportunitySkillUpIcons") then
    for _, source in ipairs(opportunity.sources) do
      local skillUp = source.skillUp
      if skillUp then
        best = math.max(best, SKILL_UP_RANKS[skillUp.difficulty])
      end
    end
  end

  local atlas = opportunity.isUnlearned and UNLEARNED_ATLAS or SKILL_UP_ATLASES[best]
  row.skillUp:SetShown(atlas ~= nil)
  row.itemName:SetWidth(atlas and row.nameWidth - SKILL_UP_WIDTH or row.nameWidth)
  if atlas then
    row.skillUp:SetAtlas(atlas, true)
  end
end

---@param row ArbitrageOpportunityRow
---@param opportunity ArbitrageCraftOpportunity
---@param itemName string
local function PopulateRow(row, opportunity, itemName)
  local quantitySuffix = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
  row.itemName:SetText(itemName .. quantitySuffix)
  PopulateSkillUp(row, opportunity)
  row.saleMethod:SetText(SaleLabel(opportunity.saleMethod or opportunity.buyoutSaleMethod))
end

-- Every Opportunities table shares one layout of columns and sort.
---@param parent Frame
---@param onSelect fun(opportunity: ArbitrageCraftOpportunity?)
---@param contextMenu (fun(opportunity: ArbitrageCraftOpportunity, rootDescription: table))? fills a row's right-click menu
---@return ArbitrageItemTable
function ns.OpportunityTable.Create(parent, onSelect, contextMenu)
  return ns.ItemTable.Create(parent, {
    itemLabel = "Item",
    minItemWidth = MIN_ITEM_WIDTH,
    -- The Companion's sales are read at login, so whether there are any can't change while the
    -- window is open.
    columns = Columns(ns.Database.HasSales()),
    layoutKey = "opportunityColumns",
    defaultSortKey = "profit",
    initializeRow = InitializeRow,
    layoutItem = LayoutItem,
    populateRow = PopulateRow,
    addTooltipLines = AddOpportunityTooltipLines,
    replacesItemPricing = true,
    onSelect = onSelect,
    contextMenu = contextMenu,
    profileName = "Opportunities Table",
  })
end

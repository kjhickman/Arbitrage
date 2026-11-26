local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : ArbitrageItemTableRow
---@field saleMethod FontString
---@field skillUp Texture
---@field craftCost FontString
---@field profit FontString
---@field buyoutCraftCost FontString
---@field buyoutProfit FontString
---@field saleRate FontString? only with the Companion's sales

local FormatMoney = ns.ItemTable.FormatMoney
local FormatSignedMoney = ns.ItemTable.FormatSignedMoney
local FormatQuantity = ns.ItemTable.FormatQuantity
local FormatPercent = ns.ItemTable.FormatPercent
local SetValueColor = ns.ItemTable.SetValueColor

-- Money columns fit "+9999g 99s": a sign and six digits of about 7 pixels, two coin icons of 14
-- and a space come to about 81 pixels, so 96 leaves slack. The Buyout columns are wider for their
-- labels. Columns sit right to left from the scroll bar, this far apart, and the Item column takes
-- the rest. In a row the name starts 18 pixels in, past the icon, and stops 4 pixels short of the
-- sale method at the column's right edge.
local TABLE_RIGHT = 735
local COLUMN_GAP = 5
local ITEM_X = 4
local NAME_X = 18
local SALE_METHOD_WIDTH = 44
local SKILL_UP_WIDTH = 26
-- Where the table that Create made puts each row's name and sale method.
local nameWidth, saleMethodX
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

-- Sale Rate shows last, and only when the Companion brought sales.
---@param withSales boolean
---@return ArbitrageItemTableColumn[] columns, number itemWidth
local function LayoutColumns(withSales)
  ---@type ArbitrageItemTableColumn[]
  local columns = {
    {
      key = "craftCost",
      label = ns.Terminology.typicalCraftCost.label,
      width = 96,
      explanation = ns.Terminology.typicalCraftCost.definition,
    },
    {
      key = "profit",
      label = ns.Terminology.typicalProfit.label,
      width = 96,
      explanation = ns.Terminology.typicalProfit.definition,
    },
    {
      key = "buyoutCraftCost",
      label = ns.Terminology.currentCraftCost.label,
      width = 135,
      explanation = ns.Terminology.currentCraftCost.definition,
    },
    {
      key = "buyoutProfit",
      label = ns.Terminology.currentProfit.label,
      width = 106,
      explanation = ns.Terminology.currentProfit.definition,
    },
  }
  if withSales then
    columns[#columns + 1] = {
      key = "saleRate",
      label = "Sale Rate",
      width = 72,
      explanation = "Share of this item's auctions that sell across your region, from TradeSkillMaster through Arbitrage Companion. Blank when TradeSkillMaster has none for it.",
    }
  end

  local x = TABLE_RIGHT
  for index = #columns, 1, -1 do
    local column = columns[index]
    x = x - column.width
    column.x = x
    x = x - COLUMN_GAP
  end
  return columns, x - ITEM_X
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
  GameTooltip:AddLine("Crafted by: " .. ns.OpportunityTable.FormatSources(opportunity.sources), 1, 1, 1, true)
  AddSkillUps(opportunity.sources)
  AddMaterials(opportunity)
end

---@param row ArbitrageOpportunityRow
local function InitializeRow(row)
  row.saleMethod = row:CreateFontString(nil, "ARTWORK", "Number13FontGray")
  row.saleMethod:SetPoint("LEFT", row, "LEFT", saleMethodX, 0)
  row.saleMethod:SetWidth(SALE_METHOD_WIDTH)
  row.saleMethod:SetJustifyH("LEFT")
  row.saleMethod:SetWordWrap(false)
  row.saleMethod:SetMaxLines(1)

  row.skillUp = row:CreateTexture(nil, "ARTWORK")
  row.skillUp:SetPoint("RIGHT", row, "LEFT", saleMethodX - 4, 0)
end

---@param row ArbitrageOpportunityRow
---@param sources ArbitrageRecipeSource[]
local function PopulateSkillUp(row, sources)
  local best = 0
  if ns.Config.Get("showOpportunitySkillUpIcons") then
    for _, source in ipairs(sources) do
      local skillUp = source.skillUp
      if skillUp then
        best = math.max(best, SKILL_UP_RANKS[skillUp.difficulty])
      end
    end
  end

  local atlas = SKILL_UP_ATLASES[best]
  row.skillUp:SetShown(atlas ~= nil)
  row.itemName:SetWidth(atlas and nameWidth - SKILL_UP_WIDTH or nameWidth)
  if atlas then
    row.skillUp:SetAtlas(atlas, true)
  end
end

-- A dash marks a missing price; gray marks a profit that misses the filters the craft passes on
-- its other profit.
---@param fontString FontString
---@param text string?
---@param isUncertain boolean?
---@param missesFilters boolean?
local function SetValue(fontString, text, isUncertain, missesFilters)
  fontString:SetText(text or "—")
  if missesFilters then
    fontString:SetTextColor(0.5, 0.5, 0.5)
  else
    SetValueColor(fontString, isUncertain)
  end
end

---@param row ArbitrageOpportunityRow
---@param opportunity ArbitrageCraftOpportunity
---@param itemName string
local function PopulateRow(row, opportunity, itemName)
  local quantitySuffix = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
  row.itemName:SetText(itemName .. quantitySuffix)
  PopulateSkillUp(row, opportunity.sources)
  row.saleMethod:SetText(SaleLabel(opportunity.saleMethod or opportunity.buyoutSaleMethod))
  SetValue(
    row.craftCost,
    opportunity.craftCost and FormatMoney(opportunity.craftCost),
    opportunity.craftCostIsUncertain
  )
  SetValue(
    row.profit,
    opportunity.profit and FormatSignedMoney(opportunity.profit),
    opportunity.isUncertain,
    opportunity.profitMissesFilters
  )
  SetValue(row.buyoutCraftCost, opportunity.buyoutCraftCost and FormatMoney(opportunity.buyoutCraftCost))
  SetValue(
    row.buyoutProfit,
    opportunity.buyoutProfit and FormatSignedMoney(opportunity.buyoutProfit),
    false,
    opportunity.buyoutProfitMissesFilters
  )
  if row.saleRate then
    SetValue(row.saleRate, opportunity.saleRate and FormatPercent(opportunity.saleRate))
  end
end

---@param parent Frame
---@param onSelect fun(opportunity: ArbitrageCraftOpportunity?)
---@param contextMenu (fun(opportunity: ArbitrageCraftOpportunity, rootDescription: table))? fills a row's right-click menu
---@return ArbitrageItemTable
function ns.OpportunityTable.Create(parent, onSelect, contextMenu)
  -- The Companion's sales are read at login, so whether there are any can't change while the window
  -- is open.
  local columns, itemWidth = LayoutColumns(ns.Database.HasSales())
  saleMethodX = itemWidth - SALE_METHOD_WIDTH - 1
  nameWidth = saleMethodX - 4 - NAME_X
  return ns.ItemTable.Create(parent, {
    itemLabel = "Item",
    itemWidth = itemWidth,
    nameWidth = nameWidth,
    columns = columns,
    defaultSortKey = "profit",
    initializeRow = InitializeRow,
    populateRow = PopulateRow,
    addTooltipLines = AddOpportunityTooltipLines,
    replacesItemPricing = true,
    onSelect = onSelect,
    contextMenu = contextMenu,
    profileName = "Opportunities Table",
  })
end

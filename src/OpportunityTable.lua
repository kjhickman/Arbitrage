local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : ArbitrageItemTableRow
---@field source FontString
---@field saleProceeds FontString
---@field craftCost FontString
---@field minimumCraftCost FontString
---@field profit FontString
---@field minimumProfit FontString
---@field roi FontString

---@class ArbitrageOpportunityTable
---@field SetItems fun(newItems: ArbitrageCraftOpportunity[])
---@field SetEmptyMessage fun(message: string?)
---@field HandleItemInfoReceived fun(itemID: number, success: boolean)

local FormatMoney = ns.ItemTable.FormatMoney
local FormatSignedMoney = ns.ItemTable.FormatSignedMoney
local SetValueColor = ns.ItemTable.SetValueColor

---@type ArbitrageItemTableColumn[]
local COLUMNS = {
  {
    key = "saleProceeds",
    label = "Net Sale",
    x = 150,
    width = 104,
    explanation = "The higher of Auction House proceeds after its cut and vendor sell value for the crafted quantity. The sale method is shown beside the crafter.",
  },
  {
    key = "craftCost",
    label = "Craft Cost",
    x = 259,
    width = 104,
    explanation = "Estimated cheapest way to make the items using rolling Auction House values, unlimited-stock vendors, and intermediate crafts.",
  },
  {
    key = "minimumCraftCost",
    label = "Best Cost",
    x = 368,
    width = 104,
    explanation = "Best-case cost for the same recipe using the cheapest per-unit buyouts from the latest full scan.",
  },
  {
    key = "profit",
    label = "Est. Profit",
    x = 477,
    width = 104,
    explanation = "Net Sale minus Craft Cost.",
  },
  {
    key = "minimumProfit",
    label = "Best Profit",
    x = 586,
    width = 104,
    explanation = "Net Sale minus Best Cost.",
  },
  {
    key = "roi",
    label = "ROI",
    x = 695,
    width = 40,
    explanation = "Net Sale minus the unrounded estimated crafting cost, divided by that cost.",
  },
}

---@param sources ArbitrageRecipeSource[]
---@return string
local function FormatSources(sources)
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

---@param opportunity ArbitrageCraftOpportunity
local function AddOpportunityTooltipLines(opportunity)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Sell to", opportunity.saleMethod == "vendor" and "Vendor" or "Auction House")
  GameTooltip:AddDoubleLine("Estimated profit per craft", FormatSignedMoney(opportunity.profit))
  if opportunity.minimumProfit then
    GameTooltip:AddDoubleLine("Best-case profit per craft", FormatSignedMoney(opportunity.minimumProfit))
  end
  local alternativeLabel, alternativeProceeds = "Vendor", opportunity.vendorSaleProceeds
  if opportunity.saleMethod == "vendor" then
    alternativeLabel, alternativeProceeds = "AH", opportunity.auctionSaleProceeds
  end
  if alternativeProceeds then
    GameTooltip:AddDoubleLine(
      alternativeLabel .. " profit per craft",
      FormatSignedMoney(alternativeProceeds - opportunity.craftCost)
    )
    if opportunity.minimumCraftCost then
      GameTooltip:AddDoubleLine(
        "Best-case " .. alternativeLabel .. " profit per craft",
        FormatSignedMoney(alternativeProceeds - opportunity.minimumCraftCost)
      )
    end
    if opportunity.saleMethod == "vendor" and opportunity.auctionIsUncertain then
      GameTooltip:AddLine("AH estimate: " .. table.concat(opportunity.auctionReasons or {}, ", "), 1, 0.82, 0, true)
    end
  end
  if opportunity.isUncertain then
    GameTooltip:AddLine("Estimate: " .. table.concat(opportunity.reasons, ", "), 1, 0.82, 0)
  end
  GameTooltip:AddLine("Crafted by: " .. FormatSources(opportunity.sources), 1, 1, 1, true)
end

---@param row ArbitrageOpportunityRow
local function InitializeRow(row)
  row.source = row:CreateFontString(nil, "ARTWORK", "Number13FontGray")
  row.source:SetPoint("LEFT", row, "LEFT", 96, 0)
  row.source:SetWidth(44)
  row.source:SetJustifyH("LEFT")
  row.source:SetWordWrap(false)
  row.source:SetMaxLines(1)
end

---@param row ArbitrageOpportunityRow
---@param opportunity ArbitrageCraftOpportunity
---@param itemName string
local function PopulateRow(row, opportunity, itemName)
  local quantitySuffix = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
  row.itemName:SetText(itemName .. quantitySuffix)
  local saleLabel = opportunity.saleMethod == "vendor" and "Vendor" or "AH"
  row.source:SetText(saleLabel .. " - " .. FormatSources(opportunity.sources))
  row.saleProceeds:SetText(FormatMoney(opportunity.saleProceeds))
  row.craftCost:SetText(FormatMoney(opportunity.craftCost))
  row.minimumCraftCost:SetText(opportunity.minimumCraftCost and FormatMoney(opportunity.minimumCraftCost) or "—")
  row.profit:SetText(FormatSignedMoney(opportunity.profit))
  row.minimumProfit:SetText(opportunity.minimumProfit and FormatSignedMoney(opportunity.minimumProfit) or "—")

  row.roi:SetText(math.floor(opportunity.roi * 100 + 0.5) .. "%")

  SetValueColor(row.saleProceeds, opportunity.marketIsUncertain)
  SetValueColor(row.craftCost, opportunity.craftCostIsUncertain)
  SetValueColor(row.minimumCraftCost, opportunity.minimumCraftCostIsUncertain)
  SetValueColor(row.profit, opportunity.isUncertain)
  SetValueColor(
    row.minimumProfit,
    opportunity.minimumProfit ~= nil and (opportunity.marketIsUncertain or opportunity.minimumCraftCostIsUncertain)
  )
  SetValueColor(row.roi, opportunity.isUncertain)
end

---@param parent Frame
---@return ArbitrageOpportunityTable
function ns.OpportunityTable.Create(parent)
  return ns.ItemTable.Create(parent, {
    itemLabel = "Item / Sale / Crafter",
    itemWidth = 141,
    nameWidth = 74,
    columns = COLUMNS,
    defaultSortKey = "profit",
    initializeRow = InitializeRow,
    populateRow = PopulateRow,
    addTooltipLines = AddOpportunityTooltipLines,
  })
end

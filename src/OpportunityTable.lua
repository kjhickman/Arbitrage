local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : ArbitrageItemTableRow
---@field saleMethod FontString
---@field saleProceeds FontString
---@field craftCost FontString
---@field profit FontString
---@field minimumProfit FontString
---@field roi FontString

local FormatMoney = ns.ItemTable.FormatMoney
local FormatSignedMoney = ns.ItemTable.FormatSignedMoney
local SetValueColor = ns.ItemTable.SetValueColor

-- Money columns fit "+9999g 99s": a sign and six digits of about 7 pixels, two coin icons of 14
-- and a space come to about 81 pixels, so 96 leaves slack. The item column takes the rest, up to
-- ROI ending at 735 beside the scroll bar. In a row the name starts 18 pixels in, past the icon,
-- and stops 4 pixels short of the sale method at the column's right edge.
local ITEM_WIDTH = 278
local NAME_WIDTH = 211
local SALE_METHOD_X = 233
local SALE_METHOD_WIDTH = 44

---@type ArbitrageItemTableColumn[]
local COLUMNS = {
  {
    key = "saleProceeds",
    label = "Net Sale",
    x = 287,
    width = 96,
    explanation = "The higher of one item's Auction House proceeds after the 5% cut and its vendor sell value. AH or Vendor beside the item shows which.",
  },
  {
    key = "craftCost",
    label = "Craft Cost",
    x = 388,
    width = 96,
    explanation = "Estimated cheapest way to make one item using rolling Market Values, unlimited-stock vendors, and intermediate crafts.",
  },
  {
    key = "profit",
    label = "Profit",
    x = 489,
    width = 96,
    explanation = "Net Sale minus Craft Cost, per item. Gray when the craft is listed only for its Buyout Profit.",
  },
  {
    key = "minimumProfit",
    label = "Buyout Profit",
    x = 590,
    width = 96,
    explanation = "Net Sale minus Buyout Cost: making one item with the same recipe at the cheapest per-unit buyouts from the latest full scan, which is not always cheaper than Craft Cost.",
  },
  {
    key = "roi",
    label = "ROI",
    x = 691,
    width = 44,
    explanation = "Net Sale minus Craft Cost, divided by Craft Cost, before rounding.",
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

---@param quantity number
---@return string
local function FormatQuantity(quantity)
  if quantity == math.floor(quantity) then
    return tostring(quantity)
  end

  local formatted = string.format("%.2f", quantity)
  return (formatted:gsub("0+$", ""):gsub("%.$", ""))
end

-- Lists one craft's materials rather than one item's, since a craft is what the player buys for.
---@param opportunity ArbitrageCraftOpportunity
---@param perCraft string
local function AddMaterials(opportunity, perCraft)
  local materials = {}
  for _, leaf in pairs(opportunity.materials) do
    local quantity = leaf.quantity * opportunity.outputQuantity
    materials[#materials + 1] = {
      name = C_Item.GetItemInfo(leaf.itemID) or leaf.name or ("Item #" .. leaf.itemID),
      quantity = quantity,
      cost = math.floor(leaf.price * quantity + 0.5),
      source = leaf.source == "vendor" and "Vendor" or "Auction House",
    }
  end
  table.sort(materials, function(left, right)
    return left.name < right.name
  end)

  GameTooltip:AddLine("Materials to buy" .. perCraft .. ":")
  for _, material in ipairs(materials) do
    GameTooltip:AddDoubleLine(
      "  " .. material.name .. " x" .. FormatQuantity(material.quantity) .. " (" .. material.source .. ")",
      FormatMoney(material.cost)
    )
  end
end

-- Everything here is per item unless labeled per craft; the item's own Arbitrage pricing lines
-- are left out of this tooltip, so these are the only prices it shows.
---@param opportunity ArbitrageCraftOpportunity
local function AddOpportunityTooltipLines(opportunity)
  local isVendorSale = opportunity.saleMethod == "vendor"
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Sell to", isVendorSale and "Vendor" or "Auction House")
  GameTooltip:AddDoubleLine("Net Sale", FormatMoney(opportunity.saleProceeds))
  GameTooltip:AddDoubleLine("Craft Cost", FormatMoney(opportunity.craftCost))
  GameTooltip:AddDoubleLine("Profit", FormatSignedMoney(opportunity.profit))
  if opportunity.minimumProfit then
    GameTooltip:AddDoubleLine("Buyout Profit", FormatSignedMoney(opportunity.minimumProfit))
  end
  local alternativeLabel, alternativeProceeds = "Vendor", opportunity.vendorSaleProceeds
  if isVendorSale then
    alternativeLabel, alternativeProceeds = "AH", opportunity.auctionSaleProceeds
  end
  if alternativeProceeds then
    GameTooltip:AddDoubleLine(
      alternativeLabel .. " Profit",
      FormatSignedMoney(alternativeProceeds - opportunity.craftCost)
    )
    if opportunity.minimumCraftCost then
      GameTooltip:AddDoubleLine(
        alternativeLabel .. " Buyout Profit",
        FormatSignedMoney(alternativeProceeds - opportunity.minimumCraftCost)
      )
    end
  end

  local perCraft = " per craft"
  if opportunity.outputQuantity > 1 then
    perCraft = perCraft .. " (x" .. opportunity.outputQuantity .. ")"
    GameTooltip:AddDoubleLine("Profit" .. perCraft, FormatSignedMoney(opportunity.perCraft.profit))
    if opportunity.perCraft.minimumProfit then
      GameTooltip:AddDoubleLine("Buyout Profit" .. perCraft, FormatSignedMoney(opportunity.perCraft.minimumProfit))
    end
  end

  if opportunity.isBuyoutOnly then
    GameTooltip:AddLine("Listed only for its Buyout Profit; its Profit is below your minimum profit.", 1, 1, 1, true)
  end
  if isVendorSale and opportunity.auctionIsUncertain then
    GameTooltip:AddLine("AH estimate: " .. table.concat(opportunity.auctionReasons or {}, ", "), 1, 0.82, 0, true)
  end
  if opportunity.isUncertain then
    GameTooltip:AddLine("Estimate: " .. table.concat(opportunity.reasons, ", "), 1, 0.82, 0, true)
  end
  GameTooltip:AddLine("Crafted by: " .. FormatSources(opportunity.sources), 1, 1, 1, true)
  AddMaterials(opportunity, perCraft)
end

---@param row ArbitrageOpportunityRow
local function InitializeRow(row)
  row.saleMethod = row:CreateFontString(nil, "ARTWORK", "Number13FontGray")
  row.saleMethod:SetPoint("LEFT", row, "LEFT", SALE_METHOD_X, 0)
  row.saleMethod:SetWidth(SALE_METHOD_WIDTH)
  row.saleMethod:SetJustifyH("LEFT")
  row.saleMethod:SetWordWrap(false)
  row.saleMethod:SetMaxLines(1)
end

---@param row ArbitrageOpportunityRow
---@param opportunity ArbitrageCraftOpportunity
---@param itemName string
local function PopulateRow(row, opportunity, itemName)
  local quantitySuffix = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
  row.itemName:SetText(itemName .. quantitySuffix)
  row.saleMethod:SetText(opportunity.saleMethod == "vendor" and "Vendor" or "AH")
  row.saleProceeds:SetText(FormatMoney(opportunity.saleProceeds))
  row.craftCost:SetText(FormatMoney(opportunity.craftCost))
  row.profit:SetText(FormatSignedMoney(opportunity.profit))
  row.minimumProfit:SetText(opportunity.minimumProfit and FormatSignedMoney(opportunity.minimumProfit) or "—")

  row.roi:SetText(math.floor(opportunity.roi * 100 + 0.5) .. "%")

  SetValueColor(row.saleProceeds, opportunity.marketIsUncertain)
  SetValueColor(row.craftCost, opportunity.craftCostIsUncertain)
  if opportunity.isBuyoutOnly then
    -- The row is listed for its Buyout Profit, so the Profit that falls short is dimmed gray.
    row.profit:SetTextColor(0.5, 0.5, 0.5)
  else
    SetValueColor(row.profit, opportunity.isUncertain)
  end
  SetValueColor(
    row.minimumProfit,
    opportunity.minimumProfit ~= nil and (opportunity.marketIsUncertain or opportunity.minimumCraftCostIsUncertain)
  )
  SetValueColor(row.roi, opportunity.isUncertain)
end

---@param parent Frame
---@return ArbitrageItemTable
function ns.OpportunityTable.Create(parent)
  return ns.ItemTable.Create(parent, {
    itemLabel = "Item",
    itemWidth = ITEM_WIDTH,
    nameWidth = NAME_WIDTH,
    columns = COLUMNS,
    defaultSortKey = "profit",
    initializeRow = InitializeRow,
    populateRow = PopulateRow,
    addTooltipLines = AddOpportunityTooltipLines,
    replacesItemPricing = true,
  })
end

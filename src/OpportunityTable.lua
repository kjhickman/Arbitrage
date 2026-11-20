local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : ArbitrageItemTableRow
---@field saleMethod FontString
---@field saleProceeds FontString
---@field craftCost FontString
---@field profit FontString
---@field scanProfit FontString
---@field roi FontString

local FormatMoney = ns.ItemTable.FormatMoney
local FormatSignedMoney = ns.ItemTable.FormatSignedMoney
local SetValueColor = ns.ItemTable.SetValueColor

-- Money columns fit "+9999g 99s": a sign and six digits of about 7 pixels, two coin icons of 14
-- and a space come to about 81 pixels, so 96 leaves slack. The comparison column, when shown,
-- ends at 735 beside the scroll bar. In a row the name starts 18 pixels in, past the icon,
-- and stops 4 pixels short of the sale method at the column's right edge.
local ITEM_WIDTH = 278
local NAME_WIDTH = 211
local SALE_METHOD_X = 233
local SALE_METHOD_WIDTH = 44

local SCAN_PROFIT = {
  key = "scanProfit",
  label = "Profit at Scan Price",
  x = 417,
  width = 145,
  explanation = "Profit with the same material cost, but selling at the lowest scanned buyout after the AH cut, or to a vendor if that pays more. A dash means no sale price is available.",
}

---@type ArbitrageItemTableColumn[]
local COLUMNS = {
  {
    key = "saleProceeds",
    label = "Net Sale",
    x = 287,
    width = 96,
    explanation = "The higher of one item's Auction House proceeds after the 5% cut and its vendor sell value. AH prices use the lowest scanned buyout in Last Scan and Market Value otherwise.",
  },
  {
    key = "craftCost",
    label = "Craft Cost",
    x = 388,
    width = 96,
    explanation = "Estimated cheapest way to make one item, including vendors and intermediate crafts. AH materials use Market Value in Typical and the lowest scanned buyouts otherwise.",
  },
  {
    key = "profit",
    label = "Profit",
    x = 489,
    width = 96,
    explanation = "Net Sale minus Craft Cost, per item, using the selected view's prices.",
  },
  {
    key = "roi",
    label = "ROI",
    x = 590,
    width = 44,
    explanation = "Net Sale minus Craft Cost, divided by Craft Cost, before rounding.",
  },
}

---@type ArbitrageItemTableColumn[]
local SELL_LATER_COLUMNS = {
  {
    key = "craftCost",
    label = "Mats at Last Scan",
    x = 287,
    width = 118,
    explanation = "Cost to make one item using scanned buyouts, vendors, and intermediate crafts. Both profit columns subtract this same cost.",
  },
  SCAN_PROFIT,
  {
    key = "profit",
    label = "Profit at Market Value",
    x = 574,
    width = 161,
    explanation = "Estimated profit using Market Value after the AH cut, or a vendor sale if that pays more. The minimum profit filter uses this column.",
  },
}

local ALL_COLUMNS = { unpack(COLUMNS) }
ALL_COLUMNS[#ALL_COLUMNS + 1] = SCAN_PROFIT

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
  local sellLater = opportunity.mode == "sellLater"
  GameTooltip:AddLine(" ")
  if sellLater then
    GameTooltip:AddDoubleLine("Mats at Last Scan", FormatMoney(opportunity.craftCost))
    if opportunity.scanProfit and opportunity.scanSaleProceeds then
      local label = opportunity.scanSaleMethod == "vendor" and "Vendor" or "AH"
      GameTooltip:AddDoubleLine("Scan Net Sale (" .. label .. ")", FormatMoney(opportunity.scanSaleProceeds))
      GameTooltip:AddDoubleLine("Profit at Scan Price", FormatSignedMoney(opportunity.scanProfit))
    else
      GameTooltip:AddLine("No scanned output price or vendor sale.", 1, 1, 1, true)
    end
    GameTooltip:AddDoubleLine(
      isVendorSale and "Vendor Net Sale" or "Market Value Net Sale",
      FormatMoney(opportunity.saleProceeds)
    )
    GameTooltip:AddDoubleLine(
      isVendorSale and "Vendor Profit" or "Profit at Market Value",
      FormatSignedMoney(opportunity.profit)
    )
    GameTooltip:AddDoubleLine("ROI", math.floor(opportunity.roi * 100 + 0.5) .. "%")
  else
    GameTooltip:AddDoubleLine("Sell to", isVendorSale and "Vendor" or "Auction House")
    GameTooltip:AddDoubleLine("Net Sale", FormatMoney(opportunity.saleProceeds))
    GameTooltip:AddDoubleLine("Craft Cost", FormatMoney(opportunity.craftCost))
    GameTooltip:AddDoubleLine("Profit", FormatSignedMoney(opportunity.profit))
  end
  if opportunity.breakEvenListing then
    -- FormatMoney drops copper above a gold; round up so the suggested listing still breaks even.
    local listing = opportunity.breakEvenListing
    if listing >= 10000 then
      listing = math.ceil(listing / 100) * 100
    end
    GameTooltip:AddDoubleLine("Break-even AH listing", FormatMoney(listing))
  end
  local alternativeLabel, alternativeProceeds = "Vendor", opportunity.vendorSaleProceeds
  if isVendorSale then
    alternativeLabel, alternativeProceeds = "AH", opportunity.auctionSaleProceeds
  end
  if not sellLater and alternativeProceeds then
    GameTooltip:AddDoubleLine(
      alternativeLabel .. " Profit",
      FormatSignedMoney(alternativeProceeds - opportunity.craftCost)
    )
  end

  local perCraft = " per craft"
  if opportunity.outputQuantity > 1 then
    perCraft = perCraft .. " (x" .. opportunity.outputQuantity .. ")"
    GameTooltip:AddDoubleLine("Profit" .. perCraft, FormatSignedMoney(opportunity.perCraft.profit))
  end

  if opportunity.mode == "scan" or opportunity.mode == "sellLater" then
    GameTooltip:AddLine(
      "Scan prices are asking prices. Listings may be gone or too small for one craft.",
      1,
      1,
      1,
      true
    )
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
  local isVendorSale = opportunity.saleMethod == "vendor"
  local sellLater = opportunity.mode == "sellLater"
  row.saleMethod:SetText(isVendorSale and "Vendor" or "AH")
  row.saleMethod:SetShown(not sellLater)
  row.saleProceeds:SetText(FormatMoney(opportunity.saleProceeds))
  row.craftCost:SetText(FormatMoney(opportunity.craftCost))
  row.profit:SetText(FormatSignedMoney(opportunity.profit) .. (sellLater and isVendorSale and " (Vendor)" or ""))
  local scanProfit = "—"
  if opportunity.scanProfit then
    scanProfit = FormatSignedMoney(opportunity.scanProfit)
      .. (opportunity.scanSaleMethod == "vendor" and " (Vendor)" or "")
  end
  row.scanProfit:SetText(scanProfit)

  row.roi:SetText(math.floor(opportunity.roi * 100 + 0.5) .. "%")

  SetValueColor(row.saleProceeds, opportunity.marketIsUncertain)
  SetValueColor(row.craftCost, opportunity.craftCostIsUncertain)
  SetValueColor(row.profit, opportunity.isUncertain)
  SetValueColor(row.scanProfit, opportunity.craftCostIsUncertain)
  SetValueColor(row.roi, opportunity.isUncertain)
end

---@param parent Frame
---@return ArbitrageItemTable
function ns.OpportunityTable.Create(parent)
  local itemTable = ns.ItemTable.Create(parent, {
    itemLabel = "Item",
    itemWidth = ITEM_WIDTH,
    nameWidth = NAME_WIDTH,
    columns = ALL_COLUMNS,
    defaultSortKey = "profit",
    initializeRow = InitializeRow,
    populateRow = PopulateRow,
    addTooltipLines = AddOpportunityTooltipLines,
    replacesItemPricing = true,
  })
  itemTable.SetColumns(COLUMNS)
  return itemTable
end

---@param itemTable ArbitrageItemTable
---@param mode ArbitrageOpportunityMode
function ns.OpportunityTable.SetPricingMode(itemTable, mode)
  itemTable.SetColumns(mode == "sellLater" and SELL_LATER_COLUMNS or COLUMNS)
end

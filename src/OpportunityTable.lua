local _, ns = ...

ns.OpportunityTable = {}

---@class ArbitrageOpportunityRow : Button
---@field arbitrageInitialized boolean?
---@field icon Texture
---@field iconBorder Texture
---@field itemName FontString
---@field source FontString
---@field market FontString
---@field cost FontString
---@field minimumCost FontString
---@field profit FontString
---@field minimumProfit FontString
---@field roi FontString

---@class ArbitrageColumnHeader : Button
---@field Text FontString
---@field Arrow Texture

---@class ArbitrageTableBackground : Frame
---@field layoutType string
---@field Background Texture
---@field NineSlice Frame

---@class ArbitrageOpportunityTable
---@field SetItems fun(newItems: ArbitrageCraftOpportunity[])
---@field SetEmptyMessage fun(message: string?)
---@field HandleItemInfoReceived fun(itemID: number, success: boolean)

local ROW_HEIGHT = 20

---@type { key: string, x: number, width: number }[]
local VALUE_COLUMNS = {
  { key = "market", x = 216, width = 85 },
  { key = "cost", x = 306, width = 85 },
  { key = "minimumCost", x = 396, width = 85 },
  { key = "profit", x = 486, width = 90 },
  { key = "minimumProfit", x = 581, width = 90 },
  { key = "roi", x = 676, width = 55 },
}

---@param value number
---@return string
local function FormatMoney(value)
  return C_CurrencyInfo.GetCoinTextureString(math.floor(value), 12)
end

---@param value number
---@return string
local function FormatSignedMoney(value)
  local sign = value >= 0 and "+" or "-"
  return sign .. FormatMoney(math.abs(value))
end

---@param fontString FontString
---@param isUncertain boolean
local function SetValueColor(fontString, isUncertain)
  local color = isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  fontString:SetTextColor(color:GetRGB())
end

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

---@param parent Frame
---@return ArbitrageOpportunityTable
function ns.OpportunityTable.Create(parent)
  ---@type table<string, ArbitrageColumnHeader>
  local headers = {}
  ---@type ArbitrageCraftOpportunity[]?
  local items
  local requestedItems = {}
  local sortKey = "profit"
  local sortAscending = false

  ---@param opportunity ArbitrageCraftOpportunity
  local function ShowOpportunityTooltip(opportunity)
    GameTooltip:SetOwner(parent, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. opportunity.itemID)
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
    GameTooltip:Show()
  end

  local function HideOpportunityTooltip()
    if GameTooltip:IsOwned(parent) then
      GameTooltip:Hide()
    end
  end

  ---@param opportunity ArbitrageCraftOpportunity
  ---@param key string
  ---@return string|number?
  local function GetSortValue(opportunity, key)
    if key == "item" then
      local itemName = C_Item.GetItemInfo(opportunity.itemID)
      if itemName == nil and not requestedItems[opportunity.itemID] then
        requestedItems[opportunity.itemID] = true
        C_Item.RequestLoadItemDataByID(opportunity.itemID)
      end
      if itemName == nil then
        return nil
      end
      return string.lower(itemName)
    end
    return opportunity[key]
  end

  local function SortItems()
    if not items then
      return
    end

    table.sort(items, function(left, right)
      local leftValue = GetSortValue(left, sortKey)
      local rightValue = GetSortValue(right, sortKey)
      if leftValue == nil or rightValue == nil then
        if leftValue == nil and rightValue == nil then
          return left.itemID < right.itemID
        end
        return leftValue ~= nil
      end
      if leftValue == rightValue then
        return left.itemID < right.itemID
      end
      local valueType = type(leftValue)
      if valueType == type(rightValue) and (valueType == "string" or valueType == "number") then
        ---@diagnostic disable-next-line: invalid-op
        return sortAscending == (leftValue < rightValue)
      end
      return left.itemID < right.itemID
    end)
  end

  local function UpdateHeaderArrows()
    for key, header in pairs(headers) do
      local active = key == sortKey
      header.Arrow:SetShown(active)
      if active then
        if sortAscending then
          header.Arrow:SetTexCoord(0, 1, 1, 0)
        else
          header.Arrow:SetTexCoord(0, 1, 0, 1)
        end
      end
    end
  end

  ---@param row ArbitrageOpportunityRow
  ---@param opportunity ArbitrageCraftOpportunity
  local function PopulateRow(row, opportunity)
    local itemName, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(opportunity.itemID)
    if itemName == nil and not requestedItems[opportunity.itemID] then
      requestedItems[opportunity.itemID] = true
      C_Item.RequestLoadItemDataByID(opportunity.itemID)
    end

    local quantitySuffix = opportunity.outputQuantity > 1 and " (x" .. opportunity.outputQuantity .. ")" or ""
    if itemName == nil then
      itemName = "Item #" .. opportunity.itemID
    end
    row.itemName:SetText(itemName .. quantitySuffix)
    local saleLabel = opportunity.saleMethod == "vendor" and "Vendor" or "AH"
    row.source:SetText(saleLabel .. " - " .. FormatSources(opportunity.sources))
    row.icon:SetTexture(icon)
    row.market:SetText(FormatMoney(opportunity.saleProceeds))
    row.cost:SetText(FormatMoney(opportunity.craftCost))
    row.minimumCost:SetText(opportunity.minimumCraftCost and FormatMoney(opportunity.minimumCraftCost) or "—")
    row.profit:SetText(FormatSignedMoney(opportunity.profit))
    row.minimumProfit:SetText(opportunity.minimumProfit and FormatSignedMoney(opportunity.minimumProfit) or "—")

    row.roi:SetText(math.floor(opportunity.roi * 100 + 0.5) .. "%")

    SetValueColor(row.market, opportunity.marketIsUncertain)
    SetValueColor(row.cost, opportunity.craftCostIsUncertain)
    SetValueColor(row.minimumCost, opportunity.minimumCraftCostIsUncertain)
    SetValueColor(row.profit, opportunity.isUncertain)
    SetValueColor(
      row.minimumProfit,
      opportunity.minimumProfit ~= nil and (opportunity.marketIsUncertain or opportunity.minimumCraftCostIsUncertain)
    )
    SetValueColor(row.roi, opportunity.isUncertain)
  end

  local tableBackground = CreateFrame("Frame", nil, parent)
  ---@cast tableBackground ArbitrageTableBackground
  tableBackground.layoutType = "InsetFrameTemplate"
  tableBackground:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -83)
  tableBackground:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 8)
  tableBackground.Background = tableBackground:CreateTexture(nil, "BACKGROUND")
  tableBackground.Background:SetAtlas("auctionhouse-background-index")
  tableBackground.Background:SetPoint("TOPLEFT", 3, -22)
  tableBackground.Background:SetPoint("BOTTOMRIGHT", -25, 3)
  tableBackground.NineSlice = CreateFrame("Frame", nil, tableBackground, "NineSlicePanelTemplate")
  tableBackground.NineSlice:SetFrameLevel(tableBackground:GetFrameLevel())
  tableBackground.NineSlice:ClearAllPoints()
  tableBackground.NineSlice:SetPoint("TOPLEFT", 0, -19)
  tableBackground.NineSlice:SetPoint("BOTTOMRIGHT", -22, 0)

  local emptyText = tableBackground:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  emptyText:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", 12, -37)
  emptyText:SetPoint("TOPRIGHT", tableBackground, "TOPRIGHT", -15, -37)
  emptyText:SetJustifyH("LEFT")
  emptyText:Hide()

  local scrollBox = CreateFrame("Frame", nil, tableBackground, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", 4, -26)
  scrollBox:SetPoint("BOTTOMRIGHT", tableBackground, "BOTTOMRIGHT", -26, 3)

  ---@param retainScrollPosition boolean
  local function RenderRows(retainScrollPosition)
    if not items then
      return
    end

    local scrollPosition = retainScrollPosition and ScrollBoxConstants.RetainScrollPosition
      or ScrollBoxConstants.DiscardScrollPosition
    scrollBox:SetDataProvider(CreateDataProvider(items), scrollPosition)
  end

  ---@param key string
  local function SetSort(key)
    if sortKey == key then
      sortAscending = not sortAscending
    else
      sortKey = key
      sortAscending = key == "item"
    end

    HideOpportunityTooltip()
    SortItems()
    UpdateHeaderArrows()
    RenderRows(false)
  end

  ---@param row ArbitrageOpportunityRow
  local function InitializeOpportunityRow(row)
    if row.arbitrageInitialized then
      return
    end
    row.arbitrageInitialized = true
    row:SetHeight(ROW_HEIGHT)
    row:SetHighlightAtlas("auctionhouse-ui-row-highlight", "ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", 0, 0)

    row.iconBorder = row:CreateTexture(nil, "OVERLAY")
    row.iconBorder:SetSize(16, 16)
    row.iconBorder:SetPoint("CENTER", row.icon, "CENTER")
    row.iconBorder:SetAtlas("auctionhouse-itemicon-small-border")

    row.itemName = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
    row.itemName:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.itemName:SetWidth(106)
    row.itemName:SetJustifyH("LEFT")
    row.itemName:SetWordWrap(false)
    row.itemName:SetMaxLines(1)

    row.source = row:CreateFontString(nil, "ARTWORK", "Number13FontGray")
    row.source:SetPoint("LEFT", row, "LEFT", 128, 0)
    row.source:SetWidth(84)
    row.source:SetJustifyH("LEFT")
    row.source:SetWordWrap(false)
    row.source:SetMaxLines(1)

    for _, column in ipairs(VALUE_COLUMNS) do
      local value = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
      value:SetPoint("LEFT", row, "LEFT", column.x, 0)
      value:SetWidth(column.width)
      value:SetJustifyH("RIGHT")
      row[column.key] = value
    end

    row:SetScript("OnEnter", function(self)
      local opportunity = self:GetElementData()
      if opportunity then
        ShowOpportunityTooltip(opportunity)
      end
    end)
    row:SetScript("OnLeave", HideOpportunityTooltip)
  end

  ---@param text string
  ---@param key string
  ---@param x number
  ---@param width number
  ---@param explanation string?
  local function CreateColumnHeader(text, key, x, width, explanation)
    local header = CreateFrame("Button", nil, tableBackground, "ColumnDisplayButtonShortTemplate")
    ---@cast header ArbitrageColumnHeader
    header:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", x, -1)
    header:SetSize(width, 19)
    header:SetText(text)
    header.Arrow = header:CreateTexture(nil, "OVERLAY")
    header.Arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
    header.Arrow:SetPoint("LEFT", header.Text, "RIGHT", 3, 0)
    header.Arrow:Hide()
    header:SetScript("OnClick", function()
      SetSort(key)
    end)
    if explanation then
      header:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(text, 1, 1, 1)
        GameTooltip:AddLine(explanation, nil, nil, nil, true)
        GameTooltip:Show()
      end)
      header:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then
          GameTooltip:Hide()
        end
      end)
    end
    headers[key] = header
  end

  CreateColumnHeader("Item / Sale / Crafter", "item", 4, 216)
  CreateColumnHeader(
    "Net Sale",
    "saleProceeds",
    220,
    85,
    "The higher of Auction House proceeds after its cut and vendor sell value for the crafted quantity. The sale method is shown beside the crafter."
  )
  CreateColumnHeader(
    "Craft Cost",
    "craftCost",
    310,
    85,
    "Estimated cheapest way to make the items using rolling Auction House values, unlimited-stock vendors, and intermediate crafts."
  )
  CreateColumnHeader(
    "Best Cost",
    "minimumCraftCost",
    400,
    85,
    "Best-case cost for the same recipe using the cheapest per-unit buyouts from the latest full scan."
  )
  CreateColumnHeader("Est. Profit", "profit", 490, 90, "Net Sale minus Craft Cost.")
  CreateColumnHeader("Best Profit", "minimumProfit", 585, 90, "Net Sale minus Best Cost.")
  CreateColumnHeader(
    "ROI",
    "roi",
    680,
    55,
    "Net Sale minus the unrounded estimated crafting cost, divided by that cost."
  )

  local scrollBar = CreateFrame("EventFrame", nil, tableBackground, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, opportunity)
    InitializeOpportunityRow(row)
    PopulateRow(row, opportunity)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideOpportunityTooltip)

  return {
    SetItems = function(newItems)
      HideOpportunityTooltip()
      items = {}
      for index, item in ipairs(newItems) do
        items[index] = item
      end
      SortItems()
      UpdateHeaderArrows()
      RenderRows(false)
    end,
    SetEmptyMessage = function(message)
      if message then
        emptyText:SetText(message)
        emptyText:Show()
      else
        emptyText:Hide()
      end
    end,
    HandleItemInfoReceived = function(itemID, success)
      if not requestedItems[itemID] then
        return
      end

      requestedItems[itemID] = nil
      if success then
        HideOpportunityTooltip()
        if sortKey == "item" then
          SortItems()
        end
        RenderRows(true)
      end
    end,
  }
end

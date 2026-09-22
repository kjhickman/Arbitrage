local addonName, ns = ...

ns.AuctionHouse = {}

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60

local frame = CreateFrame("Frame")
local panel
local summaryText
local emptyText
local scrollBox
local headers = {}
local result
local requestedItems = {}
local sortKey = "profit"
local sortAscending = false

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

---@param opportunity ArbitrageCraftOpportunity
local function ShowOpportunityTooltip(opportunity)
  GameTooltip:SetOwner(panel, "ANCHOR_RIGHT")
  GameTooltip:SetHyperlink("item:" .. opportunity.itemID)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Estimated profit per craft", FormatSignedMoney(opportunity.profit))
  if opportunity.minimumProfit then
    GameTooltip:AddDoubleLine("Best-case profit per craft", FormatSignedMoney(opportunity.minimumProfit))
  end
  if opportunity.isUncertain then
    GameTooltip:AddLine("Estimate: " .. table.concat(opportunity.reasons, ", "), 1, 0.82, 0)
  end
  GameTooltip:AddLine("Crafted by: " .. FormatSources(opportunity.sources), 1, 1, 1, true)
  GameTooltip:Show()
end

local function HideOpportunityTooltip()
  if GameTooltip:IsOwned(panel) then
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

local function SortResults()
  if not result then
    return
  end

  table.sort(result.items, function(left, right)
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
    if type(leftValue) == "string" and type(rightValue) == "string" then
      if sortAscending then
        return leftValue < rightValue
      end
      return leftValue > rightValue
    end
    if type(leftValue) == "number" and type(rightValue) == "number" then
      if sortAscending then
        return leftValue < rightValue
      end
      return leftValue > rightValue
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

---@param row Button
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
  row.source:SetText(FormatSources(opportunity.sources))
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

local function RenderRows(retainScrollPosition)
  if not result then
    return
  end

  local scrollPosition = retainScrollPosition and ScrollBoxConstants.RetainScrollPosition
    or ScrollBoxConstants.DiscardScrollPosition
  scrollBox:SetDataProvider(CreateDataProvider(result.items), scrollPosition)
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
  SortResults()
  UpdateHeaderArrows()
  RenderRows(false)
end

function ns.AuctionHouse.Refresh()
  if not summaryText then
    return
  end

  HideOpportunityTooltip()
  local status = ns.Database.GetStatus()
  result = ns.Opportunities.Get()
  SortResults()
  UpdateHeaderArrows()
  local profitableCount = #result.items
  local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"
  summaryText:SetText(
    result.totalCount
      .. " known crafts | "
      .. profitableCount
      .. " profitable | Last scan: "
      .. latestScan
      .. " | "
      .. status.recentScanCount
      .. " scans / 14 days"
  )

  if result.totalCount == 0 then
    emptyText:SetText("No known recipes. Open each character's profession window to record learned recipes.")
    emptyText:Show()
  elseif
    profitableCount == 0 and (status.latestScan == nil or status.latestScan < time() - MARKET_VALUE_WINDOW_SECONDS)
  then
    emptyText:SetText("No Auction House scan data. Run a full scan to price known crafts.")
    emptyText:Show()
  elseif result.pricedCount == 0 then
    emptyText:SetText("No known crafts have complete output and material prices.")
    emptyText:Show()
  elseif profitableCount == 0 then
    emptyText:SetText("No known crafts are currently profitable.")
    emptyText:Show()
  else
    emptyText:Hide()
  end

  RenderRows(false)
end

---@param row Button
local function InitializeOpportunityRow(row)
  if row.arbitrageInitialized then
    return
  end
  row.arbitrageInitialized = true
  row:SetScript("OnClick", nil)

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

  row.market = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.market:SetPoint("LEFT", row, "LEFT", 216, 0)
  row.market:SetWidth(85)
  row.market:SetJustifyH("RIGHT")

  row.cost = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.cost:SetPoint("LEFT", row, "LEFT", 306, 0)
  row.cost:SetWidth(85)
  row.cost:SetJustifyH("RIGHT")

  row.minimumCost = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.minimumCost:SetPoint("LEFT", row, "LEFT", 396, 0)
  row.minimumCost:SetWidth(85)
  row.minimumCost:SetJustifyH("RIGHT")

  row.profit = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.profit:SetPoint("LEFT", row, "LEFT", 486, 0)
  row.profit:SetWidth(90)
  row.profit:SetJustifyH("RIGHT")

  row.minimumProfit = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.minimumProfit:SetPoint("LEFT", row, "LEFT", 581, 0)
  row.minimumProfit:SetWidth(90)
  row.minimumProfit:SetJustifyH("RIGHT")

  row.roi = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  row.roi:SetPoint("LEFT", row, "LEFT", 676, 0)
  row.roi:SetWidth(55)
  row.roi:SetJustifyH("RIGHT")

  row:SetScript("OnEnter", function(self)
    self.HighlightTexture:Show()
    local opportunity = self:GetElementData()
    if opportunity then
      ShowOpportunityTooltip(opportunity)
    end
  end)
  row:SetScript("OnLeave", function(self)
    self.HighlightTexture:Hide()
    HideOpportunityTooltip()
  end)
end

---@param parent Frame
---@param text string
---@param x number
---@param width number
local function CreateColumnHeader(parent, text, key, x, width)
  local header = CreateFrame("Button", nil, parent, "AuctionHouseTableHeaderStringTemplate")
  header:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -1)
  header:SetSize(width, 19)
  header:SetText(text)
  header:SetScript("OnClick", function()
    SetSort(key)
  end)
  headers[key] = header
end

local function CreateAuctionHouseTab()
  if panel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  panel = CreateFrame("Frame", addonName .. "AuctionHouseFrame", auctionHouseFrame)
  panel:SetPoint("TOPLEFT", auctionHouseFrame, "TOPLEFT", 4, -69)
  panel:SetPoint("BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -5, 32)
  panel:Hide()
  panel:SetScript("OnShow", ns.AuctionHouse.Refresh)

  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", 20, -18)
  heading:SetText("Craft Opportunities")

  summaryText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  summaryText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -44)
  summaryText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -145, -44)
  summaryText:SetJustifyH("LEFT")

  local uncertaintyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  uncertaintyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  uncertaintyText:SetText("Yellow values are uncertain; more market data is needed.")
  uncertaintyText:SetTextColor(NORMAL_FONT_COLOR:GetRGB())

  local tableBackground = CreateFrame("Frame", nil, panel, "AuctionHouseBackgroundTemplate")
  tableBackground:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -83)
  tableBackground:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -5, 8)
  tableBackground.Background:SetAtlas("auctionhouse-background-index")
  tableBackground.Background:ClearAllPoints()
  tableBackground.Background:SetPoint("TOPLEFT", 3, -22)
  tableBackground.Background:SetPoint("BOTTOMRIGHT", -25, 3)
  tableBackground.NineSlice:ClearAllPoints()
  tableBackground.NineSlice:SetPoint("TOPLEFT", 0, -19)
  tableBackground.NineSlice:SetPoint("BOTTOMRIGHT", -22, 0)

  CreateColumnHeader(tableBackground, "Item / Crafter", "item", 4, 216)
  CreateColumnHeader(tableBackground, "Net Sale", "saleProceeds", 220, 85)
  CreateColumnHeader(tableBackground, "Craft Cost", "craftCost", 310, 85)
  CreateColumnHeader(tableBackground, "Min Cost", "minimumCraftCost", 400, 85)
  CreateColumnHeader(tableBackground, "Est. Profit", "profit", 490, 90)
  CreateColumnHeader(tableBackground, "Best Profit", "minimumProfit", 585, 90)
  CreateColumnHeader(tableBackground, "ROI", "roi", 680, 55)

  emptyText = tableBackground:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  emptyText:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", 12, -37)
  emptyText:SetPoint("TOPRIGHT", tableBackground, "TOPRIGHT", -15, -37)
  emptyText:SetJustifyH("LEFT")
  emptyText:Hide()

  scrollBox = CreateFrame("Frame", nil, tableBackground, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", 4, -26)
  scrollBox:SetPoint("BOTTOMRIGHT", tableBackground, "BOTTOMRIGHT", -26, 3)

  local scrollBar = CreateFrame("EventFrame", nil, tableBackground, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

  local view = CreateScrollBoxListLinearView()
  view:SetElementInitializer("AuctionHouseItemListLineTemplate", function(row, opportunity)
    InitializeOpportunityRow(row)
    PopulateRow(row, opportunity)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:GetNormalTexture():SetAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideOpportunityTooltip)

  local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scanButton:SetSize(132, 22)
  scanButton:SetPoint("TOPRIGHT", auctionHouseFrame, "TOPRIGHT", -12, -38)
  scanButton:SetText("Full Scan")
  scanButton:SetScript("OnClick", ns.Scan.Start)

  local settingsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", scanButton, "LEFT", -10, 0)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", ns.Config.OpenOptionsPanel)

  local libStub = rawget(_G, "LibStub")
  local libAHTab = libStub and libStub("LibAHTab-1-0", true)
  if libAHTab then
    libAHTab:CreateTab(addonName, panel, addonName, addonName)
    return
  end

  local tabParent = CreateFrame("Frame", nil, auctionHouseFrame)
  local tab =
    CreateFrame("Button", addonName .. "AuctionHouseTab", tabParent, "AuctionHouseFrameDisplayModeTabTemplate")
  tab:SetText("Arbitrage")
  tab:SetPoint("LEFT", auctionHouseFrame.AuctionsTab, "RIGHT", 3, 0)
  PanelTemplates_TabResize(tab, 20, nil, 70)
  PanelTemplates_DeselectTab(tab)

  hooksecurefunc(auctionHouseFrame, "SetDisplayMode", function(_, displayMode)
    if displayMode and #displayMode > 0 then
      panel:Hide()
      PanelTemplates_DeselectTab(tab)
    end
  end)

  tab:SetScript("OnClick", function()
    auctionHouseFrame:SetDisplayMode({})
    auctionHouseFrame.displayMode = nil
    for _, auctionHouseTab in ipairs(auctionHouseFrame.Tabs) do
      PanelTemplates_DeselectTab(auctionHouseTab)
    end
    PanelTemplates_SelectTab(tab)
    auctionHouseFrame:SetTitle(addonName)
    panel:Show()
  end)
end

function ns.AuctionHouse.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      CreateAuctionHouseTab()
    elseif eventName == "GET_ITEM_INFO_RECEIVED" and requestedItems[itemID] then
      requestedItems[itemID] = nil
      if success then
        HideOpportunityTooltip()
        if sortKey == "item" then
          SortResults()
        end
        RenderRows(true)
      end
    end
  end)
end

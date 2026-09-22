local addonName, ns = ...

ns.AuctionHouse = {}

local MAX_VISIBLE_ROWS = 7
local ROW_HEIGHT = 40
local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60

local frame = CreateFrame("Frame")
local panel
local summaryText
local emptyText
local previousButton
local nextButton
local rows = {}
local result
local scrollOffset = 0
local requestedItems = {}

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

---@param row Button
---@param opportunity ArbitrageCraftOpportunity
local function PopulateRow(row, opportunity)
  row.opportunity = opportunity
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

  local cost = FormatMoney(opportunity.craftCost)
  if opportunity.minimumCraftCost then
    cost = cost .. "\nmin " .. FormatMoney(opportunity.minimumCraftCost)
  end
  row.cost:SetText(cost)

  local profit = FormatSignedMoney(opportunity.profit)
  if opportunity.minimumProfit then
    profit = profit .. "\nbest " .. FormatSignedMoney(opportunity.minimumProfit)
  end
  row.profit:SetText(profit)

  local roi = math.floor(opportunity.roi * 100 + 0.5) .. "%"
  if opportunity.isUncertain then
    roi = roi .. " ?"
  end
  row.roi:SetText(roi)
  row:Show()
end

local function RenderRows()
  if not result then
    return
  end

  local maximumOffset = math.max(0, #result.items - MAX_VISIBLE_ROWS)
  previousButton:SetEnabled(scrollOffset > 0)
  nextButton:SetEnabled(scrollOffset < maximumOffset)
  for rowIndex, row in ipairs(rows) do
    local opportunity = result.items[scrollOffset + rowIndex]
    if opportunity then
      PopulateRow(row, opportunity)
    else
      row.opportunity = nil
      row:Hide()
    end
  end
end

---@param amount number
local function ScrollBy(amount)
  if not result then
    return
  end

  local maximumOffset = math.max(0, #result.items - MAX_VISIBLE_ROWS)
  local nextOffset = math.max(0, math.min(maximumOffset, scrollOffset + amount))
  if nextOffset ~= scrollOffset then
    HideOpportunityTooltip()
    scrollOffset = nextOffset
    RenderRows()
  end
end

function ns.AuctionHouse.Refresh()
  if not summaryText then
    return
  end

  HideOpportunityTooltip()
  local status = ns.Database.GetStatus()
  result = ns.Opportunities.Get()
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

  scrollOffset = 0
  RenderRows()
end

---@param parent Frame
---@param index number
---@return Button
local function CreateOpportunityRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  local topOffset = -104 - ((index - 1) * ROW_HEIGHT)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, topOffset)
  row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -42, topOffset)
  row:SetHeight(ROW_HEIGHT)

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(32, 32)
  row.icon:SetPoint("LEFT", 0, 0)

  row.itemName = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.itemName:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 7, -2)
  row.itemName:SetWidth(215)
  row.itemName:SetJustifyH("LEFT")
  row.itemName:SetWordWrap(false)
  row.itemName:SetMaxLines(1)

  row.source = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 7, 2)
  row.source:SetWidth(215)
  row.source:SetJustifyH("LEFT")
  row.source:SetWordWrap(false)
  row.source:SetMaxLines(1)

  row.market = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.market:SetPoint("LEFT", row, "LEFT", 255, 0)
  row.market:SetWidth(105)
  row.market:SetJustifyH("RIGHT")

  row.cost = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.cost:SetPoint("LEFT", row, "LEFT", 370, 0)
  row.cost:SetWidth(115)
  row.cost:SetJustifyH("RIGHT")

  row.profit = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.profit:SetPoint("LEFT", row, "LEFT", 495, 0)
  row.profit:SetWidth(120)
  row.profit:SetJustifyH("RIGHT")

  row.roi = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.roi:SetPoint("LEFT", row, "LEFT", 625, 0)
  row.roi:SetWidth(55)
  row.roi:SetJustifyH("RIGHT")

  row:SetScript("OnEnter", function(self)
    if self.opportunity then
      ShowOpportunityTooltip(self.opportunity)
    end
  end)
  row:SetScript("OnLeave", HideOpportunityTooltip)
  row:Hide()
  return row
end

---@param parent Frame
---@param text string
---@param x number
---@param width number
local function CreateColumnHeading(parent, text, x, width)
  local heading = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  heading:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -84)
  heading:SetWidth(width)
  heading:SetJustifyH(x == 20 and "LEFT" or "RIGHT")
  heading:SetText(text)
end

local function CreateAuctionHouseTab()
  if panel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  panel = CreateFrame("Frame", addonName .. "AuctionHouseFrame", auctionHouseFrame, "InsetFrameTemplate")
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

  CreateColumnHeading(panel, "ITEM / CRAFTER", 20, 235)
  CreateColumnHeading(panel, "NET SALE", 271, 105)
  CreateColumnHeading(panel, "CRAFT COST", 386, 115)
  CreateColumnHeading(panel, "PROFIT", 511, 120)
  CreateColumnHeading(panel, "ROI", 641, 55)

  emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  emptyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -120)
  emptyText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -120)
  emptyText:SetJustifyH("LEFT")
  emptyText:Hide()

  for index = 1, MAX_VISIBLE_ROWS do
    rows[index] = CreateOpportunityRow(panel, index)
  end

  previousButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  previousButton:SetSize(28, 22)
  previousButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -104)
  previousButton:SetText("^")
  previousButton:SetScript("OnClick", function()
    ScrollBy(-1)
  end)

  nextButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  nextButton:SetSize(28, 22)
  nextButton:SetPoint("TOP", previousButton, "BOTTOM", 0, -4)
  nextButton:SetText("v")
  nextButton:SetScript("OnClick", function()
    ScrollBy(1)
  end)

  panel:EnableMouseWheel(true)
  panel:SetScript("OnMouseWheel", function(_, delta)
    ScrollBy(delta > 0 and -1 or 1)
  end)

  local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scanButton:SetSize(120, 22)
  scanButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)
  scanButton:SetText("Full Scan")
  scanButton:SetScript("OnClick", ns.Scan.Start)

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
        RenderRows()
      end
    end
  end)
end

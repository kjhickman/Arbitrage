local _, ns = ...

ns.ItemDetails = {}

-- A known recipe's costs per item and what to buy for one craft, as the Opportunities tab prices
-- them. A Craft Opportunity is one.
---@class ArbitrageItemDetailsCraft
---@field outputQuantity number
---@field craftCost number?
---@field craftCostIsUncertain boolean?
---@field craftCostIsUnknown boolean? a known recipe makes it, but a material has no price
---@field buyoutCraftCost number?
---@field materials table<number, ArbitrageCraftingLeaf>? what to buy for one item at Craft Cost
---@field buyoutMaterials table<number, ArbitrageCraftingLeaf>? what to buy for one item at Buyout Craft Cost

---@class ArbitrageMaterial
---@field itemID number
---@field name string
---@field quantity number for one craft
---@field cost number copper for one craft
---@field source "Auction House"|"Vendor"

---@class ArbitrageItemDetailsOptions
---@field craftOf fun(item: ArbitrageItemTableItem): ArbitrageItemDetailsCraft? nil when no known recipe makes it
---@field onClose fun()
---@field addToList (fun(item: ArbitrageItemTableItem, count: number))? adds crafts to the shopping list; without it the details have no Add to List
---@field countOnList (fun(item: ArbitrageItemTableItem): number)? crafts of the item already on the list

---@class ArbitrageItemDetails
---@field SetItem fun(item: ArbitrageItemTableItem?) shows the item's details, or hides them for nil
---@field Refresh fun() shows the current item's details again, if they're shown

---@class ArbitrageItemDetailsFrame : Frame, PortraitFrameMixin
---@field CloseButton Button

---@class ArbitrageDetailsHeader
---@field text FontString
---@field note FontString
---@field divider Texture

---@class ArbitrageDetailsRow
---@field icon Texture
---@field label FontString
---@field value FontString

local WIDTH = 300
-- The cards' edges inside the panel's border.
local CARD_LEFT = 10
local CARD_RIGHT = -8
local CARD_PADDING = 10
-- The body keeps room at its right for a scroll bar, as the table does.
local BODY_LEFT = 10
local BODY_RIGHT = -24
local CONTENT_WIDTH = WIDTH - CARD_LEFT + CARD_RIGHT - BODY_LEFT + BODY_RIGHT
local VALUE_WIDTH = 110
local ICON_SIZE = 14
local HEADER_HEIGHT = 18
local ROW_HEIGHT = 17
local SECTION_GAP = 8
local FOOTER_HEIGHT = 22
local MAX_CRAFTS = 999
local LABEL_COLOR = { 0.8, 0.8, 0.8 }
local FormatMoney = ns.ItemTable.FormatMoney
local FormatQuantity = ns.ItemTable.FormatQuantity
local FormatCount = ns.ItemTable.FormatCount
local FormatPercent = ns.ItemTable.FormatPercent
local SetValueColor = ns.ItemTable.SetValueColor
-- Frames from templates with named children need a name of their own.
local createdCount = 0

-- Lists one craft's materials rather than one item's, since a craft is what the player buys for.
-- Buyout prices are what the materials cost right now, so they make the shopping list when known.
---@param craft ArbitrageItemDetailsCraft
---@return string? pricedAt, ArbitrageMaterial[] materials
function ns.ItemDetails.ListMaterials(craft)
  local leaves, pricedAt = craft.buyoutMaterials, "Buyout prices"
  if not leaves then
    leaves, pricedAt = craft.materials, "Market Value"
  end
  if not leaves then
    return nil, {}
  end

  local materials = {}
  for _, leaf in pairs(leaves) do
    local quantity = leaf.quantity * craft.outputQuantity
    materials[#materials + 1] = {
      itemID = leaf.itemID,
      name = C_Item.GetItemInfo(leaf.itemID) or leaf.name or ("Item #" .. leaf.itemID),
      quantity = quantity,
      cost = math.floor(leaf.price * quantity + 0.5),
      source = leaf.source == "vendor" and "Vendor" or "Auction House",
    }
  end
  table.sort(materials, function(left, right)
    return left.name < right.name
  end)
  return pricedAt, materials
end

-- An inset with the Auction House's dark background, built like the table's.
---@param parent Frame
---@return ArbitrageTableBackground
local function CreateCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  ---@cast card ArbitrageTableBackground
  card.layoutType = "InsetFrameTemplate"
  card.Background = card:CreateTexture(nil, "BACKGROUND")
  card.Background:SetAtlas("auctionhouse-background-index")
  card.Background:SetPoint("TOPLEFT", 3, -3)
  card.Background:SetPoint("BOTTOMRIGHT", -3, 3)
  card.NineSlice = CreateFrame("Frame", nil, card, "NineSlicePanelTemplate")
  card.NineSlice:SetFrameLevel(card:GetFrameLevel())
  card.NineSlice:ClearAllPoints()
  card.NineSlice:SetAllPoints()
  return card
end

-- Sits against the right edge of the window or the Auction House, beside the table. It belongs
-- to the tab's content, so it hides with its tab.
---@param parent Frame the tab's content
---@param owner Frame the window the panel sits beside
---@param options ArbitrageItemDetailsOptions
---@return ArbitrageItemDetails
function ns.ItemDetails.Create(parent, owner, options)
  createdCount = createdCount + 1
  local frame = CreateFrame("Frame", "ArbitrageItemDetails" .. createdCount, parent, "PortraitFrameTemplate")
  ---@cast frame ArbitrageItemDetailsFrame
  frame:SetWidth(WIDTH)
  -- The portrait juts a few pixels past the panel's left edge, so a gap keeps it off the window.
  frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 8, 0)
  frame:SetPoint("BOTTOMLEFT", owner, "BOTTOMRIGHT", 8, 0)
  frame:EnableMouse(true)
  frame:Hide()
  frame.CloseButton:SetScript("OnClick", options.onClose)

  local itemIDText = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  itemIDText:SetPoint("TOPLEFT", frame, "TOPLEFT", 64, -32)

  -- The chart hangs from the panel rather than its card, so the card can end just below it.
  local chartCard = CreateCard(frame)
  local chart = ns.PriceChart.Create(chartCard)
  chart.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_LEFT + CARD_PADDING, -88)
  chartCard:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_LEFT, -62)
  chartCard:SetPoint("TOPRIGHT", frame, "TOPRIGHT", CARD_RIGHT, -62)
  chartCard:SetPoint("BOTTOM", chart.frame, "BOTTOM", 0, -8)

  -- Text belongs to the card, so it draws over the card's background.
  local chartHeading = chartCard:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  chartHeading:SetPoint("TOPLEFT", chartCard, "TOPLEFT", CARD_PADDING, -9)
  chartHeading:SetText("Price History")

  local bodyCard = CreateCard(frame)
  bodyCard:SetPoint("TOPLEFT", chartCard, "BOTTOMLEFT", 0, -4)
  bodyCard:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", CARD_RIGHT, 8)

  ---@type ArbitrageItemTableItem?
  local current
  -- The item last shown, so a refresh of the same item keeps the scroll position.
  ---@type string?
  local shownKey

  -- Below the body, for crafts: how many to add to the shopping list. Shift steps by ten.
  local footer, countText
  local craftCount = 1
  if options.addToList then
    footer = CreateFrame("Frame", nil, frame)
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", CARD_LEFT, 8)
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", CARD_RIGHT, 8)
    footer:SetHeight(FOOTER_HEIGHT)
    footer:Hide()

    local label = footer:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("LEFT", footer, "LEFT", 4, 0)
    label:SetText("Crafts")

    local function CreateStepButton(text, step)
      local button = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
      button:SetSize(22, 22)
      button:SetText(text)
      button:SetScript("OnClick", function()
        local amount = IsShiftKeyDown() and step * 10 or step
        craftCount = math.max(1, math.min(MAX_CRAFTS, craftCount + amount))
        countText:SetText(tostring(craftCount))
      end)
      button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(step > 0 and "One more craft" or "One less craft", 1, 1, 1)
        GameTooltip:AddLine("Shift-click for ten.", nil, nil, nil, true)
        GameTooltip:Show()
      end)
      button:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then
          GameTooltip:Hide()
        end
      end)
      return button
    end

    local minus = CreateStepButton("-", -1)
    minus:SetPoint("LEFT", label, "RIGHT", 8, 0)
    countText = footer:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
    countText:SetWidth(32)
    countText:SetJustifyH("CENTER")
    countText:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    countText:SetText(tostring(craftCount))
    local plus = CreateStepButton("+", 1)
    plus:SetPoint("LEFT", countText, "RIGHT", 2, 0)

    local addButton = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
    addButton:SetSize(110, 22)
    addButton:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
    addButton:SetText("Add to List")
    addButton:SetScript("OnClick", function()
      if current then
        options.addToList(current, craftCount)
      end
    end)
  end

  local scrollFrame = CreateFrame("ScrollFrame", nil, bodyCard)
  scrollFrame:SetPoint("TOPLEFT", bodyCard, "TOPLEFT", BODY_LEFT, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", bodyCard, "BOTTOMRIGHT", BODY_RIGHT, 6)
  scrollFrame:EnableMouseWheel(true)
  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(CONTENT_WIDTH, 1)
  scrollFrame:SetScrollChild(content)

  local scrollBar = CreateFrame("EventFrame", nil, bodyCard, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 8, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 8, 0)
  ScrollUtil.InitScrollFrameWithScrollBar(scrollFrame, scrollBar)
  scrollBar:SetHideIfUnscrollable(true)

  ---@type ArbitrageDetailsHeader[]
  local headers = {}
  ---@type ArbitrageDetailsRow[]
  local rows = {}
  local usedHeaders, usedRows = 0, 0
  -- How far down the content the next line starts.
  local y = 0

  -- Starts a section, with an optional note at its right.
  ---@param text string
  ---@param note string?
  local function AddHeader(text, note)
    if y > 0 then
      y = y + SECTION_GAP
    end
    usedHeaders = usedHeaders + 1
    local header = headers[usedHeaders]
    if not header then
      header = {
        text = content:CreateFontString(nil, "ARTWORK", "GameFontNormal"),
        note = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall"),
        divider = content:CreateTexture(nil, "ARTWORK"),
      }
      header.divider:SetHeight(1)
      header.divider:SetColorTexture(1, 0.82, 0, 0.25)
      headers[usedHeaders] = header
    end
    local baseline = -(y + HEADER_HEIGHT - 4)
    header.text:SetPoint("BOTTOMLEFT", content, "TOPLEFT", 0, baseline)
    header.text:SetText(text)
    header.text:Show()
    header.note:SetPoint("BOTTOMRIGHT", content, "TOPRIGHT", 0, baseline)
    header.note:SetText(note or "")
    header.note:Show()
    header.divider:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(y + HEADER_HEIGHT - 1))
    header.divider:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(y + HEADER_HEIGHT - 1))
    header.divider:Show()
    y = y + HEADER_HEIGHT + 2
  end

  -- A value of nil shows a dash.
  ---@param label string
  ---@param value string?
  ---@param isUncertain boolean?
  ---@param icon (number|string)?
  local function AddRow(label, value, isUncertain, icon)
    usedRows = usedRows + 1
    local row = rows[usedRows]
    if not row then
      row = {
        icon = content:CreateTexture(nil, "ARTWORK"),
        label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight"),
        value = content:CreateFontString(nil, "ARTWORK", "Number14FontWhite"),
      }
      row.icon:SetSize(ICON_SIZE, ICON_SIZE)
      row.label:SetJustifyH("LEFT")
      row.label:SetWordWrap(false)
      row.label:SetTextColor(LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3])
      row.value:SetWidth(VALUE_WIDTH)
      row.value:SetJustifyH("RIGHT")
      row.value:SetWordWrap(false)
      rows[usedRows] = row
    end
    local middle = -(y + ROW_HEIGHT / 2)
    local labelX = icon and ICON_SIZE + 4 or 0
    row.icon:SetPoint("LEFT", content, "TOPLEFT", 0, middle)
    row.icon:SetTexture(icon)
    row.icon:SetShown(icon ~= nil)
    row.label:SetPoint("LEFT", content, "TOPLEFT", labelX, middle)
    row.label:SetWidth(CONTENT_WIDTH - VALUE_WIDTH - labelX - 4)
    row.label:SetText(label)
    row.label:Show()
    row.value:SetPoint("RIGHT", content, "TOPRIGHT", 0, middle)
    row.value:SetText(value or "—")
    row.value:Show()
    SetValueColor(row.value, isUncertain == true)
    y = y + ROW_HEIGHT
  end

  local function ClearLines()
    for _, header in ipairs(headers) do
      header.text:Hide()
      header.note:Hide()
      header.divider:Hide()
    end
    for _, row in ipairs(rows) do
      row.icon:Hide()
      row.label:Hide()
      row.value:Hide()
    end
    usedHeaders, usedRows = 0, 0
    y = 0
  end

  ---@param item ArbitrageItemTableItem
  ---@param craft ArbitrageItemDetailsCraft
  local function AddCraft(item, craft)
    AddHeader("Crafting")
    AddRow(
      "Craft Cost",
      craft.craftCostIsUnknown and "?" or craft.craftCost and FormatMoney(craft.craftCost),
      craft.craftCostIsUncertain
    )
    AddRow("Buyout Craft Cost", craft.buyoutCraftCost and FormatMoney(craft.buyoutCraftCost))
    local onList = options.countOnList and options.countOnList(item) or 0
    if onList > 0 then
      AddRow("On Shopping List", onList == 1 and "1 craft" or (FormatCount(onList) .. " crafts"))
    end

    local pricedAt, materials = ns.ItemDetails.ListMaterials(craft)
    if not pricedAt then
      return
    end
    local perCraft = craft.outputQuantity > 1 and " (x" .. craft.outputQuantity .. ")" or ""
    AddHeader("Materials", "Per craft" .. perCraft .. ", at " .. pricedAt)
    for _, material in ipairs(materials) do
      -- The quantity leads, so a long name is cut short rather than it. Auction House is the usual
      -- source, so only vendor materials say where to buy them.
      local source = material.source == "Vendor" and " (Vendor)" or ""
      AddRow(
        FormatQuantity(material.quantity) .. "x " .. material.name .. source,
        FormatMoney(material.cost),
        false,
        C_Item.GetItemIconByID(material.itemID)
      )
    end
  end

  local function Render()
    local item = current
    if not item then
      return
    end
    ClearLines()

    local itemName, _, quality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(item.link or item.itemID)
    -- Like the table, an item still loading takes Common's white. Its icon is known before it loads.
    local _, _, _, qualityColor = C_Item.GetItemQualityColor(quality or 1)
    frame:SetTitle("|c" .. qualityColor .. (itemName or ("Item #" .. item.itemID)) .. "|r")
    frame:SetPortraitToAsset(C_Item.GetItemIconByID(item.itemID))
    itemIDText:SetText("Item ID " .. item.itemID)
    if not itemName then
      C_Item.RequestLoadItemDataByID(item.itemID)
    end

    local dbKey = item.dbKey or tostring(item.itemID)
    local market = ns.RollingMarketValue.Get({ dbKey })
    local lastSeen = ns.Database.GetLastSeen(dbKey)
    chart.SetData(ns.Database.GetDailyValues(dbKey))

    AddHeader("Prices")
    AddRow("Market Value", market and FormatMoney(market.value), market and market.isUncertain)
    local buyout = ns.Database.GetLatestBuyout(dbKey)
    AddRow("Buyout", buyout and FormatMoney(buyout))
    if type(sellPrice) == "number" and sellPrice > 0 then
      AddRow("Vendor Sell Price", FormatMoney(sellPrice))
    end
    local units = ns.Database.GetListed(dbKey)
    AddRow("Listed", units and FormatCount(units))
    AddRow("Last Seen", lastSeen and ns.Time.Since(lastSeen))

    -- TradeSkillMaster's figures, region-wide rather than your realm's, and only with the Companion.
    local averagePrice, saleRate = ns.Database.GetSales(dbKey)
    if averagePrice or saleRate then
      AddHeader("Region Sales", "From TradeSkillMaster")
      AddRow("Sale Rate", saleRate and FormatPercent(saleRate))
      AddRow("Average Sale Price", averagePrice and averagePrice > 0 and FormatMoney(averagePrice) or nil)
    end
    local craft = options.craftOf(item)
    if craft then
      AddCraft(item, craft)
    end

    -- A craft's footer takes room from the body; a new item starts again at one craft.
    content:SetHeight(math.max(y, 1))
    local key = item.itemID .. ":" .. (item.link or "")
    if key ~= shownKey then
      shownKey = key
      scrollFrame:SetVerticalScroll(0)
      if countText then
        craftCount = 1
        countText:SetText(tostring(craftCount))
      end
    end
    if footer then
      footer:SetShown(craft ~= nil)
      if craft then
        bodyCard:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 4)
      else
        bodyCard:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", CARD_RIGHT, 8)
      end
    end
  end

  -- Shown again with its tab or window, its ages and prices may have moved on.
  frame:SetScript("OnShow", Render)

  local events = CreateFrame("Frame")
  events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  events:SetScript("OnEvent", function(_, _, itemID, success)
    if success and current and current.itemID == itemID and frame:IsShown() then
      Render()
    end
  end)

  return {
    SetItem = function(item)
      current = item
      if not item then
        frame:Hide()
      elseif frame:IsShown() then
        Render()
      else
        frame:Show()
      end
    end,
    Refresh = function()
      if frame:IsShown() then
        Render()
      end
    end,
  }
end

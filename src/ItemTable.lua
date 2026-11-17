local _, ns = ...

ns.ItemTable = {}

---@class ArbitrageItemTableRow : Button
---@field arbitrageInitialized boolean?
---@field icon Texture
---@field iconBorder Texture
---@field itemName FontString

---@class ArbitrageColumnHeader : Button
---@field Text FontString
---@field Arrow Texture

---@class ArbitrageTableBackground : Frame
---@field layoutType string
---@field Background Texture
---@field NineSlice Frame

-- Every listed item needs an itemID. A link, when present, names a specific variant such as a
-- random suffix and is used for item info, tooltips, and to order variants of the same item.
---@class ArbitrageItemTableItem
---@field itemID number
---@field link string?

---@class ArbitrageItemTableColumn
---@field key string item field the column sorts by
---@field cell string row field holding the column's right-aligned value
---@field label string
---@field x number header offset; the value sits 4 pixels further left so it lines up under the label
---@field width number
---@field explanation string?

---@class ArbitrageItemTableOptions
---@field itemLabel string
---@field itemWidth number
---@field nameWidth number
---@field columns ArbitrageItemTableColumn[]
---@field defaultSortKey string
---@field initializeRow fun(row: ArbitrageItemTableRow)?
---@field populateRow fun(row: ArbitrageItemTableRow, item: ArbitrageItemTableItem, itemName: string)
---@field addTooltipLines fun(item: ArbitrageItemTableItem)?

---@class ArbitrageItemTable
---@field SetItems fun(newItems: ArbitrageItemTableItem[], retainScrollPosition: boolean?)
---@field SetEmptyMessage fun(message: string?)
---@field HandleItemInfoReceived fun(itemID: number, success: boolean)

local ROW_HEIGHT = 20

---@param value number
---@return string
function ns.ItemTable.FormatMoney(value)
  return C_CurrencyInfo.GetCoinTextureString(math.floor(value), 12)
end

---@param value number
---@return string
function ns.ItemTable.FormatSignedMoney(value)
  local sign = value >= 0 and "+" or "-"
  return sign .. ns.ItemTable.FormatMoney(math.abs(value))
end

---@param fontString FontString
---@param isUncertain boolean
function ns.ItemTable.SetValueColor(fontString, isUncertain)
  local color = isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  fontString:SetTextColor(color:GetRGB())
end

---@param item ArbitrageItemTableItem
---@return string
local function GetLink(item)
  return item.link or ("item:" .. item.itemID)
end

---@param parent Frame
---@param options ArbitrageItemTableOptions
---@return ArbitrageItemTable
function ns.ItemTable.Create(parent, options)
  ---@type table<string, ArbitrageColumnHeader>
  local headers = {}
  ---@type ArbitrageItemTableItem[]?
  local items
  local requestedItems = {}
  local sortKey = options.defaultSortKey
  local sortAscending = false

  ---@param item ArbitrageItemTableItem
  local function ShowItemTooltip(item)
    GameTooltip:SetOwner(parent, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(GetLink(item))
    if options.addTooltipLines then
      options.addTooltipLines(item)
    end
    GameTooltip:Show()
  end

  local function HideItemTooltip()
    if GameTooltip:IsOwned(parent) then
      GameTooltip:Hide()
    end
  end

  ---@param item ArbitrageItemTableItem
  ---@return string|number?
  local function GetSortValue(item)
    if sortKey == "item" then
      local itemName = C_Item.GetItemInfo(item.link or item.itemID)
      return itemName and string.lower(itemName)
    end
    return item[sortKey]
  end

  ---@param left ArbitrageItemTableItem
  ---@param right ArbitrageItemTableItem
  ---@return boolean
  local function IdentityBefore(left, right)
    if left.itemID ~= right.itemID then
      return left.itemID < right.itemID
    end
    return GetLink(left) < GetLink(right)
  end

  local function SortItems()
    if not items then
      return
    end

    -- Read each value once; a name sort would otherwise look items up on every comparison.
    local values = {}
    for _, item in ipairs(items) do
      values[item] = GetSortValue(item)
    end

    table.sort(items, function(left, right)
      local leftValue = values[left]
      local rightValue = values[right]
      if leftValue == nil or rightValue == nil then
        if leftValue == nil and rightValue == nil then
          return IdentityBefore(left, right)
        end
        return leftValue ~= nil
      end
      if leftValue == rightValue then
        return IdentityBefore(left, right)
      end
      local valueType = type(leftValue)
      if valueType == type(rightValue) and (valueType == "string" or valueType == "number") then
        ---@diagnostic disable-next-line: invalid-op
        return sortAscending == (leftValue < rightValue)
      end
      return IdentityBefore(left, right)
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

  ---@param row ArbitrageItemTableRow
  ---@param item ArbitrageItemTableItem
  local function PopulateRow(row, item)
    -- Only visible rows ask for missing item data, so a long list does not request it all at once.
    local itemName, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(item.link or item.itemID)
    if itemName == nil and not requestedItems[item.itemID] then
      requestedItems[item.itemID] = true
      C_Item.RequestLoadItemDataByID(item.itemID)
    end
    row.icon:SetTexture(icon)
    options.populateRow(row, item, itemName or ("Item #" .. item.itemID))
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

    HideItemTooltip()
    SortItems()
    UpdateHeaderArrows()
    RenderRows(false)
  end

  ---@param row ArbitrageItemTableRow
  local function InitializeRow(row)
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
    row.itemName:SetWidth(options.nameWidth)
    row.itemName:SetJustifyH("LEFT")
    row.itemName:SetWordWrap(false)
    row.itemName:SetMaxLines(1)

    if options.initializeRow then
      options.initializeRow(row)
    end

    for _, column in ipairs(options.columns) do
      local value = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
      value:SetPoint("LEFT", row, "LEFT", column.x - 4, 0)
      value:SetWidth(column.width)
      value:SetJustifyH("RIGHT")
      row[column.cell] = value
    end

    row:SetScript("OnEnter", function(self)
      local item = self:GetElementData()
      if item then
        ShowItemTooltip(item)
      end
    end)
    row:SetScript("OnLeave", HideItemTooltip)
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

  CreateColumnHeader(options.itemLabel, "item", 4, options.itemWidth)
  for _, column in ipairs(options.columns) do
    CreateColumnHeader(column.label, column.key, column.x, column.width, column.explanation)
  end

  local scrollBar = CreateFrame("EventFrame", nil, tableBackground, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, item)
    InitializeRow(row)
    PopulateRow(row, item)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideItemTooltip)

  return {
    SetItems = function(newItems, retainScrollPosition)
      HideItemTooltip()
      items = {}
      for index, item in ipairs(newItems) do
        items[index] = item
      end
      SortItems()
      UpdateHeaderArrows()
      RenderRows(retainScrollPosition == true)
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
        HideItemTooltip()
        if sortKey == "item" then
          SortItems()
        end
        RenderRows(true)
      end
    end,
  }
end

local _, ns = ...

ns.ItemTable = {}

---@class ArbitrageItemTableRow : Button
---@field arbitrageInitialized boolean?
---@field arbitrageColumns ArbitrageItemTableColumn[]?
---@field item ArbitrageItemTableItem? the item the row shows
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
---@field key string item field the column sorts by, and the row field holding its value
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
---@field replacesItemPricing boolean? addTooltipLines prices the item, so Arbitrage's item-tooltip pricing is left out

---@class ArbitrageItemTable
---@field frame Frame
---@field SetItems fun(newItems: ArbitrageItemTableItem[], retainScrollPosition: boolean?, filter: (fun(item: ArbitrageItemTableItem): boolean)?): number
---@field SetColumns fun(columns: ArbitrageItemTableColumn[]) new layout for existing keys; applies to rows on the next SetItems
---@field SetEmptyMessage fun(message: string?)
---@field HandleItemInfoReceived fun(itemID: number, success: boolean)

local ROW_HEIGHT = 20
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

-- Once a larger coin shows, every smaller one follows with two digits, so a price's length
-- depends only on its gold digits and right-aligned columns line up: 9c, 1s 05c, 12g 05s.
-- From 1 gold up copper is dropped: it is noise beside the gold and costs the columns room.
---@param value number copper; never negative
---@return string
function ns.ItemTable.FormatMoney(value)
  local copper = math.floor(value)
  local gold = math.floor(copper / 10000)
  local silver = math.floor(copper / 100) % 100
  copper = copper % 100
  if gold > 0 then
    return string.format("%d%s %02d%s", gold, GOLD_ICON, silver, SILVER_ICON)
  end
  if silver > 0 then
    return string.format("%d%s %02d%s", silver, SILVER_ICON, copper, COPPER_ICON)
  end
  return copper .. COPPER_ICON
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
  local columns = options.columns
  local columnsByKey = {}
  for _, column in ipairs(columns) do
    columnsByKey[column.key] = column
  end
  -- The caller's items, a sorted copy kept until they or the sort change, and the shown subset.
  -- Filtering a sorted list keeps its order, so a new filter or search does not sort again.
  ---@type ArbitrageItemTableItem[]?
  local source
  ---@type ArbitrageItemTableItem[]?
  local sorted
  ---@type (fun(item: ArbitrageItemTableItem): boolean)?
  local filter
  ---@type ArbitrageItemTableItem[]
  local items = {}
  local requestedItems = {}
  local sortKey = options.defaultSortKey
  local sortAscending = false
  -- Row tooltips belong to the parent, and Tooltip.lua adds no pricing to tooltips whose owner
  -- carries this flag, so the item's own lines don't repeat the table's in other units.
  parent.arbitrageReplacesItemPricing = options.replacesItemPricing

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

  ---@param list ArbitrageItemTableItem[]
  local function SortItems(list)
    -- Read each value once; a name sort would otherwise look items up on every comparison.
    local values = {}
    for _, item in ipairs(list) do
      values[item] = GetSortValue(item)
    end

    table.sort(list, function(left, right)
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
      return sortAscending == (leftValue < rightValue)
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
    row.item = item
    -- Only visible rows ask for missing item data, so a long list does not request it all at once.
    local itemName, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(item.link or item.itemID)
    if itemName == nil and not requestedItems[item.itemID] then
      requestedItems[item.itemID] = true
      C_Item.RequestLoadItemDataByID(item.itemID)
    end
    row.icon:SetTexture(icon)
    options.populateRow(row, item, itemName or ("Item #" .. item.itemID))
    if row.arbitrageColumns ~= columns then
      row.arbitrageColumns = columns
      for _, base in ipairs(options.columns) do
        local column = columnsByKey[base.key]
        local value = row[base.key]
        value:SetShown(column ~= nil)
        if column then
          value:SetPoint("LEFT", row, "LEFT", column.x - 4, 0)
          value:SetWidth(column.width)
        end
      end
    end
    -- Rows are reused, so an item still loading takes Common's white rather than keeping a color.
    local red, green, blue = C_Item.GetItemQualityColor(quality or 1)
    row.itemName:SetTextColor(red, green, blue)
  end

  local tableBackground = CreateFrame("Frame", nil, parent)
  ---@cast tableBackground ArbitrageTableBackground
  tableBackground.layoutType = "InsetFrameTemplate"
  -- The panel's title shares the control row above the panel, so the table starts at its top.
  tableBackground:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -4)
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
    if not source then
      return
    end

    if not sorted then
      sorted = {}
      for index, item in ipairs(source) do
        sorted[index] = item
      end
      SortItems(sorted)
    end
    if filter then
      items = {}
      for _, item in ipairs(sorted) do
        if filter(item) then
          items[#items + 1] = item
        end
      end
    else
      items = sorted
    end

    local scrollPosition = retainScrollPosition and ScrollBoxConstants.RetainScrollPosition
      or ScrollBoxConstants.DiscardScrollPosition
    -- Rows look items up by position, so the list costs the same however many items it holds.
    scrollBox:SetDataProvider(CreateIndexRangeDataProvider(#items), scrollPosition)
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
    sorted = nil
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
      value:SetJustifyH("RIGHT")
      -- A value too wide for its column truncates rather than spilling onto the next row.
      value:SetWordWrap(false)
      value:SetMaxLines(1)
      row[column.key] = value
    end

    row:SetScript("OnEnter", function(self)
      if self.item then
        ShowItemTooltip(self.item)
      end
    end)
    row:SetScript("OnLeave", HideItemTooltip)
    -- Modified clicks act like they do on any item, such as Shift to link it in chat. Chat needs
    -- the full hyperlink, which only a loaded item has; a visible row has already requested it.
    row:SetScript("OnClick", function(self)
      if self.item then
        local _, link = C_Item.GetItemInfo(self.item.link or self.item.itemID)
        HandleModifiedItemClick(link)
      end
    end)
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
        local column = columnsByKey[key]
        if not column or not column.explanation then
          return
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(column.label, 1, 1, 1)
        GameTooltip:AddLine(column.explanation, nil, nil, nil, true)
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
  view:SetElementInitializer("Button", function(row, index)
    InitializeRow(row)
    PopulateRow(row, items[index])
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideItemTooltip)

  return {
    frame = tableBackground,
    SetColumns = function(layout)
      if columns == layout then
        return
      end
      columns = layout
      columnsByKey = {}
      for _, column in ipairs(columns) do
        columnsByKey[column.key] = column
      end
      for _, base in ipairs(options.columns) do
        local key = base.key
        local header = headers[key]
        local column = columnsByKey[key]
        if GameTooltip:IsOwned(header) then
          GameTooltip:Hide()
        end
        header:SetShown(column ~= nil)
        if column then
          header:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", column.x, -1)
          header:SetWidth(column.width)
          header:SetText(column.label)
        end
      end
      if sortKey ~= "item" and not columnsByKey[sortKey] then
        sortKey = options.defaultSortKey
        sortAscending = false
        sorted = nil
      end
    end,
    -- Shows the items passing the filter, if any, and returns how many there are.
    SetItems = function(newItems, retainScrollPosition, newFilter)
      HideItemTooltip()
      if newItems ~= source then
        source = newItems
        sorted = nil
      end
      filter = newFilter
      UpdateHeaderArrows()
      RenderRows(retainScrollPosition == true)
      return #items
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
          sorted = nil
          RenderRows(true)
        else
          scrollBox:ForEachFrame(function(row)
            PopulateRow(row, row.item)
          end)
        end
      end
    end,
  }
end

local _, ns = ...

ns.ItemTable = {}

---@class ArbitrageItemTableRow : Button
---@field arbitrageInitialized boolean?
---@field item ArbitrageItemTableItem? the item the row shows
---@field icon Texture
---@field iconBorder Texture
---@field itemName FontString
---@field selectedHighlight Texture

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
---@field dbKey string? the item's price database key, when it isn't its item ID

---@class ArbitrageItemTableColumn
---@field key string names the column, and the row field holding its value
---@field field (string|number)? the item field it sorts by, when it isn't the key
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
---@field onSelect fun(item: ArbitrageItemTableItem?)? called when the selection changes, and with the selected item's copy when new items replace it
---@field contextMenu fun(item: ArbitrageItemTableItem, rootDescription: table)? fills the menu a right-click on a row opens
---@field profileName string what /arb profile times the table's sorting, filtering, and drawing under
---@field identityOrdered boolean? items arrive ordered by item ID, then variant, so their order breaks ties without sorting them by identity
---@field sortName (fun(item: ArbitrageItemTableItem): string?)? the lowercase name the Item column sorts by, when the items keep one

---@class ArbitrageItemTable
---@field frame Frame
---@field SetItems fun(newItems: ArbitrageItemTableItem[], retainScrollPosition: boolean?, filter: (fun(item: ArbitrageItemTableItem): boolean)?): number
---@field SetEmptyMessage fun(message: string?)
---@field HandleItemInfoReceived fun(itemID: number, success: boolean)
---@field Select fun(item: ArbitrageItemTableItem?)
---@field Release fun() empties the table and lets go of its items, keeping the selection for the next ones

local ROW_HEIGHT = 20
-- Lua numbers hold integers exactly up to 2^53.
local MAX_EXACT = 2 ^ 53
-- Names carry their rank as seven digits, so a table sorts up to this many items by name that way.
local NAME_RANKS = 10000000
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

-- Material quantities per craft can be fractional, like 2.5 ore for a recipe that makes two.
---@param quantity number
---@return string
function ns.ItemTable.FormatQuantity(quantity)
  if quantity == math.floor(quantity) then
    return tostring(quantity)
  end

  local formatted = string.format("%.2f", quantity)
  return (formatted:gsub("0+$", ""):gsub("%.$", ""))
end

-- A whole count with thousands separators, such as 12,795.
---@param count number
---@return string
function ns.ItemTable.FormatCount(count)
  local text = tostring(math.floor(count + 0.5))
  local grouped
  repeat
    text, grouped = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until grouped == 0
  return text
end

-- A share as a whole percent. One above zero that rounds to none reads as under 1%.
---@param share number from 0 to 1
---@return string
function ns.ItemTable.FormatPercent(share)
  local percent = math.floor(share * 100 + 0.5)
  if percent == 0 and share > 0 then
    return "<1%"
  end
  return percent .. "%"
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
  -- The caller's items, a sorted copy kept until they or the sort change, and the shown subset.
  -- Filtering a sorted list keeps its order, so a new filter or search does not sort again.
  ---@type ArbitrageItemTableItem[]?
  local source
  ---@type ArbitrageItemTableItem[]?
  local sorted
  -- The caller's items in identity order, by item ID and then link, kept until they change. Items
  -- that sort alike keep this order, and their place in it is their rank.
  ---@type ArbitrageItemTableItem[]?
  local byRank
  ---@type (fun(item: ArbitrageItemTableItem): boolean)?
  local filter
  ---@type ArbitrageItemTableItem[]
  local items = {}
  local requestedItems = {}
  local sortKey = options.defaultSortKey
  local sortAscending = false
  -- The item whose details are open. Lists are rebuilt with new copies of their items, so it is
  -- matched by identity rather than by reference.
  ---@type ArbitrageItemTableItem?
  local selected
  -- Row tooltips belong to the parent, and Tooltip.lua adds no pricing to tooltips whose owner
  -- carries this flag, so the item's own lines don't repeat the table's in other units.
  parent.arbitrageReplacesItemPricing = options.replacesItemPricing
  ---@type table<string, string|number>
  local sortFields = {}
  for _, column in ipairs(options.columns) do
    sortFields[column.key] = column.field or column.key
  end

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
      if options.sortName then
        return options.sortName(item)
      end
      local itemName = C_Item.GetItemInfo(item.link or item.itemID)
      return itemName and string.lower(itemName)
    end
    return item[sortFields[sortKey]]
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

  ---@param left ArbitrageItemTableItem
  ---@param right ArbitrageItemTableItem
  ---@return boolean
  local function IsSameItem(left, right)
    return left.itemID == right.itemID and GetLink(left) == GetLink(right)
  end

  ---@param row ArbitrageItemTableRow
  local function ShowSelection(row)
    row.selectedHighlight:SetShown(selected ~= nil and row.item ~= nil and IsSameItem(row.item, selected))
  end

  ---@return ArbitrageItemTableItem[]
  local function RankItems()
    if options.identityOrdered then
      return source
    end
    local ranked = {}
    for index, item in ipairs(source) do
      ranked[index] = item
    end
    table.sort(ranked, IdentityBefore)
    return ranked
  end

  -- Sorts by the sort column's value, items without one last, and items that sort alike in rank
  -- order. Lua sorts numbers and strings several times faster without a comparator to call, so
  -- each value is packed with its rank into one number, or names into one string, whose order is
  -- the one wanted. Values that don't pack exactly, such as fractions, take a comparator instead.
  ---@return ArbitrageItemTableItem[]
  local function SortItems()
    byRank = byRank or RankItems()
    local count = #byRank
    -- Read each value once; a name sort would otherwise look items up on every comparison.
    local values, missing = {}, {}
    local valueType
    for rank = 1, count do
      local value = GetSortValue(byRank[rank])
      if value == nil then
        missing[#missing + 1] = rank
      else
        values[rank] = value
        if valueType == nil then
          valueType = type(value)
        elseif valueType ~= type(value) then
          valueType = "mixed"
        end
      end
    end

    -- A power of two past the last rank, so a packed number's rank is its remainder.
    local scale = 2
    while scale <= count do
      scale = scale * 2
    end
    local limit = MAX_EXACT / scale - 1
    local packs = valueType == "number" or (valueType == "string" and count < NAME_RANKS)
    if valueType == "number" then
      for rank = 1, count do
        local value = values[rank]
        if value and (value ~= math.floor(value) or value >= limit or value <= -limit) then
          packs = false
          break
        end
      end
    end

    local ranks = {}
    if packs and valueType == "number" then
      local keys, sign = {}, sortAscending and 1 or -1
      for rank = 1, count do
        local value = values[rank]
        if value then
          keys[#keys + 1] = sign * value * scale + rank
        end
      end
      table.sort(keys)
      for index, key in ipairs(keys) do
        ranks[index] = key % scale
      end
    elseif packs then
      -- Sorted ascending and read back in reverse for a descending sort, so a tie's ranks are
      -- written in reverse for it too.
      local keys = {}
      for rank = 1, count do
        local value = values[rank]
        if value then
          keys[#keys + 1] = value .. "\1" .. string.format("%07d", sortAscending and rank or NAME_RANKS - rank)
        end
      end
      table.sort(keys)
      local total = #keys
      for index = 1, total do
        local key = keys[sortAscending and index or total + 1 - index]
        local written = tonumber(key:sub(-7))
        ranks[index] = sortAscending and written or NAME_RANKS - written
      end
    else
      for rank = 1, count do
        if values[rank] ~= nil then
          ranks[#ranks + 1] = rank
        end
      end
      table.sort(ranks, function(left, right)
        local leftValue, rightValue = values[left], values[right]
        if leftValue == rightValue then
          return left < right
        end
        return sortAscending == (leftValue < rightValue)
      end)
    end

    local list = {}
    for index, rank in ipairs(ranks) do
      list[index] = byRank[rank]
    end
    for _, rank in ipairs(missing) do
      list[#list + 1] = byRank[rank]
    end
    return list
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

  -- The name, quality, and icon each item last showed with. While thousands of items load, the
  -- client can briefly have no data for one it already showed, and a redraw then would flash its
  -- ID in place of its name.
  ---@type table<ArbitrageItemTableItem, { name: string, quality: number?, icon: number|string? }>
  local shownInfo = setmetatable({}, { __mode = "k" })

  ---@param row ArbitrageItemTableRow
  ---@param item ArbitrageItemTableItem
  local function PopulateRow(row, item)
    row.item = item
    ShowSelection(row)
    local itemName, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(item.link or item.itemID)
    if itemName then
      shownInfo[item] = { name = itemName, quality = quality, icon = icon }
    else
      -- Only visible rows ask for missing item data, so a long list does not request it all at once.
      if not requestedItems[item.itemID] then
        requestedItems[item.itemID] = true
        C_Item.RequestLoadItemDataByID(item.itemID)
      end
      local shown = shownInfo[item]
      if shown then
        itemName, quality, icon = shown.name, shown.quality, shown.icon
      end
    end
    row.icon:SetTexture(icon)
    options.populateRow(row, item, itemName or ("Item #" .. item.itemID))
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

  ---@param left ArbitrageItemTableItem[]
  ---@param right ArbitrageItemTableItem[]
  ---@return boolean
  local function SameItems(left, right)
    if left == right then
      return true
    end
    if #left ~= #right then
      return false
    end
    for index = 1, #left do
      if left[index] ~= right[index] then
        return false
      end
    end
    return true
  end

  ---@param retainScrollPosition boolean
  local function RenderRows(retainScrollPosition)
    if not source then
      return
    end

    local job = options.profileName
    ns.Profile.Start(job, sorted and "Filtering" or "Sorting")
    ns.Profile.Size(job, #source, "rows")
    local shownItems = items
    if not sorted then
      sorted = SortItems()
      ns.Profile.Stage(job, "Filtering")
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

    -- Redrawing replaces every row on screen, which makes the list blink in game, and refreshes
    -- while items load in the background often leave the list as it was.
    if retainScrollPosition and SameItems(shownItems, items) then
      ns.Profile.Finish(job)
      return
    end

    ns.Profile.Stage(job, "Drawing")
    HideItemTooltip()
    local scrollPosition = retainScrollPosition and ScrollBoxConstants.RetainScrollPosition
      or ScrollBoxConstants.DiscardScrollPosition
    -- Rows look items up by position, so the list costs the same however many items it holds.
    scrollBox:SetDataProvider(CreateIndexRangeDataProvider(#items), scrollPosition)
    ns.Profile.Finish(job)
  end

  ---@param item ArbitrageItemTableItem?
  local function Select(item)
    selected = item
    scrollBox:ForEachFrame(ShowSelection)
    if options.onSelect then
      options.onSelect(item)
    end
  end

  -- New items carry the selected item's latest prices, so the selection moves to its copy, or
  -- clears when the item is gone. Items a search or filter hides stay selected.
  ---@return boolean changed
  local function FollowSelection()
    if not selected or not source then
      return false
    end
    for _, item in ipairs(source) do
      if IsSameItem(item, selected) then
        local changed = item ~= selected
        selected = item
        return changed
      end
    end
    selected = nil
    return true
  end

  ---@param key string
  local function SetSort(key)
    if sortKey == key then
      sortAscending = not sortAscending
    else
      sortKey = key
      sortAscending = key == "item"
    end

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
    -- Marks the row whose details are open, as the Auction House marks its selected row.
    row.selectedHighlight = row:CreateTexture(nil, "OVERLAY")
    row.selectedHighlight:SetAtlas("auctionhouse-ui-row-select")
    row.selectedHighlight:SetBlendMode("ADD")
    row.selectedHighlight:SetAllPoints()
    row.selectedHighlight:Hide()

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
    if options.contextMenu then
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    -- A click opens the item's details, and another on the same row closes them. Modified clicks
    -- act like they do on any item instead, such as Shift to link it in chat. Chat needs the full
    -- hyperlink, which only a loaded item has; a visible row has already requested it. A right-click
    -- opens the table's menu for the row, when it has one.
    row:SetScript("OnClick", function(self, button)
      local item = self.item
      if not item then
        return
      end
      if button == "RightButton" then
        if options.contextMenu then
          MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            options.contextMenu(item, rootDescription)
          end)
        end
      elseif IsModifierKeyDown() then
        local _, link = C_Item.GetItemInfo(item.link or item.itemID)
        HandleModifiedItemClick(link)
      elseif selected and IsSameItem(item, selected) then
        Select(nil)
      else
        Select(item)
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
    -- Shows the items passing the filter, if any, and returns how many there are.
    SetItems = function(newItems, retainScrollPosition, newFilter)
      local selectionChanged = false
      if newItems ~= source then
        source = newItems
        sorted, byRank = nil, nil
        selectionChanged = FollowSelection()
      end
      filter = newFilter
      UpdateHeaderArrows()
      RenderRows(retainScrollPosition == true)
      if selectionChanged and options.onSelect then
        options.onSelect(selected)
      end
      return #items
    end,
    Release = function()
      HideItemTooltip()
      source, sorted, byRank, filter = nil, nil, nil, nil
      items = {}
      scrollBox:SetDataProvider(CreateIndexRangeDataProvider(0), ScrollBoxConstants.DiscardScrollPosition)
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
    Select = Select,
  }
end

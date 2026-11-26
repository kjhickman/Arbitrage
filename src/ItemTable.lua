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
---@field ResizeHandle ArbitrageResizeHandle? on every header but the Item column's

-- The strip over the gap before a column's header; dragging it resizes the column.
---@class ArbitrageResizeHandle : Frame
---@field Grip Frame the sideways arrows that show while the handle is hovered or dragged

---@class ArbitrageTableBackground : Frame
---@field layoutType string
---@field Background Texture
---@field NineSlice Frame

-- Blizzard's NumericInputSpinnerMixin, on its NumericInputSpinnerTemplate.
---@class ArbitrageCountSpinner : EditBox
---@field IncrementButton Button
---@field DecrementButton Button
---@field MouseWheelCatcher Frame
---@field SetValue fun(self: ArbitrageCountSpinner, value: number)
---@field GetValue fun(self: ArbitrageCountSpinner): number
---@field SetMinMaxValues fun(self: ArbitrageCountSpinner, min: number, max: number)
---@field EndIncrement fun(self: ArbitrageCountSpinner)
---@field EndDecrement fun(self: ArbitrageCountSpinner)

-- Every listed item needs an itemID. A link, when present, names a specific variant such as a
-- random suffix and is used for item info, tooltips, and to order variants of the same item.
---@class ArbitrageItemTableItem
---@field itemID number
---@field link string?
---@field dbKey string? the item's price database key, when it isn't its item ID

-- A column's cell shows what format returns for the row's item: its text, or nil for a dash, then
-- whether the value is uncertain, which shows yellow, or muted, which shows gray.
---@class ArbitrageItemTableColumn
---@field key string names the column, the row field holding its cell, and its place in a saved layout
---@field field (string|number)? the item field it sorts by, when it isn't the key
---@field label string
---@field width number its width until it's resized
---@field explanation string?
---@field hidden boolean? left out until chosen from the column menu
---@field unavailable boolean? left out of the table and its menu, such as Sale Rate without the Companion's sales
---@field format fun(item: ArbitrageItemTableItem): string?, boolean?, boolean?

---@class ArbitrageItemTableOptions
---@field itemLabel string
---@field minItemWidth number the Item column never gets narrower, so a column that would make it doesn't fit
---@field columns ArbitrageItemTableColumn[] left to right, as they show by default
---@field layoutKey ArbitrageColumnLayoutKey the config key that keeps the columns' layout and sort; tables with the same key share the columns
---@field defaultSortKey string
---@field initializeRow fun(row: ArbitrageItemTableRow)?
---@field layoutItem fun(row: ArbitrageItemTableRow, itemWidth: number)? places the rest of what a row's Item column holds, whenever the column's width changes; the name is first made as wide as the column allows
---@field populateRow fun(row: ArbitrageItemTableRow, item: ArbitrageItemTableItem, itemName: string) fills the row's Item column
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

-- What a player chose for a table's columns: their order, which show, their widths, and the sort.
---@class ArbitrageColumnLayout
---@field order string[] every column's key, left to right
---@field shown table<string, boolean>
---@field widths table<string, number>
---@field sortKey string
---@field sortAscending boolean

-- A layout as saved: only what differs from the table's defaults, so later defaults still apply.
---@class ArbitrageSavedColumnLayout
---@field order string[]?
---@field shown table<string, boolean>?
---@field widths table<string, number>?
---@field sortKey string?
---@field sortAscending boolean?

---@class ArbitrageColumnPlacement
---@field column ArbitrageItemTableColumn
---@field x number the header's offset; the cell sits 4 pixels further left so it lines up under the label
---@field width number

local ROW_HEIGHT = 20
-- Columns sit right to left from the scroll bar, this far apart, and the Item column takes the rest.
-- A row's name starts past its icon, 18 pixels in, and stops 6 short of the next column unless the
-- table places something after it.
local TABLE_RIGHT = 735
local COLUMN_GAP = 5
local ITEM_X = 4
local NAME_INSET = 24
local HEADER_HEIGHT = 19
-- Narrower than this, a column has no room for even a short price. A header's label starts this far
-- into it and leaves room after it for the sort arrow, which is 9 pixels wide and 3 from the label.
local MIN_COLUMN_WIDTH = 40
local LABEL_X = 8
local SORT_ARROW_ROOM = 14
-- Wide enough to grab over the gap between two headers.
local RESIZE_HANDLE_WIDTH = 9
local GRIP_COLOR = { 1, 1, 1, 0.8 }
local COLUMNS_ATLAS = "questlog-icon-setting"
local COLUMNS_TITLE = "Columns"
local COLUMNS_EXPLANATION = "Choose which columns show. Drag a column's header to move it, and the edge between "
  .. "two headers to resize the columns either side."
local NO_ROOM = "Not enough room. Hide or narrow another column first."
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

-- A price, or nil without one.
---@param value number?
---@return string?
function ns.ItemTable.FormatOptionalMoney(value)
  return value and ns.ItemTable.FormatMoney(value)
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

-- Blizzard's count box draws its 23 pixel arrows outside itself, the left one 6 pixels away.
ns.ItemTable.SPINNER_ARROW_ROOM = 29

-- Blizzard's crafting count box, for a count from 1 to 999: type one, or step it with the arrows or
-- the mouse wheel, Shift for ten. A count is taken once you finish changing it: a typed one on Enter
-- or a click elsewhere, with Escape or anything below one putting the last one back; an arrow's when
-- you let go; and each wheel step at once. So a list drawn again for each change never draws over a
-- count you're still typing or holding an arrow on.
---@param parent Frame
---@param onChange (fun(count: number))? called with the count each change finishes at
---@return ArbitrageCountSpinner
function ns.ItemTable.CreateCountSpinner(parent, onChange)
  local spinner = CreateFrame("EditBox", nil, parent, "NumericInputSpinnerTemplate")
  ---@cast spinner ArbitrageCountSpinner
  -- Three digits, the most the template's box holds.
  spinner:SetMinMaxValues(1, 999)
  -- Holding an arrow steps on each frame until it's let go. Drawing a list again hides its boxes
  -- for a moment, which takes their focus without changing anything.
  local function Finish()
    if onChange and spinner:IsVisible() and not spinner:GetScript("OnUpdate") then
      onChange(spinner:GetValue())
    end
  end
  local function StopStepping(self)
    self:SetScript("OnUpdate", nil)
    Finish()
  end
  spinner.EndIncrement, spinner.EndDecrement = StopStepping, StopStepping
  spinner.MouseWheelCatcher:HookScript("OnMouseWheel", Finish)

  -- Typing changes only the text until it's finished, rather than each digit snapping to the range.
  spinner:SetScript("OnTextChanged", nil)
  spinner:SetScript("OnEnterPressed", spinner.ClearFocus)
  spinner:SetScript("OnEscapePressed", function(self)
    self:SetNumber(self:GetValue())
    self:ClearFocus()
  end)
  spinner:HookScript("OnEditFocusGained", function(self)
    self:RegisterEvent("GLOBAL_MOUSE_DOWN")
  end)
  spinner:HookScript("OnEditFocusLost", function(self)
    self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    local typed = self:GetNumber()
    self:SetValue(typed >= 1 and typed or self:GetValue())
    self:SetNumber(self:GetValue())
    Finish()
  end)
  -- A click anywhere but the box and its arrows finishes typing.
  spinner:SetScript("OnEvent", function(self)
    if not (self:IsMouseOver() or self.IncrementButton:IsMouseOver() or self.DecrementButton:IsMouseOver()) then
      self:ClearFocus()
    end
  end)
  return spinner
end

-- The Auction House's dark list art in an inset, under a 19 pixel row of column headers and beside
-- a scroll bar at its right.
---@param parent Frame
---@return ArbitrageTableBackground
function ns.ItemTable.CreateBackground(parent)
  local background = CreateFrame("Frame", nil, parent)
  ---@cast background ArbitrageTableBackground
  background.layoutType = "InsetFrameTemplate"
  background.Background = background:CreateTexture(nil, "BACKGROUND")
  background.Background:SetAtlas("auctionhouse-background-index")
  background.Background:SetPoint("TOPLEFT", 3, -22)
  background.Background:SetPoint("BOTTOMRIGHT", -25, 3)
  background.NineSlice = CreateFrame("Frame", nil, background, "NineSlicePanelTemplate")
  background.NineSlice:SetFrameLevel(background:GetFrameLevel())
  background.NineSlice:ClearAllPoints()
  background.NineSlice:SetPoint("TOPLEFT", 0, -19)
  background.NineSlice:SetPoint("BOTTOMRIGHT", -22, 0)
  return background
end

---@param owner Frame
function ns.ItemTable.HideOwnTooltip(owner)
  if GameTooltip:IsOwned(owner) then
    GameTooltip:Hide()
  end
end

-- Hovering the frame explains it: its title in white over the explanation.
---@param owner Frame
---@param anchor string
---@param title string
---@param explanation string
function ns.ItemTable.SetExplanation(owner, anchor, title, explanation)
  owner:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor)
    GameTooltip:AddLine(title, 1, 1, 1)
    GameTooltip:AddLine(explanation, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  owner:SetScript("OnLeave", ns.ItemTable.HideOwnTooltip)
end

-- The tables showing each saved layout, by its config key, so a change in one shows in the rest.
---@type table<string, fun()[]>
local tablesByLayout = {}

-- Names sort A to Z first; values sort largest first.
---@param key string
---@return boolean
local function SortsAscending(key)
  return key == "item"
end

-- The columns that show, left to right, and the width that leaves the Item column.
---@param columnsByKey table<string, ArbitrageItemTableColumn>
---@param layout ArbitrageColumnLayout
---@return ArbitrageColumnPlacement[] placements, number itemWidth
local function PlaceColumns(columnsByKey, layout)
  local shown = {}
  for _, key in ipairs(layout.order) do
    local column = columnsByKey[key]
    if layout.shown[key] and not column.unavailable then
      shown[#shown + 1] = column
    end
  end
  local placements = {}
  local x = TABLE_RIGHT
  for index = #shown, 1, -1 do
    local column = shown[index]
    local width = layout.widths[column.key]
    x = x - width
    placements[index] = { column = column, x = x, width = width }
    x = x - COLUMN_GAP
  end
  return placements, x - ITEM_X
end

-- The saved layout, with defaults for whatever it lacks or holds that isn't valid. Columns its order
-- doesn't name, such as ones added since, go last. A layout too
-- wide for the table, such as one saved before Sale Rate could show, leaves out its rightmost
-- columns until it fits; they're saved as hidden only if something else changes.
---@param options ArbitrageItemTableOptions
---@param columnsByKey table<string, ArbitrageItemTableColumn>
---@param saved table?
---@return ArbitrageColumnLayout
local function LoadLayout(options, columnsByKey, saved)
  saved = type(saved) == "table" and saved or {}

  local order, placed = {}, {}
  if type(saved.order) == "table" then
    for _, key in ipairs(saved.order) do
      if columnsByKey[key] and not placed[key] then
        order[#order + 1] = key
        placed[key] = true
      end
    end
  end
  for _, column in ipairs(options.columns) do
    if not placed[column.key] then
      order[#order + 1] = column.key
    end
  end

  local savedShown = type(saved.shown) == "table" and saved.shown or {}
  local savedWidths = type(saved.widths) == "table" and saved.widths or {}
  local maxWidth = TABLE_RIGHT - ITEM_X - options.minItemWidth - COLUMN_GAP
  local shown, widths = {}, {}
  for _, column in ipairs(options.columns) do
    local isShown, width = savedShown[column.key], savedWidths[column.key]
    if type(isShown) == "boolean" then
      shown[column.key] = isShown
    else
      shown[column.key] = not column.hidden
    end
    -- A number equals itself unless it's NaN.
    if type(width) == "number" and width == width then
      widths[column.key] = math.min(math.max(math.floor(width + 0.5), MIN_COLUMN_WIDTH), maxWidth)
    else
      widths[column.key] = column.width
    end
  end

  local sortKey = options.defaultSortKey
  if saved.sortKey == "item" or (type(saved.sortKey) == "string" and columnsByKey[saved.sortKey]) then
    sortKey = saved.sortKey
  end
  local sortAscending = SortsAscending(sortKey)
  if sortKey == saved.sortKey and type(saved.sortAscending) == "boolean" then
    sortAscending = saved.sortAscending
  end

  ---@type ArbitrageColumnLayout
  local layout = { order = order, shown = shown, widths = widths, sortKey = sortKey, sortAscending = sortAscending }
  local placements, itemWidth = PlaceColumns(columnsByKey, layout)
  for index = #placements, 1, -1 do
    if itemWidth >= options.minItemWidth then
      break
    end
    local placement = placements[index]
    shown[placement.column.key] = false
    itemWidth = itemWidth + placement.width + COLUMN_GAP
  end
  return layout
end

---@param options ArbitrageItemTableOptions
---@param layout ArbitrageColumnLayout
---@return ArbitrageSavedColumnLayout
local function SaveLayout(options, layout)
  ---@type ArbitrageSavedColumnLayout
  local saved = {}
  for index, column in ipairs(options.columns) do
    if layout.order[index] ~= column.key then
      saved.order = { unpack(layout.order) }
      break
    end
  end
  for _, column in ipairs(options.columns) do
    local key = column.key
    if layout.shown[key] == (column.hidden == true) then
      saved.shown = saved.shown or {}
      saved.shown[key] = layout.shown[key]
    end
    if layout.widths[key] ~= column.width then
      saved.widths = saved.widths or {}
      saved.widths[key] = layout.widths[key]
    end
  end
  if layout.sortKey ~= options.defaultSortKey or layout.sortAscending ~= SortsAscending(layout.sortKey) then
    saved.sortKey, saved.sortAscending = layout.sortKey, layout.sortAscending
  end
  return saved
end

---@param parent Frame
---@param options ArbitrageItemTableOptions
---@return ArbitrageItemTable
function ns.ItemTable.Create(parent, options)
  ---@type table<string, ArbitrageColumnHeader>
  local headers = {}
  ---@type table<string, ArbitrageItemTableColumn>
  local columnsByKey = {}
  for _, column in ipairs(options.columns) do
    columnsByKey[column.key] = column
  end
  local layout = LoadLayout(options, columnsByKey, ns.Config.Get(options.layoutKey))
  -- Where the shown columns sit and how wide that leaves the Item column.
  ---@type ArbitrageColumnPlacement[]
  local placements = {}
  local itemWidth = 0
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
  -- The sort the table shows: the layout's, unless its column is hidden.
  ---@type string?
  local sortKey
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
    ns.ItemTable.HideOwnTooltip(parent)
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

  -- Places the row's name and the caller's Item column content, and a cell under each shown
  -- column's header, making cells the first time their column shows.
  ---@param row ArbitrageItemTableRow
  local function LayoutRow(row)
    row.itemName:SetWidth(itemWidth - NAME_INSET)
    if options.layoutItem then
      options.layoutItem(row, itemWidth)
    end
    for _, column in ipairs(options.columns) do
      if row[column.key] then
        row[column.key]:Hide()
      end
    end
    for _, placement in ipairs(placements) do
      local cell = row[placement.column.key]
      if not cell then
        cell = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
        cell:SetJustifyH("RIGHT")
        -- A value too wide for its column truncates rather than spilling onto the next row.
        cell:SetWordWrap(false)
        cell:SetMaxLines(1)
        row[placement.column.key] = cell
      end
      cell:SetPoint("LEFT", row, "LEFT", placement.x - 4, 0)
      cell:SetWidth(placement.width)
      cell:Show()
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

    -- A dash marks a missing value.
    for _, placement in ipairs(placements) do
      local text, isUncertain, isMuted = placement.column.format(item)
      local cell = row[placement.column.key]
      cell:SetText(text or "—")
      if isMuted then
        cell:SetTextColor(0.5, 0.5, 0.5)
      else
        ns.ItemTable.SetValueColor(cell, isUncertain == true)
      end
    end
  end

  local tableBackground = ns.ItemTable.CreateBackground(parent)
  -- The panel's title shares the control row above the panel, so the table starts at its top.
  tableBackground:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -4)
  tableBackground:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 8)

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
  ---@return boolean
  local function IsShown(key)
    return key == "item" or (layout.shown[key] and not columnsByKey[key].unavailable) == true
  end

  ---@type fun()
  local Apply
  ---@type fun(owner: Frame)
  local OpenColumnMenu

  -- Reads the columns again after another table sharing them saved a change. Each table keeps its
  -- own sort while it's open.
  local function Sync()
    local ownSortKey, ownSortAscending = layout.sortKey, layout.sortAscending
    layout = LoadLayout(options, columnsByKey, ns.Config.Get(options.layoutKey))
    layout.sortKey, layout.sortAscending = ownSortKey, ownSortAscending
    Apply()
  end

  -- Saves the layout after a change, with this table's sort, for every table sharing it to show.
  local function Change()
    ns.Config.Set(options.layoutKey, SaveLayout(options, layout))
    for _, sync in ipairs(tablesByLayout[options.layoutKey]) do
      if sync ~= Sync then
        sync()
      end
    end
    Apply()
  end

  ---@param key string
  local function SetSort(key)
    if sortKey == key then
      layout.sortKey, layout.sortAscending = key, not sortAscending
    else
      layout.sortKey, layout.sortAscending = key, SortsAscending(key)
    end
    Change()
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
    row.itemName:SetJustifyH("LEFT")
    row.itemName:SetWordWrap(false)
    row.itemName:SetMaxLines(1)

    if options.initializeRow then
      options.initializeRow(row)
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

  -- The cursor's distance from the table's left edge.
  ---@return number
  local function CursorX()
    local x = GetCursorPosition()
    return x / tableBackground:GetEffectiveScale() - tableBackground:GetLeft()
  end

  -- The key of the column whose header is being dragged to move it, if any.
  ---@type string?
  local moving
  -- Marks the gap a dragged column would drop into, in gold apart from the white resize grips.
  local dropMarker = tableBackground:CreateTexture(nil, "OVERLAY")
  dropMarker:SetColorTexture(1, 0.82, 0)
  dropMarker:SetSize(2, HEADER_HEIGHT)
  dropMarker:Hide()

  -- The column a dragged one would land before: the first shown column whose middle is right of
  -- the cursor, or none past the last.
  ---@return ArbitrageColumnPlacement?
  local function DropTarget()
    local x = CursorX()
    for _, placement in ipairs(placements) do
      if x < placement.x + placement.width / 2 then
        return placement
      end
    end
    return nil
  end

  local function ShowDropMarker()
    local target = DropTarget()
    local x = target and target.x or TABLE_RIGHT + COLUMN_GAP
    dropMarker:SetPoint("TOP", tableBackground, "TOPLEFT", x - COLUMN_GAP / 2, -1)
    dropMarker:Show()
  end

  -- Moves the column before the drop target, or last. Dropping it beside where it already is
  -- changes nothing.
  ---@param key string
  local function DropColumn(key)
    local target = DropTarget()
    local before = target and target.column.key
    for index, placement in ipairs(placements) do
      local following = placements[index + 1]
      if placement.column.key == key and (before == key or before == (following and following.column.key)) then
        return
      end
    end
    for index, orderKey in ipairs(layout.order) do
      if orderKey == key then
        table.remove(layout.order, index)
        break
      end
    end
    local position = #layout.order + 1
    for index, orderKey in ipairs(layout.order) do
      if orderKey == before then
        position = index
      end
    end
    table.insert(layout.order, position, key)
    Change()
  end

  -- Dragging a header moves its column: the header dims, and a bar marks where it will drop.
  ---@param header ArbitrageColumnHeader
  ---@param key string
  local function MakeMovable(header, key)
    ---@param self ArbitrageColumnHeader
    ---@param drop boolean?
    local function Stop(self, drop)
      if moving ~= key then
        return
      end
      moving = nil
      self:SetAlpha(1)
      self:SetScript("OnUpdate", nil)
      dropMarker:Hide()
      if drop then
        DropColumn(key)
      end
    end
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function(self)
      moving = key
      self:SetAlpha(0.5)
      self:SetScript("OnUpdate", ShowDropMarker)
    end)
    header:SetScript("OnDragStop", function(self)
      Stop(self, true)
    end)
    header:SetScript("OnHide", Stop)
  end

  -- Dragging the gap before a column's header moves just that edge, trading width between the
  -- column and the one shown to its left: the Item column, down to its minimum, or another column,
  -- down to the narrowest a column gets. Every other column stays put. The table redraws as the
  -- mouse moves and saves the widths once the button is let go.
  ---@param header ArbitrageColumnHeader
  ---@param key string
  local function CreateResizeHandle(header, key)
    local handle = CreateFrame("Frame", nil, header)
    ---@cast handle ArbitrageResizeHandle
    handle:SetSize(RESIZE_HANDLE_WIDTH, HEADER_HEIGHT)
    handle:SetPoint("CENTER", header, "LEFT", -COLUMN_GAP / 2, 0)
    handle:EnableMouse(true)
    -- A bar with an arrowhead pointing away on each side, drawn rather than set as the cursor,
    -- since the game's only resize cursor is a diagonal one for corners.
    handle.Grip = CreateFrame("Frame", nil, handle)
    handle.Grip:SetAllPoints()
    handle.Grip:Hide()
    local bar = handle.Grip:CreateTexture(nil, "OVERLAY")
    bar:SetColorTexture(GRIP_COLOR[1], GRIP_COLOR[2], GRIP_COLOR[3], GRIP_COLOR[4])
    bar:SetSize(2, HEADER_HEIGHT - 6)
    bar:SetPoint("CENTER")
    for _, side in ipairs({ -1, 1 }) do
      for _, rise in ipairs({ -1, 1 }) do
        local arm = handle.Grip:CreateLine(nil, "OVERLAY")
        arm:SetThickness(1.5)
        arm:SetColorTexture(GRIP_COLOR[1], GRIP_COLOR[2], GRIP_COLOR[3], GRIP_COLOR[4])
        arm:SetStartPoint("CENTER", handle.Grip, side * 7, 0)
        arm:SetEndPoint("CENTER", handle.Grip, side * 4, rise * 3)
      end
    end

    -- The left column's key and starting width, unless it's the Item column, which takes the rest.
    ---@type { startX: number, startWidth: number, maxWidth: number, leftKey: string?, leftWidth: number? }?
    local drag

    local function Finish()
      if not drag then
        return
      end
      local changed = layout.widths[key] ~= drag.startWidth
      drag = nil
      handle:SetScript("OnUpdate", nil)
      if not handle:IsMouseOver() then
        handle.Grip:Hide()
      end
      if changed then
        Change()
      end
    end

    local function Follow()
      -- The button can be let go where the handle doesn't hear it, such as over another window.
      if not IsMouseButtonDown("LeftButton") then
        Finish()
        return
      end
      local width = math.floor(drag.startWidth + drag.startX - CursorX() + 0.5)
      width = math.min(math.max(width, MIN_COLUMN_WIDTH), drag.maxWidth)
      if width ~= layout.widths[key] then
        layout.widths[key] = width
        if drag.leftKey then
          layout.widths[drag.leftKey] = drag.leftWidth + drag.startWidth - width
        end
        Apply()
      end
    end

    -- While a column is dragged to move it, only its drop marker shows.
    handle:SetScript("OnEnter", function(self)
      if not moving then
        self.Grip:Show()
      end
    end)
    handle:SetScript("OnLeave", function(self)
      if not drag then
        self.Grip:Hide()
      end
    end)
    handle:SetScript("OnMouseDown", function(self, button)
      if button ~= "LeftButton" then
        return
      end
      local width = layout.widths[key]
      local left
      for index, placement in ipairs(placements) do
        if placement.column.key == key then
          left = placements[index - 1]
        end
      end
      drag = {
        startX = CursorX(),
        startWidth = width,
        maxWidth = width + (left and left.width - MIN_COLUMN_WIDTH or itemWidth - options.minItemWidth),
        leftKey = left and left.column.key,
        leftWidth = left and left.width,
      }
      self:SetScript("OnUpdate", Follow)
    end)
    handle:SetScript("OnMouseUp", Finish)
    handle:SetScript("OnHide", Finish)
    header.ResizeHandle = handle
  end

  -- A right-click opens the column menu, and any other click sorts. Every column but Item can be
  -- dragged to move it and resized at its left edge.
  ---@param key string
  ---@param label string
  ---@param explanation string?
  ---@return ArbitrageColumnHeader
  local function CreateColumnHeader(key, label, explanation)
    local header = CreateFrame("Button", nil, tableBackground, "ColumnDisplayButtonShortTemplate")
    ---@cast header ArbitrageColumnHeader
    header:SetText(label)
    header.Text:SetWordWrap(false)
    header.Arrow = header:CreateTexture(nil, "OVERLAY")
    header.Arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
    header.Arrow:SetPoint("LEFT", header.Text, "RIGHT", 3, 0)
    header.Arrow:Hide()
    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    header:SetScript("OnClick", function(self, button)
      if button == "RightButton" then
        ns.ItemTable.HideOwnTooltip(self)
        OpenColumnMenu(self)
      else
        SetSort(key)
      end
    end)
    if explanation then
      ns.ItemTable.SetExplanation(header, "ANCHOR_TOP", label, explanation)
    end
    if key ~= "item" then
      MakeMovable(header, key)
      CreateResizeHandle(header, key)
    end
    headers[key] = header
    return header
  end

  -- A label too long for a narrowed column truncates rather than running into the next header.
  ---@param header ArbitrageColumnHeader
  ---@param x number
  ---@param width number
  local function PlaceHeader(header, x, width)
    header:SetPoint("TOPLEFT", tableBackground, "TOPLEFT", x, -1)
    header:SetSize(width, HEADER_HEIGHT)
    local room = width - LABEL_X - SORT_ARROW_ROOM
    header.Text:SetWidth(0)
    if header.Text:GetStringWidth() > room then
      header.Text:SetWidth(room)
    end
    header:Show()
  end

  -- Shows the layout: headers for the shown columns, rows laid out under them, and the sort, which
  -- falls back to the default, or else the Item column, while its column is hidden.
  function Apply()
    placements, itemWidth = PlaceColumns(columnsByKey, layout)
    -- Only hidden columns' headers hide, since hiding a header ends a drag on its handle.
    for key, header in pairs(headers) do
      if not IsShown(key) then
        header:Hide()
      end
    end
    PlaceHeader(headers.item, ITEM_X, itemWidth)
    for _, placement in ipairs(placements) do
      local column = placement.column
      local header = headers[column.key] or CreateColumnHeader(column.key, column.label, column.explanation)
      PlaceHeader(header, placement.x, placement.width)
    end

    local shownKey, shownAscending = layout.sortKey, layout.sortAscending
    if not IsShown(shownKey) then
      shownKey = IsShown(options.defaultSortKey) and options.defaultSortKey or "item"
      shownAscending = SortsAscending(shownKey)
    end
    local resort = shownKey ~= sortKey or shownAscending ~= sortAscending
    sortKey, sortAscending = shownKey, shownAscending
    UpdateHeaderArrows()
    if resort and source then
      -- Drawing the rows again lays them out too.
      sorted = nil
      RenderRows(false)
    else
      scrollBox:ForEachFrame(function(row)
        LayoutRow(row)
        if row.item then
          PopulateRow(row, row.item)
        end
      end)
    end
  end

  -- Shown columns always fit. A hidden one fits in what the Item column can give up past its
  -- minimum, plus however far shown columns were widened past their default width.
  ---@param key string
  ---@return boolean
  local function Fits(key)
    local room = itemWidth - options.minItemWidth
    for _, placement in ipairs(placements) do
      room = room + math.max(0, placement.width - placement.column.width)
    end
    return IsShown(key) or room >= layout.widths[key] + COLUMN_GAP
  end

  -- A column shown takes the Item column's spare room first, then narrows the columns widened the
  -- most back toward their default width, never past it.
  ---@param key string
  local function ToggleColumn(key)
    if not Fits(key) then
      return
    end
    if not IsShown(key) then
      local needed = layout.widths[key] + COLUMN_GAP - (itemWidth - options.minItemWidth)
      local widened = { unpack(placements) }
      table.sort(widened, function(left, right)
        return left.width - left.column.width > right.width - right.column.width
      end)
      for _, placement in ipairs(widened) do
        local taken = math.max(0, math.min(needed, placement.width - placement.column.width))
        layout.widths[placement.column.key] = placement.width - taken
        needed = needed - taken
      end
    end
    layout.shown[key] = not layout.shown[key]
    Change()
  end

  ---@return boolean
  local function IsDefaultLayout()
    local saved = SaveLayout(options, layout)
    return saved.order == nil and saved.shown == nil and saved.widths == nil
  end

  -- Puts the columns back as they show by default, keeping the sort.
  local function ResetColumns()
    layout = LoadLayout(options, columnsByKey, { sortKey = layout.sortKey, sortAscending = layout.sortAscending })
    Change()
  end

  -- Lists every column to show or hide, and Reset Columns. It stays open while columns are checked,
  -- and each check re-evaluates what fits.
  function OpenColumnMenu(owner)
    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
      rootDescription:SetTag("MENU_ARBITRAGE_TABLE_COLUMNS")
      rootDescription:CreateTitle(COLUMNS_TITLE)
      for _, orderKey in ipairs(layout.order) do
        local column = columnsByKey[orderKey]
        if not column.unavailable then
          local checkbox = rootDescription:CreateCheckbox(column.label, IsShown, ToggleColumn, orderKey)
          checkbox:SetEnabled(function()
            return Fits(orderKey)
          end)
          checkbox:SetTooltip(function(tooltip)
            tooltip:AddLine(column.label, 1, 1, 1)
            if column.explanation then
              tooltip:AddLine(column.explanation, nil, nil, nil, true)
            end
            if not Fits(orderKey) then
              tooltip:AddLine(NO_ROOM, 1, 0.125, 0.125, true)
            end
          end)
        end
      end
      rootDescription:CreateDivider()
      rootDescription:CreateButton("Reset Columns", ResetColumns):SetEnabled(function()
        return not IsDefaultLayout()
      end)
    end)
  end

  CreateColumnHeader("item", options.itemLabel)

  local scrollBar = CreateFrame("EventFrame", nil, tableBackground, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

  -- Above the scroll bar, at the end of the header row.
  local columnsButton = CreateFrame("Button", nil, tableBackground)
  columnsButton:SetSize(15, 16)
  columnsButton:SetPoint("TOPRIGHT", tableBackground, "TOPRIGHT", -6, -2)
  columnsButton:SetNormalAtlas(COLUMNS_ATLAS)
  columnsButton:SetHighlightAtlas(COLUMNS_ATLAS, "ADD")
  columnsButton:SetScript("OnClick", function(self)
    ns.ItemTable.HideOwnTooltip(self)
    OpenColumnMenu(self)
  end)
  ns.ItemTable.SetExplanation(columnsButton, "ANCHOR_TOP", COLUMNS_TITLE, COLUMNS_EXPLANATION)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, index)
    InitializeRow(row)
    LayoutRow(row)
    PopulateRow(row, items[index])
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideItemTooltip)

  local tables = tablesByLayout[options.layoutKey] or {}
  tables[#tables + 1] = Sync
  tablesByLayout[options.layoutKey] = tables
  Apply()

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

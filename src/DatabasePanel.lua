local _, ns = ...

ns.DatabasePanel = {}

---@class ArbitrageDatabaseTableRow : ArbitrageItemTableRow
---@field marketValue FontString
---@field latestBuyout FontString
---@field craftCost FontString
---@field listed FontString
---@field saleRate FontString? only with the Companion's sales
---@field lastSeen FontString

---@class ArbitrageSearchBox : EditBox
---@field Instructions FontString

---@class ArbitrageDatabasePanelEntry
---@field panel Frame
---@field filterText FontString
---@field searchBox ArbitrageSearchBox
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable

local FormatMoney = ns.ItemTable.FormatMoney
local FormatCount = ns.ItemTable.FormatCount
local FormatPercent = ns.ItemTable.FormatPercent
local SetValueColor = ns.ItemTable.SetValueColor
local Field = ns.DatabaseIndex.Field
local READING_MESSAGE = "Reading the price database..."

-- Columns sit right to left from the scroll bar, this far apart, and the Item column takes the rest.
local TABLE_RIGHT = 735
local COLUMN_GAP = 5
local ITEM_X = 4
-- A row's name starts past its icon and stops short of the next column.
local NAME_INSET = 24

-- Prices from a gold up drop their copper, so 96 pixels fit 9999g 99s, as Opportunities' columns do.
-- Last Seen fits "59 minutes ago". Sale Rate shows only when the Companion brought sales.
---@param withSales boolean
---@return ArbitrageItemTableColumn[] columns, number itemWidth
local function LayoutColumns(withSales)
  ---@type ArbitrageItemTableColumn[]
  local columns = {
    {
      key = "marketValue",
      field = Field.marketValue,
      label = ns.Terminology.typical.label,
      width = 96,
      explanation = ns.Terminology.typical.definition,
    },
    {
      key = "latestBuyout",
      field = Field.latestBuyout,
      label = ns.Terminology.current.label,
      width = 96,
      explanation = ns.Terminology.current.definition,
    },
    {
      key = "craftCost",
      field = Field.craftCost,
      label = ns.Terminology.typicalCraftCost.label,
      width = 96,
      explanation = ns.Terminology.typicalCraftCost.definition,
    },
    {
      key = "listed",
      field = Field.listed,
      label = "Listed",
      width = 66,
      explanation = "Units listed on an average scan of the latest day your scans counted them, within the last 14 days.",
    },
  }
  if withSales then
    columns[#columns + 1] = {
      key = "saleRate",
      field = Field.saleRate,
      label = "Sale Rate",
      width = 72,
      explanation = "Share of this item's auctions that sell across your region, from TradeSkillMaster through Arbitrage Companion. Blank for random-enchant gear, whose figures blend every enchant.",
    }
  end
  columns[#columns + 1] = {
    key = "lastSeen",
    field = Field.lastSeen,
    label = "Last Seen",
    width = 105,
    explanation = "When a scan last listed this item. Scans older than 30 days are discarded.",
  }

  local x = TABLE_RIGHT
  for index = #columns, 1, -1 do
    local column = columns[index]
    x = x - column.width
    column.x = x
    x = x - COLUMN_GAP
  end
  return columns, x - ITEM_X
end

---@type ArbitrageDatabasePanelEntry?
local entry
-- The rows the table holds, which it lets go of when the index replaces them while it's hidden.
---@type ArbitrageDatabaseRow[]?
local tableRows
-- Items keep loading for a while after the table shows, often some every frame, and a refresh
-- filters every row, so the refreshes they cause are gathered up to twice a second.
local LOADED_REFRESH_SECONDS = 0.5
local refreshPending = false

---@param value number?
---@return string
local function FormatOptionalMoney(value)
  return value and FormatMoney(value) or "—"
end

---@param row ArbitrageDatabaseTableRow
---@param item ArbitrageDatabaseRow
---@param itemName string
local function PopulateRow(row, item, itemName)
  -- The item turned out grey after the list's last refresh: its row was redrawn as it loaded, or
  -- scrolled to. Off-screen grey rows wait, since a refresh redraws every row.
  if item[Field.isIgnored] then
    ns.DatabasePanel.RefreshForLoadedItems()
  end
  local lastSeen = item[Field.lastSeen]
  row.itemName:SetText(itemName)
  row.marketValue:SetText(FormatOptionalMoney(item[Field.marketValue]))
  row.latestBuyout:SetText(FormatOptionalMoney(item[Field.latestBuyout]))
  row.craftCost:SetText(item[Field.craftCostIsUnknown] and "?" or FormatOptionalMoney(item[Field.craftCost]))
  local listed, saleRate = item[Field.listed], item[Field.saleRate]
  row.listed:SetText(listed and FormatCount(listed) or "—")
  if row.saleRate then
    row.saleRate:SetText(saleRate and FormatPercent(saleRate / 1000) or "—")
  end
  row.lastSeen:SetText(lastSeen and ns.Time.Since(lastSeen) or "—")

  SetValueColor(row.marketValue, item[Field.marketIsUncertain] == true)
  SetValueColor(row.craftCost, item[Field.craftCostIsUncertain] == true)
end

-- Rows don't keep why a price is uncertain, so the tooltip asks again.
---@param item ArbitrageDatabaseRow
local function AddTooltipLines(item)
  local market = item[Field.marketIsUncertain] and ns.RollingMarketValue.Get({ item.dbKey })
  if market and market.isUncertain then
    GameTooltip:AddLine("Estimate: " .. table.concat(market.reasons, ", "), 1, 0.82, 0, true)
  end
  local craft = item[Field.craftCostIsUncertain] and ns.Crafting.GetCostForItemID(item.itemID)
  if craft and not craft.isUnknown and craft.isUncertain then
    ---@cast craft ArbitrageCraftingPlan
    GameTooltip:AddLine(
      ns.Terminology.typicalCraftCost.label .. " estimate: " .. table.concat(craft.reasons, ", "),
      1,
      0.82,
      0,
      true
    )
  end
end

-- Prices a craft as the Opportunities tab does without filters: Buyout Craft Cost uses the recipe
-- behind Craft Cost when it has one, so both name the same materials. Rows only keep Craft Cost,
-- so the costs are worked out again for the one item whose details are open.
---@param row ArbitrageDatabaseRow
---@return ArbitrageItemDetailsCraft?
local function CraftOf(row)
  local plan = ns.Crafting.GetCostForItemID(row.itemID)
  if plan == nil then
    return nil
  end
  local known = not plan.isUnknown and plan or nil
  ---@cast known ArbitrageCraftingPlan?
  local recipeKeys = known and known.recipeKey and { [known.recipeKey] = true } or nil
  local buyoutPlan = ns.Crafting.GetScanCostForItemID(row.itemID, recipeKeys)
  local buyoutKnown = buyoutPlan and not buyoutPlan.isUnknown and buyoutPlan or nil
  ---@cast buyoutKnown ArbitrageCraftingPlan?
  return {
    outputQuantity = (known and known.outputQuantity) or (buyoutKnown and buyoutKnown.outputQuantity) or 1,
    craftCost = known and math.floor(known.cost + 0.5),
    craftCostIsUncertain = known ~= nil and known.isUncertain,
    craftCostIsUnknown = known == nil,
    buyoutCraftCost = buyoutKnown and math.floor(buyoutKnown.cost + 0.5),
    materials = known and known.leaves,
    buyoutMaterials = buyoutKnown and buyoutKnown.leaves,
  }
end

---@param row ArbitrageDatabaseRow
---@param query string
---@param queryID number?
---@return boolean
local function MatchesSearch(row, query, queryID)
  if query == "" or row.itemID == queryID then
    return true
  end
  local searchName = row[Field.searchName]
  return searchName ~= nil and searchName:find(query, 1, true) ~= nil
end

-- The filters sit in nested menus, so while any are active they are listed above the table, which
-- moves down a row to make room; otherwise the table fills the panel.
local function ShowActiveFilters()
  local filters = ns.DatabaseFilters.Describe()
  entry.filterText:SetText(filters and "Filters: " .. filters or "")
  entry.table.frame:SetPoint("TOPLEFT", entry.panel, "TOPLEFT", 16, filters and -24 or -4)
end

-- Refreshes for items that finished loading in the background, keeping the scroll position.
function ns.DatabasePanel.RefreshForLoadedItems()
  if refreshPending then
    return
  end
  refreshPending = true
  C_Timer.After(LOADED_REFRESH_SECONDS, function()
    refreshPending = false
    ns.DatabasePanel.Refresh(true)
  end)
end

---@return boolean
function ns.DatabasePanel.IsShown()
  return entry ~= nil and entry.panel:IsShown()
end

---@param retainScrollPosition boolean?
function ns.DatabasePanel.Refresh(retainScrollPosition)
  if not entry then
    return
  end
  if not entry.panel:IsShown() then
    -- Rows the index has replaced or let go would be held twice, or for nothing, so the table lets
    -- go of them too and reads the index's as it shows.
    if tableRows ~= nil and tableRows ~= ns.DatabaseIndex.Peek() then
      entry.table.Release()
      tableRows = nil
    end
    return
  end

  entry.filterDropdown:ValidateResetState()

  local rows = ns.DatabaseIndex.Get().rows
  if rows == nil then
    entry.table.Release()
    tableRows = nil
    entry.table.SetEmptyMessage(READING_MESSAGE)
    return
  end

  local query = strlower(strtrim(entry.searchBox:GetText() or ""))
  local queryID = tonumber(query)
  local matcher = ns.DatabaseFilters.Matcher(time())
  local isIgnored = Field.isIgnored
  -- Rows whose items load as grey after they were read stay in the list until the next read. With
  -- nothing to leave out, the table shows every row without checking each.
  local filter
  if query ~= "" or matcher ~= nil or ns.DatabaseIndex.HasGrey(rows) then
    filter = function(row)
      return not row[isIgnored] and MatchesSearch(row, query, queryID) and (matcher == nil or matcher(row))
    end
  end
  tableRows = rows
  local visibleCount = entry.table.SetItems(rows, retainScrollPosition, filter)
  ShowActiveFilters()

  local emptyMessage
  if #rows == 0 then
    emptyMessage = "No Auction House scan data. Run a full scan at the Auction House to fill the database."
  elseif visibleCount == 0 then
    emptyMessage = "No items match the current search and filters."
  end
  entry.table.SetEmptyMessage(emptyMessage)
end

---@param panel Frame
---@param controlsParent Frame
function ns.DatabasePanel.Create(panel, controlsParent)
  -- The window is first opened after saved variables have loaded.
  ns.DatabaseFilters.Init()
  panel:SetScript("OnShow", function()
    ns.DatabasePanel.Refresh()
  end)

  -- Centered on the control row, clear of the portrait.
  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("LEFT", controlsParent, "TOPLEFT", 66, -49)
  heading:SetText("Database")

  -- Spans the table, from the item column to the scroll bar.
  local filterText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  filterText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -6)
  filterText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -27, -6)
  filterText:SetJustifyH("LEFT")
  filterText:SetWordWrap(false)

  ---@type ArbitrageItemDetails
  local details
  -- The Companion's sales are read at login, so whether there are any can't change while the window
  -- is open.
  local columns, itemWidth = LayoutColumns(ns.Database.HasSales())
  local itemTable = ns.ItemTable.Create(panel, {
    itemLabel = "Item",
    itemWidth = itemWidth,
    nameWidth = itemWidth - NAME_INSET,
    columns = columns,
    defaultSortKey = "marketValue",
    populateRow = PopulateRow,
    addTooltipLines = AddTooltipLines,
    onSelect = function(item)
      details.SetItem(item)
    end,
    profileName = "Database Table",
    -- The index reads rows in order of item ID and variant, and keeps each loaded item's name.
    identityOrdered = true,
    sortName = function(row)
      return row[Field.searchName]
    end,
  })
  details = ns.ItemDetails.Create(panel, controlsParent, {
    craftOf = CraftOf,
    onClose = function()
      itemTable.Select(nil)
    end,
  })

  local filterDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1FilterDropdownTemplate")
  ---@cast filterDropdown ArbitrageFilterDropdown
  filterDropdown:SetWidth(93)
  filterDropdown:SetPoint("TOPRIGHT", controlsParent, "TOPRIGHT", -12, -38)
  filterDropdown:SetIsDefaultCallback(ns.DatabaseFilters.IsDefault)
  filterDropdown:SetDefaultCallback(function()
    ns.DatabaseFilters.Reset()
    ns.DatabasePanel.Refresh()
  end)
  filterDropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("MENU_ARBITRAGE_DATABASE_FILTER")
    local facets = ns.DatabaseIndex.Get().facets or { subclasses = {}, slots = {}, qualities = {}, stats = {} }
    ns.DatabaseFilters.SetupMenu(rootDescription, facets, function()
      ns.DatabasePanel.Refresh()
    end)
  end)
  filterDropdown:ValidateResetState()

  local searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
  ---@cast searchBox ArbitrageSearchBox
  searchBox:SetSize(200, 20)
  searchBox:SetPoint("RIGHT", filterDropdown, "LEFT", -12, 0)
  searchBox:SetAutoFocus(false)
  searchBox.Instructions:SetText("Search by name or item ID")
  searchBox:HookScript("OnTextChanged", function()
    ns.DatabasePanel.Refresh()
  end)

  local eventFrame = CreateFrame("Frame")
  eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  eventFrame:SetScript("OnEvent", function(_, _, itemID, success)
    local loaded = ns.DatabaseIndex.HandleItemInfoReceived(itemID, success)
    itemTable.HandleItemInfoReceived(itemID, success)
    -- Newly loaded items can change what a search or a rarity or level filter matches.
    local needsRefresh = entry and (entry.searchBox:GetText() ~= "" or ns.DatabaseFilters.NeedsItemInfo())
    if loaded and needsRefresh then
      ns.DatabasePanel.RefreshForLoadedItems()
    end
  end)

  entry = {
    panel = panel,
    filterText = filterText,
    searchBox = searchBox,
    filterDropdown = filterDropdown,
    table = itemTable,
  }
end

local _, ns = ...

ns.DatabasePanel = {}

---@class ArbitrageDatabaseTableRow : ArbitrageItemTableRow
---@field marketValue FontString
---@field latestBuyout FontString
---@field craftCost FontString
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
local SetValueColor = ns.ItemTable.SetValueColor
local READING_MESSAGE = "Reading the price database..."

-- Sized when prices kept their copper: 104 pixels cut off 9999g 99s 99c in game, and 130 left room.
-- Prices of a gold or more now drop their copper, so these columns have room to spare.
---@type ArbitrageItemTableColumn[]
local COLUMNS = {
  {
    key = "marketValue",
    label = "Market Value",
    x = 225,
    width = 130,
    explanation = "Estimated low-end Auction House price from the last 14 days of scans; recent days count more. Yellow values have limited, stale, or volatile data.",
  },
  {
    key = "latestBuyout",
    label = "Min Buyout",
    x = 360,
    width = 130,
    explanation = "Cheapest per-unit buyout in the latest scan that covers the item. Blank when it was not listed.",
  },
  {
    key = "craftCost",
    label = "Craft Cost",
    x = 495,
    width = 130,
    explanation = "Estimated cheapest way to make one with your characters' recipes, using rolling Auction House values, unlimited-stock vendors, and intermediate crafts. Blank when no known recipe makes it; ? when a material has no price.",
  },
  {
    key = "lastSeen",
    label = "Last Seen",
    x = 630,
    width = 105,
    explanation = "When a scan last priced this item. Scans older than 30 days are discarded.",
  },
}

---@type ArbitrageDatabasePanelEntry?
local entry
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
  row.itemName:SetText(itemName)
  row.marketValue:SetText(FormatOptionalMoney(item.marketValue))
  row.latestBuyout:SetText(FormatOptionalMoney(item.latestBuyout))
  row.craftCost:SetText(item.craftCostIsUnknown and "?" or FormatOptionalMoney(item.craftCost))
  row.lastSeen:SetText(item.lastSeen and ns.Time.Since(item.lastSeen) or "—")

  SetValueColor(row.marketValue, item.marketIsUncertain)
  SetValueColor(row.craftCost, item.craftCostIsUncertain)
end

---@param item ArbitrageDatabaseRow
local function AddTooltipLines(item)
  if item.marketIsUncertain and item.reasons then
    GameTooltip:AddLine("Estimate: " .. table.concat(item.reasons, ", "), 1, 0.82, 0, true)
  end
  if item.craftCostIsUncertain and item.craftReasons then
    GameTooltip:AddLine("Craft Cost estimate: " .. table.concat(item.craftReasons, ", "), 1, 0.82, 0, true)
  end
end

---@param row ArbitrageDatabaseRow
---@param query string
---@param queryID number?
---@return boolean
local function MatchesSearch(row, query, queryID)
  if query == "" or row.itemID == queryID then
    return true
  end
  return row.searchName ~= nil and row.searchName:find(query, 1, true) ~= nil
end

-- The filters sit in nested menus, so while any are active they are listed above the table, which
-- moves down a row to make room; otherwise the table fills the panel.
---@param visibleCount number
---@param totalCount number
local function ShowActiveFilters(visibleCount, totalCount)
  local filters = ns.DatabaseFilters.Describe()
  local text = ""
  if filters then
    -- The count leads, so a long list of filters is what gets cut short.
    local count = BreakUpLargeNumbers(visibleCount) .. " of " .. BreakUpLargeNumbers(totalCount) .. " items"
    text = count .. " · Filters: " .. filters
  end
  entry.filterText:SetText(text)
  entry.table.frame:SetPoint("TOPLEFT", entry.panel, "TOPLEFT", 16, filters and -24 or -4)
end

---@param retainScrollPosition boolean?
function ns.DatabasePanel.Refresh(retainScrollPosition)
  if not entry or not entry.panel:IsShown() then
    return
  end

  entry.filterDropdown:ValidateResetState()

  local rows = ns.DatabaseIndex.Get().rows
  if rows == nil then
    entry.table.SetItems({})
    entry.table.SetEmptyMessage(READING_MESSAGE)
    return
  end

  local query = strlower(strtrim(entry.searchBox:GetText() or ""))
  local queryID = tonumber(query)
  local matcher = ns.DatabaseFilters.Matcher(time())
  local filter = matcher
  if query ~= "" then
    filter = function(row)
      return MatchesSearch(row, query, queryID) and (matcher == nil or matcher(row))
    end
  end
  local visibleCount = entry.table.SetItems(rows, retainScrollPosition, filter)
  ShowActiveFilters(visibleCount, #rows)

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

  local itemTable = ns.ItemTable.Create(panel, {
    itemLabel = "Item",
    itemWidth = 216,
    nameWidth = 192,
    columns = COLUMNS,
    defaultSortKey = "marketValue",
    populateRow = PopulateRow,
    addTooltipLines = AddTooltipLines,
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
    if loaded and needsRefresh and not refreshPending then
      refreshPending = true
      C_Timer.After(0, function()
        refreshPending = false
        ns.DatabasePanel.Refresh(true)
      end)
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

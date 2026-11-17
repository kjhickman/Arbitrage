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
---@field summaryText FontString
---@field filterText FontString
---@field searchBox ArbitrageSearchBox
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable

local FormatMoney = ns.ItemTable.FormatMoney
local SetValueColor = ns.ItemTable.SetValueColor
local READING_MESSAGE = "Reading the price database..."
local UNCERTAINTY_NOTE = "Yellow values are uncertain; more market data is needed."

-- 104 pixels cut off 9999g 99s 99c in game; 130 leaves room.
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
    explanation = "Cheapest per-unit buyout in the latest full scan. Blank when the item was not listed.",
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
  SetValueColor(row.latestBuyout, false)
  SetValueColor(row.craftCost, item.craftCostIsUncertain)
  SetValueColor(row.lastSeen, false)
end

---@param item ArbitrageDatabaseRow
local function AddTooltipLines(item)
  if item.marketIsUncertain and item.reasons then
    GameTooltip:AddLine("Estimate: " .. table.concat(item.reasons, ", "), 1, 0.82, 0, true)
  end
  if item.craftCostIsUncertain and item.craftReasons then
    GameTooltip:AddLine("Craft cost estimate: " .. table.concat(item.craftReasons, ", "), 1, 0.82, 0, true)
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

---@param count number
---@return string
local function DescribeLoading(count)
  return count == 1 and "1 item is still loading" or BreakUpLargeNumbers(count) .. " items are still loading"
end

---@param retainScrollPosition boolean?
function ns.DatabasePanel.Refresh(retainScrollPosition)
  if not entry or not entry.panel:IsShown() then
    return
  end

  ns.Profile.Begin("panel: refresh")
  entry.filterDropdown:ValidateResetState()
  local filters = ns.DatabaseFilters.Describe()
  entry.filterText:SetText(filters and ("Filters: " .. filters) or UNCERTAINTY_NOTE)
  entry.filterText:SetTextColor((filters and WHITE_FONT_COLOR or NORMAL_FONT_COLOR):GetRGB())

  local index = ns.DatabaseIndex.Get()
  local rows = index.rows
  if rows == nil then
    entry.summaryText:SetText(READING_MESSAGE)
    entry.table.SetItems({})
    entry.table.SetEmptyMessage(READING_MESSAGE)
    ns.Profile.End("panel: refresh")
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

  -- Search, rarity, and levels can only match items the client has loaded.
  local loading = (query ~= "" or ns.DatabaseFilters.NeedsItemInfo()) and index.loadingCount > 0

  local summary = BreakUpLargeNumbers(#rows) .. " items"
  if visibleCount ~= #rows then
    summary = BreakUpLargeNumbers(visibleCount) .. " of " .. summary
  end
  summary = summary .. " | Last scan: " .. (index.latestScan and ns.Time.Since(index.latestScan) or "unknown")
  if index.isBuilding then
    summary = summary .. " | Updating..."
  elseif loading then
    summary = summary .. " | " .. DescribeLoading(index.loadingCount)
  end
  entry.summaryText:SetText(summary)

  local emptyMessage
  if #rows == 0 then
    emptyMessage = "No Auction House scan data. Run a full scan at the Auction House to fill the database."
  elseif visibleCount == 0 then
    emptyMessage = "No items match the current search and filters."
  end
  entry.table.SetEmptyMessage(emptyMessage)
  ns.Profile.End("panel: refresh")
end

---@param panel Frame
---@param controlsParent Frame
function ns.DatabasePanel.Create(panel, controlsParent)
  panel:SetScript("OnShow", function()
    ns.DatabasePanel.Refresh()
  end)

  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", 20, -18)
  heading:SetText("Price Database")

  local summaryText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  summaryText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -44)
  summaryText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -145, -44)
  summaryText:SetJustifyH("LEFT")

  -- Active filters, or the uncertainty note when nothing is filtered.
  local filterText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  filterText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  filterText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -62)
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
    ns.Profile.Begin("menu: build filter menu")
    local facets = ns.DatabaseIndex.Get().facets or { subclasses = {}, slots = {}, qualities = {}, stats = {} }
    ns.DatabaseFilters.SetupMenu(rootDescription, facets, function()
      ns.DatabasePanel.Refresh()
    end)
    ns.Profile.End("menu: build filter menu")
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
  eventFrame:SetScript("OnEvent", function(_, _, itemID, success)
    ns.Profile.Begin("events: item data loaded")
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
    ns.Profile.End("events: item data loaded")
  end)

  entry = {
    panel = panel,
    summaryText = summaryText,
    filterText = filterText,
    searchBox = searchBox,
    filterDropdown = filterDropdown,
    table = itemTable,
  }
end

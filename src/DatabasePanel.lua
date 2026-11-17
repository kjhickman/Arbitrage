local _, ns = ...

ns.DatabasePanel = {}

---@class ArbitrageDatabaseTableRow : ArbitrageItemTableRow
---@field market FontString
---@field minBuyout FontString
---@field craftCost FontString
---@field lastSeen FontString

---@class ArbitrageSearchBox : EditBox
---@field Instructions FontString

---@class ArbitrageDatabasePanelEntry
---@field panel Frame
---@field summaryText FontString
---@field searchBox ArbitrageSearchBox
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable

local FormatMoney = ns.ItemTable.FormatMoney
local SetValueColor = ns.ItemTable.SetValueColor
local READING_MESSAGE = "Reading the price database..."

-- The game draws Number14FontWhite wider than its measured advances, so money columns leave
-- about 30% room over the estimate for 9999g 99s 99c.
---@type ArbitrageItemTableColumn[]
local COLUMNS = {
  {
    key = "marketValue",
    cell = "market",
    label = "Market Value",
    x = 225,
    width = 130,
    explanation = "Estimated low-end Auction House price from the last 14 days of scans; recent days count more. Yellow values have limited, stale, or volatile data.",
  },
  {
    key = "latestBuyout",
    cell = "minBuyout",
    label = "Min Buyout",
    x = 360,
    width = 130,
    explanation = "Cheapest per-unit buyout in the latest full scan. Blank when the item was not listed.",
  },
  {
    key = "craftCost",
    cell = "craftCost",
    label = "Craft Cost",
    x = 495,
    width = 130,
    explanation = "Estimated cheapest way to make one with your characters' recipes, using rolling Auction House values, unlimited-stock vendors, and intermediate crafts. Blank when no known recipe makes it; ? when a material has no price.",
  },
  {
    key = "lastSeen",
    cell = "lastSeen",
    label = "Last Seen",
    x = 630,
    width = 105,
    explanation = "When a scan last priced this item. Scans older than 30 days are discarded.",
  },
}

---@type ArbitrageDatabasePanelEntry?
local entry
local refreshPending = false
-- Filters last for the session; the search box keeps its own text.
---@type number?
local selectedClassID
local hideUncertain = false

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
  row.market:SetText(FormatOptionalMoney(item.marketValue))
  row.minBuyout:SetText(FormatOptionalMoney(item.latestBuyout))
  row.craftCost:SetText(item.craftCostIsUnknown and "?" or FormatOptionalMoney(item.craftCost))
  row.lastSeen:SetText(item.lastSeen and ns.Time.Since(item.lastSeen) or "—")

  SetValueColor(row.market, item.marketIsUncertain)
  SetValueColor(row.minBuyout, false)
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

---@param value number
---@return string
local function FormatCount(value)
  return BreakUpLargeNumbers(value)
end

---@param row ArbitrageDatabaseRow
---@param query string
---@param queryID number?
---@return boolean
local function Matches(row, query, queryID)
  if selectedClassID ~= nil and row.classID ~= selectedClassID then
    return false
  end
  if hideUncertain and (row.marketValue == nil or row.marketIsUncertain) then
    return false
  end
  if query == "" or row.itemID == queryID then
    return true
  end
  return row.searchName ~= nil and row.searchName:find(query, 1, true) ~= nil
end

---@return boolean
local function AreFiltersDefault()
  return selectedClassID == nil and not hideUncertain
end

local function ResetFiltersToDefault()
  selectedClassID = nil
  hideUncertain = false
  ns.DatabasePanel.Refresh()
end

---@param classID number?
---@return boolean
local function IsClassSelected(classID)
  return selectedClassID == classID
end

---@param classID number?
local function SelectClass(classID)
  selectedClassID = classID
  ns.DatabasePanel.Refresh()
end

---@return boolean
local function IsHidingUncertain()
  return hideUncertain
end

local function ToggleHideUncertain()
  hideUncertain = not hideUncertain
  ns.DatabasePanel.Refresh()
end

-- Offers only the categories that appear in the database, by name.
---@return { classID: number, name: string }[]
local function GetCategories()
  local categories = {}
  local seen = {}
  for _, row in ipairs(ns.DatabaseIndex.Get().rows or {}) do
    local classID = row.classID
    if classID ~= nil and not seen[classID] then
      seen[classID] = true
      local name = C_Item.GetItemClassInfo(classID)
      if name then
        categories[#categories + 1] = { classID = classID, name = name }
      end
    end
  end
  table.sort(categories, function(left, right)
    return left.name < right.name
  end)
  return categories
end

---@param retainScrollPosition boolean?
function ns.DatabasePanel.Refresh(retainScrollPosition)
  if not entry or not entry.panel:IsShown() then
    return
  end

  entry.filterDropdown:ValidateResetState()
  local index = ns.DatabaseIndex.Get()
  local rows = index.rows
  if rows == nil then
    entry.summaryText:SetText(READING_MESSAGE)
    entry.table.SetItems({})
    entry.table.SetEmptyMessage(READING_MESSAGE)
    return
  end

  local query = strlower(strtrim(entry.searchBox:GetText() or ""))
  local queryID = tonumber(query)
  local visible = {}
  for _, row in ipairs(rows) do
    if Matches(row, query, queryID) then
      visible[#visible + 1] = row
    end
  end
  entry.table.SetItems(visible, retainScrollPosition)

  local summary = FormatCount(#rows) .. " items"
  if #visible ~= #rows then
    summary = FormatCount(#visible) .. " of " .. summary
  end
  summary = summary .. " | Last scan: " .. (index.latestScan and ns.Time.Since(index.latestScan) or "unknown")
  if index.isBuilding then
    summary = summary .. " | Updating..."
  end
  entry.summaryText:SetText(summary)

  local emptyMessage
  if #rows == 0 then
    emptyMessage = "No Auction House scan data. Run a full scan at the Auction House to fill the database."
  elseif #visible == 0 and query ~= "" and index.unnamedCount > 0 then
    local loading = index.unnamedCount == 1 and "1 item name is" or FormatCount(index.unnamedCount) .. " item names are"
    emptyMessage = "No items match yet. " .. loading .. " still loading; search by item ID to find them now."
  elseif #visible == 0 then
    emptyMessage = "No items match the current search and filters."
  end
  entry.table.SetEmptyMessage(emptyMessage)
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

  local uncertaintyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  uncertaintyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  uncertaintyText:SetText("Yellow values are uncertain; more market data is needed.")
  uncertaintyText:SetTextColor(NORMAL_FONT_COLOR:GetRGB())

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
  filterDropdown:SetIsDefaultCallback(AreFiltersDefault)
  filterDropdown:SetDefaultCallback(ResetFiltersToDefault)
  filterDropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("MENU_ARBITRAGE_DATABASE_FILTER")
    local categoryMenu = rootDescription:CreateButton("Category")
    categoryMenu:CreateRadio("All categories", IsClassSelected, SelectClass, nil)
    for _, category in ipairs(GetCategories()) do
      categoryMenu:CreateRadio(category.name, IsClassSelected, SelectClass, category.classID)
    end
    rootDescription
      :CreateCheckbox("Hide uncertain prices", IsHidingUncertain, ToggleHideUncertain)
      :SetTitleAndTextTooltip(
        "Hide uncertain prices",
        "Hides items whose Market Value is uncertain or missing because they have no scans in the last 14 days."
      )
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
    local named = ns.DatabaseIndex.HandleItemInfoReceived(itemID, success)
    itemTable.HandleItemInfoReceived(itemID, success)
    -- Newly loaded names can change what a search matches.
    if named and entry and entry.searchBox:GetText() ~= "" and not refreshPending then
      refreshPending = true
      C_Timer.After(0, function()
        refreshPending = false
        ns.DatabasePanel.Refresh(true)
      end)
    end
  end)

  entry = {
    panel = panel,
    summaryText = summaryText,
    searchBox = searchBox,
    filterDropdown = filterDropdown,
    table = itemTable,
  }
end

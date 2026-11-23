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
    explanation = "Typical price over the last 14 days; recent days count more. Yellow values have limited, stale, or volatile data.",
  },
  {
    key = "latestBuyout",
    label = "Buyout",
    x = 360,
    width = 130,
    explanation = "Cheapest listing in the latest scan, per item. Blank when it wasn't listed.",
  },
  {
    key = "craftCost",
    label = "Craft Cost",
    x = 495,
    width = 130,
    explanation = "Cheapest way to make one at Market Value with your characters' recipes, including unlimited-stock vendors and intermediate crafts. Blank when no known recipe makes it; ? when a material has no price.",
  },
  {
    key = "lastSeen",
    label = "Last Seen",
    x = 630,
    width = 105,
    explanation = "When a scan last listed this item. Scans older than 30 days are discarded.",
  },
}

---@type ArbitrageDatabasePanelEntry?
local entry
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
  if item.isIgnored then
    ns.DatabasePanel.RefreshForLoadedItems()
  end
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
  return row.searchName ~= nil and row.searchName:find(query, 1, true) ~= nil
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
  -- Rows whose items load as grey after they were read stay in the list until the next read.
  local function filter(row)
    return not row.isIgnored and MatchesSearch(row, query, queryID) and (matcher == nil or matcher(row))
  end
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
  local itemTable = ns.ItemTable.Create(panel, {
    itemLabel = "Item",
    itemWidth = 216,
    nameWidth = 192,
    columns = COLUMNS,
    defaultSortKey = "marketValue",
    populateRow = PopulateRow,
    addTooltipLines = AddTooltipLines,
    onSelect = function(item)
      details.SetItem(item)
    end,
    profileName = "Database Table",
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

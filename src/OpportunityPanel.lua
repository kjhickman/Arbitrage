local addonName, ns = ...

ns.OpportunityPanel = {}

---@class ArbitrageScanButton : Button
---@field disabledTooltip string?

---@class ArbitrageFilterDropdown : DropdownButton
---@field ValidateResetState fun(self: ArbitrageFilterDropdown)

---@class ArbitrageScanProgressBar : Frame
---@field Fill Texture
---@field SetFillPercent fun(self: ArbitrageScanProgressBar, fraction: number)

---@class ArbitrageScanOverlay : Frame
---@field spinner Frame
---@field progressBar ArbitrageScanProgressBar
---@field statusText FontString
---@field guidance FontString
---@field cancelButton Button

---@class ArbitrageOpportunityPanelEntry
---@field panel Frame
---@field content Frame every control and the table
---@field heading FontString
---@field glossaryButton Button
---@field filterText FontString
---@field searchBox ArbitrageSearchBox
---@field scanButton ArbitrageScanButton?
---@field quickScanButton ArbitrageScanButton?
---@field scanOverlay ArbitrageScanOverlay
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable
---@field idleEmptyMessage string?

---@class ArbitrageFilterChoice
---@field value string|number
---@field label string

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }
local AWAY_SCAN_TOOLTIP = "Open the Auction House to run a scan."
local NEUTRAL_SCAN_TOOLTIP = "Arbitrage only scans your faction's Auction House."
local NEUTRAL_NOTICE = "Arbitrage only works with your faction's Auction House.\n\n"
  .. "Neutral Auction Houses keep their own prices and take a larger cut, so Arbitrage doesn't scan or "
  .. "price them. Visit your faction's Auction House to scan and see your opportunities."
-- How long each scan usually waits for the server, and what it says meanwhile. Past the usual wait
-- by SLOW_WAIT_MARGIN, it says it's taking longer, and from LONG_WAIT_SECONDS it suggests cancelling.
-- Only a full scan has to wait out the 15 minute cooldown to try again.
---@type table<ArbitrageScanKind, { usual: number, guidance: string, long: string }>
local WAITS = {
  full = {
    usual = 18,
    guidance = "This usually takes about 20 seconds. Keep the Auction House open.",
    long = "This is taking much longer than usual. Consider cancelling and trying again in 15 minutes.",
  },
  quick = {
    usual = 32,
    guidance = "This usually takes about 30 seconds. Keep the Auction House open.",
    long = "This is taking much longer than usual. Consider cancelling and trying again.",
  },
}
local SLOW_WAIT_MARGIN = 5
local LONG_WAIT_SECONDS = 60
local SLOW_WAIT_GUIDANCE = "This is taking longer than usual. Keep the Auction House open."
local READING_GUIDANCE = "This can take a minute. Keep the Auction House open; closing it cancels the scan."
local PRICING_GUIDANCE = "The auctions are read, so closing the Auction House now won't cancel the scan."
local CANCEL_TOOLTIP = "Stop waiting for the server. The request still counts toward the 15 minute full scan cooldown."
---@type table<ArbitrageScanKind, string>
local SCAN_DESCRIPTIONS = {
  full = ("Runs a slower, full scan that contributes to %s prices and refreshes %s prices."):format(
    ns.Terminology.typical.label,
    ns.Terminology.current.label
  ),
  quick = ("Runs a faster scan that only refreshes %s prices, except for random-enchant gear."):format(
    ns.Terminology.current.label
  ),
}
local HIDE_UNCERTAIN_LABEL = "Hide uncertain opportunities"
---@type string[]
local GLOSSARY = {
  ns.Terminology.typical.label .. ": " .. ns.Terminology.typical.definition,
  ns.Terminology.current.label .. ": " .. ns.Terminology.current.definition,
  "Profits are per item.",
}
---@type ArbitrageOpportunityFilterKey[]
local FILTER_KEYS = {
  "minimumProfit",
  "showUncertainOpportunities",
  "opportunityProfession",
  "opportunityCrafter",
  "opportunitySaleMethod",
}

local SHOPPING_TAB_LABEL = "Shopping List"

local frame = CreateFrame("Frame")
---@type Frame?
local auctionHousePanel
---@type ArbitrageOpportunityPanelEntry?
local auctionHouseEntry
-- The Auction House tab's shopping list, made the first time its view is chosen.
---@type ArbitrageShoppingPanelEntry?
local auctionHouseShopping
-- The Auction House tab's Opportunities and Shopping List tabs.
---@type Button[]
local viewTabs = {}
-- The Auction House tab's view, kept while it's closed.
---@type "opportunities"|"shopping"
local auctionHouseView = "opportunities"
---@type FontString?
local neutralNotice
---@type ArbitrageOpportunityPanelEntry[]
local panels = {}
-- The latest evaluation, which each panel narrows with its own search.
---@type ArbitrageOpportunityResult?
local result
local hasRecentScan = false
local priceRefreshPending = false

---@return boolean
function ns.OpportunityPanel.IsAuctionHouseOpen()
  return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() == true
end

-- Visible rather than shown: the Auction House tab stays shown after the Auction House closes. Its
-- content hides while the tab shows the shopping list instead.
---@return boolean
local function HasVisiblePanel()
  for _, entry in ipairs(panels) do
    if entry.content:IsVisible() then
      return true
    end
  end
  return false
end

---@param button Button
local function ShowPricingGlossary(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Arbitrage Pricing", 1, 1, 1)
  for _, line in ipairs(GLOSSARY) do
    GameTooltip:AddLine(line, nil, nil, nil, true)
  end
  GameTooltip:AddLine("Yellow values are uncertain.", 1, 0.82, 0, true)
  GameTooltip:Show()
end

---@param button Button
local function HidePricingGlossary(button)
  if GameTooltip:IsOwned(button) then
    GameTooltip:Hide()
  end
end

---@param key ArbitrageOpportunityFilterKey
---@param value boolean|number|string
local function SetFilter(key, value)
  ns.Config.Set(key, value)
  ns.OpportunityPanel.Refresh()
end

---@return boolean
local function AreFiltersDefault()
  for _, key in ipairs(FILTER_KEYS) do
    if not ns.Config.IsDefault(key) then
      return false
    end
  end
  return true
end

local function ResetFiltersToDefault()
  for _, key in ipairs(FILTER_KEYS) do
    ns.Config.Reset(key)
  end
  ns.OpportunityPanel.Refresh()
end

-- The filters that differ from their defaults as one line, or nil when none do. A crafter later
-- forgotten or a profession unlearned drops out of the menu but stays saved, so values are named
-- as saved rather than looked up in the menu's choices.
---@return string?
local function DescribeFilters()
  local parts = {}
  local minimumProfit = ns.Config.Get("minimumProfit")
  if not ns.Config.IsDefault("minimumProfit") then
    parts[#parts + 1] = minimumProfit <= 0 and "Including losses"
      or "Minimum profit " .. C_CurrencyInfo.GetCoinTextureString(minimumProfit, 10)
  end
  local profession = ns.Config.Get("opportunityProfession")
  if profession ~= "" then
    parts[#parts + 1] = profession
  end
  local crafter = ns.Config.Get("opportunityCrafter")
  if crafter == ns.Config.CURRENT_CHARACTER then
    local currentName = ns.Realm.GetCharacterName()
    parts[#parts + 1] = "Crafted by current character" .. (currentName and " (" .. currentName .. ")" or "")
  elseif crafter ~= "" then
    parts[#parts + 1] = "Crafted by " .. crafter
  end
  local saleMethod = ns.Config.Get("opportunitySaleMethod")
  if saleMethod ~= "" then
    parts[#parts + 1] = saleMethod == "vendor" and "Sell to vendor" or "Sell to Auction House"
  end
  if not ns.Config.Get("showUncertainOpportunities") then
    parts[#parts + 1] = HIDE_UNCERTAIN_LABEL
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

---@param menu table a menu element description
---@param key ArbitrageOpportunityFilterKey
---@param choices ArbitrageFilterChoice[]
local function AddChoices(menu, key, choices)
  local function IsSelected(value)
    return ns.Config.Get(key) == value
  end
  local function Select(value)
    SetFilter(key, value)
  end
  for _, choice in ipairs(choices) do
    menu:CreateRadio(choice.label, IsSelected, Select, choice.value)
  end
end

---@param allLabel string the choice that turns the filter off
---@param names string[]
---@return ArbitrageFilterChoice[]
local function NameChoices(allLabel, names)
  local choices = { { value = "", label = allLabel } }
  for _, name in ipairs(names) do
    choices[#choices + 1] = { value = name, label = name }
  end
  return choices
end

---@param opportunity ArbitrageCraftOpportunity
---@param query string lowercase
---@param queryID number?
---@return boolean
local function MatchesSearch(opportunity, query, queryID)
  if opportunity.itemID == queryID then
    return true
  end
  local itemName = C_Item.GetItemInfo(opportunity.itemID)
  return itemName ~= nil and strlower(itemName):find(query, 1, true) ~= nil
end

---@param tableFrame Frame
---@return ArbitrageScanOverlay
local function CreateScanOverlay(tableFrame)
  local overlay = CreateFrame("Frame", nil, tableFrame)
  ---@cast overlay ArbitrageScanOverlay
  overlay:SetAllPoints(tableFrame)
  -- Sit above the scroll box's rows and scrollbar without covering the controls or tabs.
  overlay:SetFrameLevel(tableFrame:GetFrameLevel() + 10)
  overlay:EnableMouse(true)
  overlay:EnableMouseWheel(true)
  overlay:Hide()

  local shade = overlay:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.85)

  local heading = overlay:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge4")
  heading:SetPoint("BOTTOM", overlay, "CENTER", 0, 52)
  heading:SetText("Scanning the Auction House")

  local spinner = CreateFrame("Frame", nil, overlay, "SpinnerTemplate")
  spinner:SetSize(90, 90)
  spinner:SetPoint("CENTER")
  overlay.spinner = spinner

  local progressBar = CreateFrame("Frame", nil, overlay, "ColoredProgressBarTemplate")
  ---@cast progressBar ArbitrageScanProgressBar
  progressBar:SetSize(240, 29)
  progressBar:SetPoint("CENTER")
  progressBar.Fill:SetVertexColor(0.9, 0.7, 0.36)
  overlay.progressBar = progressBar

  local statusText = overlay:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  statusText:SetPoint("LEFT", overlay, "LEFT", 16, -60)
  statusText:SetPoint("RIGHT", overlay, "RIGHT", -16, -60)
  overlay.statusText = statusText

  local guidance = overlay:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  guidance:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -8)
  guidance:SetPoint("TOPRIGHT", statusText, "BOTTOMRIGHT", 0, -8)
  overlay.guidance = guidance

  local cancelButton = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
  cancelButton:SetSize(132, 22)
  cancelButton:SetPoint("TOP", guidance, "BOTTOM", 0, -16)
  cancelButton:SetText("Cancel Scan")
  cancelButton:SetScript("OnClick", ns.Scan.Cancel)
  cancelButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local quick = ns.Scan.GetStatus().kind == "quick"
    GameTooltip:AddLine(
      quick and ("Stop collecting %s prices. Previous prices are kept."):format(ns.Terminology.current.label)
        or CANCEL_TOOLTIP,
      1,
      1,
      1,
      true
    )
    GameTooltip:Show()
  end)
  cancelButton:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)
  overlay.cancelButton = cancelButton

  return overlay
end

-- Why the button is disabled, if it is, what the scan does, when one last ran, and how this session's
-- latest attempt ended. The age comes from the database, so it survives a reload and includes synced scans.
---@param scanButton ArbitrageScanButton
---@param kind ArbitrageScanKind
local function ShowScanTooltip(scanButton, kind)
  GameTooltip:SetOwner(scanButton, "ANCHOR_RIGHT")
  if scanButton.disabledTooltip then
    GameTooltip:AddLine(scanButton.disabledTooltip, 1, 1, 1, true)
  end
  GameTooltip:AddLine(SCAN_DESCRIPTIONS[kind], 1, 1, 1, true)
  local status = ns.Database.GetStatus()
  local scannedAt = ({ full = status.latestScan, quick = status.latestQuickScan })[kind]
  local age = scannedAt and ns.Time.Since(scannedAt)
  GameTooltip:AddLine("Last " .. kind .. " scan: " .. (age or "never"), NORMAL_FONT_COLOR:GetRGB())
  local outcome = ns.Scan.GetLastOutcome(kind)
  if outcome then
    -- A scan that stored prices reports just after saving them, so its age is already shown.
    local outcomeAge = ns.Time.Since(outcome.at)
    if outcomeAge ~= age then
      GameTooltip:AddLine("Last attempt, " .. outcomeAge, NORMAL_FONT_COLOR:GetRGB())
    end
    GameTooltip:AddLine(outcome.message, 1, 1, 1, true)
  end
  GameTooltip:Show()
end

---@param entry ArbitrageOpportunityPanelEntry
---@param scanStatus ArbitrageScanStatus
---@param auctionHouseOpen boolean
---@param atNeutralAuctionHouse boolean
local function ApplyScanStatus(entry, scanStatus, auctionHouseOpen, atNeutralAuctionHouse)
  local scanButton = entry.scanButton
  local quickScanButton = entry.quickScanButton
  local overlay = entry.scanOverlay
  local phase = scanStatus.phase
  local idle = phase == "idle"
  if scanButton and quickScanButton then
    local cooldown = idle and scanStatus.cooldownRemainingMinutes
    local canScan = idle and auctionHouseOpen and not atNeutralAuctionHouse
    local disabledTooltip = idle
        and (not auctionHouseOpen and AWAY_SCAN_TOOLTIP or atNeutralAuctionHouse and NEUTRAL_SCAN_TOOLTIP)
      or nil
    scanButton.disabledTooltip = disabledTooltip
    quickScanButton.disabledTooltip = disabledTooltip
    scanButton:SetEnabled(canScan and not cooldown)
    quickScanButton:SetEnabled(canScan)
    scanButton:SetText(cooldown and ("Full Scan (" .. cooldown .. "m)") or "Full Scan")
    if GameTooltip:IsOwned(scanButton) then
      ShowScanTooltip(scanButton, "full")
    elseif GameTooltip:IsOwned(quickScanButton) then
      ShowScanTooltip(quickScanButton, "quick")
    end
  end
  entry.table.SetEmptyMessage(idle and entry.idleEmptyMessage or nil)

  if not idle then
    local waiting = phase == "waiting"
    local quick = scanStatus.kind == "quick"
    overlay.spinner:SetShown(waiting)
    overlay.progressBar:SetShown(not waiting)
    overlay.cancelButton:SetShown(waiting)
    local guidance
    if waiting then
      local seconds = scanStatus.elapsedSeconds or 0
      local wait = WAITS[quick and "quick" or "full"]
      if seconds >= LONG_WAIT_SECONDS then
        guidance = wait.long
      elseif seconds >= wait.usual + SLOW_WAIT_MARGIN then
        guidance = SLOW_WAIT_GUIDANCE
      else
        guidance = wait.guidance
      end
      overlay.statusText:SetText(
        ("Waiting for a response from Blizzard... %d:%02d"):format(math.floor(seconds / 60), seconds % 60)
      )
    else
      guidance = phase == "pricing" and PRICING_GUIDANCE or READING_GUIDANCE
      local progress = scanStatus.progress or 0
      overlay.progressBar:SetFillPercent(progress / 100)
      local label = quick and ("Refreshing %s prices"):format(ns.Terminology.current.label)
        or phase == "reading" and "Reading auctions"
        or ("Calculating and saving %s prices"):format(ns.Terminology.typical.label)
      overlay.statusText:SetText(("%s... %d%%"):format(label, progress))
    end
    overlay.guidance:SetText(guidance)
  end
  overlay:SetShown(not idle)
end

function ns.OpportunityPanel.RefreshScanStatus()
  if #panels == 0 then
    return
  end

  local scanStatus = ns.Scan.GetStatus()
  local auctionHouseOpen = ns.OpportunityPanel.IsAuctionHouseOpen()
  local atNeutralAuctionHouse = auctionHouseOpen and ns.Scan.IsAtNeutralAuctionHouse()
  for _, entry in ipairs(panels) do
    ApplyScanStatus(entry, scanStatus, auctionHouseOpen, atNeutralAuctionHouse)
  end
  -- The shopping list's Refresh Prices waits for scans too.
  ns.ShoppingPanel.RefreshStatus()
end

-- Filters are saved across sessions and sit in nested menus, so while any are active they are listed
-- above the table, which moves down a row to make room; otherwise the table fills the panel.
---@param entry ArbitrageOpportunityPanelEntry
local function ShowActiveFilters(entry)
  local filters = DescribeFilters()
  entry.filterText:SetText(filters and "Filters: " .. filters or "")
  entry.table.frame:SetPoint("TOPLEFT", entry.content, "TOPLEFT", 16, filters and -24 or -4)
end

-- Shows the latest evaluation narrowed by the panel's search, without evaluating crafts again.
---@param entry ArbitrageOpportunityPanelEntry
local function ShowResult(entry)
  if not result then
    return
  end

  local query = strlower(strtrim(entry.searchBox:GetText() or ""))
  local queryID = tonumber(query)
  local filter
  if query ~= "" then
    filter = function(opportunity)
      return MatchesSearch(opportunity, query, queryID)
    end
  end
  local visibleCount = entry.table.SetItems(result.items, false, filter)
  ShowActiveFilters(entry)

  local emptyMessage
  if result.totalCount == 0 then
    emptyMessage = "No known recipes. Open each character's profession window to record learned recipes."
  elseif result.pricedCount == 0 and not hasRecentScan then
    emptyMessage = "No Auction House scan data. Run a full scan to price known crafts."
  elseif result.pricedCount == 0 then
    emptyMessage = "No known crafts have complete output and material prices."
  -- Only speak up when the list is actually empty; the notice draws over the rows otherwise.
  elseif visibleCount == 0 and query ~= "" then
    emptyMessage = "No crafts match the current search and filters."
  elseif visibleCount == 0 and result.profitableCount == 0 then
    emptyMessage = "No known crafts are profitable at these prices."
  -- For the first few days after a first scan nearly every price is uncertain.
  elseif visibleCount == 0 and not ns.Config.Get("showUncertainOpportunities") then
    emptyMessage = "Uncertain opportunities are hidden. Prices firm up after scans on 3 separate days, "
      .. "or sooner with Arbitrage Companion's synced prices."
  elseif visibleCount == 0 then
    emptyMessage = "No crafts match the current filters."
  end
  entry.idleEmptyMessage = emptyMessage
end

-- Prices every known craft, so it waits while no panel can be seen: each refreshes as it shows.
function ns.OpportunityPanel.Refresh()
  if not HasVisiblePanel() then
    return
  end

  ns.Profile.Start("Opportunities", "Pricing")
  local status = ns.Database.GetStatus()
  local cutoff = time() - MARKET_VALUE_WINDOW_SECONDS
  result = ns.Opportunities.Get()
  ns.Profile.Size("Opportunities", result.totalCount, "crafts")
  -- A Quick Scan alone prices crafts at Buyout prices, so it counts as scan data.
  hasRecentScan = (status.latestScan or -math.huge) >= cutoff or (status.latestQuickScan or -math.huge) >= cutoff

  ns.Profile.Stage("Opportunities", "Showing")
  for _, entry in ipairs(panels) do
    entry.filterDropdown:ValidateResetState()
    ShowResult(entry)
  end
  ns.OpportunityPanel.RefreshScanStatus()
  ns.Profile.Finish("Opportunities")
end

---@param panel Frame
---@param controlsParent Frame
---@param showScanButtons boolean? only the Auction House tab has a scan footer
---@return ArbitrageOpportunityPanelEntry
function ns.OpportunityPanel.Create(panel, controlsParent, showScanButtons)
  panel:SetScript("OnShow", ns.OpportunityPanel.Refresh)

  -- Holds every control, so the Auction House tab can swap them for its neutral Auction House notice
  -- or its shopping list.
  local content = CreateFrame("Frame", nil, panel)
  content:SetAllPoints()

  -- Centered on the control row, clear of the portrait.
  local heading = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("LEFT", controlsParent, "TOPLEFT", 66, -49)
  heading:SetText("Opportunities")

  local glossaryButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  glossaryButton:SetSize(22, 22)
  glossaryButton:SetPoint("LEFT", heading, "RIGHT", 8, 0)
  glossaryButton:SetText("?")
  glossaryButton:SetScript("OnEnter", ShowPricingGlossary)
  glossaryButton:SetScript("OnLeave", HidePricingGlossary)

  -- Spans the table, from the item column to the scroll bar.
  local filterText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  filterText:SetPoint("TOPLEFT", content, "TOPLEFT", 20, -6)
  filterText:SetPoint("TOPRIGHT", content, "TOPRIGHT", -27, -6)
  filterText:SetJustifyH("LEFT")
  filterText:SetWordWrap(false)

  ---@type ArbitrageItemDetails
  local details
  local opportunityTable = ns.OpportunityTable.Create(content, function(opportunity)
    details.SetItem(opportunity)
  end, function(opportunity, rootDescription)
    rootDescription:CreateButton("Add to Shopping List", function()
      ns.ShoppingList.Add(opportunity, 1)
    end)
  end)
  details = ns.ItemDetails.Create(content, controlsParent, {
    -- A craft keeps the costs the row shows, from the recipes the filters allow.
    craftOf = function(opportunity)
      return opportunity
    end,
    onClose = function()
      opportunityTable.Select(nil)
    end,
    addToList = ns.ShoppingList.Add,
    countOnList = function(opportunity)
      return ns.ShoppingList.GetCount(opportunity.itemID)
    end,
  })
  -- The details count what's on the list, which changes from either view.
  ns.ShoppingList.OnChange(details.Refresh)

  ---@param kind ArbitrageScanKind
  ---@param label string
  ---@param start fun()
  ---@return ArbitrageScanButton
  local function CreateScanButton(kind, label, start)
    local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    ---@cast button ArbitrageScanButton
    button:SetSize(120, 22)
    button:SetText(label)
    button:SetMotionScriptsWhileDisabled(true)
    button:SetScript("OnClick", start)
    button:SetScript("OnEnter", function(self)
      ShowScanTooltip(self, kind)
    end)
    button:SetScript("OnLeave", function(self)
      if GameTooltip:IsOwned(self) then
        GameTooltip:Hide()
      end
    end)
    return button
  end

  local scanButton, quickScanButton
  if showScanButtons then
    scanButton = CreateScanButton("full", "Full Scan", ns.Scan.Start)
    -- Use the same space above and below the buttons to center them in the footer.
    local footerPadding = 9
    scanButton:SetPoint("BOTTOMRIGHT", controlsParent, "BOTTOMRIGHT", -12, footerPadding)
    quickScanButton = CreateScanButton("quick", "Quick Scan", ns.Scan.StartQuick)
    quickScanButton:SetPoint("RIGHT", scanButton, "LEFT", -8, 0)
    opportunityTable.frame:SetPoint("BOTTOMRIGHT", scanButton, "TOPRIGHT", 2, footerPadding)
  end

  local filterDropdown = CreateFrame("DropdownButton", nil, content, "WowStyle1FilterDropdownTemplate")
  ---@cast filterDropdown ArbitrageFilterDropdown
  filterDropdown:SetWidth(93)
  filterDropdown:SetIsDefaultCallback(AreFiltersDefault)
  filterDropdown:SetDefaultCallback(ResetFiltersToDefault)
  filterDropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("MENU_ARBITRAGE_OPPORTUNITIES_FILTER")
    local profitMenu = rootDescription:CreateButton("Minimum profit")
    profitMenu:SetTitleAndTextTooltip(
      "Minimum profit",
      ("Hides crafts whose %s and %s are both less than this per item."):format(
        ns.Terminology.typicalProfit.label,
        ns.Terminology.currentProfit.label
      )
    )
    local profitChoices = {}
    for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
      local label = MINIMUM_PROFIT_LABELS[copper] or C_CurrencyInfo.GetCoinTextureString(copper, 10)
      profitChoices[#profitChoices + 1] = { value = copper, label = label }
    end
    AddChoices(profitMenu, "minimumProfit", profitChoices)

    local professionMenu = rootDescription:CreateButton("Profession")
    professionMenu:SetTitleAndTextTooltip("Profession", "Shows crafts your characters make with this profession.")
    AddChoices(
      professionMenu,
      "opportunityProfession",
      NameChoices("All professions", ns.RecipeBook.GetProfessionNames())
    )

    local crafterMenu = rootDescription:CreateButton("Crafter")
    crafterMenu:SetTitleAndTextTooltip(
      "Crafter",
      "Shows crafts this character knows. Current character follows whoever you are logged in as."
    )
    local crafterChoices = NameChoices("All characters", ns.RecipeBook.GetCharacterNames())
    local currentName = ns.Realm.GetCharacterName()
    table.insert(crafterChoices, 2, {
      value = ns.Config.CURRENT_CHARACTER,
      label = currentName and ("Current character (" .. currentName .. ")") or "Current character",
    })
    AddChoices(crafterMenu, "opportunityCrafter", crafterChoices)

    local saleMenu = rootDescription:CreateButton("Sell to")
    saleMenu:SetTitleAndTextTooltip(
      "Sell to",
      "Filters crafts by whether they earn more at the Auction House or from a vendor. Each craft is tagged AH or Vendor beside its name."
    )
    AddChoices(saleMenu, "opportunitySaleMethod", {
      { value = "", label = "Auction House or vendor" },
      { value = "auction", label = "Auction House" },
      { value = "vendor", label = "Vendor" },
    })

    rootDescription
      :CreateCheckbox(HIDE_UNCERTAIN_LABEL, function()
        return not ns.Config.Get("showUncertainOpportunities")
      end, function()
        SetFilter("showUncertainOpportunities", not ns.Config.Get("showUncertainOpportunities"))
      end)
      :SetTitleAndTextTooltip(
        HIDE_UNCERTAIN_LABEL,
        ("Hides crafts listed only for an uncertain %s, such as one with fewer than 3 days of scans."):format(
          ns.Terminology.typicalProfit.label
        )
      )
  end)
  filterDropdown:ValidateResetState()

  local settingsButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", controlsParent, "TOPRIGHT", -12, -49)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", ns.Config.OpenOptionsPanel)
  filterDropdown:SetPoint("RIGHT", settingsButton, "LEFT", -10, 0)

  local searchBox = CreateFrame("EditBox", nil, content, "SearchBoxTemplate")
  ---@cast searchBox ArbitrageSearchBox
  searchBox:SetSize(200, 20)
  searchBox:SetPoint("RIGHT", filterDropdown, "LEFT", -12, 0)
  searchBox:SetAutoFocus(false)
  searchBox.Instructions:SetText("Search by name or item ID")

  ---@type ArbitrageOpportunityPanelEntry
  local entry = {
    panel = panel,
    content = content,
    heading = heading,
    glossaryButton = glossaryButton,
    filterText = filterText,
    searchBox = searchBox,
    scanButton = scanButton,
    quickScanButton = quickScanButton,
    scanOverlay = CreateScanOverlay(opportunityTable.frame),
    filterDropdown = filterDropdown,
    table = opportunityTable,
  }
  panels[#panels + 1] = entry

  searchBox:HookScript("OnTextChanged", function()
    ShowResult(entry)
    ns.OpportunityPanel.RefreshScanStatus()
  end)
  return entry
end

local function UpdateShoppingTabLabel()
  local shoppingTab = viewTabs[2]
  if not shoppingTab then
    return
  end
  local count = #ns.ShoppingList.GetCrafts()
  shoppingTab:SetText(count > 0 and (SHOPPING_TAB_LABEL .. " (" .. count .. ")") or SHOPPING_TAB_LABEL)
  PanelTemplates_TabResize(shoppingTab, nil)
end

-- The tabs show Opportunities or the shopping list, or at a neutral Auction House only the notice
-- explaining why the tab is empty.
local function ShowAuctionHouseView()
  local atNeutralAuctionHouse = ns.Scan.IsAtNeutralAuctionHouse()
  local shopping = auctionHouseView == "shopping"
  if shopping and not auctionHouseShopping then
    auctionHouseShopping = ns.ShoppingPanel.Create(auctionHousePanel, AuctionHouseFrame, true)
    auctionHouseShopping.heading:Hide()
  end
  auctionHouseEntry.content:SetShown(not atNeutralAuctionHouse and not shopping)
  if auctionHouseShopping then
    auctionHouseShopping.content:SetShown(not atNeutralAuctionHouse and shopping)
  end
  neutralNotice:SetShown(atNeutralAuctionHouse)
  for _, tab in ipairs(viewTabs) do
    tab:SetShown(not atNeutralAuctionHouse)
  end
  PanelTemplates_SetTab(auctionHousePanel, shopping and 2 or 1)
end

-- Top tabs in the control row, where the window shows each tab's heading.
---@param panelName string
local function CreateViewTabs(panelName)
  local views = { { "opportunities", "Opportunities" }, { "shopping", SHOPPING_TAB_LABEL } }
  for index, view in ipairs(views) do
    local tab = CreateFrame("Button", panelName .. "Tab" .. index, auctionHousePanel, "PanelTopTabButtonTemplate")
    tab:SetID(index)
    tab:SetText(view[2])
    if index > 1 then
      tab:SetPoint("LEFT", viewTabs[index - 1], "RIGHT", -3, 0)
    else
      tab:SetPoint("BOTTOMLEFT", auctionHousePanel, "TOPLEFT", 60, -2)
    end
    tab:SetScript("OnClick", function()
      PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
      auctionHouseView = view[1]
      ShowAuctionHouseView()
      if auctionHouseView == "shopping" then
        ns.ShoppingPanel.Refresh()
      else
        ns.OpportunityPanel.Refresh()
      end
    end)
    viewTabs[index] = tab
  end
  PanelTemplates_SetNumTabs(auctionHousePanel, #views)
  UpdateShoppingTabLabel()
  ns.ShoppingList.OnChange(UpdateShoppingTabLabel)
end

local function CreateAuctionHouseTab()
  if auctionHousePanel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  local panelName = addonName .. "AuctionHouseFrame"
  auctionHousePanel = CreateFrame("Frame", panelName, auctionHouseFrame)
  auctionHousePanel:SetPoint("TOPLEFT", auctionHouseFrame, "TOPLEFT", 4, -69)
  auctionHousePanel:SetPoint("BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -5, 32)
  auctionHousePanel:Hide()

  auctionHouseEntry = ns.OpportunityPanel.Create(auctionHousePanel, auctionHouseFrame, true)
  -- The tabs name the views here, so the glossary moves beside the search box.
  auctionHouseEntry.heading:Hide()
  auctionHouseEntry.glossaryButton:ClearAllPoints()
  auctionHouseEntry.glossaryButton:SetPoint("RIGHT", auctionHouseEntry.searchBox, "LEFT", -10, 0)
  CreateViewTabs(panelName)
  neutralNotice = auctionHousePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  neutralNotice:SetPoint("LEFT", auctionHousePanel, "LEFT", 60, 0)
  neutralNotice:SetPoint("RIGHT", auctionHousePanel, "RIGHT", -60, 0)
  neutralNotice:SetText(NEUTRAL_NOTICE)
  neutralNotice:Hide()
  LibStub("LibAHTab-1-0"):CreateTab(addonName, auctionHousePanel, addonName, addonName)
end

function ns.OpportunityPanel.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      CreateAuctionHouseTab()
      ShowAuctionHouseView()
      ns.ShoppingPanel.Refresh()
      if HasVisiblePanel() then
        ns.OpportunityPanel.Refresh()
      else
        ns.OpportunityPanel.RefreshScanStatus()
      end
    elseif eventName == "AUCTION_HOUSE_CLOSED" then
      ns.OpportunityPanel.RefreshScanStatus()
    elseif eventName == "GET_ITEM_INFO_RECEIVED" then
      for _, entry in ipairs(panels) do
        entry.table.HandleItemInfoReceived(itemID, success)
      end
      if ns.Opportunities.HandleItemInfoReceived(itemID, success) and not priceRefreshPending then
        priceRefreshPending = true
        C_Timer.After(0, function()
          priceRefreshPending = false
          ns.OpportunityPanel.Refresh()
        end)
      end
    end
  end)
end

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
---@field filterText FontString
---@field pricingText FontString
---@field pricingButtons table<ArbitrageOpportunityMode, Button>
---@field searchBox ArbitrageSearchBox
---@field scanButton ArbitrageScanButton
---@field scanOverlay ArbitrageScanOverlay
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable
---@field idleEmptyMessage string?

---@class ArbitrageFilterChoice
---@field value string|number
---@field label string

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }
local AWAY_SCAN_TOOLTIP = "Open the Auction House to run a full scan."
local NEUTRAL_SCAN_TOOLTIP = "Arbitrage only scans your faction's Auction House."
local NEUTRAL_NOTICE = "Arbitrage only works with your faction's Auction House.\n\n"
  .. "Neutral Auction Houses keep their own prices and take a larger cut, so Arbitrage doesn't scan or "
  .. "price them. Visit your faction's Auction House to scan and see your opportunities."
local READING_GUIDANCE = "This can take a minute. Keep the Auction House open; closing it cancels the scan."
local LONG_WAIT_GUIDANCE =
  "Blizzard hasn't sent any auction data yet. Consider cancelling the scan and trying again in 15 minutes."
local PRICING_GUIDANCE = "The auctions are read, so closing the Auction House now won't cancel the scan."
local CANCEL_TOOLTIP = "Stop waiting for the server. The request still counts toward the 15 minute full scan cooldown."
local HIDE_UNCERTAIN_LABEL = "Hide uncertain opportunities"
---@type {mode: ArbitrageOpportunityMode, label: string, width: number, description: string}[]
local PRICING_CHOICES = {
  { mode = "typical", label = "Typical", width = 72, description = "Buy and sell at Market Value." },
  { mode = "scan", label = "Last Scan", width = 90, description = "Buy and list at last-scan prices." },
  {
    mode = "sellLater",
    label = "Buy Now, Sell Later",
    width = 144,
    description = "Compare two sale prices with the same scanned mats.",
  },
}
---@type ArbitrageOpportunityMode
local pricingMode = "typical"
local pricingScanTime
---@type ArbitrageOpportunityFilterKey[]
local FILTER_KEYS = {
  "minimumProfit",
  "showUncertainOpportunities",
  "opportunityProfession",
  "opportunityCrafter",
  "opportunitySaleMethod",
}

local frame = CreateFrame("Frame")
---@type Frame?
local auctionHousePanel
---@type ArbitrageOpportunityPanelEntry?
local auctionHouseEntry
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
local function IsAuctionHouseOpen()
  return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() == true
end

---@return boolean
local function HasVisiblePanel()
  for _, entry in ipairs(panels) do
    if entry.panel:IsShown() then
      return true
    end
  end
  return false
end

---@param button Button
local function ShowPricingGlossary(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Arbitrage Pricing", 1, 1, 1)
  GameTooltip:AddLine(
    "Market Value: Estimated low-end Auction House price from the last 14 days of scans; recent days count more.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Typical uses Market Value for both materials and sales. Last Scan uses the lowest per-unit buyouts from the last full scan for both.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Buy Now, Sell Later uses the same scanned material cost for both profit columns. Sales use either the scanned price or Market Value.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Net Sale: The better of Auction House proceeds after the 5% cut and vendor sell value; each craft is tagged AH or Vendor.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Craft Cost includes unlimited-stock vendors and intermediate crafts. Profit is Net Sale minus Craft Cost.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Yellow values are uncertain, such as prices with fewer than 3 days of scans; hover a craft to see why.",
    1,
    0.82,
    0,
    true
  )
  GameTooltip:AddLine(
    "All values are per item. Excludes deposits, listing depth, sale rate, inventory, and cooldowns.",
    nil,
    nil,
    nil,
    true
  )
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
    GameTooltip:AddLine(CANCEL_TOOLTIP, 1, 1, 1, true)
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

-- Why the button is disabled, if it is, how old the stored prices are, and how this session's latest
-- scan ended. The age comes from the database, so it survives a reload and includes synced scans.
---@param scanButton ArbitrageScanButton
local function ShowScanTooltip(scanButton)
  GameTooltip:SetOwner(scanButton, "ANCHOR_RIGHT")
  if scanButton.disabledTooltip then
    GameTooltip:AddLine(scanButton.disabledTooltip, 1, 1, 1, true)
  end
  local latestScan = ns.Database.GetStatus().latestScan
  local scanAge = latestScan and ns.Time.Since(latestScan)
  GameTooltip:AddLine(scanAge and "Last scan: " .. scanAge or "No scans yet", NORMAL_FONT_COLOR:GetRGB())
  local outcome = ns.Scan.GetLastOutcome()
  if outcome then
    -- A scan that stored prices reports just after saving them, so its age is already shown.
    local outcomeAge = ns.Time.Since(outcome.at)
    if outcomeAge ~= scanAge then
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
  local overlay = entry.scanOverlay
  local phase = scanStatus.phase
  if phase ~= "idle" then
    scanButton.disabledTooltip = nil
    scanButton:Disable()
    scanButton:SetText("Full Scan")
    entry.table.SetEmptyMessage(nil)

    local waiting = phase == "waiting"
    overlay.spinner:SetShown(waiting)
    overlay.progressBar:SetShown(not waiting)
    overlay.cancelButton:SetShown(waiting)
    local guidance = phase == "pricing" and PRICING_GUIDANCE or READING_GUIDANCE
    if waiting then
      local seconds = scanStatus.elapsedSeconds or 0
      local label = "Waiting for auction data from the server"
      if seconds > 60 then
        label = "This is taking much longer than expected"
        guidance = LONG_WAIT_GUIDANCE
      elseif seconds > 30 then
        label = "This is taking longer than usual"
      end
      overlay.statusText:SetText(("%s... %d:%02d"):format(label, math.floor(seconds / 60), seconds % 60))
    else
      local progress = scanStatus.progress or 0
      overlay.progressBar:SetFillPercent(progress / 100)
      local label = phase == "reading" and "Reading auctions" or "Calculating and saving Market Values"
      overlay.statusText:SetText(("%s... %d%%"):format(label, progress))
    end
    overlay.guidance:SetText(guidance)
    overlay:Show()
  else
    local cooldown = scanStatus.cooldownRemainingMinutes
    scanButton.disabledTooltip = not auctionHouseOpen and AWAY_SCAN_TOOLTIP
      or atNeutralAuctionHouse and NEUTRAL_SCAN_TOOLTIP
      or nil
    scanButton:SetEnabled(auctionHouseOpen and not atNeutralAuctionHouse and not cooldown)
    scanButton:SetText(cooldown and ("Full Scan (" .. cooldown .. "m)") or "Full Scan")
    overlay:Hide()
    entry.table.SetEmptyMessage(entry.idleEmptyMessage)
  end

  if GameTooltip:IsOwned(scanButton) then
    ShowScanTooltip(scanButton)
  end
end

function ns.OpportunityPanel.RefreshScanStatus()
  if #panels == 0 then
    return
  end

  local scanStatus = ns.Scan.GetStatus()
  local auctionHouseOpen = IsAuctionHouseOpen()
  local atNeutralAuctionHouse = auctionHouseOpen and ns.Scan.IsAtNeutralAuctionHouse()
  for _, entry in ipairs(panels) do
    ApplyScanStatus(entry, scanStatus, auctionHouseOpen, atNeutralAuctionHouse)
  end
end

-- Filters are saved across sessions and sit in nested menus, so while any are active they are listed
-- above the table, which moves down a row to make room; otherwise the table fills the panel.
---@param entry ArbitrageOpportunityPanelEntry
---@param visibleCount number
---@param pricedCount number
local function ShowActiveFilters(entry, visibleCount, pricedCount)
  local filters = DescribeFilters()
  local text = ""
  if filters then
    -- The count leads, so a long list of filters is what gets cut short. Crafts without complete
    -- prices are never listed, so only priced ones make up the total.
    local count = BreakUpLargeNumbers(visibleCount) .. " of " .. BreakUpLargeNumbers(pricedCount) .. " crafts"
    text = count .. " · Filters: " .. filters
  end
  entry.filterText:SetText(text)
  entry.table.frame:SetPoint("TOPLEFT", entry.content, "TOPLEFT", 16, filters and -52 or -32)
end

---@param entry ArbitrageOpportunityPanelEntry
local function ShowPricingMode(entry)
  entry.panel:SetScript("OnUpdate", nil)
  for _, choice in ipairs(PRICING_CHOICES) do
    local button = entry.pricingButtons[choice.mode]
    if pricingMode == choice.mode then
      button:LockHighlight()
      if pricingMode == "typical" then
        entry.pricingText:SetText(choice.description)
      elseif pricingScanTime then
        local function UpdateAge()
          entry.pricingText:SetText(choice.description .. "  Last full scan: " .. ns.Time.Since(pricingScanTime))
        end
        UpdateAge()
        local elapsed = 0
        entry.panel:SetScript("OnUpdate", function(_, delta)
          elapsed = elapsed + delta
          if elapsed >= 15 then
            elapsed = 0
            UpdateAge()
          end
        end)
      else
        entry.pricingText:SetText(choice.description .. "  No full scan yet.")
      end
    else
      button:UnlockHighlight()
    end
  end
  ns.OpportunityTable.SetPricingMode(entry.table, pricingMode)
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
  ShowActiveFilters(entry, visibleCount, result.pricedCount)

  local emptyMessage
  if result.totalCount == 0 then
    emptyMessage = "No known recipes. Open each character's profession window to record learned recipes."
  elseif result.pricedCount == 0 and pricingMode ~= "typical" and not pricingScanTime then
    emptyMessage = "No full scan yet. Run a full scan to see opportunities at scanned prices."
  elseif result.pricedCount == 0 and pricingMode ~= "typical" then
    emptyMessage = "No known crafts have the prices needed for this view."
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

function ns.OpportunityPanel.Refresh()
  if #panels == 0 then
    return
  end

  pricingScanTime = ns.Database.GetStatus().latestScan
  result = ns.Opportunities.Get(pricingMode)
  hasRecentScan = pricingScanTime ~= nil and pricingScanTime >= time() - MARKET_VALUE_WINDOW_SECONDS

  for _, entry in ipairs(panels) do
    entry.filterDropdown:ValidateResetState()
    ShowPricingMode(entry)
    ShowResult(entry)
  end
  ns.OpportunityPanel.RefreshScanStatus()
end

---@param panel Frame
---@param controlsParent Frame
---@return ArbitrageOpportunityPanelEntry
function ns.OpportunityPanel.Create(panel, controlsParent)
  panel:SetScript("OnShow", ns.OpportunityPanel.Refresh)

  -- Holds every control, so the Auction House tab can swap them for its neutral Auction House notice.
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
  filterText:SetPoint("TOPLEFT", content, "TOPLEFT", 20, -36)
  filterText:SetPoint("TOPRIGHT", content, "TOPRIGHT", -27, -36)
  filterText:SetJustifyH("LEFT")
  filterText:SetWordWrap(false)

  local opportunityTable = ns.OpportunityTable.Create(content)
  opportunityTable.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -32)
  local pricingButtons = {}
  local x = 20
  for _, choice in ipairs(PRICING_CHOICES) do
    local mode = choice.mode
    local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    button:SetSize(choice.width, 22)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", x, -4)
    button:SetText(choice.label)
    button:SetScript("OnClick", function()
      if pricingMode ~= mode then
        pricingMode = mode
        ns.OpportunityPanel.Refresh()
      end
    end)
    pricingButtons[mode] = button
    x = x + choice.width + 4
  end
  local pricingText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  pricingText:SetPoint("LEFT", pricingButtons.sellLater, "RIGHT", 10, 0)
  pricingText:SetPoint("RIGHT", content, "TOPRIGHT", -27, -15)
  pricingText:SetJustifyH("LEFT")
  pricingText:SetWordWrap(false)

  local scanButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  ---@cast scanButton ArbitrageScanButton
  scanButton:SetSize(132, 22)
  scanButton:SetPoint("TOPRIGHT", controlsParent, "TOPRIGHT", -12, -38)
  scanButton:SetText("Full Scan")
  scanButton:SetMotionScriptsWhileDisabled(true)
  scanButton:SetScript("OnClick", ns.Scan.Start)
  scanButton:SetScript("OnEnter", ShowScanTooltip)
  scanButton:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)

  local filterDropdown = CreateFrame("DropdownButton", nil, content, "WowStyle1FilterDropdownTemplate")
  ---@cast filterDropdown ArbitrageFilterDropdown
  filterDropdown:SetWidth(93)
  filterDropdown:SetPoint("RIGHT", scanButton, "LEFT", -10, 0)
  filterDropdown:SetIsDefaultCallback(AreFiltersDefault)
  filterDropdown:SetDefaultCallback(ResetFiltersToDefault)
  filterDropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("MENU_ARBITRAGE_OPPORTUNITIES_FILTER")
    local profitMenu = rootDescription:CreateButton("Minimum profit")
    profitMenu:SetTitleAndTextTooltip("Minimum profit", "Hides crafts earning less than this per item.")
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
    saleMenu:SetTitleAndTextTooltip("Sell to", "Shows crafts whose better sale is to the Auction House or a vendor.")
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
        "Hides crafts whose prices are still uncertain, such as those with fewer than 3 days of scans."
      )
  end)
  filterDropdown:ValidateResetState()

  local settingsButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", filterDropdown, "LEFT", -10, 0)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", ns.Config.OpenOptionsPanel)

  local searchBox = CreateFrame("EditBox", nil, content, "SearchBoxTemplate")
  ---@cast searchBox ArbitrageSearchBox
  searchBox:SetSize(200, 20)
  searchBox:SetPoint("RIGHT", settingsButton, "LEFT", -12, 0)
  searchBox:SetAutoFocus(false)
  searchBox.Instructions:SetText("Search by name or item ID")

  ---@type ArbitrageOpportunityPanelEntry
  local entry = {
    panel = panel,
    content = content,
    filterText = filterText,
    pricingText = pricingText,
    pricingButtons = pricingButtons,
    searchBox = searchBox,
    scanButton = scanButton,
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

local function CreateAuctionHouseTab()
  if auctionHousePanel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  auctionHousePanel = CreateFrame("Frame", addonName .. "AuctionHouseFrame", auctionHouseFrame)
  auctionHousePanel:SetPoint("TOPLEFT", auctionHouseFrame, "TOPLEFT", 4, -69)
  auctionHousePanel:SetPoint("BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -5, 32)
  auctionHousePanel:Hide()

  auctionHouseEntry = ns.OpportunityPanel.Create(auctionHousePanel, auctionHouseFrame)
  neutralNotice = auctionHousePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  neutralNotice:SetPoint("LEFT", auctionHousePanel, "LEFT", 60, 0)
  neutralNotice:SetPoint("RIGHT", auctionHousePanel, "RIGHT", -60, 0)
  neutralNotice:SetText(NEUTRAL_NOTICE)
  neutralNotice:Hide()
  LibStub("LibAHTab-1-0"):CreateTab(addonName, auctionHousePanel, addonName, addonName)
end

-- At a neutral Auction House the tab holds only the notice explaining why it is empty.
local function ShowAuctionHouseTabContent()
  local atNeutralAuctionHouse = ns.Scan.IsAtNeutralAuctionHouse()
  auctionHouseEntry.content:SetShown(not atNeutralAuctionHouse)
  neutralNotice:SetShown(atNeutralAuctionHouse)
end

function ns.OpportunityPanel.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      CreateAuctionHouseTab()
      ShowAuctionHouseTabContent()
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

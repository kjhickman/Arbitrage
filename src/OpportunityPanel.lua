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

---@class ArbitrageOpportunityPanelEntry
---@field panel Frame
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
---@type ArbitrageOpportunityFilterKey[]
local FILTER_KEYS = {
  "minimumProfit",
  "includeBestCaseOnly",
  "showUncertainOpportunities",
  "opportunityProfession",
  "opportunityCrafter",
  "opportunitySaleMethod",
}

local frame = CreateFrame("Frame")
---@type Frame?
local auctionHousePanel
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
    "Market Value: Estimated low-end Auction House price from your scans; recent scan days count more.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Crafting Cost: Estimated cheapest route using rolling Auction House values, unlimited-stock vendors, and intermediate crafts.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Best-case Crafting Cost: The same recipe priced with the cheapest per-unit buyouts from the latest full scan.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine("Yellow values have limited, stale, volatile, or fallback market data.", 1, 0.82, 0, true)
  GameTooltip:AddLine(
    "Net Sale: The higher of Auction House proceeds after its cut and vendor sell value. The sale method is shown beside the crafter; hover a craft to compare profits.",
    nil,
    nil,
    nil,
    true
  )
  GameTooltip:AddLine(
    "Auction House sales include its cut; vendor sales have no cut. Excludes deposits, listing depth, sale rate, inventory, and cooldowns.",
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

---@param key "includeBestCaseOnly"|"showUncertainOpportunities"
---@return boolean
local function IsFilterSelected(key)
  return ns.Config.Get(key) == true
end

---@param key "includeBestCaseOnly"|"showUncertainOpportunities"
local function ToggleFilter(key)
  SetFilter(key, not IsFilterSelected(key))
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
  guidance:SetText("This can take a minute. Keep the Auction House open; closing it cancels the scan.")

  return overlay
end

---@param entry ArbitrageOpportunityPanelEntry
---@param scanStatus ArbitrageScanStatus
---@param auctionHouseOpen boolean
local function ApplyScanStatus(entry, scanStatus, auctionHouseOpen)
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
    if waiting then
      local seconds = scanStatus.elapsedSeconds or 0
      overlay.statusText:SetText(
        ("Waiting for auction data from the server... %d:%02d"):format(math.floor(seconds / 60), seconds % 60)
      )
    else
      local progress = scanStatus.progress or 0
      overlay.progressBar:SetFillPercent(progress / 100)
      local label = phase == "reading" and "Reading auctions" or "Calculating and saving market values"
      overlay.statusText:SetText(("%s... %d%%"):format(label, progress))
    end
    overlay:Show()
  else
    local cooldown = scanStatus.cooldownRemainingMinutes
    scanButton.disabledTooltip = not auctionHouseOpen and AWAY_SCAN_TOOLTIP or nil
    scanButton:SetEnabled(auctionHouseOpen and not cooldown)
    scanButton:SetText(cooldown and ("Full Scan (" .. cooldown .. "m)") or "Full Scan")
    overlay:Hide()
    entry.table.SetEmptyMessage(entry.idleEmptyMessage)
  end

  if not scanButton.disabledTooltip and GameTooltip:IsOwned(scanButton) then
    GameTooltip:Hide()
  end
end

function ns.OpportunityPanel.RefreshScanStatus()
  if #panels == 0 then
    return
  end

  local scanStatus = ns.Scan.GetStatus()
  local auctionHouseOpen = IsAuctionHouseOpen()
  for _, entry in ipairs(panels) do
    ApplyScanStatus(entry, scanStatus, auctionHouseOpen)
  end
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

  local emptyMessage
  if result.totalCount == 0 then
    emptyMessage = "No known recipes. Open each character's profession window to record learned recipes."
  elseif visibleCount == 0 and result.pricedCount == 0 and not hasRecentScan then
    emptyMessage = "No Auction House scan data. Run a full scan to price known crafts."
  elseif result.pricedCount == 0 then
    emptyMessage = "No known crafts have complete output and material prices."
  -- Only speak up when the list is actually empty; the notice draws over the rows otherwise.
  elseif visibleCount == 0 and query ~= "" then
    emptyMessage = "No crafts match the current search and filters."
  elseif visibleCount == 0 and result.profitableCount == 0 then
    emptyMessage = "No known crafts are currently profitable."
  elseif visibleCount == 0 then
    emptyMessage = "No crafts match the current filters."
  end
  entry.idleEmptyMessage = emptyMessage
end

function ns.OpportunityPanel.Refresh()
  if #panels == 0 then
    return
  end

  local latestScan = ns.Database.GetStatus().latestScan
  result = ns.Opportunities.Get()
  hasRecentScan = latestScan ~= nil and latestScan >= time() - MARKET_VALUE_WINDOW_SECONDS

  for _, entry in ipairs(panels) do
    entry.filterDropdown:ValidateResetState()
    ShowResult(entry)
  end
  ns.OpportunityPanel.RefreshScanStatus()
end

---@param panel Frame
---@param controlsParent Frame
function ns.OpportunityPanel.Create(panel, controlsParent)
  panel:SetScript("OnShow", ns.OpportunityPanel.Refresh)

  -- Centered on the control row, clear of the portrait.
  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("LEFT", controlsParent, "TOPLEFT", 66, -49)
  heading:SetText("Opportunities")

  local glossaryButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  glossaryButton:SetSize(22, 22)
  glossaryButton:SetPoint("LEFT", heading, "RIGHT", 8, 0)
  glossaryButton:SetText("?")
  glossaryButton:SetScript("OnEnter", ShowPricingGlossary)
  glossaryButton:SetScript("OnLeave", HidePricingGlossary)

  local opportunityTable = ns.OpportunityTable.Create(panel)

  local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  ---@cast scanButton ArbitrageScanButton
  scanButton:SetSize(132, 22)
  scanButton:SetPoint("TOPRIGHT", controlsParent, "TOPRIGHT", -12, -38)
  scanButton:SetText("Full Scan")
  scanButton:SetMotionScriptsWhileDisabled(true)
  scanButton:SetScript("OnClick", ns.Scan.Start)
  scanButton:SetScript("OnEnter", function(self)
    if self.disabledTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(self.disabledTooltip, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  scanButton:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)

  local filterDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1FilterDropdownTemplate")
  ---@cast filterDropdown ArbitrageFilterDropdown
  filterDropdown:SetWidth(93)
  filterDropdown:SetPoint("RIGHT", scanButton, "LEFT", -10, 0)
  filterDropdown:SetIsDefaultCallback(AreFiltersDefault)
  filterDropdown:SetDefaultCallback(ResetFiltersToDefault)
  filterDropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("MENU_ARBITRAGE_OPPORTUNITIES_FILTER")
    local profitMenu = rootDescription:CreateButton("Minimum profit")
    profitMenu:SetTitleAndTextTooltip("Minimum profit", "Hides crafts earning less than this per craft.")
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
      :CreateCheckbox("Best-case-only opportunities", IsFilterSelected, ToggleFilter, "includeBestCaseOnly")
      :SetTitleAndTextTooltip(
        "Best-case-only opportunities",
        "Includes crafts that are profitable only when materials can be bought at Best Cost."
      )
    rootDescription
      :CreateCheckbox("Uncertain opportunities", IsFilterSelected, ToggleFilter, "showUncertainOpportunities")
      :SetTitleAndTextTooltip(
        "Uncertain opportunities",
        "Includes opportunities based on limited, stale, volatile, or fallback market data."
      )
  end)
  filterDropdown:ValidateResetState()

  local settingsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", filterDropdown, "LEFT", -10, 0)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", ns.Config.OpenOptionsPanel)

  local searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
  ---@cast searchBox ArbitrageSearchBox
  searchBox:SetSize(200, 20)
  searchBox:SetPoint("RIGHT", settingsButton, "LEFT", -12, 0)
  searchBox:SetAutoFocus(false)
  searchBox.Instructions:SetText("Search by name or item ID")

  ---@type ArbitrageOpportunityPanelEntry
  local entry = {
    panel = panel,
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

  ns.OpportunityPanel.Create(auctionHousePanel, auctionHouseFrame)
  LibStub("LibAHTab-1-0"):CreateTab(addonName, auctionHousePanel, addonName, addonName)
end

function ns.OpportunityPanel.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      CreateAuctionHouseTab()
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

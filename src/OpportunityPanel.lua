local addonName, ns = ...

ns.OpportunityPanel = {}

---@class ArbitrageScanButton : Button
---@field disabledTooltip string?

---@class ArbitrageFilterDropdown : DropdownButton
---@field ValidateResetState fun(self: ArbitrageFilterDropdown)

---@class ArbitrageOpportunityPanelEntry
---@field panel Frame
---@field summaryText FontString
---@field scanButton ArbitrageScanButton
---@field filterDropdown ArbitrageFilterDropdown
---@field table ArbitrageItemTable

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }
local AWAY_SCAN_TOOLTIP = "Open the Auction House to run a full scan."

local frame = CreateFrame("Frame")
---@type Frame?
local auctionHousePanel
---@type ArbitrageOpportunityPanelEntry[]
local panels = {}
local idleSummaryText = ""
---@type string?
local idleEmptyMessage
local hasVisibleItems = false
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

---@param key "minimumProfit"|"includeBestCaseOnly"|"showUncertainOpportunities"
---@param value boolean|number
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

---@param copper number
---@return boolean
local function IsMinimumProfitSelected(copper)
  return ns.Config.Get("minimumProfit") == copper
end

---@param copper number
local function SetMinimumProfit(copper)
  SetFilter("minimumProfit", copper)
end

---@return boolean
local function AreFiltersDefault()
  return IsMinimumProfitSelected(1)
    and IsFilterSelected("includeBestCaseOnly")
    and IsFilterSelected("showUncertainOpportunities")
end

local function ResetFiltersToDefault()
  ns.Config.Set("minimumProfit", 1)
  ns.Config.Set("includeBestCaseOnly", true)
  SetFilter("showUncertainOpportunities", true)
end

---@param entry ArbitrageOpportunityPanelEntry
---@param scanStatus ArbitrageScanStatus
---@param auctionHouseOpen boolean
local function ApplyScanStatus(entry, scanStatus, auctionHouseOpen)
  local scanButton = entry.scanButton
  if scanStatus.phase ~= "idle" then
    local progress = scanStatus.progress or 0
    local step = scanStatus.phase == "reading" and ("reading auctions (" .. progress .. "%)")
      or scanStatus.phase == "pricing" and "calculating prices"
      or "waiting for server"
    scanButton.disabledTooltip = nil
    scanButton:Disable()
    scanButton:SetText(scanStatus.phase == "reading" and ("Scanning... " .. progress .. "%") or "Scanning...")
    entry.summaryText:SetText("Scanning Auction House — " .. step .. "... Keep the Auction House open.")
    entry.table.SetEmptyMessage(
      not hasVisibleItems and "Scanning Auction House... Results will appear when the scan finishes." or nil
    )
  else
    local cooldown = scanStatus.cooldownRemainingMinutes
    scanButton.disabledTooltip = not auctionHouseOpen and AWAY_SCAN_TOOLTIP or nil
    scanButton:SetEnabled(auctionHouseOpen and not cooldown)
    scanButton:SetText(cooldown and ("Full Scan (" .. cooldown .. "m)") or "Full Scan")
    entry.summaryText:SetText(idleSummaryText)
    entry.table.SetEmptyMessage(idleEmptyMessage)
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

function ns.OpportunityPanel.Refresh()
  if #panels == 0 then
    return
  end

  local status = ns.Database.GetStatus()
  local result = ns.Opportunities.Get()
  local visibleCount = #result.items
  hasVisibleItems = visibleCount > 0
  local latestScan = status.latestScan and ns.Time.Since(status.latestScan) or "unknown"
  idleSummaryText = result.totalCount
    .. " known crafts | "
    .. result.profitableCount
    .. " profitable | Last scan: "
    .. latestScan
    .. " | "
    .. status.recentScanCount
    .. " scans / 14 days"

  idleEmptyMessage = nil
  if result.totalCount == 0 then
    idleEmptyMessage = "No known recipes. Open each character's profession window to record learned recipes."
  elseif
    visibleCount == 0
    and result.pricedCount == 0
    and (status.latestScan == nil or status.latestScan < time() - MARKET_VALUE_WINDOW_SECONDS)
  then
    idleEmptyMessage = "No Auction House scan data. Run a full scan to price known crafts."
  elseif result.pricedCount == 0 then
    idleEmptyMessage = "No known crafts have complete output and material prices."
  -- Only speak up when the list is actually empty; the notice draws over the rows otherwise.
  elseif visibleCount == 0 and result.profitableCount == 0 then
    idleEmptyMessage = "No known crafts are currently profitable."
  elseif visibleCount == 0 then
    idleEmptyMessage = "No crafts match the current filters."
  end

  for _, entry in ipairs(panels) do
    entry.filterDropdown:ValidateResetState()
    entry.table.SetItems(result.items)
  end
  ns.OpportunityPanel.RefreshScanStatus()
end

---@param panel Frame
---@param controlsParent Frame
function ns.OpportunityPanel.Create(panel, controlsParent)
  panel:SetScript("OnShow", ns.OpportunityPanel.Refresh)

  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", 20, -18)
  heading:SetText("Craft Opportunities")

  local glossaryButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  glossaryButton:SetSize(22, 22)
  glossaryButton:SetPoint("LEFT", heading, "RIGHT", 8, 0)
  glossaryButton:SetText("?")
  glossaryButton:SetScript("OnEnter", ShowPricingGlossary)
  glossaryButton:SetScript("OnLeave", HidePricingGlossary)

  local summaryText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  summaryText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -44)
  summaryText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -145, -44)
  summaryText:SetJustifyH("LEFT")

  local uncertaintyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  uncertaintyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  uncertaintyText:SetText("Yellow values are uncertain; more market data is needed.")
  uncertaintyText:SetTextColor(NORMAL_FONT_COLOR:GetRGB())

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
    for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
      local label = MINIMUM_PROFIT_LABELS[copper] or C_CurrencyInfo.GetCoinTextureString(copper, 10)
      profitMenu:CreateRadio(label, IsMinimumProfitSelected, SetMinimumProfit, copper)
    end
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

  panels[#panels + 1] = {
    panel = panel,
    summaryText = summaryText,
    scanButton = scanButton,
    filterDropdown = filterDropdown,
    table = opportunityTable,
  }
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

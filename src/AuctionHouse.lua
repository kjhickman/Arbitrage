local addonName, ns = ...

ns.AuctionHouse = {}

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }

local frame = CreateFrame("Frame")
local panel
local summaryText
local scanButton
local idleSummaryText = ""
local idleEmptyMessage
local hasVisibleItems = false
local priceRefreshPending = false

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

function ns.AuctionHouse.RefreshScanStatus()
  if not summaryText or not scanButton then
    return
  end

  local scanStatus = ns.Scan.GetStatus()
  if scanStatus.phase ~= "idle" then
    local progress = scanStatus.progress or 0
    local step = scanStatus.phase == "reading" and ("reading auctions (" .. progress .. "%)")
      or scanStatus.phase == "pricing" and "calculating prices"
      or "waiting for server"
    scanButton:Disable()
    scanButton:SetText(scanStatus.phase == "reading" and ("Scanning... " .. progress .. "%") or "Scanning...")
    summaryText:SetText("Scanning Auction House — " .. step .. "... Keep the Auction House open.")
    ns.OpportunityTable.SetEmptyMessage(
      not hasVisibleItems and "Scanning Auction House... Results will appear when the scan finishes." or nil
    )
    return
  end

  if scanStatus.cooldownRemainingMinutes then
    scanButton:Disable()
    scanButton:SetText("Full Scan (" .. scanStatus.cooldownRemainingMinutes .. "m)")
  else
    scanButton:Enable()
    scanButton:SetText("Full Scan")
  end
  summaryText:SetText(idleSummaryText)
  ns.OpportunityTable.SetEmptyMessage(idleEmptyMessage)
end

function ns.AuctionHouse.Refresh()
  if not summaryText then
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

  ns.OpportunityTable.SetItems(result.items)
  ns.AuctionHouse.RefreshScanStatus()
end

local function CreateAuctionHouseTab()
  if panel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  panel = CreateFrame("Frame", addonName .. "AuctionHouseFrame", auctionHouseFrame)
  panel:SetPoint("TOPLEFT", auctionHouseFrame, "TOPLEFT", 4, -69)
  panel:SetPoint("BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -5, 32)
  panel:Hide()
  panel:SetScript("OnShow", ns.AuctionHouse.Refresh)

  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", 20, -18)
  heading:SetText("Craft Opportunities")

  local glossaryButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  glossaryButton:SetSize(22, 22)
  glossaryButton:SetPoint("LEFT", heading, "RIGHT", 8, 0)
  glossaryButton:SetText("?")
  glossaryButton:SetScript("OnEnter", ShowPricingGlossary)
  glossaryButton:SetScript("OnLeave", HidePricingGlossary)

  summaryText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  summaryText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -44)
  summaryText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -145, -44)
  summaryText:SetJustifyH("LEFT")

  local uncertaintyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  uncertaintyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  uncertaintyText:SetText("Yellow values are uncertain; more market data is needed.")
  uncertaintyText:SetTextColor(NORMAL_FONT_COLOR:GetRGB())

  ns.OpportunityTable.Create(panel)

  scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scanButton:SetSize(132, 22)
  scanButton:SetPoint("TOPRIGHT", auctionHouseFrame, "TOPRIGHT", -12, -38)
  scanButton:SetText("Full Scan")
  scanButton:SetScript("OnClick", ns.Scan.Start)

  local function SetFilter(key, value)
    ns.Config.Set(key, value)
    ns.AuctionHouse.Refresh()
  end

  local function IsFilterSelected(key)
    return ns.Config.Get(key) == true
  end

  local function ToggleFilter(key)
    SetFilter(key, not IsFilterSelected(key))
  end

  local function IsMinimumProfitSelected(copper)
    return ns.Config.Get("minimumProfit") == copper
  end

  local function SetMinimumProfit(copper)
    SetFilter("minimumProfit", copper)
  end

  local filterDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1FilterDropdownTemplate")
  filterDropdown:SetWidth(93)
  filterDropdown:SetPoint("RIGHT", scanButton, "LEFT", -10, 0)
  filterDropdown:SetIsDefaultCallback(function()
    return IsMinimumProfitSelected(1)
      and IsFilterSelected("includeBestCaseOnly")
      and IsFilterSelected("showUncertainOpportunities")
  end)
  filterDropdown:SetDefaultCallback(function()
    ns.Config.Set("minimumProfit", 1)
    ns.Config.Set("includeBestCaseOnly", true)
    SetFilter("showUncertainOpportunities", true)
  end)
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

  local settingsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", filterDropdown, "LEFT", -10, 0)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", ns.Config.OpenOptionsPanel)

  LibStub("LibAHTab-1-0"):CreateTab(addonName, panel, addonName, addonName)
end

function ns.AuctionHouse.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      CreateAuctionHouseTab()
    elseif eventName == "GET_ITEM_INFO_RECEIVED" then
      ns.OpportunityTable.HandleItemInfoReceived(itemID, success)
      if ns.Opportunities.HandleItemInfoReceived(itemID, success) and not priceRefreshPending then
        priceRefreshPending = true
        C_Timer.After(0, function()
          priceRefreshPending = false
          ns.AuctionHouse.Refresh()
        end)
      end
    end
  end)
end

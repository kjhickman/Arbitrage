local addonName, ns = ...

ns.AuctionHouse = {}

local MARKET_VALUE_WINDOW_SECONDS = 14 * 24 * 60 * 60

local frame = CreateFrame("Frame")
local panel
local summaryText

function ns.AuctionHouse.Refresh()
  if not summaryText then
    return
  end

  local status = ns.Database.GetStatus()
  local result = ns.Opportunities.Get()
  local profitableCount = #result.items
  local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"
  summaryText:SetText(
    result.totalCount
      .. " known crafts | "
      .. profitableCount
      .. " profitable | Last scan: "
      .. latestScan
      .. " | "
      .. status.recentScanCount
      .. " scans / 14 days"
  )

  local emptyMessage
  if result.totalCount == 0 then
    emptyMessage = "No known recipes. Open each character's profession window to record learned recipes."
  elseif
    profitableCount == 0 and (status.latestScan == nil or status.latestScan < time() - MARKET_VALUE_WINDOW_SECONDS)
  then
    emptyMessage = "No Auction House scan data. Run a full scan to price known crafts."
  elseif result.pricedCount == 0 then
    emptyMessage = "No known crafts have complete output and material prices."
  elseif profitableCount == 0 then
    emptyMessage = "No known crafts are currently profitable."
  end

  ns.OpportunityTable.SetEmptyMessage(emptyMessage)
  ns.OpportunityTable.SetItems(result.items)
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

  summaryText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  summaryText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -44)
  summaryText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -145, -44)
  summaryText:SetJustifyH("LEFT")

  local uncertaintyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  uncertaintyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  uncertaintyText:SetText("Yellow values are uncertain; more market data is needed.")
  uncertaintyText:SetTextColor(NORMAL_FONT_COLOR:GetRGB())

  ns.OpportunityTable.Create(panel)

  local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scanButton:SetSize(132, 22)
  scanButton:SetPoint("TOPRIGHT", auctionHouseFrame, "TOPRIGHT", -12, -38)
  scanButton:SetText("Full Scan")
  scanButton:SetScript("OnClick", ns.Scan.Start)

  local settingsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("RIGHT", scanButton, "LEFT", -10, 0)
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
    end
  end)
end

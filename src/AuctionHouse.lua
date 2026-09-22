local addonName, ns = ...

ns.AuctionHouse = {}

local frame = CreateFrame("Frame")
local panel
local statusText

local function EnabledLabel(value)
  return value and "enabled" or "disabled"
end

function ns.AuctionHouse.Refresh()
  if not statusText then
    return
  end

  local status = ns.Database.GetStatus()
  local recipeStatus = ns.RecipeBook.GetStatus()
  local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"

  statusText:SetText(table.concat({
    "Stored items: " .. status.itemCount,
    "Known vendor prices: " .. ns.Database.CountVendorPrices(),
    "Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters",
    "Tooltips: " .. EnabledLabel(ns.Config.Get("showTooltips")),
    "Crafting cost: " .. EnabledLabel(ns.Config.Get("showCraftingCost")),
    "Minimum craft cost: " .. EnabledLabel(ns.Config.Get("showMinimumCraftCost")),
    "Latest scan: " .. latestScan,
    "Scans in last 14 days: " .. status.recentScanCount,
  }, "\n"))
end

local function CreateAuctionHouseTab()
  if panel then
    return
  end

  local auctionHouseFrame = AuctionHouseFrame
  panel = CreateFrame("Frame", addonName .. "AuctionHouseFrame", auctionHouseFrame, "InsetFrameTemplate")
  panel:SetPoint("TOPLEFT", auctionHouseFrame, "TOPLEFT", 4, -69)
  panel:SetPoint("BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -5, 32)
  panel:Hide()
  panel:SetScript("OnShow", ns.AuctionHouse.Refresh)

  local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", 20, -20)
  heading:SetText("Status")

  statusText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  statusText:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -12)
  statusText:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetJustifyV("TOP")
  statusText:SetSpacing(4)

  local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scanButton:SetSize(120, 22)
  scanButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)
  scanButton:SetText("Full Scan")
  scanButton:SetScript("OnClick", ns.Scan.Start)

  local libStub = rawget(_G, "LibStub")
  local libAHTab = libStub and libStub("LibAHTab-1-0", true)
  if libAHTab then
    libAHTab:CreateTab(addonName, panel, addonName, addonName)
    return
  end

  local tabParent = CreateFrame("Frame", nil, auctionHouseFrame)
  local tab =
    CreateFrame("Button", addonName .. "AuctionHouseTab", tabParent, "AuctionHouseFrameDisplayModeTabTemplate")
  tab:SetText("Arbitrage")
  tab:SetPoint("LEFT", auctionHouseFrame.AuctionsTab, "RIGHT", 3, 0)
  PanelTemplates_TabResize(tab, 20, nil, 70)
  PanelTemplates_DeselectTab(tab)

  hooksecurefunc(auctionHouseFrame, "SetDisplayMode", function(_, displayMode)
    if displayMode and #displayMode > 0 then
      panel:Hide()
      PanelTemplates_DeselectTab(tab)
    end
  end)

  tab:SetScript("OnClick", function()
    auctionHouseFrame:SetDisplayMode({})
    auctionHouseFrame.displayMode = nil
    for _, auctionHouseTab in ipairs(auctionHouseFrame.Tabs) do
      PanelTemplates_DeselectTab(auctionHouseTab)
    end
    PanelTemplates_SelectTab(tab)
    auctionHouseFrame:SetTitle(addonName)
    panel:Show()
  end)
end

function ns.AuctionHouse.Register()
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:SetScript("OnEvent", CreateAuctionHouseTab)
end

local _, ns = ...

ns.Tooltip = {}

local LABEL = "Market Value"

local function ShouldShowStackPrice(itemCount)
  local showStackPrices = IsShiftKeyDown()

  if not Auctionator.Config.Get(Auctionator.Config.Options.SHIFT_STACK_TOOLTIPS) then
    showStackPrices = not IsShiftKeyDown()
  end

  return showStackPrices and itemCount ~= nil and itemCount > 1
end

local function FormatMoney(value, color)
  return color:WrapTextInColorCode(Auctionator.Utilities.CreatePaddedMoneyString(value))
end

local function FormatUnknown()
  return WHITE_FONT_COLOR:WrapTextInColorCode(Auctionator.Locales.Apply("UNKNOWN") .. "  ")
end

local function CanAuction(itemLink)
  local itemInfo = { C_Item.GetItemInfo(itemLink) }

  return #itemInfo ~= 0 and not Auctionator.Utilities.IsBound(itemInfo)
end

local function AddStatusLine(tooltipFrame, result)
  if not IsShiftKeyDown() then
    return
  end

  local latestAge = result.latestAgeDays
  local detail = result.dayCount .. " days, " .. result.scanCount .. " scans, latest " .. latestAge .. "d ago"

  if result.isUncertain then
    detail = detail .. " (" .. table.concat(result.reasons, ", ") .. ")"
  end

  tooltipFrame:AddDoubleLine("MP data", WHITE_FONT_COLOR:WrapTextInColorCode(detail))
end

function ns.Tooltip.AddMarketValue(tooltipFrame, dbKeys, itemLink, itemCount)
  if not ns.Config.Get("showTooltips") then
    return
  end

  if type(dbKeys) ~= "table" or #dbKeys == 0 then
    return
  end

  if not CanAuction(itemLink) then
    return
  end

  local result = ns.Database.GetRollingMarketValue(dbKeys)

  if result == nil then
    tooltipFrame:AddDoubleLine(LABEL, FormatUnknown())
    return
  end

  local value = result.value
  local countString = ""
  if ShouldShowStackPrice(itemCount) then
    value = value * itemCount
    countString = Auctionator.Utilities.CreateCountString(itemCount)
  end

  local color = result.isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  tooltipFrame:AddDoubleLine(LABEL .. countString, FormatMoney(value, color))
  AddStatusLine(tooltipFrame, result)
end

function ns.Tooltip.Register()
  if not (Auctionator and Auctionator.Tooltip and Auctionator.Tooltip.ShowTipWithPricingDBKey) then
    return false
  end

  hooksecurefunc(Auctionator.Tooltip, "ShowTipWithPricingDBKey", function(tooltipFrame, dbKeys, itemLink, itemCount)
    ns.Tooltip.AddMarketValue(tooltipFrame, dbKeys, itemLink, itemCount)
  end)

  return true
end

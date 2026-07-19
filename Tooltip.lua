local _, ns = ...

ns.Tooltip = {}

local LABEL = "Market Value"
local CRAFTING_LABEL = "Crafting Cost"

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

local function FormatQuantity(quantity)
  if quantity == math.floor(quantity) then
    return tostring(quantity)
  end

  local formatted = string.format("%.2f", quantity)
  formatted = formatted:gsub("0+$", ""):gsub("%.$", "")
  return formatted
end

local function AddCraftingStatusLine(tooltipFrame, result)
  if not IsShiftKeyDown() or not result.isUncertain then
    return
  end

  tooltipFrame:AddDoubleLine("CC data", NORMAL_FONT_COLOR:WrapTextInColorCode(table.concat(result.reasons, ", ")))
end

local function AddPurchasedMaterials(tooltipFrame, result, multiplier)
  local materials = {}
  for _, leaf in pairs(result.leaves) do
    local name = C_Item.GetItemInfo(leaf.itemID) or leaf.name or "item:" .. leaf.itemID
    materials[#materials + 1] = {
      name = name,
      quantity = leaf.quantity * multiplier,
      value = leaf.price * leaf.quantity * multiplier,
    }
  end

  table.sort(materials, function(left, right)
    return left.name < right.name
  end)

  tooltipFrame:AddLine("Materials to Buy" .. (multiplier == 1 and " (per item):" or ":"))
  for _, material in ipairs(materials) do
    tooltipFrame:AddDoubleLine(
      "  " .. material.name .. " x" .. FormatQuantity(material.quantity),
      FormatMoney(math.floor(material.value + 0.5), WHITE_FONT_COLOR)
    )
  end
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

function ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showTooltips") or itemLink == nil then
    return
  end

  local result = ns.Crafting.GetCost(itemLink)
  if result == nil then
    return
  end

  if result.isUnknown then
    tooltipFrame:AddDoubleLine(CRAFTING_LABEL, FormatUnknown())
    return
  end

  local multiplier = ShouldShowStackPrice(itemCount) and itemCount or 1
  local countString = multiplier > 1 and Auctionator.Utilities.CreateCountString(multiplier) or ""
  tooltipFrame:AddDoubleLine(
    CRAFTING_LABEL .. countString,
    FormatMoney(result.value * multiplier, result.isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR)
  )
  AddPurchasedMaterials(tooltipFrame, result, multiplier)
  AddCraftingStatusLine(tooltipFrame, result)
end

function ns.Tooltip.Register()
  if not (Auctionator and Auctionator.Tooltip and Auctionator.Tooltip.ShowTipWithPricingDBKey) then
    return false
  end

  hooksecurefunc(Auctionator.Tooltip, "ShowTipWithPricingDBKey", function(tooltipFrame, dbKeys, itemLink, itemCount)
    ns.Tooltip.AddMarketValue(tooltipFrame, dbKeys, itemLink, itemCount)
    ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
  end)

  return true
end

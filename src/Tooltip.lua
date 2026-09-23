local _, ns = ...

ns.Tooltip = {}

local LABEL = "Market Value"
local CRAFTING_LABEL = "Crafting Cost"
local MINIMUM_CRAFTING_LABEL = "Minimum Craft Cost"

local function ShouldShowStackPrice(itemCount)
  return IsShiftKeyDown() and itemCount ~= nil and itemCount > 1
end

local function ShouldShowPricingDetails()
  local mode = ns.Config.Get("tooltipDetails")
  return mode == "always" or (mode == "shift" and IsShiftKeyDown())
end

local function FormatMoney(value, color)
  return color:WrapTextInColorCode(C_CurrencyInfo.GetCoinTextureString(math.floor(value), 12))
end

local function FormatUnknown()
  return WHITE_FONT_COLOR:WrapTextInColorCode(UNKNOWN .. "  ")
end

local function CanAuction(itemLink)
  if itemLink == nil then
    return false
  end

  local itemInfo = { C_Item.GetItemInfo(itemLink) }
  local bindType = itemInfo[14]

  return itemInfo[1] ~= nil
    and (bindType == Enum.ItemBind.None or bindType == Enum.ItemBind.OnEquip or bindType == Enum.ItemBind.OnUse)
end

---@param tooltipFrame GameTooltip
---@param result ArbitrageMarketValueResult
local function AddStatusLine(tooltipFrame, result)
  if not ShouldShowPricingDetails() then
    return
  end

  local latestAge = result.latestAgeDays
  local detail = result.dayCount .. " days, " .. result.scanCount .. " scans, latest " .. latestAge .. "d ago"

  if result.isUncertain then
    detail = detail .. " (" .. table.concat(result.reasons, ", ") .. ")"
  end

  tooltipFrame:AddDoubleLine("MP data", WHITE_FONT_COLOR:WrapTextInColorCode(detail))
end

---@param quantity number
---@return string
local function FormatQuantity(quantity)
  if quantity == math.floor(quantity) then
    return tostring(quantity)
  end

  local formatted = string.format("%.2f", quantity)
  return (formatted:gsub("0+$", ""):gsub("%.$", ""))
end

---@param tooltipFrame GameTooltip
---@param label string
---@param result ArbitrageCraftingPlan
local function AddCraftingStatusLine(tooltipFrame, label, result)
  if not result.isUncertain then
    return
  end

  tooltipFrame:AddDoubleLine(
    label .. " data",
    NORMAL_FONT_COLOR:WrapTextInColorCode(table.concat(result.reasons, ", "))
  )
end

---@param tooltipFrame GameTooltip
---@param label string
---@param result ArbitrageCraftingPlan
---@param multiplier number
local function AddPurchasedMaterials(tooltipFrame, label, result, multiplier)
  local materials = {}
  for _, leaf in pairs(result.leaves) do
    ---@type string?
    local name = C_Item.GetItemInfo(leaf.itemID)
    name = name or leaf.name or "Item #" .. leaf.itemID
    materials[#materials + 1] = {
      name = name,
      quantity = leaf.quantity * multiplier,
      value = leaf.price * leaf.quantity * multiplier,
      source = leaf.source,
    }
  end

  table.sort(materials, function(left, right)
    return left.name < right.name
  end)

  tooltipFrame:AddLine(label .. " Materials to Buy" .. (multiplier == 1 and " (per item):" or ":"))
  for _, material in ipairs(materials) do
    local source = material.source == "vendor" and "Vendor" or "Auction House"
    tooltipFrame:AddDoubleLine(
      "  " .. material.name .. " x" .. FormatQuantity(material.quantity) .. " (" .. source .. ")",
      FormatMoney(math.floor(material.value + 0.5), WHITE_FONT_COLOR)
    )
  end
end

---@param tooltipFrame GameTooltip
---@param itemLink string?
---@param itemCount number?
function ns.Tooltip.AddMarketValue(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showTooltips") or not ns.Config.Get("showMarketValue") or not CanAuction(itemLink) then
    return
  end

  local result = ns.RollingMarketValue.Get(ns.Keys.FromLink(itemLink))
  if result == nil then
    tooltipFrame:AddDoubleLine(LABEL, FormatUnknown())
    return
  end

  local value = result.value
  local countString = ""
  if itemCount and ShouldShowStackPrice(itemCount) then
    value = value * itemCount
    countString = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. itemCount)
  end

  local color = result.isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  tooltipFrame:AddDoubleLine(LABEL .. countString, FormatMoney(value, color))
  AddStatusLine(tooltipFrame, result)
end

---@param tooltipFrame GameTooltip
---@param label string
---@param result ArbitrageCraftingCostResult
---@param multiplier number
---@param countString string
local function AddCraftingCostLine(tooltipFrame, label, result, multiplier, countString)
  if result.isUnknown then
    tooltipFrame:AddDoubleLine(label, FormatUnknown())
    return
  end

  tooltipFrame:AddDoubleLine(
    label .. countString,
    FormatMoney(
      math.floor(result.cost * multiplier + 0.5),
      result.isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
    )
  )
end

---@param tooltipFrame GameTooltip
---@param itemLink string?
---@param itemCount number?
function ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showTooltips") or itemLink == nil then
    return
  end

  local itemID = C_Item.GetItemInfoInstant(itemLink)
  if itemID == nil then
    return
  end

  local craftingCost = ns.Config.Get("showCraftingCost") and ns.Crafting.GetCostForItemID(itemID) or nil
  local minimumCraftCost = ns.Config.Get("showMinimumCraftCost") and ns.Crafting.GetMinimumCostForItemID(itemID) or nil
  if craftingCost == nil and minimumCraftCost == nil then
    return
  end

  local multiplier = ShouldShowStackPrice(itemCount) and itemCount or 1
  local countString = multiplier > 1 and LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. multiplier) or ""

  if craftingCost then
    AddCraftingCostLine(tooltipFrame, CRAFTING_LABEL, craftingCost, multiplier, countString)
  end
  if minimumCraftCost then
    AddCraftingCostLine(tooltipFrame, MINIMUM_CRAFTING_LABEL, minimumCraftCost, multiplier, countString)
  end

  if not ShouldShowPricingDetails() then
    return
  end

  if craftingCost and not craftingCost.isUnknown then
    ---@cast craftingCost ArbitrageCraftingPlan
    AddPurchasedMaterials(tooltipFrame, CRAFTING_LABEL, craftingCost, multiplier)
    AddCraftingStatusLine(tooltipFrame, CRAFTING_LABEL, craftingCost)
  end
  if minimumCraftCost and not minimumCraftCost.isUnknown then
    ---@cast minimumCraftCost ArbitrageCraftingPlan
    AddPurchasedMaterials(tooltipFrame, MINIMUM_CRAFTING_LABEL, minimumCraftCost, multiplier)
    AddCraftingStatusLine(tooltipFrame, MINIMUM_CRAFTING_LABEL, minimumCraftCost)
  end
end

function ns.Tooltip.Register()
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltipFrame, tooltipData)
    if tooltipFrame:IsForbidden() then
      return
    end

    local primaryData = tooltipFrame:GetPrimaryTooltipData()
    if primaryData ~= nil and primaryData ~= tooltipData then
      return
    end

    local _, itemLink, displayedItemID = TooltipUtil.GetDisplayedItem(tooltipFrame)
    local itemID = tooltipData.id or displayedItemID
    local linkItemID = itemLink and C_Item.GetItemInfoInstant(itemLink)
    if itemID and (itemLink == nil or (linkItemID and linkItemID ~= itemID)) then
      itemLink = "item:" .. itemID
    end
    if itemLink == nil then
      return
    end

    local itemCount = 1
    if tooltipData.guid then
      local itemLocation = C_Item.GetItemLocation(tooltipData.guid)
      if itemLocation and itemLocation:HasAnyLocation() and C_Item.DoesItemExist(itemLocation) then
        local stackCount = C_Item.GetStackCount(itemLocation)
        if type(stackCount) == "number" and stackCount > 0 then
          itemCount = stackCount
        end
      end
    end

    ns.Tooltip.AddMarketValue(tooltipFrame, itemLink, itemCount)
    ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
  end)
end

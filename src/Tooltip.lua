local _, ns = ...

ns.Tooltip = {}

local LABEL = "Market Value"
local CRAFTING_LABEL = "Crafting Cost"
local MINIMUM_CRAFTING_LABEL = "Minimum Craft Cost"

local function ShouldShowStackPrice(itemCount)
  return IsShiftKeyDown() and itemCount ~= nil and itemCount > 1
end

local function FormatMoney(value, color)
  value = math.floor(value)
  local copper = value % 100
  local silver = (value % 10000 - copper) / 100
  local gold = (value - silver * 100 - copper) / 10000
  local result = copper .. " |TInterface\\MoneyFrame\\UI-CopperIcon:12:12:0:0|t"

  if (gold ~= 0 or silver ~= 0) and copper < 10 then
    result = "0" .. result
  end
  if silver ~= 0 or gold ~= 0 then
    result = silver .. " |TInterface\\MoneyFrame\\UI-SilverIcon:12:12:0:0|t " .. result
  end
  if gold ~= 0 and silver < 10 then
    result = "0" .. result
  end
  if gold ~= 0 then
    result = gold .. " |TInterface\\MoneyFrame\\UI-GoldIcon:12:12:0:0|t " .. result
  end

  return color:WrapTextInColorCode(result)
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

  return #itemInfo ~= 0
    and (bindType == LE_ITEM_BIND_NONE or bindType == LE_ITEM_BIND_ON_EQUIP or bindType == LE_ITEM_BIND_ON_USE)
end

---@param tooltipFrame GameTooltip
---@param result ArbitrageMarketValueResult
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

---@param quantity number
---@return string
local function FormatQuantity(quantity)
  if quantity == math.floor(quantity) then
    return tostring(quantity)
  end

  local formatted = string.format("%.2f", quantity)
  return (formatted:gsub("0+$", ""):gsub("%.$", ""))
end

---@param itemID number
---@return string?
local function GetCachedItemName(itemID)
  return C_Item.GetItemInfo(itemID)
end

---@param tooltipFrame GameTooltip
---@param label string
---@param result ArbitrageCraftingPlan
local function AddCraftingStatusLine(tooltipFrame, label, result)
  if not IsShiftKeyDown() or not result.isUncertain then
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
    local name = GetCachedItemName(leaf.itemID) or leaf.name or "Item #" .. leaf.itemID
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
  if not ns.Config.Get("showTooltips") or not CanAuction(itemLink) then
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

  local craftingCost = ns.Config.Get("showCraftingCost") and ns.Crafting.GetCost(itemLink) or nil
  local minimumCraftCost = ns.Config.Get("showMinimumCraftCost") and ns.Crafting.GetMinimumCost(itemLink) or nil
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

  if not IsShiftKeyDown() then
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

---@param info table
---@return number?
local function GetContextItemCount(info)
  local getterName = info.getterName
  local args = info.getterArgs
  if args == nil then
    return nil
  end

  if getterName == "GetBagItem" then
    local location = ItemLocation:CreateFromBagAndSlot(args[1], args[2])
    if C_Item.DoesItemExist(location) then
      return C_Item.GetStackCount(location)
    end
  elseif getterName == "GetBuybackItem" then
    return select(4, GetBuybackItemInfo(args[1]))
  elseif getterName == "GetMerchantItem" then
    return select(4, GetMerchantItemInfo(args[1]))
  elseif getterName == "GetInventoryItem" then
    local count = GetInventoryItemCount(args[1], args[2])
    return count ~= 0 and count or 1
  elseif getterName == "GetGuildBankItem" then
    return select(2, GetGuildBankItemInfo(args[1], args[2]))
  elseif getterName == "GetLootItem" then
    if LootSlotHasItem(args[1]) then
      return select(3, GetLootSlotInfo(args[1]))
    end
  elseif getterName == "GetLootRollItem" then
    return select(3, GetLootRollItemInfo(args[1]))
  elseif getterName == "GetQuestItem" then
    return select(3, GetQuestItemInfo(args[1], args[2]))
  elseif getterName == "GetSendMailItem" then
    return select(4, GetSendMailItem(args[1]))
  elseif getterName == "GetInboxItem" then
    return select(4, GetInboxItem(args[1], args[2] or 1))
  elseif getterName == "GetTradePlayerItem" then
    return select(3, GetTradePlayerItemInfo(args[1]))
  elseif getterName == "GetTradeTargetItem" then
    return select(3, GetTradeTargetItemInfo(args[1]))
  end

  return nil
end

---@param tooltipFrame GameTooltip
---@param tooltipData TooltipData
---@return string?
local function GetTooltipItemLink(tooltipFrame, tooltipData)
  local _, itemLink = TooltipUtil.GetDisplayedItem(tooltipFrame)
  if itemLink then
    return itemLink
  end
  if tooltipData.hyperlink then
    return tooltipData.hyperlink
  end
  if tooltipData.id then
    return select(2, C_Item.GetItemInfo(tooltipData.id))
  end

  return nil
end

function ns.Tooltip.Register()
  ---@type table<table, number>
  local legacyItemCounts = setmetatable({}, { __mode = "k" })

  ---@param tooltipFrame GameTooltip
  ---@param itemLink string?
  ---@param itemCount number?
  local function ShowTip(tooltipFrame, itemLink, itemCount)
    if itemLink == nil then
      return
    end

    ns.Tooltip.AddMarketValue(tooltipFrame, itemLink, itemCount)
    ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
  end

  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltipFrame, tooltipData)
    if tooltipFrame ~= GameTooltip and tooltipFrame ~= ItemRefTooltip then
      return
    end
    if tooltipFrame:GetPrimaryTooltipData() ~= tooltipData then
      return
    end

    local info = tooltipFrame:GetProcessingTooltipInfo()
    local itemCount = info and (legacyItemCounts[info] or GetContextItemCount(info)) or 1
    ShowTip(tooltipFrame, GetTooltipItemLink(tooltipFrame, tooltipData), itemCount)
  end)

  ---@param tooltipFrame GameTooltip
  ---@param itemCount number?
  local function SetLegacyItemCount(tooltipFrame, itemCount)
    local info = tooltipFrame:GetPrimaryTooltipInfo()
    if info == nil then
      return
    end

    legacyItemCounts[info] = itemCount or 1
    if ShouldShowStackPrice(itemCount) then
      tooltipFrame:RebuildFromTooltipInfo()
    end
  end

  if GameTooltip.SetAuctionItem then
    hooksecurefunc(GameTooltip, "SetAuctionItem", function(tooltipFrame, viewType, index)
      SetLegacyItemCount(tooltipFrame, select(3, GetAuctionItemInfo(viewType, index)))
    end)
  end
  if GameTooltip.SetTradeSkillItem then
    hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        SetLegacyItemCount(tooltipFrame, select(3, GetTradeSkillReagentInfo(recipeIndex, reagentIndex)))
      else
        SetLegacyItemCount(tooltipFrame, GetTradeSkillNumMade(recipeIndex))
      end
    end)
  end
  if GameTooltip.SetCraftItem then
    hooksecurefunc(GameTooltip, "SetCraftItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        SetLegacyItemCount(tooltipFrame, select(3, GetCraftReagentInfo(recipeIndex, reagentIndex)))
      else
        SetLegacyItemCount(tooltipFrame, GetCraftNumMade(recipeIndex))
      end
    end)
  end
end

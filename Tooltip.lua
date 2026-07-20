local _, ns = ...

ns.Tooltip = {}

local LABEL = "Market Value"
local CRAFTING_LABEL = "Crafting Cost"

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
    and (bindType == (LE_ITEM_BIND_NONE or Enum.ItemBind.None)
      or bindType == (LE_ITEM_BIND_ON_EQUIP or Enum.ItemBind.OnEquip)
      or bindType == (LE_ITEM_BIND_ON_USE or Enum.ItemBind.OnUse))
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
  return formatted:gsub("0+$", ""):gsub("%.$", "")
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

function ns.Tooltip.AddMarketValue(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showTooltips") or not CanAuction(itemLink) then
    return
  end

  local result = ns.Database.GetRollingMarketValue(ns.Keys.FromLink(itemLink))
  if result == nil then
    tooltipFrame:AddDoubleLine(LABEL, FormatUnknown())
    return
  end

  local value = result.value
  local countString = ""
  if ShouldShowStackPrice(itemCount) then
    value = value * itemCount
    countString = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. itemCount)
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
  local countString = multiplier > 1 and LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. multiplier) or ""
  tooltipFrame:AddDoubleLine(
    CRAFTING_LABEL .. countString,
    FormatMoney(result.value * multiplier, result.isUncertain and NORMAL_FONT_COLOR or WHITE_FONT_COLOR)
  )
  AddPurchasedMaterials(tooltipFrame, result, multiplier)
  AddCraftingStatusLine(tooltipFrame, result)
end

function ns.Tooltip.Register()
  local function ShowTip(tooltipFrame, itemLink, itemCount)
    if itemLink == nil then
      return
    end

    ns.Tooltip.AddMarketValue(tooltipFrame, itemLink, itemCount)
    ns.Tooltip.AddCraftingCost(tooltipFrame, itemLink, itemCount)
    tooltipFrame:Show()
  end

  hooksecurefunc(ItemRefTooltip, "SetHyperlink", function(tooltipFrame, itemLink)
    ShowTip(tooltipFrame, itemLink, 1)
  end)
  hooksecurefunc(GameTooltip, "SetHyperlink", function(tooltipFrame, itemLink)
    ShowTip(tooltipFrame, itemLink, 1)
  end)
  hooksecurefunc(GameTooltip, "SetBagItem", function(tooltipFrame, bag, slot)
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    if C_Item.DoesItemExist(location) then
      ShowTip(tooltipFrame, C_Item.GetItemLink(location), C_Item.GetStackCount(location))
    end
  end)
  hooksecurefunc(GameTooltip, "SetBuybackItem", function(tooltipFrame, slot)
    local _, _, _, count = GetBuybackItemInfo(slot)
    ShowTip(tooltipFrame, GetBuybackItemLink(slot), count)
  end)
  hooksecurefunc(GameTooltip, "SetMerchantItem", function(tooltipFrame, index)
    local _, _, _, count = GetMerchantItemInfo(index)
    ShowTip(tooltipFrame, GetMerchantItemLink(index), count)
  end)
  hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltipFrame, unit, slot)
    local count = GetInventoryItemCount(unit, slot)
    ShowTip(tooltipFrame, GetInventoryItemLink(unit, slot), count ~= 0 and count or 1)
  end)
  hooksecurefunc(GameTooltip, "SetGuildBankItem", function(tooltipFrame, tab, slot)
    local _, count = GetGuildBankItemInfo(tab, slot)
    ShowTip(tooltipFrame, GetGuildBankItemLink(tab, slot), count)
  end)
  hooksecurefunc(GameTooltip, "SetLootItem", function(tooltipFrame, slot)
    if LootSlotHasItem(slot) then
      local itemLink, _, count = GetLootSlotLink(slot)
      ShowTip(tooltipFrame, itemLink, count)
    end
  end)
  hooksecurefunc(GameTooltip, "SetLootRollItem", function(tooltipFrame, slot)
    local _, _, count = GetLootRollItemInfo(slot)
    ShowTip(tooltipFrame, GetLootRollItemLink(slot), count)
  end)
  hooksecurefunc(GameTooltip, "SetQuestItem", function(tooltipFrame, itemType, index)
    local _, _, count = GetQuestItemInfo(itemType, index)
    ShowTip(tooltipFrame, GetQuestItemLink(itemType, index), count)
  end)
  hooksecurefunc(GameTooltip, "SetSendMailItem", function(tooltipFrame, id)
    local _, _, _, count = GetSendMailItem(id)
    ShowTip(tooltipFrame, GetSendMailItemLink(id), count)
  end)
  hooksecurefunc(GameTooltip, "SetInboxItem", function(tooltipFrame, index, attachIndex)
    local attachmentIndex = attachIndex or 1
    local _, _, _, count = GetInboxItem(index, attachmentIndex)
    ShowTip(tooltipFrame, GetInboxItemLink(index, attachmentIndex), count)
  end)
  hooksecurefunc(GameTooltip, "SetTradePlayerItem", function(tooltipFrame, id)
    local _, _, count = GetTradePlayerItemInfo(id)
    ShowTip(tooltipFrame, GetTradePlayerItemLink(id), count)
  end)
  hooksecurefunc(GameTooltip, "SetTradeTargetItem", function(tooltipFrame, id)
    local _, _, count = GetTradeTargetItemInfo(id)
    ShowTip(tooltipFrame, GetTradeTargetItemLink(id), count)
  end)
  if GameTooltip.SetAuctionItem then
    hooksecurefunc(GameTooltip, "SetAuctionItem", function(tooltipFrame, viewType, index)
      local count = select(3, GetAuctionItemInfo(viewType, index))
      ShowTip(tooltipFrame, GetAuctionItemLink(viewType, index), count)
    end)
  end
  if GameTooltip.SetTradeSkillItem then
    hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        ShowTip(
          tooltipFrame,
          GetTradeSkillReagentItemLink(recipeIndex, reagentIndex),
          select(3, GetTradeSkillReagentInfo(recipeIndex, reagentIndex))
        )
      else
        ShowTip(tooltipFrame, GetTradeSkillItemLink(recipeIndex), GetTradeSkillNumMade(recipeIndex))
      end
    end)
  end
  if GameTooltip.SetCraftItem then
    hooksecurefunc(GameTooltip, "SetCraftItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        ShowTip(
          tooltipFrame,
          GetCraftReagentItemLink(recipeIndex, reagentIndex),
          select(3, GetCraftReagentInfo(recipeIndex, reagentIndex))
        )
      else
        ShowTip(tooltipFrame, GetCraftItemLink(recipeIndex), GetCraftNumMade(recipeIndex))
      end
    end)
  end
  hooksecurefunc(GameTooltip, "SetItemByID", function(tooltipFrame, itemID)
    if itemID then
      ShowTip(tooltipFrame, select(2, C_Item.GetItemInfo(itemID)), 1)
    end
  end)
end

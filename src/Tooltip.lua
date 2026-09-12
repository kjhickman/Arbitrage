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

function ns.Tooltip.Register()
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

  ---@type table<GameTooltip, number>
  local renderGenerations = setmetatable({}, { __mode = "k" })
  ---@type table<GameTooltip, { itemLink: string, itemCount: number, owner: Frame? }>
  local stackContexts = setmetatable({}, { __mode = "k" })

  ---@param tooltipFrame GameTooltip
  local function OnTooltipSetItem(tooltipFrame)
    local _, itemLink = tooltipFrame:GetItem()
    if itemLink == nil then
      return
    end

    local generation = (renderGenerations[tooltipFrame] or 0) + 1
    renderGenerations[tooltipFrame] = generation
    C_Timer.After(0, function()
      if renderGenerations[tooltipFrame] ~= generation or not tooltipFrame:IsShown() then
        return
      end

      local _, currentItemLink = tooltipFrame:GetItem()
      if currentItemLink ~= itemLink then
        return
      end

      local context = stackContexts[tooltipFrame]
      local itemCount = 1
      if context and context.itemLink == itemLink and context.owner == tooltipFrame:GetOwner() then
        itemCount = context.itemCount
      end

      ShowTip(tooltipFrame, itemLink, itemCount)
      tooltipFrame:Show()
    end)
  end

  GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
  ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)

  ---@param tooltipFrame GameTooltip
  ---@param itemLink string?
  ---@param itemCount number?
  local function SetStackContext(tooltipFrame, itemLink, itemCount)
    if itemLink == nil then
      return
    end

    stackContexts[tooltipFrame] = {
      itemLink = itemLink,
      itemCount = itemCount or 1,
      owner = tooltipFrame:GetOwner(),
    }
  end

  hooksecurefunc(GameTooltip, "SetBagItem", function(tooltipFrame, bag, slot)
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    if C_Item.DoesItemExist(location) then
      SetStackContext(tooltipFrame, C_Item.GetItemLink(location), C_Item.GetStackCount(location))
    end
  end)
  hooksecurefunc(GameTooltip, "SetBuybackItem", function(tooltipFrame, slot)
    SetStackContext(tooltipFrame, GetBuybackItemLink(slot), select(4, GetBuybackItemInfo(slot)))
  end)
  hooksecurefunc(GameTooltip, "SetMerchantItem", function(tooltipFrame, index)
    SetStackContext(tooltipFrame, GetMerchantItemLink(index), select(4, GetMerchantItemInfo(index)))
  end)
  hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltipFrame, unit, slot)
    local count = GetInventoryItemCount(unit, slot)
    SetStackContext(tooltipFrame, GetInventoryItemLink(unit, slot), count ~= 0 and count or 1)
  end)
  hooksecurefunc(GameTooltip, "SetGuildBankItem", function(tooltipFrame, tab, slot)
    SetStackContext(tooltipFrame, GetGuildBankItemLink(tab, slot), select(2, GetGuildBankItemInfo(tab, slot)))
  end)
  hooksecurefunc(GameTooltip, "SetLootItem", function(tooltipFrame, slot)
    if LootSlotHasItem(slot) then
      SetStackContext(tooltipFrame, GetLootSlotLink(slot), select(3, GetLootSlotInfo(slot)))
    end
  end)
  hooksecurefunc(GameTooltip, "SetLootRollItem", function(tooltipFrame, slot)
    SetStackContext(tooltipFrame, GetLootRollItemLink(slot), select(3, GetLootRollItemInfo(slot)))
  end)
  hooksecurefunc(GameTooltip, "SetQuestItem", function(tooltipFrame, itemType, index)
    SetStackContext(tooltipFrame, GetQuestItemLink(itemType, index), select(3, GetQuestItemInfo(itemType, index)))
  end)
  hooksecurefunc(GameTooltip, "SetSendMailItem", function(tooltipFrame, id)
    SetStackContext(tooltipFrame, GetSendMailItemLink(id), select(4, GetSendMailItem(id)))
  end)
  hooksecurefunc(GameTooltip, "SetInboxItem", function(tooltipFrame, index, attachIndex)
    local attachmentIndex = attachIndex or 1
    SetStackContext(
      tooltipFrame,
      GetInboxItemLink(index, attachmentIndex),
      select(4, GetInboxItem(index, attachmentIndex))
    )
  end)
  hooksecurefunc(GameTooltip, "SetTradePlayerItem", function(tooltipFrame, id)
    SetStackContext(tooltipFrame, GetTradePlayerItemLink(id), select(3, GetTradePlayerItemInfo(id)))
  end)
  hooksecurefunc(GameTooltip, "SetTradeTargetItem", function(tooltipFrame, id)
    SetStackContext(tooltipFrame, GetTradeTargetItemLink(id), select(3, GetTradeTargetItemInfo(id)))
  end)
  if GameTooltip.SetAuctionItem then
    hooksecurefunc(GameTooltip, "SetAuctionItem", function(tooltipFrame, viewType, index)
      SetStackContext(tooltipFrame, GetAuctionItemLink(viewType, index), select(3, GetAuctionItemInfo(viewType, index)))
    end)
  end
  if GameTooltip.SetTradeSkillItem then
    hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        SetStackContext(
          tooltipFrame,
          GetTradeSkillReagentItemLink(recipeIndex, reagentIndex),
          select(3, GetTradeSkillReagentInfo(recipeIndex, reagentIndex))
        )
      else
        SetStackContext(tooltipFrame, GetTradeSkillItemLink(recipeIndex), GetTradeSkillNumMade(recipeIndex))
      end
    end)
  end
  if GameTooltip.SetCraftItem then
    hooksecurefunc(GameTooltip, "SetCraftItem", function(tooltipFrame, recipeIndex, reagentIndex)
      if reagentIndex then
        SetStackContext(
          tooltipFrame,
          GetCraftReagentItemLink(recipeIndex, reagentIndex),
          select(3, GetCraftReagentInfo(recipeIndex, reagentIndex))
        )
      else
        SetStackContext(tooltipFrame, GetCraftItemLink(recipeIndex), GetCraftNumMade(recipeIndex))
      end
    end)
  end
end

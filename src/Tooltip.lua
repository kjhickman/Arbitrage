local _, ns = ...

ns.Tooltip = {}

local LABEL = ns.Terminology.typical.label
local VENDOR_LABEL = ns.Terminology.vendor.label
local BUYOUT_LABEL = ns.Terminology.current.label
local LISTED_LABEL = "Listed"
local SALE_RATE_LABEL = "Sale Rate"
local AVERAGE_SALE_PRICE_LABEL = "Average Sale Price"
local CRAFT_COST_LABEL = ns.Terminology.typicalCraftCost.label
local BUYOUT_COST_LABEL = ns.Terminology.currentCraftCost.label
local CRAFT_PROFIT_LABEL = ns.Terminology.typicalProfit.label

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

  local amount = multiplier == 1 and "one item" or multiplier .. " items"
  tooltipFrame:AddLine("Materials for " .. amount .. " (" .. label .. "):")
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
local function AddMarketValue(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showMarketValue") or not CanAuction(itemLink) then
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
end

-- With pricing details, when a scan last listed the item, above the prices it set. Gear falls back
-- to any variant's scan, as Market Value does.
---@param tooltipFrame GameTooltip
---@param itemLink string?
local function AddLastScan(tooltipFrame, itemLink)
  if
    not ShouldShowPricingDetails()
    or not (ns.Config.Get("showMarketValue") or ns.Config.Get("showBuyout"))
    or not CanAuction(itemLink)
  then
    return
  end

  for _, dbKey in ipairs(ns.Keys.FromLink(itemLink)) do
    local lastSeen = ns.Database.GetLastSeen(dbKey)
    if lastSeen then
      tooltipFrame:AddDoubleLine("Last scan", WHITE_FONT_COLOR:WrapTextInColorCode(ns.Time.Since(lastSeen)))
      return
    end
  end
end

---@param tooltipFrame GameTooltip
---@param itemLink string
---@param itemCount number?
local function AddVendor(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showVendor") then
    return
  end

  local itemID = C_Item.GetItemInfoInstant(itemLink)
  local sellPrice = itemID and ns.Vendor.GetSellPrice(itemID)
  local vendorPrice = sellPrice and sellPrice > 0 and sellPrice or nil
  if vendorPrice == nil then
    return
  end

  local countString = ""
  if itemCount and ShouldShowStackPrice(itemCount) then
    vendorPrice = vendorPrice * itemCount
    countString = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. itemCount)
  end
  tooltipFrame:AddDoubleLine(VENDOR_LABEL .. countString, FormatMoney(vendorPrice, WHITE_FONT_COLOR))
end

-- Gear prices by its first key, its own variant, rather than falling back to the cheapest variant.
---@param tooltipFrame GameTooltip
---@param itemLink string?
---@param itemCount number?
local function AddBuyout(tooltipFrame, itemLink, itemCount)
  if not ns.Config.Get("showBuyout") or not CanAuction(itemLink) then
    return
  end

  local dbKey = ns.Keys.FromLink(itemLink)[1]
  local buyout = dbKey and ns.Database.GetLatestBuyout(dbKey)
  if buyout == nil then
    return
  end

  local countString = ""
  if itemCount and ShouldShowStackPrice(itemCount) then
    buyout = buyout * itemCount
    countString = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. itemCount)
  end
  tooltipFrame:AddDoubleLine(BUYOUT_LABEL .. countString, FormatMoney(buyout, WHITE_FONT_COLOR))
end

-- Units listed on an average scan of the latest day that counted them, for the item's own variant as
-- Buyout is. Left out when no scan in the window counted it.
---@param tooltipFrame GameTooltip
---@param itemLink string?
local function AddListed(tooltipFrame, itemLink)
  if not ns.Config.Get("showListed") or not CanAuction(itemLink) then
    return
  end

  local dbKey = ns.Keys.FromLink(itemLink)[1]
  local units = dbKey and ns.Database.GetListed(dbKey)
  if units then
    tooltipFrame:AddDoubleLine(LISTED_LABEL, WHITE_FONT_COLOR:WrapTextInColorCode(ns.ItemTable.FormatCount(units)))
  end
end

-- TradeSkillMaster's region-wide figures, each its own setting, and each left out when Arbitrage
-- Companion brought none for the item. A gear variant has none, since its figures blend every enchant.
---@param tooltipFrame GameTooltip
---@param itemLink string?
---@param itemCount number?
local function AddSales(tooltipFrame, itemLink, itemCount)
  local showSaleRate = ns.Config.Get("showSaleRate")
  local showAveragePrice = ns.Config.Get("showAverageSalePrice")
  if not (showSaleRate or showAveragePrice) or not CanAuction(itemLink) then
    return
  end

  local dbKey = ns.Keys.FromLink(itemLink)[1]
  if dbKey == nil then
    return
  end
  local averagePrice, saleRate = ns.Database.GetSales(dbKey)
  if showSaleRate and saleRate then
    tooltipFrame:AddDoubleLine(
      SALE_RATE_LABEL,
      WHITE_FONT_COLOR:WrapTextInColorCode(ns.ItemTable.FormatPercent(saleRate))
    )
  end
  if showAveragePrice and averagePrice and averagePrice > 0 then
    local countString = ""
    if itemCount and ShouldShowStackPrice(itemCount) then
      averagePrice = averagePrice * itemCount
      countString = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. itemCount)
    end
    tooltipFrame:AddDoubleLine(AVERAGE_SALE_PRICE_LABEL .. countString, FormatMoney(averagePrice, WHITE_FONT_COLOR))
  end
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

-- Sells the item the way the Opportunities table does: at auction or to a vendor, whichever pays more.
---@param tooltipFrame GameTooltip
---@param marketValue ArbitrageMarketValueResult? nil when the item can't be auctioned or has no Typical price
---@param vendorPrice number? what a vendor pays for one, or nil when it buys none
---@param craftingCost ArbitrageCraftingPlan
---@param multiplier number
---@param countString string
local function AddCraftProfitLine(tooltipFrame, marketValue, vendorPrice, craftingCost, multiplier, countString)
  local auctionSale = marketValue and marketValue.value * (1 - ns.Opportunities.AUCTION_HOUSE_CUT_RATE)
  local sale, method = ns.Opportunities.BestSale(auctionSale, vendorPrice)
  if sale == nil then
    return
  end

  local saleIsUncertain = method == "auction" and (marketValue and marketValue.isUncertain == true)

  -- Like the Opportunities table, the cut comes off the whole sale before rounding down.
  local proceeds = math.floor(sale * multiplier)
  local profit = proceeds - math.floor(craftingCost.cost * multiplier + 0.5)
  local sign = profit >= 0 and "+" or "-"
  local color = (saleIsUncertain or craftingCost.isUncertain) and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  tooltipFrame:AddDoubleLine(CRAFT_PROFIT_LABEL .. countString, sign .. FormatMoney(math.abs(profit), color))
end

---@param tooltipFrame GameTooltip
---@param itemLink string the crafted item
---@param craftingCost ArbitrageCraftingCostResult?
---@param minimumCraftCost ArbitrageCraftingCostResult?
---@param multiplier number
---@param unlearned boolean? the costs use a recipe no character has learned
local function AddCraftingLines(tooltipFrame, itemLink, craftingCost, minimumCraftCost, multiplier, unlearned)
  if craftingCost == nil and minimumCraftCost == nil then
    return
  end

  local showCraftingCost = ns.Config.Get("showCraftingCost")
  local showMinimumCraftCost = ns.Config.Get("showMinimumCraftCost")
  local showCraftProfit = ns.Config.Get("showCraftProfit")
  local countString = multiplier > 1 and LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(" x" .. multiplier) or ""

  if showCraftingCost and craftingCost then
    AddCraftingCostLine(tooltipFrame, CRAFT_COST_LABEL, craftingCost, multiplier, countString)
  end
  if showMinimumCraftCost and minimumCraftCost then
    AddCraftingCostLine(tooltipFrame, BUYOUT_COST_LABEL, minimumCraftCost, multiplier, countString)
  end

  if showCraftProfit and craftingCost and not craftingCost.isUnknown then
    ---@cast craftingCost ArbitrageCraftingPlan
    local marketValue = CanAuction(itemLink) and ns.RollingMarketValue.Get(ns.Keys.FromLink(itemLink)) or nil
    local itemID = C_Item.GetItemInfoInstant(itemLink)
    local sellPrice = itemID and ns.Vendor.GetSellPrice(itemID)
    local vendorPrice = sellPrice and sellPrice > 0 and sellPrice or nil
    if marketValue or vendorPrice then
      AddCraftProfitLine(tooltipFrame, marketValue, vendorPrice, craftingCost, multiplier, countString)
    end
  end

  if unlearned then
    tooltipFrame:AddDoubleLine("Recipe", NORMAL_FONT_COLOR:WrapTextInColorCode("Not learned"))
  end

  if not ShouldShowPricingDetails() then
    return
  end

  if showCraftingCost and craftingCost and not craftingCost.isUnknown then
    ---@cast craftingCost ArbitrageCraftingPlan
    AddPurchasedMaterials(tooltipFrame, CRAFT_COST_LABEL, craftingCost, multiplier)
    AddCraftingStatusLine(tooltipFrame, CRAFT_COST_LABEL, craftingCost)
  end
  if showMinimumCraftCost and minimumCraftCost and not minimumCraftCost.isUnknown then
    ---@cast minimumCraftCost ArbitrageCraftingPlan
    AddPurchasedMaterials(tooltipFrame, BUYOUT_COST_LABEL, minimumCraftCost, multiplier)
    AddCraftingStatusLine(tooltipFrame, BUYOUT_COST_LABEL, minimumCraftCost)
  end
end

---@param tooltipFrame GameTooltip
---@param itemLink string?
---@param itemCount number?
local function AddCraftingCost(tooltipFrame, itemLink, itemCount)
  if itemLink == nil then
    return
  end

  local itemID = C_Item.GetItemInfoInstant(itemLink)
  if itemID == nil then
    return
  end

  local wantsCraftCost = ns.Config.Get("showCraftingCost") or ns.Config.Get("showCraftProfit")
  local wantsBuyoutCost = ns.Config.Get("showMinimumCraftCost")
  local craftingCost = wantsCraftCost and ns.Crafting.GetCostForItemID(itemID) or nil
  local minimumCraftCost = wantsBuyoutCost and ns.Crafting.GetScanCostForItemID(itemID) or nil
  -- Without a recipe any character knows, the costs come from one they could learn, as the
  -- Opportunities tab lists it.
  local unlearned = false
  if craftingCost == nil and minimumCraftCost == nil and (wantsCraftCost or wantsBuyoutCost) then
    local recipes = ns.RecipeBook.GetUnlearnedRecipes(itemID)
    if #recipes > 0 then
      unlearned = true
      craftingCost, minimumCraftCost = ns.Crafting.GetRecipeCosts(recipes)
      craftingCost = wantsCraftCost and craftingCost or nil
      minimumCraftCost = wantsBuyoutCost and minimumCraftCost or nil
    end
  end
  local multiplier = ShouldShowStackPrice(itemCount) and itemCount or 1
  AddCraftingLines(tooltipFrame, itemLink, craftingCost, minimumCraftCost, multiplier, unlearned)
end

-- Prices the item a recipe teaches to make with that recipe, learned or not, the way the
-- crafted item's own tooltip would with the recipes characters know.
---@param tooltipFrame GameTooltip
---@param productLink string the item the recipe makes
local function AddRecipeCraftingCost(tooltipFrame, productLink)
  local productID = C_Item.GetItemInfoInstant(productLink)
  if
    productID == nil
    or ns.Database.IsIgnoredItem(productID)
    or not (
      ns.Config.Get("showCraftingCost")
      or ns.Config.Get("showMinimumCraftCost")
      or ns.Config.Get("showCraftProfit")
    )
  then
    return
  end

  local recipes = {}
  for _, recipeID in ipairs(ns.RecipeBook.GetRecipeIDs(productID)) do
    for _, recipe in ipairs(ns.RecipeParser.Preview(recipeID) or {}) do
      recipes[#recipes + 1] = recipe
    end
  end
  if #recipes > 0 then
    local craftingCost, minimumCraftCost = ns.Crafting.GetRecipeCosts(recipes)
    AddCraftingLines(tooltipFrame, productLink, craftingCost, minimumCraftCost, 1)
  end
end

function ns.Tooltip.Register()
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltipFrame, tooltipData)
    if tooltipFrame:IsForbidden() then
      return
    end

    -- Tables that price their rows themselves own their tooltips with this flag set.
    local owner = tooltipFrame:GetOwner()
    if owner and owner.arbitrageReplacesItemPricing then
      return
    end

    local primaryData = tooltipFrame:GetPrimaryTooltipData()
    if primaryData ~= nil and primaryData ~= tooltipData then
      return
    end

    local _, itemLink, displayedItemID = TooltipUtil.GetDisplayedItem(tooltipFrame)
    local itemID = tooltipData.id or displayedItemID
    local linkItemID = itemLink and C_Item.GetItemInfoInstant(itemLink)
    -- A recipe's tooltip links the item it teaches to make, not the recipe itself.
    local productLink = itemID and linkItemID and linkItemID ~= itemID and itemLink or nil
    if itemID and (itemLink == nil or productLink) then
      itemLink = "item:" .. itemID
    end
    if itemLink == nil or ns.Database.IsIgnoredItem(itemID or itemLink) then
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

    AddVendor(tooltipFrame, itemLink, itemCount)
    AddBuyout(tooltipFrame, itemLink, itemCount)
    AddMarketValue(tooltipFrame, itemLink, itemCount)
    AddListed(tooltipFrame, itemLink)
    AddSales(tooltipFrame, itemLink, itemCount)
    AddCraftingCost(tooltipFrame, itemLink, itemCount)
    if productLink then
      AddRecipeCraftingCost(tooltipFrame, productLink)
    end
    AddLastScan(tooltipFrame, itemLink)
  end)
end

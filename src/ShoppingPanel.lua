local _, ns = ...

ns.ShoppingPanel = {}

---@class ArbitrageShoppingList
---@field frame Frame the list's card
---@field SetRows fun(rows: table[], marked: number?) marked is the item whose row shows as selected
---@field SetEmptyMessage fun(message: string?)

---@class ArbitrageShoppingListColumn
---@field label string
---@field x number header offset; values sit 4 pixels further left, as in the item tables
---@field width number
---@field explanation string?

---@class ArbitrageShoppingListOptions
---@field itemLabel string
---@field itemWidth number
---@field columns ArbitrageShoppingListColumn[]
---@field initializeRow fun(row: ArbitrageShoppingRow)?
---@field populateRow fun(row: ArbitrageShoppingRow, data: table)
---@field addTooltipLines fun(data: table)?
---@field replacesItemPricing boolean? the rows' tooltips price their items, so Arbitrage's item-tooltip pricing is left out
---@field onClick fun(data: table)? a plain click on a row

---@class ArbitrageShoppingRow : Button
---@field arbitrageInitialized boolean?
---@field data table? the craft or material the row shows
---@field selectedHighlight Texture
---@field icon Texture
---@field iconBorder Texture
---@field itemName FontString
---@field values FontString[] one per column
---@field check Texture? materials: marks what you have enough of
---@field choice ArbitrageChoiceButton? materials: shows whether the material is made or bought, and flips it
---@field minus Button? crafts
---@field count FontString? crafts
---@field plus Button? crafts
---@field remove Button? crafts

---@class ArbitrageShoppingPanelEntry
---@field panel Frame
---@field content Frame every control and both lists
---@field heading FontString
---@field crafts ArbitrageShoppingList
---@field materials ArbitrageShoppingList
---@field total FontString
---@field refreshButton ArbitrageScanButton? only in the Auction House; counts through a refresh's searches
---@field rechoose CheckButton? only in the Auction House: whether a refresh also re-chooses make or buy
---@field canRefresh boolean? as last drawn, whether anything is left to buy or make
---@field buyCard ArbitrageBuyCard? only in the Auction House
---@field next ArbitrageShoppingMaterial? as last drawn, the commodity Buy buys
---@field auctionRequests ArbitrageSearchRequest[]? as last drawn, what isn't a commodity and is still needed
---@field leftToBuy number? as last drawn, what's left on the list costs
---@field names table<number, string>? as last drawn, each material's name, from its recipe while the item loads

---@class ArbitrageChoiceButton : Button
---@field Icon Texture
---@field Highlight Texture

---@class ArbitrageBuyCardIcon : Button
---@field Texture Texture
---@field Border Texture
---@field itemID number?
---@field arbitrageReplacesItemPricing boolean

---@class ArbitrageBuyCard : ArbitrageTableBackground
---@field Title FontString
---@field Icon ArbitrageBuyCardIcon
---@field Name FontString
---@field Detail FontString
---@field TotalLabel FontString
---@field Total FontString
---@field Notice FontString
---@field Empty FontString says only that there's nothing to buy
---@field BuyButton ArbitrageScanButton
---@field SkipButton Button

---@class ArbitrageShoppingCraftRow
---@field craft ArbitrageShoppingCraft
---@field recipe ArbitrageStoredRecipe? nil once no character knows the recipe

local ROW_HEIGHT = 20
local NAME_X = 18
local INDENT = 12
-- The two cards share the width the item tables use, which leave 35 pixels at their right for the
-- scroll bar: 770 wide from 16 pixels in, the crafts first.
local CRAFTS_WIDTH = 300
local CARD_GAP = 8
local MATERIALS_WIDTH = 770 - CRAFTS_WIDTH - CARD_GAP
local SCROLL_BAR_ROOM = 35
local FOOTER_HEIGHT = 30
-- The crafts card's right edge leaves this much for its scroll bar, which the cards below line up with.
local SCROLL_BAR_GUTTER = 22
-- The card that buys, under the crafts and Clear in the Auction House.
local BUY_CARD_HEIGHT = 132
local CARD_PADDING = 10
local CARD_ICON_SIZE = 30
local CLEAR_HEIGHT = 20
local CLEAR_GAP = 5
local NEXT_TITLE = "Next to buy"
local NOTE_COLOR = { 0.6, 0.6, 0.6 }
-- Left to buy sits in the Auction House's footer, past Blizzard's gold display, which ends 163 pixels
-- in and is centered 16 pixels up.
local TOTAL_X = 178
local TOTAL_Y = 16
local TOTAL_WIDTH = 240
local CHECKBOX_SCALE = 0.7
local COLUMN_GAP = 5
-- The make-or-buy icon, the room it takes from a material's name, and its art: the menu bar's
-- Professions tools and the Auction House's gold coin. The tools' art is a whole 32 by 41 menu
-- button, padding and all, so it's drawn larger than the coin, in its own proportions.
local CHOICE_SIZE = 16
local CHOICE_ROOM = CHOICE_SIZE + 8
local MAKE_ATLAS = "UI-HUD-MicroMenu-Professions-Up"
local MAKE_ART_HEIGHT = 24
local MAKE_ART_WIDTH = 19
local BUY_ATLAS = "auctionhouse-icon-coin-gold"
local DONE_COLOR = { 0.5, 0.5, 0.5 }
local EMPTY_MESSAGE = "Your shopping list is empty. Click a craft in Opportunities, then choose Add to List."
local FORGOTTEN_MESSAGE = "No character on this realm knows these recipes any more."
local TOTAL_EXPLANATION = "At each material's Buyout, the cheapest listing in your latest scan, or a vendor's price "
  .. "when lower. Buying many can cost more than the cheapest listing; Refresh Prices at the Auction House "
  .. "counts every listing they take."
local REFRESH_LABEL = "Refresh Prices"
local REFRESH_EXPLANATION = "Refreshes the Buyout prices of every ingredient. Your own auctions are excluded."
local RECHOOSE_LABEL = "Re-choose make/buy"
local RECHOOSE_EXPLANATION = "Uses the refreshed Buyout prices to make or buy each ingredient, whichever costs less."
local CLEAR_DIALOG = "ARBITRAGE_CLEAR_SHOPPING_LIST"
local LOW_GOLD_DIALOG = "ARBITRAGE_SHOPPING_LOW_GOLD"
local AUCTIONS_DIALOG = "ARBITRAGE_SHOPPING_BUY_AUCTIONS"
local FormatMoney = ns.ItemTable.FormatMoney
local FormatCount = ns.ItemTable.FormatCount

local frame = CreateFrame("Frame")
---@type ArbitrageShoppingPanelEntry[]
local panels = {}
-- Items whose names were missing when shown; a refresh follows once they load.
local requestedItems = {}
local refreshPending = false
-- The material a click chose to buy next, and those Skip passed over, until the Auction House opens
-- again. Skips wrap around once every material is skipped.
---@type number?
local chosenNext
---@type table<number, true>
local skipped = {}
-- What was left on the list when you chose to keep buying short of gold, until the Auction House
-- opens again; more than this asks again.
---@type number?
local acknowledgedTotal

---@param message string
local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

---@param itemID number
---@return string? name, number? quality
local function ItemInfo(itemID)
  local name, _, quality = C_Item.GetItemInfo(itemID)
  if not name and not requestedItems[itemID] then
    requestedItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
  end
  return name, quality
end

---@param row ArbitrageShoppingRow
---@param itemID number
---@param name string
---@param quality number?
---@param done boolean?
local function ShowItem(row, itemID, name, quality, done)
  row.icon:SetTexture(C_Item.GetItemIconByID(itemID))
  row.itemName:SetText(name)
  if done then
    row.itemName:SetTextColor(DONE_COLOR[1], DONE_COLOR[2], DONE_COLOR[3])
  else
    local red, green, blue = C_Item.GetItemQualityColor(quality or 1)
    row.itemName:SetTextColor(red, green, blue)
  end
end

-- A card like the item tables': the Auction House's list art under a row of column labels, which
-- don't sort, since a shopping list keeps its own order.
---@param parent Frame
---@param options ArbitrageShoppingListOptions
---@return ArbitrageShoppingList
local function CreateList(parent, options)
  ---@type table[]
  local rows = {}

  local card = CreateFrame("Frame", nil, parent)
  ---@cast card ArbitrageTableBackground
  card.layoutType = "InsetFrameTemplate"
  -- Row tooltips belong to the card, so Tooltip.lua sees this flag on their owner.
  card.arbitrageReplacesItemPricing = options.replacesItemPricing
  card.Background = card:CreateTexture(nil, "BACKGROUND")
  card.Background:SetAtlas("auctionhouse-background-index")
  card.Background:SetPoint("TOPLEFT", 3, -22)
  card.Background:SetPoint("BOTTOMRIGHT", -25, 3)
  card.NineSlice = CreateFrame("Frame", nil, card, "NineSlicePanelTemplate")
  card.NineSlice:SetFrameLevel(card:GetFrameLevel())
  card.NineSlice:ClearAllPoints()
  card.NineSlice:SetPoint("TOPLEFT", 0, -19)
  card.NineSlice:SetPoint("BOTTOMRIGHT", -22, 0)

  local emptyText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  emptyText:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -37)
  emptyText:SetPoint("TOPRIGHT", card, "TOPRIGHT", -15, -37)
  emptyText:SetJustifyH("LEFT")
  emptyText:Hide()

  local function AddHeader(text, x, width, explanation)
    local header = CreateFrame("Button", nil, card, "ColumnDisplayButtonShortTemplate")
    ---@cast header ArbitrageColumnHeader
    header:SetPoint("TOPLEFT", card, "TOPLEFT", x, -1)
    header:SetSize(width, 19)
    header:SetText(text)
    if explanation then
      header:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(text, 1, 1, 1)
        GameTooltip:AddLine(explanation, nil, nil, nil, true)
        GameTooltip:Show()
      end)
      header:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then
          GameTooltip:Hide()
        end
      end)
    end
  end
  AddHeader(options.itemLabel, 4, options.itemWidth)
  for _, column in ipairs(options.columns) do
    AddHeader(column.label, column.x, column.width, column.explanation)
  end

  local scrollBox = CreateFrame("Frame", nil, card, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -26)
  scrollBox:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -26, 3)
  local scrollBar = CreateFrame("EventFrame", nil, card, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

  local function HideTooltip()
    if GameTooltip:IsOwned(card) then
      GameTooltip:Hide()
    end
  end

  ---@param row ArbitrageShoppingRow
  local function InitializeRow(row)
    if row.arbitrageInitialized then
      return
    end
    row.arbitrageInitialized = true
    row:SetHeight(ROW_HEIGHT)
    row:SetHighlightAtlas("auctionhouse-ui-row-highlight", "ADD")
    -- Marks the material to buy next, as the Auction House marks its selected row.
    row.selectedHighlight = row:CreateTexture(nil, "OVERLAY")
    row.selectedHighlight:SetAtlas("auctionhouse-ui-row-select")
    row.selectedHighlight:SetBlendMode("ADD")
    row.selectedHighlight:SetAllPoints()
    row.selectedHighlight:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.iconBorder = row:CreateTexture(nil, "OVERLAY")
    row.iconBorder:SetSize(16, 16)
    row.iconBorder:SetPoint("CENTER", row.icon, "CENTER")
    row.iconBorder:SetAtlas("auctionhouse-itemicon-small-border")

    row.itemName = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
    row.itemName:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.itemName:SetJustifyH("LEFT")
    row.itemName:SetWordWrap(false)
    row.itemName:SetMaxLines(1)

    row.values = {}
    for index, column in ipairs(options.columns) do
      local value = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
      value:SetPoint("LEFT", row, "LEFT", column.x - 4, 0)
      value:SetWidth(column.width)
      value:SetJustifyH("RIGHT")
      value:SetWordWrap(false)
      value:SetMaxLines(1)
      row.values[index] = value
    end

    row:SetScript("OnEnter", function(self)
      local data = self.data
      if not data then
        return
      end
      GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("item:" .. (data.itemID or data.craft.itemID))
      if options.addTooltipLines then
        options.addTooltipLines(data)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", HideTooltip)
    -- Shift-click links the item in chat, as anywhere else.
    row:SetScript("OnClick", function(self)
      local data = self.data
      if data and IsModifierKeyDown() then
        local _, link = C_Item.GetItemInfo(data.itemID or data.craft.itemID)
        HandleModifiedItemClick(link)
      elseif data and options.onClick then
        options.onClick(data)
      end
    end)

    if options.initializeRow then
      options.initializeRow(row)
    end
  end

  local marked
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, index)
    InitializeRow(row)
    local data = rows[index]
    row.data = data
    options.populateRow(row, data)
    row.selectedHighlight:SetShown(marked ~= nil and data.itemID == marked)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideTooltip)

  return {
    frame = card,
    SetRows = function(newRows, newMarked)
      HideTooltip()
      rows = newRows
      marked = newMarked
      -- The list changes a row at a time, so it keeps its place.
      scrollBox:SetDataProvider(CreateIndexRangeDataProvider(#rows), ScrollBoxConstants.RetainScrollPosition)
    end,
    SetEmptyMessage = function(message)
      emptyText:SetText(message or "")
      emptyText:SetShown(message ~= nil)
    end,
  }
end

---@param parent Frame
---@param text string
---@param width number
---@param onClick fun(self: Button)
---@param tooltip string?
---@param template string?
---@return Button
local function CreateButton(parent, text, width, onClick, tooltip, template)
  local button = CreateFrame("Button", nil, parent, template or "UIPanelButtonTemplate")
  button:SetSize(width, 20)
  if text then
    button:SetText(text)
  end
  button:SetScript("OnClick", onClick)
  if tooltip then
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(tooltip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
      if GameTooltip:IsOwned(self) then
        GameTooltip:Hide()
      end
    end)
  end
  return button
end

-- Crafts: the item and how many, with buttons to change it or take it off the list. Shift steps
-- the count by ten.
---@param parent Frame
---@return ArbitrageShoppingList
local function CreateCraftList(parent)
  local right = CRAFTS_WIDTH - SCROLL_BAR_ROOM
  local controlsX = right - 98
  local nameWidth = controlsX - 4 - NAME_X

  ---@param row ArbitrageShoppingRow
  ---@param step number
  local function Step(row, step)
    local data = row.data
    if data then
      local amount = IsShiftKeyDown() and step * 10 or step
      ns.ShoppingList.SetCount(data.craft.itemID, math.max(1, data.craft.count + amount))
    end
  end

  return CreateList(parent, {
    itemLabel = "Craft",
    itemWidth = controlsX - 4 - COLUMN_GAP,
    columns = {},
    initializeRow = function(row)
      row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
      row.itemName:SetWidth(nameWidth)
      row.minus = CreateButton(row, "-", 20, function()
        Step(row, -1)
      end, "One less craft. Shift-click for ten.")
      row.minus:SetPoint("LEFT", row, "LEFT", controlsX - 4, 0)
      row.count = row:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
      row.count:SetWidth(32)
      row.count:SetJustifyH("CENTER")
      row.count:SetPoint("LEFT", row.minus, "RIGHT", 1, 0)
      row.plus = CreateButton(row, "+", 20, function()
        Step(row, 1)
      end, "One more craft. Shift-click for ten.")
      row.plus:SetPoint("LEFT", row.count, "RIGHT", 1, 0)
      row.remove = CreateButton(row, nil, 20, function()
        local data = row.data
        if data then
          ns.ShoppingList.Remove(data.craft.itemID)
        end
      end, "Remove from the shopping list", "UIPanelCloseButtonNoScripts")
      row.remove:SetPoint("LEFT", row.plus, "RIGHT", 2, 0)
    end,
    ---@param data ArbitrageShoppingCraftRow
    populateRow = function(row, data)
      local craft = data.craft
      local name, quality = ItemInfo(craft.itemID)
      name = name or ("Item #" .. craft.itemID)
      local outputQuantity = data.recipe and data.recipe.outputQuantity or 1
      if outputQuantity > 1 then
        name = name .. " (x" .. FormatCount(outputQuantity) .. ")"
      end
      ShowItem(row, craft.itemID, name, quality, data.recipe == nil)
      row.count:SetText(FormatCount(craft.count))
      row.minus:SetEnabled(craft.count > 1)
    end,
    ---@param data ArbitrageShoppingCraftRow
    addTooltipLines = function(data)
      GameTooltip:AddLine(" ")
      if data.recipe then
        local crafts = data.craft.count
        GameTooltip:AddLine(FormatCount(crafts) .. (crafts == 1 and " craft" or " crafts") .. " on your shopping list")
      else
        GameTooltip:AddLine(FORGOTTEN_MESSAGE, 1, 0.82, 0, true)
      end
    end,
  })
end

---@param copper number
---@return string
local function Coins(copper)
  return C_CurrencyInfo.GetCoinTextureString(copper)
end

---@class ArbitrageMakeOrBuyChoice
---@field short number still needed after what you have
---@field makeTotal number? copper to make them all
---@field makeRefreshed boolean
---@field buyTotal number? copper to buy them all
---@field buyRefreshed boolean
---@field buyLabel string
---@field difference number? buyTotal less makeTotal, when both have a price
---@field makers string? who knows the recipe making it uses

-- What making and buying what's still needed of a material cost, to the copper, at refreshed prices
-- where there are any, and who makes it.
---@param data ArbitrageShoppingMaterial
---@return ArbitrageMakeOrBuyChoice
local function DescribeMakeOrBuy(data)
  local short = math.max(0, data.need - data.have)
  local comparison = ns.ShoppingList.CompareMakeAndBuy(data.itemID, short, ns.ShoppingSearch.Quote)
  ---@type ArbitrageMakeOrBuyChoice
  local choice = {
    short = short,
    makeTotal = comparison.makeTotal,
    makeRefreshed = comparison.makeRefreshed,
    buyTotal = comparison.buyTotal,
    buyRefreshed = comparison.buyRefreshed,
    buyLabel = comparison.buySource == "vendor" and "Buy from a vendor" or "Buy",
  }
  if choice.makeTotal and choice.buyTotal then
    choice.difference = choice.buyTotal - choice.makeTotal
  end
  local makers = {}
  for _, source in ipairs(ns.RecipeBook.GetSources(data.itemID)) do
    if source.recipeKey == comparison.recipeKey then
      makers[#makers + 1] = source
    end
  end
  if #makers > 0 then
    choice.makers = ns.OpportunityTable.FormatSources(makers)
  end
  return choice
end

---@param data ArbitrageShoppingMaterial
local function AddMakeOrBuyLines(data)
  local choice = DescribeMakeOrBuy(data)
  if choice.short == 0 then
    return
  end
  local making = data.kind == "make"

  -- Both refreshed, or both from the latest scan, says so once; otherwise the scan's side says so.
  local bothRefreshed = choice.makeRefreshed and choice.buyRefreshed
  local neitherRefreshed = not choice.makeRefreshed and not choice.buyRefreshed
  local prices = bothRefreshed and ", at refreshed prices" or neitherRefreshed and ", at Buyout prices" or ""
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("For the " .. FormatCount(choice.short) .. " still needed" .. prices .. ":", nil, nil, nil, true)
  local function AddOption(label, total, chosen, refreshed)
    local shade = chosen and 1 or 0.6
    local scanned = not (refreshed or neitherRefreshed) and " (latest scan)" or ""
    GameTooltip:AddDoubleLine(
      label .. scanned .. (chosen and " (chosen)" or ""),
      total and Coins(total) or "No price",
      shade,
      shade,
      shade,
      shade,
      shade,
      shade
    )
  end
  AddOption("Make", choice.makeTotal, making, choice.makeRefreshed)
  AddOption(choice.buyLabel, choice.buyTotal, not making, choice.buyRefreshed)
  local difference = choice.difference
  if difference then
    local verdict = difference > 0 and ("Buying costs " .. Coins(difference) .. " more.")
      or difference < 0 and ("Making costs " .. Coins(-difference) .. " more.")
      or "Making and buying cost the same."
    GameTooltip:AddLine(verdict, NORMAL_FONT_COLOR:GetRGB())
  end
  if choice.makers then
    GameTooltip:AddLine("Made by " .. choice.makers, 1, 1, 1, true)
  end
end

-- Clicking a material still to buy at the Auction House makes it the next one Buy buys, dropping a
-- purchase still waiting on a price or on you.
---@param data ArbitrageShoppingMaterial
local function ChooseNext(data)
  if data.kind ~= "buy" or (data.toBuy or 0) == 0 or data.source == "vendor" then
    return
  end
  local step = ns.ShoppingPurchase.GetStep()
  if step == "quoting" or step == "confirm" then
    ns.ShoppingPurchase.Cancel()
  elseif step ~= "idle" then
    return
  end
  chosenNext = data.itemID
  skipped[data.itemID] = nil
  ns.ShoppingPanel.Refresh()
end

-- Materials: what the crafts use, each made material followed by its own materials, indented.
---@param parent Frame
---@return ArbitrageShoppingList
local function CreateMaterialList(parent)
  local columns = {
    {
      label = "Need",
      width = 50,
      explanation = "How many the crafts on your list use in all, including what you already have.",
    },
    {
      label = "Have",
      width = 50,
      explanation = "How many are in your bags and banks, and bought and waiting in your mailbox.",
    },
    {
      label = "Cost",
      width = 96,
      explanation = "What's left to buy at its Buyout, the cheapest listing in your latest scan, or a vendor's "
        .. "price when lower. A material you make shows how many crafts are left to make.",
    },
  }
  local x = MATERIALS_WIDTH - SCROLL_BAR_ROOM
  for index = #columns, 1, -1 do
    x = x - columns[index].width
    columns[index].x = x
    x = x - COLUMN_GAP
  end
  local itemWidth = x - 4
  local nameWidth = itemWidth - NAME_X

  ---@param button Button
  ---@param data ArbitrageShoppingMaterial
  local function ShowChoiceTooltip(button, data)
    local making = data.kind == "make"
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine((making and "Making " or "Buying ") .. (ItemInfo(data.itemID) or data.name), 1, 1, 1)
    AddMakeOrBuyLines(data)
    GameTooltip:AddLine(making and "Click to buy instead." or "Click to make instead.", 0.1, 1, 0.1)
    GameTooltip:AddLine("Applies to every craft on your list.", nil, nil, nil, true)
    GameTooltip:Show()
  end

  -- An icon showing the choice in use, a crafter to make or a gold coin to buy, which one click
  -- flips for every craft on the list.
  ---@param row ArbitrageShoppingRow
  ---@return Button
  local function CreateChoiceButton(row)
    local button = CreateFrame("Button", nil, row)
    ---@cast button ArbitrageChoiceButton
    button:SetSize(CHOICE_SIZE, CHOICE_SIZE)
    -- Textures of its own, so each icon draws at its own size, centered, and brightens on hover.
    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetPoint("CENTER")
    button.Highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.Highlight:SetPoint("CENTER")
    button.Highlight:SetBlendMode("ADD")
    button.Highlight:SetAlpha(0.5)
    button:SetScript("OnClick", function(self)
      local data = row.data
      if not data then
        return
      end
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      ns.ShoppingList.SetMake(data.itemID, data.kind ~= "make")
      -- The list has drawn the row again, so its tooltip follows the new choice.
      if GameTooltip:IsOwned(self) then
        if self:IsShown() and row.data then
          ShowChoiceTooltip(self, row.data)
        else
          GameTooltip:Hide()
        end
      end
    end)
    button:SetScript("OnEnter", function(self)
      if row.data then
        ShowChoiceTooltip(self, row.data)
      end
    end)
    button:SetScript("OnLeave", function(self)
      if GameTooltip:IsOwned(self) then
        GameTooltip:Hide()
      end
    end)
    return button
  end

  return CreateList(parent, {
    itemLabel = "Material",
    itemWidth = itemWidth,
    columns = columns,
    -- The rows say what a material costs here, so the item's own pricing lines would only crowd them.
    replacesItemPricing = true,
    onClick = ChooseNext,
    initializeRow = function(row)
      -- At the start of the Need column, whose numbers sit at its right.
      row.check = row:CreateTexture(nil, "OVERLAY")
      row.check:SetAtlas("checkmark-minimal")
      row.check:SetSize(14, 14)
      row.check:SetPoint("LEFT", row, "LEFT", columns[1].x - 4, 0)
      -- Make or buy, at the end of the Material column.
      row.choice = CreateChoiceButton(row)
      row.choice:SetPoint("RIGHT", row, "LEFT", columns[1].x - 8, 0)
    end,
    ---@param data ArbitrageShoppingMaterial
    populateRow = function(row, data)
      local indent = data.depth * INDENT
      local done = data.kind == "make" and data.crafts == 0 or data.kind == "buy" and data.toBuy == 0
      -- What you already have needs no choosing.
      local choosing = data.canMake and not done
      row.icon:SetPoint("LEFT", row, "LEFT", indent, 0)
      row.itemName:SetWidth(nameWidth - indent - (choosing and CHOICE_ROOM or 0))
      row.choice:SetShown(choosing)
      if choosing then
        -- Making shows the Professions tools, buying the gold coin.
        local making = data.kind == "make"
        for _, texture in ipairs({ row.choice.Icon, row.choice.Highlight }) do
          if making then
            texture:SetAtlas(MAKE_ATLAS)
            texture:SetSize(MAKE_ART_WIDTH, MAKE_ART_HEIGHT)
          else
            texture:SetAtlas(BUY_ATLAS)
            texture:SetSize(CHOICE_SIZE, CHOICE_SIZE)
          end
        end
      end

      local name, quality = ItemInfo(data.itemID)
      name = name or data.name
      if data.source == "vendor" then
        name = name .. " (Vendor)"
      end
      ShowItem(row, data.itemID, name, quality, done)
      row.check:SetShown(done)

      local need, have, cost = row.values[1], row.values[2], row.values[3]
      need:SetText(FormatCount(data.need))
      have:SetText(FormatCount(data.have))
      -- A refreshed material with fewer listed than you need shows in yellow.
      local short = data.listed ~= nil and data.listed < (data.toBuy or 0)
      if data.kind == "make" then
        cost:SetText(done and "" or ("Make " .. FormatCount(data.crafts)))
      elseif done then
        cost:SetText("")
      elseif data.listed == 0 then
        cost:SetText("None listed")
      else
        cost:SetText(data.cost and FormatMoney(data.cost) or "—")
      end
      for _, value in ipairs(row.values) do
        if done or data.kind == "make" then
          value:SetTextColor(DONE_COLOR[1], DONE_COLOR[2], DONE_COLOR[3])
        else
          value:SetTextColor(WHITE_FONT_COLOR:GetRGB())
        end
      end
      if short and not done then
        cost:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
      end
    end,
    ---@param data ArbitrageShoppingMaterial
    addTooltipLines = function(data)
      GameTooltip:AddLine(" ")
      if data.inMail then
        GameTooltip:AddLine(FormatCount(data.inMail) .. " bought and waiting in your mailbox", 1, 1, 1, true)
      end
      if data.kind == "make" and data.crafts > 0 then
        local crafts = data.crafts
        local makes = data.outputQuantity and data.outputQuantity > 1 and (", " .. data.outputQuantity .. " each") or ""
        GameTooltip:AddLine(
          "Made from the materials below it: "
            .. FormatCount(crafts)
            .. (crafts == 1 and " craft" or " crafts")
            .. makes,
          1,
          1,
          1,
          true
        )
      elseif data.kind == "make" then
        GameTooltip:AddLine("You have all the crafts on your list need.", 1, 1, 1, true)
      elseif data.refreshedAt then
        local listed = FormatCount(data.listed) .. " listed"
        GameTooltip:AddDoubleLine("Refreshed " .. ns.Time.Since(data.refreshedAt), listed)
        if data.unitPrice then
          GameTooltip:AddDoubleLine("Each, on average", Coins(data.unitPrice))
        end
        if data.listed < data.toBuy then
          local missing = data.toBuy - data.listed
          GameTooltip:AddLine(
            "Only " .. FormatCount(data.listed) .. " listed, " .. FormatCount(missing) .. " short of what you need.",
            1,
            0.82,
            0,
            true
          )
        end
      elseif data.unitPrice then
        local where = data.source == "vendor" and "Vendor price" or "Buyout"
        GameTooltip:AddDoubleLine(where .. " each", Coins(data.unitPrice))
      else
        GameTooltip:AddLine("No Buyout or vendor price yet.", 1, 0.82, 0, true)
      end
      if data.canMake then
        AddMakeOrBuyLines(data)
      end
    end,
  })
end

---@return boolean
local function IsAuctionHouseOpen()
  return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() == true
end

-- Whether Refresh Prices can run and why not. While it runs, it counts through its searches.
---@param entry ArbitrageShoppingPanelEntry
local function UpdateRefresh(entry)
  local button = entry.refreshButton
  if not button then
    return
  end
  local running = ns.ShoppingSearch.IsRunning()
  local buying = ns.ShoppingPurchase.GetStep() ~= "idle"
  local reason
  if not IsAuctionHouseOpen() then
    reason = "Open the Auction House to refresh prices."
  elseif ns.Scan.GetStatus().phase ~= "idle" then
    reason = "Wait for the scan to finish."
  elseif buying then
    reason = "Finish buying first."
  elseif not running and not entry.canRefresh then
    reason = "Nothing is left to buy at the Auction House."
  end
  button:SetEnabled(not running and reason == nil)
  button.disabledTooltip = reason

  -- Finding auctions to buy searches too, which the buy bar counts instead.
  local run = ns.ShoppingSearch.GetRun()
  if run and running and not buying then
    button:SetText(("%d/%d"):format(math.min(run.done + 1, run.total), run.total))
  else
    button:SetText(REFRESH_LABEL)
  end
end

-- The commodity Buy buys next: the material a click chose, or the first in the list's order not
-- skipped, starting over once all are. Also what isn't a commodity, which is bought once every
-- commodity is. A material refreshed with none listed is passed over.
---@param rows ArbitrageShoppingMaterial[]
---@return ArbitrageShoppingMaterial? next, ArbitrageSearchRequest[] auctionRequests
local function FindNext(rows)
  local commodities, auctionRequests = {}, {}
  for _, row in ipairs(rows) do
    if row.kind == "buy" and row.toBuy > 0 and row.source ~= "vendor" and row.listed ~= 0 then
      if ns.ShoppingSearch.IsCommodity(row.itemID) == false then
        auctionRequests[#auctionRequests + 1] = { itemID = row.itemID, quantity = row.toBuy }
      else
        commodities[#commodities + 1] = row
      end
    end
  end
  for _, row in ipairs(commodities) do
    if row.itemID == chosenNext then
      return row, auctionRequests
    end
  end
  for _, row in ipairs(commodities) do
    if not skipped[row.itemID] then
      return row, auctionRequests
    end
  end
  skipped = {}
  return commodities[1], auctionRequests
end

-- "8x Copper Ore", named by the recipe while the item loads.
---@param entry ArbitrageShoppingPanelEntry
---@param itemID number
---@param quantity number
---@return string
local function DescribeMaterial(entry, itemID, quantity)
  local name = ItemInfo(itemID) or (entry.names and entry.names[itemID]) or ("Item #" .. itemID)
  return FormatCount(quantity) .. "x " .. name
end

-- How many of the next material Buy buys: all still needed, or as many as a refresh found listed.
---@param row ArbitrageShoppingMaterial
---@return number
local function BuyQuantity(row)
  return row.listed and math.min(row.toBuy, row.listed) or row.toBuy
end

---@class ArbitrageBuyCardView
---@field title string
---@field itemID number? the item it buys, shown with its icon and name
---@field name string? what it shows in place of an item
---@field detail string?
---@field total number? copper, beside Total, for an item
---@field totalWarning boolean? the total is higher than shown before
---@field notice string?
---@field noticeWarning boolean? the notice needs your attention, rather than only explaining
---@field empty string? the card says only this
---@field buyLabel string
---@field canBuy boolean?
---@field skipLabel string? Skip's label, when it's offered
---@field canSkip boolean?

-- What the card shows and offers at each step of buying.
---@param entry ArbitrageShoppingPanelEntry
---@return ArbitrageBuyCardView
local function DescribeCard(entry)
  local step, purchase, plan = ns.ShoppingPurchase.GetStep()
  local next, auctionRequests = entry.next, entry.auctionRequests or {}
  ---@type ArbitrageBuyCardView
  local view = { title = NEXT_TITLE, buyLabel = "Buy" }
  if (step == "quoting" or step == "buying") and purchase then
    view.itemID = purchase.itemID
    view.detail = step == "quoting" and "Getting a price..." or "Buying..."
    view.total = purchase.total or purchase.expected
    view.buyLabel, view.skipLabel = "Buy " .. FormatCount(purchase.quantity), "Skip"
  elseif step == "confirm" and purchase and purchase.total then
    view.itemID = purchase.itemID
    view.detail = FormatCount(purchase.quantity) .. " to buy"
    view.total, view.totalWarning = purchase.total, true
    view.notice = purchase.expected
        and (FormatMoney(purchase.total - purchase.expected) .. " more than the " .. FormatMoney(purchase.expected) .. " shown")
      or "The Auction House's price right now"
    view.noticeWarning = true
    view.buyLabel, view.canBuy, view.skipLabel, view.canSkip = "Buy anyway", true, "Skip", true
  elseif step == "reviewing" then
    local run = ns.ShoppingSearch.GetRun()
    view.name = "Finding auctions"
    view.detail = run and ("%d of %d searched"):format(run.done, run.total) or nil
    view.buyLabel = "Review"
  elseif (step == "auctions" or step == "bidding") and plan and plan.auctions[plan.index] then
    local auction = plan.auctions[plan.index]
    view.title = ("Auction %d of %d"):format(plan.index, #plan.auctions)
    view.itemID = auction.itemID
    view.detail = FormatCount(auction.quantity) .. " in this auction"
    view.total = auction.buyout
    view.buyLabel, view.canBuy = ("Buy %d/%d"):format(plan.index, #plan.auctions), step == "auctions"
    view.skipLabel, view.canSkip = "Stop", step == "auctions"
  elseif next then
    local quantity = BuyQuantity(next)
    view.itemID = next.itemID
    view.detail = FormatCount(quantity) .. " to buy"
    if next.cost and quantity > 0 then
      view.detail = view.detail .. " · " .. FormatMoney(math.floor(next.cost / quantity + 0.5)) .. " each"
    end
    view.total = next.cost
    if next.listed and next.listed < next.toBuy then
      view.notice = "Only " .. FormatCount(next.listed) .. " listed of the " .. FormatCount(next.toBuy) .. " needed"
      view.noticeWarning = true
    elseif not next.refreshedAt then
      view.notice = "Price from your latest scan"
    end
    view.buyLabel, view.canBuy = "Buy " .. FormatCount(quantity), true
    view.skipLabel, view.canSkip = "Skip", true
  elseif #auctionRequests > 0 then
    local count = #auctionRequests
    view.name = "Sold by the auction"
    view.detail = count == 1 and "1 material sells one auction at a time"
      or (count .. " materials sell one auction at a time")
    view.buyLabel, view.canBuy = "Review", true
  else
    view.empty = "Nothing left to buy at the Auction House."
  end
  return view
end

-- Shows the card's view: the item and what it costs, a notice, and Buy and Skip.
---@param entry ArbitrageShoppingPanelEntry
local function UpdateCard(entry)
  local card = entry.buyCard
  if not card then
    return
  end
  local view = DescribeCard(entry)
  local step = ns.ShoppingPurchase.GetStep()
  local reason
  if not IsAuctionHouseOpen() then
    reason = "Open the Auction House to buy."
  elseif ns.Scan.GetStatus().phase ~= "idle" then
    reason = "Wait for the scan to finish."
  elseif ns.ShoppingSearch.IsRunning() and step ~= "reviewing" then
    reason = "Wait for Refresh Prices to finish."
  end

  card.Title:SetText(view.title)
  card.Empty:SetText(view.empty or "")
  card.Empty:SetShown(view.empty ~= nil)
  local showing = view.empty == nil
  local itemID = view.itemID
  card.Icon:SetShown(showing and itemID ~= nil)
  card.Name:SetShown(showing)
  card.Detail:SetShown(showing)
  card.Notice:SetShown(showing)
  card.TotalLabel:SetShown(showing and itemID ~= nil)
  card.Total:SetShown(showing and itemID ~= nil)
  card.BuyButton:SetShown(showing)
  card.SkipButton:SetShown(showing and view.skipLabel ~= nil)
  if not showing then
    return
  end

  -- An item takes its icon and quality color; anything else is named in white beside no icon.
  card.Name:ClearAllPoints()
  if itemID then
    card.Icon.itemID = itemID
    card.Icon.Texture:SetTexture(C_Item.GetItemIconByID(itemID))
    local name, quality = ItemInfo(itemID)
    card.Name:SetText(name or (entry.names and entry.names[itemID]) or ("Item #" .. itemID))
    local red, green, blue = C_Item.GetItemQualityColor(quality or 1)
    card.Name:SetTextColor(red, green, blue)
    card.Name:SetPoint("TOPLEFT", card.Icon, "TOPRIGHT", 8, -1)
  else
    card.Name:SetText(view.name or "")
    card.Name:SetTextColor(WHITE_FONT_COLOR:GetRGB())
    card.Name:SetPoint("TOPLEFT", card.Icon, "TOPLEFT", 0, -1)
  end
  card.Name:SetPoint("RIGHT", card, "RIGHT", -CARD_PADDING, 0)
  card.Detail:SetText(view.detail or "")
  card.Total:SetText(view.total and FormatMoney(view.total) or "—")
  local totalColor = view.totalWarning and NORMAL_FONT_COLOR or WHITE_FONT_COLOR
  card.Total:SetTextColor(totalColor:GetRGB())
  card.Notice:SetText(view.notice or "")
  if view.noticeWarning then
    card.Notice:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
  else
    card.Notice:SetTextColor(NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
  end

  card.BuyButton:SetText(view.buyLabel)
  card.BuyButton:SetEnabled(view.canBuy == true and reason == nil)
  card.BuyButton.disabledTooltip = view.canBuy and reason or nil
  card.SkipButton:SetText(view.skipLabel or "")
  card.SkipButton:SetEnabled(view.canSkip == true)
end

-- Short of gold for what's left on the list, asks once an Auction House visit before buying,
-- again only if the list grows. Keep Buying does it from its own click.
---@param entry ArbitrageShoppingPanelEntry
---@param buy fun()
local function WithEnoughGold(entry, buy)
  local total = entry.leftToBuy or 0
  if GetMoney() >= total or (acknowledgedTotal and total <= acknowledgedTotal) then
    buy()
    return
  end
  if not StaticPopupDialogs[LOW_GOLD_DIALOG] then
    StaticPopupDialogs[LOW_GOLD_DIALOG] = {
      text = "You have %s, and what's left on your list costs about %s.\n\nKeep buying?",
      button1 = "Keep Buying",
      button2 = CANCEL,
      OnAccept = function(_, accepted)
        accepted()
      end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
  end
  StaticPopup_Show(LOW_GOLD_DIALOG, Coins(GetMoney()), Coins(total), function()
    acknowledgedTotal = total
    buy()
  end)
end

-- Asks to buy the auctions found, listing each material's and any extra from buying whole auctions.
-- Accepting buys the first, from its own click.
---@param entry ArbitrageShoppingPanelEntry
---@param plan ArbitrageAuctionPlan
local function ShowAuctionPlan(entry, plan)
  if #plan.auctions == 0 then
    Print("None of the materials that sell by the auction are listed.")
    return
  end
  local order, byItem = {}, {}
  for _, auction in ipairs(plan.auctions) do
    local item = byItem[auction.itemID]
    if not item then
      item = { auctions = 0, units = 0 }
      byItem[auction.itemID] = item
      order[#order + 1] = auction.itemID
    end
    item.auctions = item.auctions + 1
    item.units = item.units + auction.quantity
  end
  local auctionCount = #plan.auctions
  local lines = {
    ("Buy %d %s for %s?"):format(auctionCount, auctionCount == 1 and "auction" or "auctions", Coins(plan.total)),
  }
  for _, itemID in ipairs(order) do
    local item = byItem[itemID]
    local detail = item.auctions == 1 and "1 auction" or (item.auctions .. " auctions")
    if plan.extra[itemID] then
      detail = detail .. ", " .. plan.extra[itemID] .. " extra"
    end
    lines[#lines + 1] = DescribeMaterial(entry, itemID, item.units) .. " (" .. detail .. ")"
  end
  for itemID, missing in pairs(plan.short) do
    lines[#lines + 1] = DescribeMaterial(entry, itemID, missing) .. " more aren't listed."
  end
  if GetMoney() < plan.total then
    lines[#lines + 1] = "You have " .. Coins(GetMoney()) .. "."
  end
  if not StaticPopupDialogs[AUCTIONS_DIALOG] then
    StaticPopupDialogs[AUCTIONS_DIALOG] = {
      text = "%s",
      button1 = "Buy",
      button2 = CANCEL,
      OnAccept = function(_, accepted)
        ns.ShoppingPurchase.StartAuctions(accepted)
      end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
  end
  StaticPopup_Show(AUCTIONS_DIALOG, table.concat(lines, "\n"), nil, plan)
end

-- Buys the next commodity, takes a higher price, buys the next auction, or finds the auctions to
-- buy, as the bar offers.
---@param entry ArbitrageShoppingPanelEntry
local function OnBuyClick(entry)
  local step = ns.ShoppingPurchase.GetStep()
  local next = entry.next
  if step == "confirm" then
    ns.ShoppingPurchase.ConfirmAnyway()
  elseif step == "auctions" then
    ns.ShoppingPurchase.BuyNextAuction()
  elseif step ~= "idle" then
    return
  elseif next then
    local itemID, quantity, expected = next.itemID, BuyQuantity(next), next.cost
    WithEnoughGold(entry, function()
      ns.ShoppingPurchase.BuyCommodity(itemID, quantity, expected)
    end)
  elseif entry.auctionRequests and #entry.auctionRequests > 0 then
    ns.ShoppingPurchase.Review(entry.auctionRequests, function(plan)
      ShowAuctionPlan(entry, plan)
    end)
  end
end

-- Passes over the next commodity, dropping a purchase of it still waiting, or stops buying auctions.
---@param entry ArbitrageShoppingPanelEntry
local function OnSkipClick(entry)
  local step = ns.ShoppingPurchase.GetStep()
  if step == "auctions" then
    ns.ShoppingPurchase.Cancel()
    return
  end
  if step == "quoting" or step == "confirm" then
    ns.ShoppingPurchase.Cancel()
  end
  local next = entry.next
  if next then
    skipped[next.itemID] = true
    if chosenNext == next.itemID then
      chosenNext = nil
    end
  end
  ns.ShoppingPanel.Refresh()
end

-- Searches every material the list could need, then, when the checkbox asks, makes or buys each as
-- costs least at the prices found.
local function StartRefresh()
  ns.ShoppingSearch.Start(ns.ShoppingList.GetSearchList(), function()
    if ns.Config.Get("rechooseOnRefresh") then
      ns.ShoppingList.ChooseCheapest(ns.ShoppingSearch.UnitPrice)
    end
  end)
end

---@param entry ArbitrageShoppingPanelEntry
local function Render(entry)
  ns.Profile.Start("Shopping List", "Materials")
  local crafts = ns.ShoppingList.GetCrafts()
  ---@type ArbitrageShoppingCraftRow[]
  local craftRows = {}
  local knownCount = 0
  for index, craft in ipairs(crafts) do
    local recipe = ns.ShoppingList.GetRecipe(craft.itemID, craft.recipeKey)
    craftRows[index] = { craft = craft, recipe = recipe }
    if recipe then
      knownCount = knownCount + 1
    end
  end
  local materials = ns.ShoppingList.GetMaterials(ns.ShoppingSearch.Quote)
  ns.Profile.Size("Shopping List", #materials.rows, "materials")
  -- A refresh has something to search while anything is left to buy at the Auction House or make.
  entry.canRefresh = false
  for _, row in ipairs(materials.rows) do
    if row.kind == "buy" and row.toBuy > 0 and row.source ~= "vendor" or row.kind == "make" and row.crafts > 0 then
      entry.canRefresh = true
    end
  end

  entry.leftToBuy = materials.cost
  entry.names = {}
  for _, row in ipairs(materials.rows) do
    entry.names[row.itemID] = row.name
  end
  -- The bar's next material is marked in the list, or the auction it's buying.
  local marked
  if entry.buyCard then
    entry.next, entry.auctionRequests = FindNext(materials.rows)
    local step, purchase, plan = ns.ShoppingPurchase.GetStep()
    local auction = plan and plan.auctions[plan.index]
    if purchase then
      marked = purchase.itemID
    elseif auction and (step == "auctions" or step == "bidding") then
      marked = auction.itemID
    elseif entry.next then
      marked = entry.next.itemID
    end
  end

  ns.Profile.Stage("Shopping List", "Drawing")
  entry.crafts.SetRows(craftRows)
  entry.crafts.SetEmptyMessage(#crafts == 0 and EMPTY_MESSAGE or nil)
  entry.materials.SetRows(materials.rows, marked)
  entry.materials.SetEmptyMessage(#crafts > 0 and knownCount == 0 and FORGOTTEN_MESSAGE or nil)

  local total = "Left to buy: " .. FormatMoney(materials.cost)
  if materials.unpricedCount > 0 then
    total = total .. " + " .. materials.unpricedCount .. " unpriced"
  end
  if materials.shortCount > 0 then
    total = total .. ", " .. materials.shortCount .. " short"
  end
  entry.total:SetText(total)
  UpdateRefresh(entry)
  UpdateCard(entry)
  ns.Profile.Finish("Shopping List")
end

-- Draws every shopping list that can be seen; each draws as it shows.
function ns.ShoppingPanel.Refresh()
  for _, entry in ipairs(panels) do
    if entry.content:IsVisible() then
      Render(entry)
    end
  end
end

-- Follows a scan starting or stopping, which Refresh Prices and buying wait for.
function ns.ShoppingPanel.RefreshStatus()
  for _, entry in ipairs(panels) do
    if entry.content:IsVisible() then
      UpdateRefresh(entry)
      UpdateCard(entry)
    end
  end
end

local function ConfirmClear()
  if not StaticPopupDialogs[CLEAR_DIALOG] then
    StaticPopupDialogs[CLEAR_DIALOG] = {
      text = "Remove every craft from your shopping list?",
      button1 = YES,
      button2 = NO,
      OnAccept = ns.ShoppingList.Clear,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
  end
  StaticPopup_Show(CLEAR_DIALOG)
end

-- In the Auction House's footer, where Opportunities keeps its scan buttons.
---@param entry ArbitrageShoppingPanelEntry
---@param auctionHouse Frame
local function CreateFooter(entry, auctionHouse)
  local button = CreateFrame("Button", nil, entry.content, "UIPanelButtonTemplate")
  ---@cast button ArbitrageScanButton
  button:SetSize(120, 22)
  button:SetPoint("BOTTOMRIGHT", auctionHouse, "BOTTOMRIGHT", -12, 9)
  button:SetText(REFRESH_LABEL)
  button:SetMotionScriptsWhileDisabled(true)
  button:SetScript("OnClick", StartRefresh)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(REFRESH_LABEL, 1, 1, 1)
    GameTooltip:AddLine(REFRESH_EXPLANATION, nil, nil, nil, true)
    if self.disabledTooltip then
      GameTooltip:AddLine(self.disabledTooltip, 1, 0.82, 0, true)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)
  -- Whether a refresh also re-chooses make or buy, which is remembered. Blizzard draws the box at
  -- its art's size, so it's scaled down to sit beside the buttons.
  local rechoose = CreateFrame("CheckButton", nil, entry.content, "MinimalCheckboxTemplate")
  rechoose:SetScale(CHECKBOX_SCALE)
  local label = entry.content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  label:SetPoint("RIGHT", button, "LEFT", -10, 0)
  label:SetText(RECHOOSE_LABEL)
  rechoose:SetPoint("RIGHT", label, "LEFT", 0, 0)
  rechoose:SetChecked(ns.Config.Get("rechooseOnRefresh"))
  rechoose:SetScript("OnClick", function(self)
    ns.Config.Set("rechooseOnRefresh", self:GetChecked())
  end)
  rechoose:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(RECHOOSE_LABEL, 1, 1, 1)
    GameTooltip:AddLine(RECHOOSE_EXPLANATION, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  rechoose:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)
  entry.refreshButton = button
  entry.rechoose = rechoose
end

-- The card under the crafts that buys the next material: its icon and name, how many and what each
-- costs, the total, a notice when something needs your attention, and Buy and Skip.
---@param entry ArbitrageShoppingPanelEntry
---@return ArbitrageBuyCard
local function CreateBuyCard(entry)
  local card = CreateFrame("Frame", nil, entry.content)
  ---@cast card ArbitrageBuyCard
  card.layoutType = "InsetFrameTemplate"
  card:SetSize(CRAFTS_WIDTH - SCROLL_BAR_GUTTER, BUY_CARD_HEIGHT)
  card.Background = card:CreateTexture(nil, "BACKGROUND")
  card.Background:SetAtlas("auctionhouse-background-index")
  card.Background:SetPoint("TOPLEFT", 3, -3)
  card.Background:SetPoint("BOTTOMRIGHT", -3, 3)
  card.NineSlice = CreateFrame("Frame", nil, card, "NineSlicePanelTemplate")
  card.NineSlice:SetFrameLevel(card:GetFrameLevel())
  card.NineSlice:ClearAllPoints()
  card.NineSlice:SetAllPoints()

  card.Title = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  card.Title:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -10)

  -- The item's icon shows its tooltip, without Arbitrage's pricing, which the card covers.
  card.Icon = CreateFrame("Button", nil, card)
  card.Icon:SetSize(CARD_ICON_SIZE, CARD_ICON_SIZE)
  card.Icon:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -28)
  card.Icon.arbitrageReplacesItemPricing = true
  card.Icon.Texture = card.Icon:CreateTexture(nil, "ARTWORK")
  card.Icon.Texture:SetAllPoints()
  card.Icon.Border = card.Icon:CreateTexture(nil, "OVERLAY")
  card.Icon.Border:SetAtlas("auctionhouse-itemicon-small-border")
  card.Icon.Border:SetPoint("TOPLEFT", -2, 2)
  card.Icon.Border:SetPoint("BOTTOMRIGHT", 2, -2)
  card.Icon:SetScript("OnEnter", function(self)
    if self.itemID then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("item:" .. self.itemID)
      GameTooltip:Show()
    end
  end)
  card.Icon:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)

  card.Name = card:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  card.Name:SetJustifyH("LEFT")
  card.Name:SetWordWrap(false)
  card.Name:SetMaxLines(1)
  card.Detail = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  card.Detail:SetPoint("TOPLEFT", card.Name, "BOTTOMLEFT", 0, -4)
  card.Detail:SetPoint("RIGHT", card, "RIGHT", -CARD_PADDING, 0)
  card.Detail:SetJustifyH("LEFT")
  card.Detail:SetWordWrap(false)

  card.TotalLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  card.TotalLabel:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -68)
  card.TotalLabel:SetText("Total")
  card.Total = card:CreateFontString(nil, "ARTWORK", "Number14FontWhite")
  card.Total:SetPoint("RIGHT", card, "RIGHT", -CARD_PADDING, 0)
  card.Total:SetPoint("TOP", card.TotalLabel, "TOP", 0, 0)
  card.Total:SetJustifyH("RIGHT")

  card.Notice = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  card.Notice:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -86)
  card.Notice:SetPoint("RIGHT", card, "RIGHT", -CARD_PADDING, 0)
  card.Notice:SetJustifyH("LEFT")
  card.Notice:SetWordWrap(false)

  card.Empty = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  card.Empty:SetPoint("LEFT", card, "LEFT", CARD_PADDING, 0)
  card.Empty:SetPoint("RIGHT", card, "RIGHT", -CARD_PADDING, 0)
  card.Empty:SetJustifyH("CENTER")
  card.Empty:Hide()

  card.BuyButton = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  card.BuyButton:SetSize(150, 22)
  card.BuyButton:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", CARD_PADDING - 2, CARD_PADDING)
  card.BuyButton:SetMotionScriptsWhileDisabled(true)
  card.BuyButton:SetScript("OnClick", function()
    OnBuyClick(entry)
  end)
  card.BuyButton:SetScript("OnEnter", function(self)
    if self.disabledTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.disabledTooltip, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  card.BuyButton:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)
  card.SkipButton = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  card.SkipButton:SetSize(90, 22)
  card.SkipButton:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -CARD_PADDING + 2, CARD_PADDING)
  card.SkipButton:SetScript("OnClick", function()
    OnSkipClick(entry)
  end)
  return card
end

-- Fills the panel, which may hold other content: the Auction House tab swaps this for Opportunities.
-- Only there can it refresh prices.
---@param panel Frame
---@param controlsParent Frame the window or Auction House whose control row holds the heading
---@param inAuctionHouse boolean?
---@return ArbitrageShoppingPanelEntry
function ns.ShoppingPanel.Create(panel, controlsParent, inAuctionHouse)
  local content = CreateFrame("Frame", nil, panel)
  content:SetAllPoints()
  content:Show()

  local heading = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("LEFT", controlsParent, "TOPLEFT", 66, -49)
  heading:SetText("Shopping List")

  -- In the Auction House the crafts make room below for Clear and the card that buys; in the window
  -- Clear and the total share the row below them.
  local crafts = CreateCraftList(content)
  crafts.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -4)
  local craftsBottom = inAuctionHouse and (8 + BUY_CARD_HEIGHT + 2 * CLEAR_GAP + CLEAR_HEIGHT) or (8 + FOOTER_HEIGHT)
  crafts.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 16, craftsBottom)
  crafts.frame:SetWidth(CRAFTS_WIDTH)

  local materials = CreateMaterialList(content)
  materials.frame:SetPoint("TOPLEFT", crafts.frame, "TOPRIGHT", CARD_GAP, 0)
  materials.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -5, 8)

  local clearButton = CreateButton(content, "Clear", 80, ConfirmClear, "Remove every craft from your shopping list.")
  if inAuctionHouse then
    clearButton:SetPoint("TOPRIGHT", crafts.frame, "BOTTOMRIGHT", -SCROLL_BAR_GUTTER, -CLEAR_GAP)
  else
    clearButton:SetPoint("BOTTOMRIGHT", crafts.frame, "BOTTOMRIGHT", -SCROLL_BAR_GUTTER, -FOOTER_HEIGHT + 2)
  end

  -- The total explains its prices on hover, so it sits on a frame of its own. In the Auction House
  -- it's beside your gold, which it's measured against.
  local totalFrame = CreateFrame("Frame", nil, content)
  if inAuctionHouse then
    totalFrame:SetPoint("LEFT", controlsParent, "BOTTOMLEFT", TOTAL_X, TOTAL_Y)
    totalFrame:SetWidth(TOTAL_WIDTH)
  else
    totalFrame:SetPoint("LEFT", crafts.frame, "BOTTOMLEFT", 4, -FOOTER_HEIGHT / 2)
    totalFrame:SetPoint("RIGHT", clearButton, "LEFT", -8, 0)
  end
  totalFrame:SetHeight(20)
  totalFrame:EnableMouse(true)
  local total = totalFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  total:SetAllPoints()
  total:SetJustifyH("LEFT")
  totalFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Left to buy", 1, 1, 1)
    GameTooltip:AddLine(TOTAL_EXPLANATION, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  totalFrame:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)

  ---@type ArbitrageShoppingPanelEntry
  local entry = {
    panel = panel,
    content = content,
    heading = heading,
    crafts = crafts,
    materials = materials,
    total = total,
  }
  if inAuctionHouse then
    CreateFooter(entry, controlsParent)
    entry.buyCard = CreateBuyCard(entry)
    entry.buyCard:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 16, 8)
  end
  panels[#panels + 1] = entry
  panel:HookScript("OnShow", ns.ShoppingPanel.Refresh)
  return entry
end

-- Refreshes as the list changes, as prices refresh, as buying moves along, as bags and banks change,
-- and as item names load, since the materials sort by name.
function ns.ShoppingPanel.Register()
  ns.ShoppingList.OnChange(ns.ShoppingPanel.Refresh)
  ns.ShoppingSearch.OnChange(ns.ShoppingPanel.Refresh)
  ns.ShoppingPurchase.OnChange(ns.ShoppingPanel.Refresh)
  frame:RegisterEvent("BAG_UPDATE_DELAYED")
  frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  -- Whether a material sells as a commodity loads with what the Auction House knows of it.
  frame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "AUCTION_HOUSE_SHOW" then
      -- A new visit starts buying over: no choice or skips, and the gold warning asks again.
      chosenNext, skipped, acknowledgedTotal = nil, {}, nil
    elseif eventName == "GET_ITEM_INFO_RECEIVED" then
      if not requestedItems[itemID] then
        return
      end
      requestedItems[itemID] = nil
      if not success then
        return
      end
    end
    -- Bank slots change one at a time, so their refreshes wait for the frame to end.
    if not refreshPending then
      refreshPending = true
      C_Timer.After(0, function()
        refreshPending = false
        ns.ShoppingPanel.Refresh()
      end)
    end
  end)
end

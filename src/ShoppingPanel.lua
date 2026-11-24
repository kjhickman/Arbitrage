local _, ns = ...

ns.ShoppingPanel = {}

---@class ArbitrageShoppingList
---@field frame Frame the list's card
---@field SetRows fun(rows: table[])
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

---@class ArbitrageShoppingRow : Button
---@field arbitrageInitialized boolean?
---@field data table? the craft or material the row shows
---@field icon Texture
---@field iconBorder Texture
---@field itemName FontString
---@field values FontString[] one per column
---@field check Texture? materials: marks what you have enough of
---@field choice Button? materials: shows whether the material is made or bought, and flips it
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
local COLUMN_GAP = 5
-- The make-or-buy icon, the room it takes from a material's name, and its art: the crafting orders'
-- crafter and the Auction House's gold coin.
local CHOICE_SIZE = 16
local CHOICE_ROOM = CHOICE_SIZE + 8
local MAKE_ATLAS = "professions-icon-crafter"
local BUY_ATLAS = "auctionhouse-icon-coin-gold"
local DONE_COLOR = { 0.5, 0.5, 0.5 }
local EMPTY_MESSAGE = "Your shopping list is empty. Click a craft in Opportunities, then choose Add to List."
local FORGOTTEN_MESSAGE = "No character on this realm knows these recipes any more."
local TOTAL_EXPLANATION = "At each material's Buyout, the cheapest listing in your latest scan, or a vendor's price "
  .. "when lower. Buying many can cost more than the cheapest listing."
local CLEAR_DIALOG = "ARBITRAGE_CLEAR_SHOPPING_LIST"
local FormatMoney = ns.ItemTable.FormatMoney
local FormatCount = ns.ItemTable.FormatCount

local frame = CreateFrame("Frame")
---@type ArbitrageShoppingPanelEntry[]
local panels = {}
-- Items whose names were missing when shown; a refresh follows once they load.
local requestedItems = {}
local refreshPending = false

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
      end
    end)

    if options.initializeRow then
      options.initializeRow(row)
    end
  end

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, index)
    InitializeRow(row)
    row.data = rows[index]
    options.populateRow(row, rows[index])
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  ScrollUtil.RegisterAlternateRowBehavior(scrollBox, function(row, alternate)
    row:SetNormalAtlas(alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  end)
  scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnScroll, HideTooltip)

  return {
    frame = card,
    SetRows = function(newRows)
      HideTooltip()
      rows = newRows
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
---@field buyTotal number? copper to buy them all
---@field buyLabel string
---@field difference number? buyTotal less makeTotal, when both have a price
---@field makers string? who knows the recipe making it uses

-- What making and buying what's still needed of a material cost, to the copper, and who makes it.
---@param data ArbitrageShoppingMaterial
---@return ArbitrageMakeOrBuyChoice
local function DescribeMakeOrBuy(data)
  local short = math.max(0, data.need - data.have)
  local comparison = ns.ShoppingList.CompareMakeAndBuy(data.itemID)
  ---@type ArbitrageMakeOrBuyChoice
  local choice = {
    short = short,
    makeTotal = comparison.makeCost and math.floor(comparison.makeCost * short + 0.5),
    buyTotal = comparison.buyCost and math.floor(comparison.buyCost * short + 0.5),
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

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(
    "For the " .. FormatCount(choice.short) .. " still needed, at Buyout prices:",
    nil,
    nil,
    nil,
    true
  )
  local function AddOption(label, total, chosen)
    local shade = chosen and 1 or 0.6
    GameTooltip:AddDoubleLine(
      label .. (chosen and " (chosen)" or ""),
      total and Coins(total) or "No price",
      shade,
      shade,
      shade,
      shade,
      shade,
      shade
    )
  end
  AddOption("Make", choice.makeTotal, making)
  AddOption(choice.buyLabel, choice.buyTotal, not making)
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
    { label = "Have", width = 50, explanation = "How many are in your bags and banks." },
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
    button:SetSize(CHOICE_SIZE, CHOICE_SIZE)
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
        local atlas = data.kind == "make" and MAKE_ATLAS or BUY_ATLAS
        row.choice:SetNormalAtlas(atlas)
        row.choice:SetHighlightAtlas(atlas, "ADD")
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
      if data.kind == "make" then
        cost:SetText(done and "" or ("Make " .. FormatCount(data.crafts)))
      elseif done then
        cost:SetText("")
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
    end,
    ---@param data ArbitrageShoppingMaterial
    addTooltipLines = function(data)
      GameTooltip:AddLine(" ")
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
  local materials = ns.ShoppingList.GetMaterials()
  ns.Profile.Size("Shopping List", #materials.rows, "materials")

  ns.Profile.Stage("Shopping List", "Drawing")
  entry.crafts.SetRows(craftRows)
  entry.crafts.SetEmptyMessage(#crafts == 0 and EMPTY_MESSAGE or nil)
  entry.materials.SetRows(materials.rows)
  entry.materials.SetEmptyMessage(#crafts > 0 and knownCount == 0 and FORGOTTEN_MESSAGE or nil)

  local total = "Left to buy: " .. FormatMoney(materials.cost)
  if materials.unpricedCount > 0 then
    total = total .. " + " .. materials.unpricedCount .. " unpriced"
  end
  entry.total:SetText(total)
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

-- Fills the panel, which may hold other content: the Auction House tab swaps this for Opportunities.
---@param panel Frame
---@param controlsParent Frame the window or Auction House whose control row holds the heading
---@return ArbitrageShoppingPanelEntry
function ns.ShoppingPanel.Create(panel, controlsParent)
  local content = CreateFrame("Frame", nil, panel)
  content:SetAllPoints()
  content:Show()

  local heading = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  heading:SetPoint("LEFT", controlsParent, "TOPLEFT", 66, -49)
  heading:SetText("Shopping List")

  local crafts = CreateCraftList(content)
  crafts.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -4)
  crafts.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 16, 8 + FOOTER_HEIGHT)
  crafts.frame:SetWidth(CRAFTS_WIDTH)

  local materials = CreateMaterialList(content)
  materials.frame:SetPoint("TOPLEFT", crafts.frame, "TOPRIGHT", CARD_GAP, 0)
  materials.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -5, 8)

  local clearButton = CreateButton(content, "Clear", 80, ConfirmClear, "Remove every craft from your shopping list.")
  clearButton:SetPoint("BOTTOMRIGHT", crafts.frame, "BOTTOMRIGHT", -22, -FOOTER_HEIGHT + 2)

  -- The total explains its prices on hover, so it sits on a frame of its own.
  local totalFrame = CreateFrame("Frame", nil, content)
  totalFrame:SetPoint("LEFT", crafts.frame, "BOTTOMLEFT", 4, -FOOTER_HEIGHT / 2)
  totalFrame:SetPoint("RIGHT", clearButton, "LEFT", -8, 0)
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
  panels[#panels + 1] = entry
  panel:HookScript("OnShow", ns.ShoppingPanel.Refresh)
  return entry
end

-- Refreshes as the list changes, as bags and banks change, and as item names load, since the
-- materials sort by name.
function ns.ShoppingPanel.Register()
  ns.ShoppingList.OnChange(ns.ShoppingPanel.Refresh)
  frame:RegisterEvent("BAG_UPDATE_DELAYED")
  frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
  frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  frame:SetScript("OnEvent", function(_, eventName, itemID, success)
    if eventName == "GET_ITEM_INFO_RECEIVED" then
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

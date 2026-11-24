local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingPanel", function()
  local environment
  local harness

  local function IsDescendantOf(region, ancestor)
    local current = region and region.parent
    while current do
      if current == ancestor then
        return true
      end
      current = current.parent
    end
    return false
  end

  -- The shopping list inside root: its content, the crafts list and the materials list in the
  -- order they're made, the Clear button, and the total.
  local function FindShopping(root)
    local found = { lists = {} }
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.text == "Shopping List" and fontString.parent.parent == root then
        found.content = fontString.parent
        found.heading = fontString
      end
    end
    assert(found.content, "has a shopping list")
    for _, frame in ipairs(harness.createdFrames) do
      if IsDescendantOf(frame, found.content) then
        if frame.template == "WowScrollBoxList" then
          found.lists[#found.lists + 1] = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Clear" then
          found.clearButton = frame
        end
      end
    end
    for _, fontString in ipairs(harness.createdFontStrings) do
      if IsDescendantOf(fontString, found.content) and fontString.text and fontString.text:find("^Left to buy") then
        found.total = fontString
      end
    end
    found.crafts, found.materials = found.lists[1], found.lists[2]
    return found
  end

  local function VisibleRows(scrollBox)
    local rows = {}
    for _, row in ipairs(scrollBox.frames) do
      if row:IsShown() then
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  -- Each visible material as "name need have cost".
  local function MaterialLines(scrollBox)
    local lines = {}
    for index, row in ipairs(VisibleRows(scrollBox)) do
      lines[index] = table.concat({
        row.itemName.text,
        row.values[1].text,
        row.values[2].text,
        harness.PlainMoney(row.values[3].text),
      }, " | ")
    end
    return lines
  end

  local function FindFontString(text)
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.text == text then
        return fontString
      end
    end
  end

  -- The details footer's button with this text.
  local function FooterButton(text)
    for _, frame in ipairs(harness.createdFrames) do
      if
        frame.text == text
        and frame.parent
        and frame.parent.parent
        and frame.parent.parent.template == "PortraitFrameTemplate"
      then
        return frame
      end
    end
  end

  local function Opportunity(itemID)
    for _, frame in ipairs(harness.FindComponents().scrollBox.frames) do
      if frame.item and frame.item.itemID == itemID then
        return frame.item
      end
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
  end)

  describe("in the Auction House", function()
    local components

    before_each(function()
      setfenv(1, environment)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      components = harness.FindComponents()
      components.tab:Click()
    end)

    it("switches between Opportunities and the shopping list, remembering the choice", function()
      setfenv(1, environment)
      local opportunities, shopping = components.viewTabs[1], components.viewTabs[2]
      assert.are.equal(1, components.panel.selectedTab)
      assert.is_true(opportunities.selected)

      local calls = harness.GetOpportunityCalls()
      shopping:Click()
      assert.are.same({ 841 }, harness.playedSounds)
      assert.are.equal(2, components.panel.selectedTab)
      assert.is_false(components.content:IsShown())
      local found = FindShopping(components.panel)
      assert.is_true(found.content:IsShown())
      assert.is_false(found.heading:IsShown(), "the tab names the view")

      -- Hidden Opportunities aren't priced when prices change.
      harness.ns.OpportunityPanel.Refresh()
      assert.are.equal(calls, harness.GetOpportunityCalls())

      harness.FireEvent("AUCTION_HOUSE_CLOSED")
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert.is_false(components.content:IsShown())
      assert.is_true(found.content:IsShown())

      opportunities:Click()
      assert.are.equal(calls + 1, harness.GetOpportunityCalls())
      assert.is_true(components.content:IsShown())
      assert.is_false(found.content:IsShown())
    end)

    it("adds crafts from the details and a row's menu, counting them on the tab", function()
      setfenv(1, environment)
      local shoppingTab = components.viewTabs[2]
      components.scrollBox.frames[1]:Click()
      assert.are.equal(100, components.scrollBox.frames[1].item.itemID)

      local plus = assert(FooterButton("+"), "offers more crafts")
      plus:Click()
      harness.SetHeldModifier("SHIFT")
      plus:Click()
      harness.SetHeldModifier(nil)
      assert(FindFontString("12"), "counts ten more on Shift")
      FooterButton("Add to List"):Click()
      assert.are.equal(12, harness.ns.ShoppingList.GetCount(100))
      -- Flask's details listed materials at Buyout prices.
      assert.are.same({ itemID = 100, recipeKey = "shared", atBuyout = true }, harness.choiceRequests[1])
      assert.are.equal("Shopping List (1)", shoppingTab.text)
      assert.is_true(FindFontString("On Shopping List"):IsShown())
      assert(FindFontString("12 crafts"), "shows how many are on the list")

      components.scrollBox.frames[2]:Click("RightButton")
      local menu = assert(harness.contextMenus[1])
      assert.are.equal(components.scrollBox.frames[2], menu.owner)
      assert.are.equal("Add to Shopping List", menu.entries[1].label)
      menu.entries[1].Pick()
      assert.are.equal(1, harness.ns.ShoppingList.GetCount(200))
      assert.are.same({ itemID = 200, recipeKey = "item-200", atBuyout = false }, harness.choiceRequests[2])
      assert.are.equal("Shopping List (2)", shoppingTab.text)

      -- A right-click opens the menu without changing the details.
      assert.are.equal(100, components.scrollBox.frames[1].item.itemID)
      assert.are.equal(1, #harness.contextMenus)
    end)

    it("starts each item at one craft", function()
      setfenv(1, environment)
      components.scrollBox.frames[1]:Click()
      FooterButton("+"):Click()
      assert(FindFontString("2"))
      components.scrollBox.frames[2]:Click()
      FooterButton("Add to List"):Click()
      assert.are.equal(1, harness.ns.ShoppingList.GetCount(200))
    end)

    it("makes or buys a material for every craft, saying what each costs and who makes it", function()
      setfenv(1, environment)
      -- Iron Bars are smelted from two Iron Ore each, and item 200's costs buy them.
      harness.recipes[201] = {
        {
          recipeKey = "smelt-iron",
          outputItemID = 201,
          outputQuantity = 1,
          reagents = { { itemID = 202, quantity = 2, name = "Iron Ore" } },
        },
      }
      harness.recipeSources[201] = { { characterName = "Main", professionName = "Mining", recipeKey = "smelt-iron" } }
      harness.craftingChoices[200] = { [201] = false }
      -- Smelting is the cheapest way to make Iron Bars, which costs four Iron Ore at 20c for two.
      harness.scanCraftingCosts[201] = { recipeKey = "smelt-iron", cost = 40 }
      harness.latestBuyouts["201"] = 60
      harness.latestBuyouts["202"] = 20
      harness.ns.ShoppingList.Add(Opportunity(200), 1)
      components.viewTabs[2]:Click()
      local found = FindShopping(components.panel)

      local bar = VisibleRows(found.materials)[1]
      assert.are.same({ "Iron Bar | 2 | 0 | 1s 20c" }, MaterialLines(found.materials))
      assert.is_true(bar.choice:IsShown())
      assert.are.same(
        { "auctionhouse-icon-coin-gold", 16, 16 },
        { bar.choice.Icon.atlas, bar.choice.Icon.width, bar.choice.Icon.height },
        "shows a gold coin while it's bought"
      )

      local function TooltipSince(lineCount, doubleCount)
        return { unpack(harness.tooltipLines, lineCount + 1) }, { unpack(harness.tooltipDoubleLines, doubleCount + 1) }
      end
      local lineCount, doubleCount = #harness.tooltipLines, #harness.tooltipDoubleLines
      bar.choice.scripts.OnEnter(bar.choice)
      local lines, doubles = TooltipSince(lineCount, doubleCount)
      assert.are.same({
        "Buying Iron Bar",
        " ",
        "For the 2 still needed, at Buyout prices:",
        "Buying costs 40c more.",
        "Made by Mining - Main",
        "Click to make instead.",
        "Applies to every craft on your list.",
      }, lines)
      assert.are.same({ { "Make", "80c" }, { "Buy (chosen)", "120c" } }, doubles)

      -- One click makes it instead, and the tooltip still showing follows.
      lineCount, doubleCount = #harness.tooltipLines, #harness.tooltipDoubleLines
      bar.choice:Click()
      assert.are.equal(856, harness.playedSounds[#harness.playedSounds], "clicks like a checkbox")
      assert.are.same({ "Iron Bar | 2 | 0 | Make 2", "Iron Ore | 4 | 0 | 80c" }, MaterialLines(found.materials))
      local rows = VisibleRows(found.materials)
      local icon, highlight = rows[1].choice.Icon, rows[1].choice.Highlight
      assert.are.same(
        { "UI-HUD-MicroMenu-Professions-Up", 19, 24 },
        { icon.atlas, icon.width, icon.height },
        "shows the menu bar's Professions tools, in their own proportions, while it's made"
      )
      assert.are.same(
        { icon.atlas, 19, 24, "ADD" },
        { highlight.atlas, highlight.width, highlight.height, highlight.blendMode }
      )
      assert.is_false(rows[2].choice:IsShown(), "no character can make Iron Ore")
      assert.are.equal("Left to buy: 80c", harness.PlainMoney(found.total.text))
      lines, doubles = TooltipSince(lineCount, doubleCount)
      assert.are.equal("Making Iron Bar", lines[1])
      assert.are.equal("Click to buy instead.", lines[6])
      assert.are.same({ { "Make (chosen)", "80c" }, { "Buy", "120c" } }, doubles)

      -- The row's own tooltip compares them too.
      lineCount, doubleCount = #harness.tooltipLines, #harness.tooltipDoubleLines
      rows[1].scripts.OnEnter(rows[1])
      lines = TooltipSince(lineCount, doubleCount)
      assert.are.same({
        " ",
        "Made from the materials below it: 2 crafts",
        " ",
        "For the 2 still needed, at Buyout prices:",
        "Buying costs 40c more.",
        "Made by Mining - Main",
      }, lines)

      -- With the bars in your bags, there's nothing left to choose.
      harness.ownedItems[201] = 2
      harness.FireEvent("BAG_UPDATE_DELAYED")
      harness.RunTimers()
      assert.is_false(VisibleRows(found.materials)[1].choice:IsShown())

      harness.ownedItems[201] = 0
      harness.FireEvent("BAG_UPDATE_DELAYED")
      harness.RunTimers()
      VisibleRows(found.materials)[1].choice:Click()
      assert.are.same({ "Iron Bar | 2 | 0 | 1s 20c" }, MaterialLines(found.materials))
      local coin = VisibleRows(found.materials)[1].choice.Icon
      assert.are.same(
        { "auctionhouse-icon-coin-gold", 16, 16 },
        { coin.atlas, coin.width, coin.height },
        "back to the coin's size"
      )
    end)

    it("refreshes every material made or bought, then re-chooses the cheapest way when asked", function()
      setfenv(1, environment)
      harness.recipes[201] = {
        {
          recipeKey = "smelt-iron",
          outputItemID = 201,
          outputQuantity = 1,
          reagents = { { itemID = 202, quantity = 2, name = "Iron Ore" } },
        },
      }
      harness.craftingChoices[200] = { [201] = false }
      harness.scanCraftingCosts[201] = { recipeKey = "smelt-iron", cost = 40 }
      harness.latestBuyouts["201"] = 60
      harness.latestBuyouts["202"] = 20
      harness.ns.ShoppingList.Add(Opportunity(200), 1)
      components.viewTabs[2]:Click()
      local found = FindShopping(components.panel)
      local refreshButton, rechoose
      for _, frame in ipairs(harness.createdFrames) do
        if IsDescendantOf(frame, found.content) then
          if frame.text == "Refresh Prices" then
            refreshButton = frame
          elseif frame.template == "MinimalCheckboxTemplate" then
            rechoose = frame
          end
        end
      end
      assert.is_true(rechoose:GetChecked(), "re-chooses by default")
      assert.are.same({ "Iron Bar | 2 | 0 | 1s 20c" }, MaterialLines(found.materials))

      -- The bars are bought, but the ore they'd be smelted from is searched too, next.
      refreshButton:Click()
      assert.are.equal("1/2", refreshButton.text)
      harness.commodityListings[201] = { { 70, 5 } }
      harness.commodityListings[202] = { { 15, 10 } }
      harness.refreshedChoices[200] = { [201] = "smelt-iron" }
      harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 201)
      assert.are.same({ 201, 202 }, harness.sentSearches)
      assert.are.equal("2/2", refreshButton.text)
      harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 202)
      assert.are.equal("Refresh Prices", refreshButton.text)

      -- At refreshed prices smelting is cheaper, so the bars are made now.
      assert.are.same({ "Iron Bar | 2 | 0 | Make 2", "Iron Ore | 4 | 0 | 60c" }, MaterialLines(found.materials))
      local bar = VisibleRows(found.materials)[1]
      local lineCount, doubleCount = #harness.tooltipLines, #harness.tooltipDoubleLines
      bar.choice.scripts.OnEnter(bar.choice)
      assert.are.equal("For the 2 still needed, at refreshed prices:", harness.tooltipLines[lineCount + 3])
      assert.are.same(
        { { "Make (chosen)", "60c" }, { "Buy", "140c" } },
        { unpack(harness.tooltipDoubleLines, doubleCount + 1) }
      )

      -- Unchecked, a refresh leaves the choices alone, and that's remembered.
      rechoose:Click()
      assert.is_false(harness.ns.Config.Get("rechooseOnRefresh"))
      harness.refreshedChoices[200] = { [201] = false }
      refreshButton:Click()
      harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 201)
      harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 202)
      assert.are.same({ "Iron Bar | 2 | 0 | Make 2", "Iron Ore | 4 | 0 | 60c" }, MaterialLines(found.materials))
      assert.are.same({}, harness.chatMessages, "says nothing when every search answers")
    end)

    describe("buying", function()
      local found, card, refreshButton, rechoose

      -- Opens the list, and finds the card that buys, Refresh Prices, and its checkbox.
      local function OpenList()
        components.viewTabs[2]:Click()
        found = FindShopping(components.panel)
        for _, fontString in ipairs(harness.createdFontStrings) do
          if fontString.text == "Next to buy" and IsDescendantOf(fontString, found.content) then
            card = fontString.parent
          end
        end
        for _, frame in ipairs(harness.createdFrames) do
          if IsDescendantOf(frame, found.content) then
            if frame.text == "Refresh Prices" then
              refreshButton = frame
            elseif frame.template == "MinimalCheckboxTemplate" then
              rechoose = frame
            end
          end
        end
      end

      -- What the card shows, money in plain letters, leaving out what's hidden or blank.
      local function Card()
        local function Shown(region)
          local text = region:IsShown() and region.text or ""
          return text ~= "" and harness.PlainMoney(text) or nil
        end
        return {
          title = card.Title.text,
          name = Shown(card.Name),
          detail = Shown(card.Detail),
          total = card.Total:IsShown() and harness.PlainMoney(card.Total.text) or nil,
          notice = Shown(card.Notice),
          empty = Shown(card.Empty),
          buy = card.BuyButton:IsShown() and card.BuyButton.text or nil,
          skip = card.SkipButton:IsShown() and card.SkipButton.text or nil,
        }
      end

      local function Marked()
        local marked = {}
        for _, row in ipairs(VisibleRows(found.materials)) do
          if row.selectedHighlight:IsShown() then
            marked[#marked + 1] = row.itemName.text
          end
        end
        return marked
      end

      before_each(function()
        setfenv(1, environment)
        harness.latestBuyouts["101"] = 30
        harness.latestBuyouts["201"] = 60
        harness.vendorPrices[102] = 40
      end)

      it("puts the card that buys under the crafts, and what's left to buy beside your gold", function()
        setfenv(1, environment)
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        OpenList()
        assert.are.same({ "BOTTOMLEFT", found.content, "BOTTOMLEFT", 16, 8 }, card.points[1])
        assert.are.same({ 278, 132 }, { card.width, card.height }, "lines up with the crafts card's inset")
        local craftsCard = found.crafts.parent
        assert.are.same({ "BOTTOMLEFT", found.content, "BOTTOMLEFT", 16, 170 }, craftsCard.points[2])
        local totalFrame = found.total.parent
        assert.are.same({ "LEFT", harness.auctionHouseFrame, "BOTTOMLEFT", 178, 16 }, totalFrame.points[1])
        assert.are.equal("Left to buy: 2s 60c", harness.PlainMoney(found.total.text))
        assert.are.equal(0.7, rechoose.scale, "shrinks the checkbox to the buttons' height")
        assert.are.equal(
          "Remove every craft from your shopping list.",
          (function()
            for _, frame in ipairs(harness.createdFrames) do
              if frame.text == "Clear" and IsDescendantOf(frame, found.content) then
                assert.are.same({ "TOPRIGHT", craftsCard, "BOTTOMRIGHT", -22, -5 }, frame.points[1])
                frame.scripts.OnEnter(frame)
                return harness.tooltipLines[#harness.tooltipLines]
              end
            end
          end)()
        )
      end)

      it("buys the next material at the price shown without asking, then moves on", function()
        setfenv(1, environment)
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        OpenList()
        assert.are.same({
          title = "Next to buy",
          name = "Herb",
          detail = "6 to buy · 30c each",
          total = "1s 80c",
          notice = "Price from your latest scan",
          buy = "Buy 6",
          skip = "Skip",
        }, Card())
        assert.are.equal(1101, card.Icon.Texture.texture)
        assert.is_true(card.Icon:IsShown())
        assert.are.same({ "Herb" }, Marked())

        card.BuyButton:Click()
        assert.are.same({ { "start", 101, 6 } }, harness.purchaseCalls)
        assert.are.equal("Getting a price...", Card().detail)
        assert.is_false(card.BuyButton:IsEnabled())
        assert.is_false(card.SkipButton:IsEnabled())
        assert.is_false(refreshButton:IsEnabled())
        refreshButton.scripts.OnEnter(refreshButton)
        assert.are.equal("Finish buying first.", harness.tooltipLines[#harness.tooltipLines])

        harness.FireEvent("COMMODITY_PRICE_UPDATED", 30, 180)
        assert.are.same({ "confirm", 101, 6 }, harness.purchaseCalls[2])
        assert.are.equal("Buying...", Card().detail)

        -- The Herbs arrive by mail, and count as yours right away.
        harness.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
        assert.are.equal(120, harness.playedSounds[#harness.playedSounds])
        assert.are.same({ "Empty Vial (Vendor) | 2 | 0 | 80c", "Herb | 6 | 6 | " }, MaterialLines(found.materials))
        -- The Empty Vials come from a vendor.
        assert.are.same({ title = "Next to buy", empty = "Nothing left to buy at the Auction House." }, Card())
        assert.are.same({}, Marked())
        local herb = VisibleRows(found.materials)[2]
        herb.scripts.OnEnter(herb)
        assert.are.equal("6 bought and waiting in your mailbox", harness.tooltipLines[#harness.tooltipLines])
      end)

      it("asks before paying more, and skips or switches to another material", function()
        setfenv(1, environment)
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        harness.ns.ShoppingList.Add(Opportunity(200), 1)
        OpenList()
        card.BuyButton:Click()
        harness.FireEvent("COMMODITY_PRICE_UPDATED", 32, 192)
        local shown = Card()
        assert.are.same(
          { "1s 92c", "12c more than the 1s 80c shown", "Buy anyway" },
          { shown.total, shown.notice, shown.buy }
        )
        assert.are.same({ 1, 0.82, 0 }, card.Total.textColor)
        assert.are.same({ 1, 0.82, 0 }, card.Notice.textColor)
        assert.are.equal(1, #harness.purchaseCalls, "waits for you")
        card.BuyButton:Click()
        assert.are.same({ "confirm", 101, 6 }, harness.purchaseCalls[2])
        harness.FireEvent("COMMODITY_PURCHASE_FAILED")
        assert.are.equal(
          "|cff00ccffArbitrage:|r Couldn't buy 6x item 101: the Auction House refused it.",
          harness.chatMessages[1]
        )

        -- Skip moves on, dropping a higher price still waiting, and comes back around.
        card.BuyButton:Click()
        harness.FireEvent("COMMODITY_PRICE_UPDATED", 32, 192)
        card.SkipButton:Click()
        assert.are.same({ "cancel" }, harness.purchaseCalls[#harness.purchaseCalls])
        shown = Card()
        assert.are.same({ "Iron Bar", "2 to buy · 60c each", "1s 20c" }, { shown.name, shown.detail, shown.total })
        assert.are.same({ 1, 1, 1 }, card.Total.textColor)
        assert.are.same({ "Iron Bar" }, Marked())
        card.SkipButton:Click()
        assert.are.equal("Herb", Card().name)

        -- Clicking a material to buy makes it next; one you make or get from a vendor doesn't.
        VisibleRows(found.materials)[3]:Click()
        assert.are.same({ "Iron Bar" }, Marked())
        VisibleRows(found.materials)[1]:Click()
        assert.are.same({ "Iron Bar" }, Marked())
      end)

      it("says when fewer are listed than you need", function()
        setfenv(1, environment)
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        OpenList()
        refreshButton:Click()
        harness.commodityListings[101] = { { 30, 4 } }
        harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 101)
        local shown = Card()
        assert.are.same(
          { "4 to buy · 30c each", "1s 20c", "Only 4 listed of the 6 needed", "Buy 4" },
          { shown.detail, shown.total, shown.notice, shown.buy }
        )
        assert.are.same({ 1, 0.82, 0 }, card.Notice.textColor)
      end)

      it("warns once a visit when your gold falls short of what's left, then buys as you go on", function()
        setfenv(1, environment)
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        harness.SetMoney(100)
        OpenList()
        card.BuyButton:Click()
        assert.are.same({}, harness.purchaseCalls)
        local dialog = assert(harness.shownDialogs[1])
        assert.are.equal("You have 100c, and what's left on your list costs about 260c.\n\nKeep buying?", dialog.text)
        dialog.Accept()
        assert.are.same({ { "start", 101, 6 } }, harness.purchaseCalls, "buys from the dialog's click")

        harness.FireEvent("COMMODITY_PRICE_UNAVAILABLE")
        card.BuyButton:Click()
        assert.are.equal(2, #harness.purchaseCalls)
        assert.are.equal(1, #harness.shownDialogs, "doesn't ask again this visit")

        harness.FireEvent("COMMODITY_PRICE_UNAVAILABLE")
        harness.FireEvent("AUCTION_HOUSE_CLOSED")
        harness.FireEvent("AUCTION_HOUSE_SHOW")
        card.BuyButton:Click()
        assert.are.equal(2, #harness.shownDialogs, "asks again the next visit")
      end)

      it("buys what isn't a commodity auction by auction, after one confirmation", function()
        setfenv(1, environment)
        harness.nonCommodities[201] = true
        harness.ns.ShoppingList.Add(Opportunity(200), 1)
        OpenList()
        assert.are.same({
          title = "Next to buy",
          name = "Sold by the auction",
          detail = "1 material sells one auction at a time",
          buy = "Review",
        }, Card())
        assert.is_false(card.Icon:IsShown())

        card.BuyButton:Click()
        assert.are.same({ 201 }, harness.sentSearches)
        assert.are.same({ "Finding auctions", "0 of 1 searched" }, { Card().name, Card().detail })
        assert.are.equal("Refresh Prices", refreshButton.text, "isn't a refresh")

        -- One Iron Bar for 70c, or three for 1s 50c, which is cheaper each.
        harness.itemAuctions[201] = { { 9001, 1, 70 }, { 9002, 3, 150 } }
        harness.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201 })
        local dialog = assert(harness.shownDialogs[1])
        assert.are.equal("Buy 1 auction for 150c?\n3x Iron Bar (1 auction, 1 extra)", dialog.text)
        assert.are.same({}, harness.purchaseCalls)

        dialog.Accept()
        assert.are.same({ { "bid", 9002, 150 } }, harness.purchaseCalls)
        assert.are.same({
          title = "Auction 1 of 1",
          name = "Iron Bar",
          detail = "3 in this auction",
          total = "1s 50c",
          buy = "Buy 1/1",
          skip = "Stop",
        }, Card())
        assert.is_false(card.BuyButton:IsEnabled())

        -- The auction arrives by mail, extra and all.
        harness.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 9002)
        assert.are.equal("Iron Bar | 2 | 3 | ", MaterialLines(found.materials)[1])
        assert.are.equal("Nothing left to buy at the Auction House.", Card().empty)
      end)
    end)

    describe("with crafts on the list", function()
      local found

      before_each(function()
        setfenv(1, environment)
        harness.latestBuyouts["101"] = 30
        harness.vendorPrices[102] = 40
        harness.ownedItems[101] = 1
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        components.viewTabs[2]:Click()
        found = FindShopping(components.panel)
      end)

      it("lists the crafts and what's left to buy", function()
        setfenv(1, environment)
        local craftRows = VisibleRows(found.crafts)
        assert.are.equal(1, #craftRows)
        assert.are.equal("Flask (x2)", craftRows[1].itemName.text)
        assert.are.equal("2", craftRows[1].count.text)

        -- Two crafts use six Herbs, one owned, and two Empty Vials from a vendor.
        assert.are.same({
          "Empty Vial (Vendor) | 2 | 0 | 80c",
          "Herb | 6 | 1 | 1s 50c",
        }, MaterialLines(found.materials))
        assert.are.equal("Left to buy: 2s 30c", harness.PlainMoney(found.total.text))

        -- A material's tooltip leaves out Arbitrage's item pricing, which its row already covers; a
        -- craft's keeps it.
        local herb = VisibleRows(found.materials)[2]
        herb.scripts.OnEnter(herb)
        assert.are.equal("item:101", GameTooltip.hyperlink)
        assert.is_true(GameTooltip.owner.arbitrageReplacesItemPricing)
        craftRows[1].scripts.OnEnter(craftRows[1])
        assert.are.equal("item:100", GameTooltip.hyperlink)
        assert.is_nil(GameTooltip.owner.arbitrageReplacesItemPricing)

        harness.ns.ShoppingList.Add(Opportunity(200), 1)
        assert.are.same({
          "Empty Vial (Vendor) | 2 | 0 | 80c",
          "Herb | 6 | 1 | 1s 50c",
          "Iron Bar | 2 | 0 | —",
        }, MaterialLines(found.materials))
        assert.are.equal("Left to buy: 2s 30c + 1 unpriced", harness.PlainMoney(found.total.text))
      end)

      it("checks off what you have enough of as your bags change", function()
        setfenv(1, environment)
        local herb = VisibleRows(found.materials)[2]
        assert.is_false(herb.check:IsShown())

        harness.ownedItems[101] = 6
        harness.FireEvent("BAG_UPDATE_DELAYED")
        harness.FireEvent("BAG_UPDATE_DELAYED")
        assert.are.equal(1, #harness.timers, "waits for the frame to end, once")
        harness.RunTimers()
        assert.are.same({ "Empty Vial (Vendor) | 2 | 0 | 80c", "Herb | 6 | 6 | " }, MaterialLines(found.materials))
        assert.is_true(herb.check:IsShown())
        assert.are.same({ 0.5, 0.5, 0.5 }, herb.itemName.textColor)
        assert.are.equal("Left to buy: 80c", harness.PlainMoney(found.total.text))
      end)

      it("changes counts, removes crafts, and clears after asking", function()
        setfenv(1, environment)
        local row = VisibleRows(found.crafts)[1]
        row.plus:Click()
        assert.are.equal(3, harness.ns.ShoppingList.GetCount(100))
        assert.are.equal("3", row.count.text)
        assert.are.same("Herb | 9 | 1 | 2s 40c", MaterialLines(found.materials)[2])

        harness.SetHeldModifier("SHIFT")
        row.plus:Click()
        row.minus:Click()
        harness.SetHeldModifier(nil)
        assert.are.equal(3, harness.ns.ShoppingList.GetCount(100))
        row.minus:Click()
        assert.are.equal(2, harness.ns.ShoppingList.GetCount(100))
        row.minus:Click()
        assert.are.equal(1, harness.ns.ShoppingList.GetCount(100))
        assert.is_false(row.minus:IsEnabled(), "keeps at least one craft; removing takes the other button")

        row.remove:Click()
        assert.are.equal(0, #VisibleRows(found.crafts))
        assert.are.equal("Shopping List", components.viewTabs[2].text)
        assert(
          FindFontString("Your shopping list is empty. Click a craft in Opportunities, then choose Add to List."):IsShown()
        )

        harness.ns.ShoppingList.Add(Opportunity(100), 1)
        found.clearButton:Click()
        assert.are.equal(1, harness.ns.ShoppingList.GetCraftCount(), "asks first")
        local dialog = assert(harness.shownDialogs[1])
        assert.are.equal("Remove every craft from your shopping list?", dialog.text)
        dialog.Accept()
        assert.are.equal(0, harness.ns.ShoppingList.GetCraftCount())
        assert.are.equal(0, #VisibleRows(found.materials))
      end)

      describe("refreshing prices", function()
        local refreshButton

        before_each(function()
          setfenv(1, environment)
          for _, frame in ipairs(harness.createdFrames) do
            if frame.text == "Refresh Prices" and IsDescendantOf(frame, found.content) then
              refreshButton = frame
            end
          end
        end)

        it("searches what's left to buy at the Auction House and prices it from every listing it takes", function()
          setfenv(1, environment)
          assert.are.same({ "BOTTOMRIGHT", harness.auctionHouseFrame, "BOTTOMRIGHT", -12, 9 }, refreshButton.points[1])
          assert.is_true(refreshButton:IsEnabled())

          refreshButton:Click()
          -- The Empty Vials come from a vendor, so only the Herbs are searched.
          assert.are.same({ 101 }, harness.sentSearches)
          assert.are.equal("1/1", refreshButton.text, "counts through its searches")
          assert.is_false(refreshButton:IsEnabled())

          -- Five more Herbs: four at 30c and one at 35c.
          harness.commodityListings[101] = { { 30, 4 }, { 35, 10 } }
          harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 101)
          assert.are.same(
            { "Empty Vial (Vendor) | 2 | 0 | 80c", "Herb | 6 | 1 | 1s 55c" },
            MaterialLines(found.materials)
          )
          assert.are.equal("Left to buy: 2s 35c", harness.PlainMoney(found.total.text))
          assert.are.equal("Refresh Prices", refreshButton.text)
          assert.is_true(refreshButton:IsEnabled())

          local herb = VisibleRows(found.materials)[2]
          local lineCount, doubleCount = #harness.tooltipLines, #harness.tooltipDoubleLines
          herb.scripts.OnEnter(herb)
          assert.are.same(
            { { "Refreshed just now", "14 listed" }, { "Each, on average", "31c" } },
            { unpack(harness.tooltipDoubleLines, doubleCount + 1) }
          )
          assert.are.same({ " " }, { unpack(harness.tooltipLines, lineCount + 1) })
        end)

        it("marks a material with fewer listed than you need", function()
          setfenv(1, environment)
          refreshButton:Click()
          harness.commodityListings[101] = { { 30, 3 }, { 40, 2, 2 } }
          harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 101)
          local herb = VisibleRows(found.materials)[2]
          assert.are.equal("90c", harness.PlainMoney(herb.values[3].text))
          assert.are.same({ 1, 0.82, 0 }, herb.values[3].textColor)
          assert.are.equal("Left to buy: 1s 70c, 1 short", harness.PlainMoney(found.total.text))

          herb.scripts.OnEnter(herb)
          assert.are.equal("Only 3 listed, 2 short of what you need.", harness.tooltipLines[#harness.tooltipLines])

          harness.commodityListings[101] = {}
          refreshButton:Click()
          harness.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 101)
          assert.are.equal("None listed", VisibleRows(found.materials)[2].values[3].text)
        end)

        it("waits for scans, and for something to buy", function()
          setfenv(1, environment)
          local function DisabledBecause()
            refreshButton.scripts.OnEnter(refreshButton)
            return not refreshButton:IsEnabled() and harness.tooltipLines[#harness.tooltipLines]
          end

          harness.SetScanStatus({ phase = "waiting", kind = "quick", elapsedSeconds = 3 })
          harness.ns.OpportunityPanel.RefreshScanStatus()
          assert.are.equal("Wait for the scan to finish.", DisabledBecause())
          refreshButton:Click()
          assert.are.same({}, harness.sentSearches)

          harness.SetScanStatus({ phase = "idle" })
          harness.ns.OpportunityPanel.RefreshScanStatus()
          assert.is_true(refreshButton:IsEnabled())

          harness.ownedItems[101] = 6
          harness.FireEvent("BAG_UPDATE_DELAYED")
          harness.RunTimers()
          assert.are.equal("Nothing is left to buy at the Auction House.", DisabledBecause())
        end)

        it("says in chat when a search fails or the Auction House closes before it finishes", function()
          setfenv(1, environment)
          refreshButton:Click()
          harness.RunAllTimers()
          assert.are.same({ 101, 101 }, harness.sentSearches, "tries once more")
          assert.are.same({
            "|cff00ccffArbitrage:|r Couldn't refresh the price of item 101: the Auction House didn't answer.",
          }, harness.chatMessages)
          assert.are.equal("Refresh Prices", refreshButton.text)

          refreshButton:Click()
          harness.FireEvent("AUCTION_HOUSE_CLOSED")
          harness.FireEvent("AUCTION_HOUSE_SHOW")
          assert.are.equal(
            "|cff00ccffArbitrage:|r Stopped refreshing prices: the Auction House closed.",
            harness.chatMessages[2]
          )
          assert.are.equal("Refresh Prices", refreshButton.text)
          assert.is_true(refreshButton:IsEnabled())
        end)
      end)

      it("explains a craft whose recipe no character knows any more", function()
        setfenv(1, environment)
        harness.recipes[100] = nil
        harness.ns.ShoppingPanel.Refresh()
        local row = VisibleRows(found.crafts)[1]
        assert.are.equal("Flask", row.itemName.text)
        assert.are.same({ 0.5, 0.5, 0.5 }, row.itemName.textColor)
        assert.are.equal(0, #VisibleRows(found.materials))
        assert(FindFontString("No character on this realm knows these recipes any more."):IsShown())
      end)
    end)
  end)

  it("has a tab of its own in the window, drawn as it shows", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow
    local found = FindShopping(harness.GetWindowContents()[3])
    assert.are_not.equal(false, found.heading.shown, "titles the tab, as the window's others are")
    for _, frame in ipairs(harness.createdFrames) do
      assert(frame.text ~= "Refresh Prices", "refreshes prices only in the Auction House")
    end
    assert.are.same({ "LEFT", window, "TOPLEFT", 66, -49 }, found.heading.points[1])
    assert.are.equal(0, #VisibleRows(found.crafts))

    harness.ns.ShoppingList.Add({ itemID = 200, recipeKey = "item-200" }, 1)
    assert.are.equal(0, #VisibleRows(found.crafts), "waits until it shows")
    window.Tabs[3]:Click()
    assert.are.equal("Item #200", VisibleRows(found.crafts)[1].itemName.text)
    assert.are.same({ "Iron Bar | 2 | 0 | —" }, MaterialLines(found.materials))
  end)
end)

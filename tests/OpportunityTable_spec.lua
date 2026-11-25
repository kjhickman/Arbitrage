local NewEnvironment = dofile("tests/support/Environment.lua")

describe("OpportunityTable", function()
  local environment
  local harness
  local components
  local headers
  local scrollBox
  local scrollBar
  local opportunityRows

  -- Opens the Opportunities tab on a new harness, after prepare sets up what the table reads as it
  -- is made.
  local function Open(prepare)
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness =
      assert(environment.loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    if prepare then
      prepare()
    end
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    components = harness.FindComponents()
    headers = components.headers
    scrollBox = components.scrollBox
    scrollBar = components.scrollBar
    components.tab:Click()
    opportunityRows = {}
    for _, createdFrame in ipairs(harness.createdFrames) do
      if createdFrame.parent == scrollBox and createdFrame.frameType == "Button" then
        opportunityRows[#opportunityRows + 1] = createdFrame
      end
    end
  end

  before_each(function()
    Open()
  end)

  -- Hovers a row and returns the tooltip's new single lines, and its new double lines both in
  -- order and by label, with money as plain text.
  local function Hover(row)
    local lineCount, doubleLineCount = #harness.tooltipLines, #harness.tooltipDoubleLines
    row.scripts.OnEnter(row)
    local lines, doubleLines, values = {}, {}, {}
    for index = lineCount + 1, #harness.tooltipLines do
      lines[#lines + 1] = harness.tooltipLines[index]
    end
    for index = doubleLineCount + 1, #harness.tooltipDoubleLines do
      local left, right = unpack(harness.tooltipDoubleLines[index])
      doubleLines[#doubleLines + 1] = { left, harness.PlainMoney(right) }
      values[left] = harness.PlainMoney(right)
    end
    row.scripts.OnLeave(row)
    return lines, values, doubleLines
  end

  it("connects a native scroll box and scrollbar", function()
    setfenv(1, environment)
    assert(scrollBox and scrollBox.parent == components.tableBackground, "creates a native Auction House scroll box")
    assert(scrollBar and scrollBar.parent == components.tableBackground, "creates the Forever Auction House scrollbar")
    assert(scrollBox.scrollBar == scrollBar, "connects the opportunity list to its scrollbar")
    assert(
      scrollBox.view and scrollBox.view.template == "Button" and scrollBox.view.extent == 20,
      "uses SharedXML button rows sized to the Auction House row height"
    )
  end)

  it("explains every pricing column in a tooltip anchored to its header", function()
    setfenv(1, environment)
    local headerExplanations = {
      ["Typical Craft Cost"] = "Cheapest way to make one item at Typical prices, including vendors and intermediate crafts.",
      ["Typical Profit"] = "Profit from crafting and selling an item at Typical prices, or to a vendor when that pays more. Accounts for the 5% Auction House cut.",
      ["Current Craft Cost"] = "Cheapest way to make one item at Current prices, including vendors and intermediate crafts.",
      ["Current Profit"] = "Profit from crafting and selling an item at Current prices, or to a vendor when that pays more. Accounts for the 5% Auction House cut.",
    }
    for label, explanation in pairs(headerExplanations) do
      local header = headers[label]
      local lineCount = #harness.tooltipLines
      header.scripts.OnEnter(header)
      assert(harness.tooltipLines[lineCount + 1] == label, "labels the " .. label .. " header tooltip")
      assert(harness.tooltipLines[lineCount + 2] == explanation, "explains the " .. label .. " column")
      assert(GameTooltip.owner == header, "anchors the " .. label .. " tooltip to its header")

      local hideCalls = harness.GetTooltipHideCalls()
      header.scripts.OnLeave(header)
      assert(harness.GetTooltipHideCalls() == hideCalls + 1, "hides the " .. label .. " header tooltip")
    end
  end)

  it("renders compact native rows with item borders and alternating stripes", function()
    setfenv(1, environment)
    assert(#opportunityRows >= 2, "creates compact rows for visible opportunities")
    assert(
      opportunityRows[1].icon.width == 14 and opportunityRows[1].icon.height == 14,
      "matches native item icon sizing"
    )
    assert(
      opportunityRows[1].iconBorder.atlas == "auctionhouse-itemicon-small-border"
        and opportunityRows[1].iconBorder.width == 16
        and opportunityRows[1].iconBorder.height == 16,
      "uses the native Auction House item icon border"
    )
    assert(
      opportunityRows[1].highlightAtlas == "auctionhouse-ui-row-highlight"
        and opportunityRows[1].highlightBlendMode == "ADD",
      "uses the native Auction House hover highlight"
    )
    assert(
      opportunityRows[1].normalAtlas == "auctionhouse-rowstripe-2"
        and opportunityRows[2].normalAtlas == "auctionhouse-rowstripe-1",
      "alternates native Auction House row stripes"
    )
  end)

  it("renders the item, its sale method, and pricing cells with explicit missing values", function()
    setfenv(1, environment)
    local function Texts(row)
      local cells = { row.itemName, row.saleMethod, row.craftCost, row.profit, row.buyoutCraftCost, row.buyoutProfit }
      local texts = {}
      for index, cell in ipairs(cells) do
        texts[index] = harness.PlainMoney(cell.text)
        assert(not cell.wordWrap and cell.maxLines == 1, "keeps every cell within one row")
      end
      return texts
    end
    assert.are.same({ "Flask (x2)", "AH", "80c", "+1s 10c", "70c", "+1s 01c" }, Texts(opportunityRows[1]))
    assert.are.same({ "Item #200", "AH", "90c", "+5c", "—", "—" }, Texts(opportunityRows[2]))
  end)

  it(
    "sorts by Profit by default, colors uncertain values yellow, and grays a profit that misses the filters",
    function()
      setfenv(1, environment)
      assert(headers["Typical Profit"].Arrow.shown, "marks Profit as the default sort")
      assert(opportunityRows[1].itemName.text == "Flask (x2)", "sorts Profit descending by default")
      assert.are.same({ 1, 0.82, 0 }, opportunityRows[2].profit.textColor, "colors an uncertain Profit yellow")
      assert.are.same({ 1, 1, 1 }, opportunityRows[2].craftCost.textColor, "keeps reliable values white")

      local opportunity = harness.ns.Opportunities.Get().items[2]
      opportunity.profitMissesFilters = true
      harness.ns.OpportunityPanel.Refresh()
      assert.are.same({ 0.5, 0.5, 0.5 }, opportunityRows[1].profit.textColor)
      assert.are.same({ 1, 1, 1 }, opportunityRows[1].buyoutProfit.textColor)
    end
  )

  it("lists only the crafters and one craft's Current price materials on hover, leaving prices to the row", function()
    setfenv(1, environment)
    harness.itemInfo[101] = { "Peacebloom", "item:101", 1, 1, 1, "", "", 20, "", 101 }
    local lines, _, doubleLines = Hover(opportunityRows[1])
    assert.are.same({
      { "  Empty Vial x1 (Vendor)", "40c" },
      { "  Peacebloom x3 (Auction House)", "90c" },
    }, doubleLines, "sorts materials by name")
    assert.are.same({
      " ",
      "Crafted by: Alchemy - Alt, Main",
      "Materials to buy per craft (x2) at Current prices:",
    }, lines)
  end)

  it("falls back to Typical price materials without a Current Craft Cost", function()
    setfenv(1, environment)
    local lines, values = Hover(opportunityRows[2])
    assert.are.same({ ["  Iron Bar x2 (Auction House)"] = "90c" }, values)
    assert.are.equal("Materials to buy per craft at Typical prices:", lines[#lines])
  end)

  it("uses the native icon for the best skill-up chance and clears it on reused rows", function()
    setfenv(1, environment)
    local row = opportunityRows[1]
    local nameWidth = row.itemName.width
    local opportunity = harness.ns.Opportunities.Get().items[2]
    opportunity.sources[1].skillUp = { points = 1, difficulty = "medium" }
    opportunity.sources[2].skillUp = { points = 2, difficulty = "optimal" }
    harness.ns.OpportunityPanel.Refresh()

    assert.is_true(row.skillUp:IsShown())
    assert.are.equal("Professions-Icon-Skill-High", row.skillUp.atlas)
    assert.is_true(row.itemName.width < nameWidth)
    local lines = Hover(row)
    assert.are.equal("Alt (Alchemy): Chance at +1 skill per craft", lines[3])
    assert.are.equal("Main (Alchemy): +2 skill per craft", lines[4])

    opportunity.sources[2].skillUp = nil
    harness.ns.OpportunityPanel.Refresh()
    assert.is_true(row.skillUp:IsShown())
    assert.are.equal("Professions-Icon-Skill-Medium", row.skillUp.atlas)

    opportunity.sources[1].skillUp.difficulty = "easy"
    harness.ns.OpportunityPanel.Refresh()
    assert.are.equal("Professions-Icon-Skill-Low", row.skillUp.atlas)
    assert.are.equal("Alt (Alchemy): Low chance at +1 skill per craft", Hover(row)[3])

    ARBITRAGE_CONFIG.showOpportunitySkillUpIcons = false
    harness.ns.OpportunityPanel.Refresh()
    assert.is_false(row.skillUp:IsShown())
    assert.are.equal(nameWidth, row.itemName.width)
    lines = Hover(row)
    assert.is_truthy(table.concat(lines, "\n"):find("Alt (Alchemy): Low chance at +1 skill per craft", 1, true))

    ARBITRAGE_CONFIG.showOpportunitySkillUpIcons = true
    harness.ns.OpportunityPanel.Refresh()
    assert.is_true(row.skillUp:IsShown())

    opportunity.sources[1].skillUp = nil
    harness.ns.OpportunityPanel.Refresh()
    assert.is_false(row.skillUp:IsShown())
    assert.are.equal(nameWidth, row.itemName.width)
  end)

  it("marks an unlearned craft with a lock and names who could learn it", function()
    setfenv(1, environment)
    local row = opportunityRows[1]
    local nameWidth = row.itemName.width
    local opportunity = harness.ns.Opportunities.Get().items[2]
    opportunity.isUnlearned = true
    ARBITRAGE_CONFIG.showOpportunitySkillUpIcons = false
    harness.ns.OpportunityPanel.Refresh()

    assert.is_true(row.skillUp:IsShown(), "marks it even with skill-up icons off")
    assert.are.equal("talents-lock-c60", row.skillUp.atlas)
    assert.is_true(row.itemName.width < nameWidth)
    assert.are.same({
      " ",
      "Recipe not learned",
      "Could be learned by: Alchemy - Alt, Main",
      "Materials to buy per craft (x2) at Current prices:",
    }, Hover(row))

    opportunity.isUnlearned = nil
    harness.ns.OpportunityPanel.Refresh()
    assert.is_false(row.skillUp:IsShown())
    assert.are.equal(nameWidth, row.itemName.width)
  end)

  it("loads missing item display data without recalculating", function()
    setfenv(1, environment)
    assert(harness.requestedItemIDs[1] == 200, "requests missing item display data")
    harness.itemInfo[200] = { "Widget", "item:200", 1, 1, 1, "", "", 20, "", 2000 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 200, true)
    assert(harness.GetOpportunityCalls() == 1, "rerenders without recalculating when requested item data loads")
    local loadedName
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.text == "Widget" then
        loadedName = fontString
      end
    end
    assert(loadedName, "refreshes rows when requested item data loads")
  end)

  it("tags vendor sales in the row and names materials without item data by ID", function()
    setfenv(1, environment)
    harness.SetOpportunityResult({
      totalCount = 1,
      pricedCount = 1,
      profitableCount = 1,
      items = {
        {
          itemID = 100,
          outputQuantity = 2,
          saleMethod = "vendor",
          craftCost = 80,
          profit = 70,
          perCraft = { saleProceeds = 300, craftCost = 160, profit = 140 },
          materials = { [301] = { itemID = 301, quantity = 0.25, price = 10, source = "auction" } },
          craftCostIsUncertain = true,
          sources = {},
          reasons = { "stale materials" },
          isUncertain = true,
        },
      },
    })
    harness.ns.OpportunityPanel.Refresh()
    assert.are.equal("Vendor", opportunityRows[1].saleMethod.text, "makes vendor sale methods visible in the row")
    assert(opportunityRows[1].profit.textColor[2] == 0.82, "still marks vendor profits with uncertain material costs")
    local lines, values = Hover(opportunityRows[1])
    assert.are.same({
      " ",
      "Crafted by: Known recipe",
      "Materials to buy per craft (x2) at Typical prices:",
    }, lines)
    assert.are.equal("5c", values["  Item #301 x0.5 (Auction House)"], "names materials without item data by ID")
  end)

  it("adds a Sale Rate column only when the Companion brought region-wide sales", function()
    setfenv(1, environment)
    assert.is_nil(headers["Sale Rate"])
    assert.is_nil(opportunityRows[1].saleRate)

    Open(function()
      harness.sales[2589] = { 1250, 0.412 }
    end)
    setfenv(1, environment)
    local header = headers["Sale Rate"]
    header.scripts.OnEnter(header)
    assert.are.equal(
      "Share of this item's auctions that sell across your region, from TradeSkillMaster through Arbitrage Companion. Blank when TradeSkillMaster has none for it.",
      harness.tooltipLines[#harness.tooltipLines]
    )
    header.scripts.OnLeave(header)

    harness.itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
    harness.itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
    harness.itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
    local function Item(itemID, saleRate)
      return {
        itemID = itemID,
        outputQuantity = 1,
        saleMethod = "auction",
        craftCost = 10,
        profit = 5,
        sources = {},
        reasons = {},
        isUncertain = false,
        saleRate = saleRate,
      }
    end
    harness.SetOpportunityResult({
      totalCount = 3,
      pricedCount = 3,
      profitableCount = 3,
      items = { Item(1, 0.412), Item(2), Item(3, 0.004) },
    })
    harness.ns.OpportunityPanel.Refresh()

    headers["Sale Rate"]:Click()
    local texts = {}
    for _, row in ipairs(scrollBox.frames) do
      if row:IsShown() then
        texts[#texts + 1] = row.itemName.text .. " " .. row.saleRate.text
      end
    end
    assert.are.same({ "Alpha 41%", "Charlie <1%", "Bravo —" }, texts, "sorts the best sellers first")
  end)

  it("shows Typical, Typical ROI, Current, and Current ROI once chosen, beside the columns they explain", function()
    setfenv(1, environment)
    Open(function()
      harness.ns.Config.Set("opportunityColumns", {
        shown = {
          marketValue = true,
          roi = true,
          buyout = true,
          buyoutRoi = true,
          buyoutCraftCost = false,
          buyoutProfit = false,
        },
        widths = { marketValue = 80, craftCost = 96, buyout = 80 },
      })
    end)
    setfenv(1, environment)
    headers = harness.FindComponents().headers
    local labels = {}
    for label, header in pairs(headers) do
      labels[#labels + 1] = { label = label, x = header.points[1][4] }
    end
    table.sort(labels, function(left, right)
      return left.x < right.x
    end)
    for index, header in ipairs(labels) do
      labels[index] = header.label
    end
    assert.are.same(
      { "Item", "Typical", "Typical Craft Cost", "Typical Profit", "Typical ROI", "Current", "Current ROI" },
      labels
    )

    harness.itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
    harness.itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
    harness.itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
    local function Craft(itemID, fields)
      local craft = { itemID = itemID, outputQuantity = 1, sources = {}, reasons = {}, isUncertain = false }
      for key, value in pairs(fields) do
        craft[key] = value
      end
      return craft
    end
    harness.SetOpportunityResult({
      totalCount = 3,
      pricedCount = 3,
      profitableCount = 2,
      items = {
        Craft(1, { craftCost = 4000, profit = 1520, roi = 0.38, marketValue = 6000, buyout = 5800, buyoutRoi = 0.2 }),
        Craft(2, {
          craftCost = 9000,
          profit = -1080,
          roi = -0.12,
          marketValue = 8000,
          marketValueIsUncertain = true,
          profitMissesFilters = true,
          buyoutProfit = 50,
          buyoutRoi = 0.5,
          buyoutProfitMissesFilters = true,
        }),
        Craft(3, { craftCost = 100, profit = 12504, roi = 125.04, isUncertain = true }),
      },
    })
    harness.ns.OpportunityPanel.Refresh()

    local function Row(name)
      for _, row in ipairs(scrollBox.frames) do
        if row:IsShown() and row.itemName.text == name then
          return row
        end
      end
    end
    local alpha, bravo, charlie = Row("Alpha"), Row("Bravo"), Row("Charlie")
    local function Texts(row)
      return {
        harness.PlainMoney(row.marketValue.text),
        harness.PlainMoney(row.craftCost.text),
        harness.PlainMoney(row.profit.text),
        row.roi.text,
        harness.PlainMoney(row.buyout.text),
        row.buyoutRoi.text,
      }
    end
    assert.are.same({ "60s 00c", "40s 00c", "+15s 20c", "+38%", "58s 00c", "+20%" }, Texts(alpha))
    assert.are.same({ "80s 00c", "90s 00c", "-10s 80c", "-12%", "—", "+50%" }, Texts(bravo))
    assert.are.same({ "—", "1s 00c", "+1g 25s", "+12,504%", "—", "—" }, Texts(charlie))
    assert.are.same({ 1, 1, 1 }, alpha.marketValue.textColor)
    assert.are.same({ 1, 0.82, 0 }, bravo.marketValue.textColor, "colors an uncertain Market Value yellow")
    assert.are.same({ 0.5, 0.5, 0.5 }, bravo.roi.textColor, "grays ROI with the Profit it comes from")
    assert.are.same({ 1, 0.82, 0 }, charlie.roi.textColor, "colors ROI from an uncertain Profit yellow")
    assert.are.same({ 1, 1, 1 }, alpha.buyoutRoi.textColor, "leaves Buyout ROI white, as Buyouts are never uncertain")
    assert.are.same({ 0.5, 0.5, 0.5 }, bravo.buyoutRoi.textColor, "grays Buyout ROI with Buyout Profit")

    local function FirstNames()
      return { scrollBox.frames[1].itemName.text, scrollBox.frames[2].itemName.text, scrollBox.frames[3].itemName.text }
    end
    headers["Typical ROI"]:Click()
    assert.are.same({ "Charlie", "Alpha", "Bravo" }, FirstNames(), "sorts the best return first")
    headers["Typical"]:Click()
    assert.are.same({ "Bravo", "Alpha", "Charlie" }, FirstNames())
    headers["Current"]:Click()
    assert.are.same({ "Alpha", "Bravo", "Charlie" }, FirstNames())
    headers["Current ROI"]:Click()
    assert.are.same({ "Bravo", "Alpha", "Charlie" }, FirstNames())
  end)

  describe("column sorting", function()
    before_each(function()
      setfenv(1, environment)
      harness.itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
      harness.itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
      harness.itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
      local function Item(itemID, craftCost, profit, buyoutCraftCost, buyoutProfit)
        return {
          itemID = itemID,
          outputQuantity = 1,
          craftCost = craftCost,
          profit = profit,
          buyoutCraftCost = buyoutCraftCost,
          buyoutProfit = buyoutProfit,
          sources = {},
          reasons = {},
          isUncertain = false,
        }
      end
      local sortableItems = { Item(3, 10, 30, 12, 35), Item(1, 20, 10, 25, 15), Item(2, 40, 5) }
      harness.SetOpportunityResult({ totalCount = 3, pricedCount = 3, profitableCount = 3, items = sortableItems })
      harness.ns.OpportunityPanel.Refresh()
    end)

    it("uses each column's default direction and reverses it on a second click", function()
      setfenv(1, environment)
      local function AssertColumnSort(label, firstDefault, firstReversed)
        headers[label]:Click()
        assert(opportunityRows[1].itemName.text == firstDefault, label .. " uses its default sort direction")
        assert(headers[label].Arrow.shown, label .. " shows its active sort arrow")
        headers[label]:Click()
        assert(opportunityRows[1].itemName.text == firstReversed, label .. " reverses on a second click")
      end

      AssertColumnSort("Item", "Alpha", "Charlie")
      AssertColumnSort("Typical Craft Cost", "Bravo", "Charlie")
      AssertColumnSort("Typical Profit", "Charlie", "Bravo")
      AssertColumnSort("Current Craft Cost", "Alpha", "Charlie")
      -- A missing price sorts last either way.
      AssertColumnSort("Current Profit", "Charlie", "Alpha")
    end)

    it("sorts known item names before unresolved names and resorts when a requested name loads", function()
      setfenv(1, environment)
      harness.itemInfo[1][1] = "Zulu"
      harness.itemInfo[2] = nil
      headers["Item"]:Click()
      assert(opportunityRows[1].itemName.text == "Charlie", "sorts known item names ahead of unresolved names")
      harness.itemInfo[2] = { "Alpha", "item:2", 1, 1, 1, "", "", 20, "", 2 }
      harness.FireEvent("GET_ITEM_INFO_RECEIVED", 2, true)
      assert(opportunityRows[1].itemName.text == "Alpha", "reapplies item sorting when a requested name loads")
    end)
  end)

  describe("a scrolling opportunity list", function()
    before_each(function()
      setfenv(1, environment)
      local scrollingItems = {}
      for itemID = 1, 17 do
        scrollingItems[itemID] = {
          itemID = itemID,
          outputQuantity = 1,
          craftCost = 50,
          profit = 50,
          materials = {},
          sources = {},
          reasons = {},
          isUncertain = false,
        }
      end
      harness.SetOpportunityResult({ totalCount = 17, pricedCount = 17, profitableCount = 17, items = scrollingItems })
      harness.ns.OpportunityPanel.Refresh()
    end)

    it("hides stale tooltips and retains the scroll position as item data loads", function()
      setfenv(1, environment)
      opportunityRows[1].scripts.OnEnter(opportunityRows[1])
      local hideCallsBeforeScroll = harness.GetTooltipHideCalls()
      scrollBox:SetScrollOffset(1)
      assert(harness.GetTooltipHideCalls() == hideCallsBeforeScroll + 1, "hides a stale row tooltip when scrolling")
      harness.itemInfo[2] = { "Loaded Item", "item:2", 1, 1, 1, "", "", 20, "", 2000 }
      harness.FireEvent("GET_ITEM_INFO_RECEIVED", 2, true)
      assert(opportunityRows[1].itemName.text == "Loaded Item", "preserves the scroll position after item data loads")
    end)

    it("retries item display data after a failed load", function()
      setfenv(1, environment)
      local itemFourRequestCount = 0
      for _, requestedItemID in ipairs(harness.requestedItemIDs) do
        if requestedItemID == 4 then
          itemFourRequestCount = itemFourRequestCount + 1
        end
      end
      harness.FireEvent("GET_ITEM_INFO_RECEIVED", 4, false)
      harness.ns.OpportunityPanel.Refresh()
      local itemFourRetryCount = 0
      for _, requestedItemID in ipairs(harness.requestedItemIDs) do
        if requestedItemID == 4 then
          itemFourRetryCount = itemFourRetryCount + 1
        end
      end
      assert(itemFourRetryCount == itemFourRequestCount + 1, "retries item display data after a failed load")
    end)

    it("hides the row tooltip before replacing ranked results", function()
      setfenv(1, environment)
      opportunityRows[1].scripts.OnEnter(opportunityRows[1])
      local hideCallsBeforeRefresh = harness.GetTooltipHideCalls()
      harness.SetOpportunityResult({ totalCount = 0, pricedCount = 0, profitableCount = 0, items = {} })
      harness.ns.OpportunityPanel.Refresh()
      assert(
        harness.GetTooltipHideCalls() == hideCallsBeforeRefresh + 1,
        "hides its tooltip before replacing ranked results"
      )
    end)
  end)
end)

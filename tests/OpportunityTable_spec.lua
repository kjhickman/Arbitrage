local NewEnvironment = dofile("tests/support/Environment.lua")

describe("OpportunityTable", function()
  local environment
  local harness
  local components
  local headers
  local scrollBox
  local scrollBar
  local opportunityRows

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness =
      assert(environment.loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
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
      ["Net Sale"] = "The higher of one item's Auction House proceeds after the 5% cut and its vendor sell value. The sale method is shown beside the crafter.",
      ["Craft Cost"] = "Estimated cheapest way to make one item using rolling Market Values, unlimited-stock vendors, and intermediate crafts.",
      ["Best Cost"] = "Best-case cost to make one item with the same recipe using the cheapest per-unit buyouts from the latest full scan.",
      ["Est. Profit"] = "Net Sale minus Craft Cost, per item.",
      ["Best Profit"] = "Net Sale minus Best Cost, per item.",
      ROI = "Net Sale minus Craft Cost, divided by Craft Cost, before rounding.",
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

  it("renders compact product, crafter, and pricing cells with explicit missing values", function()
    setfenv(1, environment)
    local itemName
    local sourceText
    local marketText
    local costText
    local minimumCostText
    local profitText
    local minimumProfitText
    local roiText
    local missingValueCount = 0
    for _, fontString in ipairs(harness.createdFontStrings) do
      local text = fontString.text and harness.PlainMoney(fontString.text)
      if text == "Flask (x2)" then
        itemName = fontString
      elseif text == "AH - Alchemy - Alt, Main" then
        sourceText = fontString
      elseif text == "1s 90c" then
        marketText = fontString
      elseif text == "80c" then
        costText = fontString
      elseif text == "60c" then
        minimumCostText = fontString
      elseif text == "+1s 10c" then
        profitText = fontString
      elseif text == "+1s 30c" then
        minimumProfitText = fontString
      elseif text == "138%" then
        roiText = fontString
      elseif fontString.text == "—" then
        missingValueCount = missingValueCount + 1
      end
    end
    assert(itemName and sourceText, "shows the product, output quantity, profession, and crafters")
    assert(not itemName.wordWrap and itemName.maxLines == 1, "keeps item names within one row")
    assert(not sourceText.wordWrap and sourceText.maxLines == 1, "keeps long crafter lists within one row")
    assert(
      marketText and costText and minimumCostText and profitText and minimumProfitText and roiText,
      "shows sale, both costs, both profits, and ROI in separate cells"
    )
    for _, value in ipairs({ marketText, costText, minimumCostText, profitText, minimumProfitText, roiText }) do
      assert(not value.wordWrap and value.maxLines == 1, "keeps every value within one row")
    end
    assert(missingValueCount >= 2, "shows missing minimum values explicitly")
  end)

  it("sorts by estimated profit by default and colors only uncertain values yellow", function()
    setfenv(1, environment)
    assert(headers["Est. Profit"].Arrow.shown, "marks estimated profit as the default sort")
    assert(opportunityRows[1].itemName.text == "Flask (x2)", "sorts estimated profit descending by default")
    assert(
      opportunityRows[2].saleProceeds.textColor[2] == 0.82
        and opportunityRows[2].profit.textColor[2] == 0.82
        and opportunityRows[2].roi.textColor[2] == 0.82
        and opportunityRows[2].roi.text == "6%",
      "colors uncertain market-derived values and ROI yellow"
    )
    assert(opportunityRows[2].craftCost.textColor[2] == 1, "keeps reliable values white in an otherwise uncertain row")
  end)

  it("compares Auction House and vendor profits, totals a craft, and lists every crafter on hover", function()
    setfenv(1, environment)
    local lines, values = Hover(opportunityRows[1])
    assert.are.equal("Auction House", values["Sell to"])
    assert.are.equal("+1s 10c", values["Estimated profit"])
    assert.are.equal("+1s 30c", values["Best-case profit"])
    assert.are.equal("-10c", values["Vendor profit"])
    assert.are.equal("+10c", values["Best-case Vendor profit"])
    assert.are.equal("+2s 20c", values["Estimated profit per craft (x2)"])
    assert.are.equal("+2s 60c", values["Best-case profit per craft (x2)"])
    assert.are.equal("Crafted by: Alchemy - Alt, Main", lines[#lines])
  end)

  it("totals a craft only for recipes that make several items", function()
    setfenv(1, environment)
    local _, values = Hover(opportunityRows[2])
    assert.are.equal("+5c", values["Estimated profit"])
    for label in pairs(values) do
      assert.is_nil(label:find("per craft", 1, true), label .. " is not a per-craft total")
    end
  end)

  it("loads missing item display data without recalculating and ignores unrelated item events", function()
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

    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    assert(harness.GetOpportunityCalls() == 1, "ignores unrelated item data events")
  end)

  it("shows fixed vendor proceeds and separately explains uncertain materials and alternative AH profits", function()
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
          saleProceeds = 150,
          auctionSaleProceeds = 100,
          auctionIsUncertain = true,
          auctionReasons = { "stale output" },
          vendorSaleProceeds = 150,
          craftCost = 80,
          minimumCraftCost = 60,
          profit = 70,
          minimumProfit = 90,
          perCraft = { saleProceeds = 300, craftCost = 160, profit = 140, minimumCraftCost = 120, minimumProfit = 180 },
          roi = 0.875,
          marketIsUncertain = false,
          craftCostIsUncertain = true,
          sources = {},
          reasons = { "stale materials" },
          isUncertain = true,
        },
      },
    })
    harness.ns.OpportunityPanel.Refresh()
    assert(
      opportunityRows[1].source.text == "Vendor - Known recipe",
      "makes vendor sale methods visible in the compact row"
    )
    assert(
      harness.PlainMoney(opportunityRows[1].saleProceeds.text) == "1s 50c"
        and opportunityRows[1].saleProceeds.textColor[2] == 1,
      "keeps fixed vendor proceeds white"
    )
    assert(opportunityRows[1].profit.textColor[2] == 0.82, "still marks vendor profits with uncertain material costs")
    local lines, values = Hover(opportunityRows[1])
    assert.are.equal("Vendor", values["Sell to"])
    assert.are.equal("+20c", values["AH profit"])
    assert.are.equal("+40c", values["Best-case AH profit"])
    assert.are.same(
      { "AH estimate: stale output", "Estimate: stale materials" },
      { lines[#lines - 2], lines[#lines - 1] },
      "warns about uncertain alternative AH prices separately from vendor material costs"
    )
  end)

  describe("column sorting", function()
    before_each(function()
      setfenv(1, environment)
      harness.itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
      harness.itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
      harness.itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
      local sortableItems = {
        {
          itemID = 3,
          outputQuantity = 1,
          saleProceeds = 40,
          craftCost = 10,
          minimumCraftCost = 5,
          profit = 30,
          minimumProfit = 35,
          roi = 3,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
        {
          itemID = 1,
          outputQuantity = 1,
          saleProceeds = 30,
          craftCost = 20,
          minimumCraftCost = 15,
          profit = 10,
          minimumProfit = 15,
          roi = 0.5,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
        {
          itemID = 2,
          outputQuantity = 1,
          saleProceeds = 50,
          craftCost = 40,
          profit = 5,
          roi = 0.125,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
      }
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

      AssertColumnSort("Item / Sale / Crafter", "Alpha", "Charlie")
      AssertColumnSort("Net Sale", "Bravo", "Alpha")
      AssertColumnSort("Craft Cost", "Bravo", "Charlie")
      AssertColumnSort("Best Cost", "Alpha", "Charlie")
      AssertColumnSort("Est. Profit", "Charlie", "Bravo")
      AssertColumnSort("Best Profit", "Charlie", "Alpha")
      AssertColumnSort("ROI", "Charlie", "Bravo")
    end)

    it("sorts known item names before unresolved names and resorts when a requested name loads", function()
      setfenv(1, environment)
      harness.itemInfo[1][1] = "Zulu"
      harness.itemInfo[2] = nil
      headers["Item / Sale / Crafter"]:Click()
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
          saleProceeds = 100,
          craftCost = 50,
          profit = 50,
          roi = 1,
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

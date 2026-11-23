local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ItemDetails", function()
  local DAY = 24 * 60 * 60
  local TODAY = 100
  local NOW = TODAY * DAY + 12 * 60 * 60
  local environment
  local harness

  -- The details panel a tab's rows open.
  local function FindDetails(parent)
    for _, frame in ipairs(harness.createdFrames) do
      if frame.template == "PortraitFrameTemplate" and frame.parent == parent then
        return frame
      end
    end
    error("no details panel")
  end

  local function IsInside(region, details)
    local parent = region.parent
    while parent do
      if parent == details then
        return true
      end
      parent = parent.parent
    end
    return false
  end

  -- The panel's text, the chart's included, that matches a pattern.
  local function FindText(details, pattern)
    for _, fontString in ipairs(harness.createdFontStrings) do
      if IsInside(fontString, details) and fontString.text and fontString.text:find(pattern) then
        return fontString
      end
    end
    error("no text matching " .. pattern)
  end

  -- What the panel lists under the chart: each row's value by its label, the icons rows show, and
  -- the section headers and the notes at their right, top to bottom.
  local function ReadBody(details)
    local body = { values = {}, icons = {}, headers = {}, notes = {} }
    local labels, values, headers, notes = {}, {}, {}, {}
    local byPoint = { LEFT = labels, RIGHT = values, BOTTOMLEFT = headers, BOTTOMRIGHT = notes }
    for _, fontString in ipairs(harness.createdFontStrings) do
      local point = fontString.points[1]
      local content = point and point[2]
      if
        fontString:IsShown()
        and IsInside(fontString, details)
        and type(content) == "table"
        and content.parent.frameType == "ScrollFrame"
      then
        table.insert(byPoint[point[1]], { y = point[5], text = fontString.text })
      end
    end
    for _, list in ipairs({ labels, values, headers, notes }) do
      table.sort(list, function(top, bottom)
        return top.y > bottom.y
      end)
    end
    for index, label in ipairs(labels) do
      assert.are.equal(label.y, values[index].y, label.text .. " shares its row with its value")
      body.values[label.text] = harness.PlainMoney(values[index].text)
    end
    for index, header in ipairs(headers) do
      body.headers[index] = header.text
      body.notes[index] = notes[index].text
    end
    for _, texture in ipairs(harness.createdTextures) do
      if texture:IsShown() and texture.texture and IsInside(texture, details) then
        for _, label in ipairs(labels) do
          if label.y == texture.points[1][5] then
            body.icons[label.text] = texture.texture
          end
        end
      end
    end
    return body
  end

  -- The chart's shown markers of a color, gold daily values unless named, left to right. Each is a
  -- square over a dark outline.
  local function Markers(details, red)
    local markers = {}
    for _, texture in ipairs(harness.createdTextures) do
      -- Textures record their draw layer as their template.
      if
        texture.template == "OVERLAY"
        and texture:IsShown()
        and IsInside(texture, details)
        and texture.color[1] == (red or 1)
      then
        local point = texture.points[1]
        markers[#markers + 1] = { x = point[4], y = point[5] }
      end
    end
    table.sort(markers, function(left, right)
      return left.x < right.x
    end)
    return markers
  end

  -- The chart's shown price lines: the dashes of the level line at Market Value, and the lines
  -- joining the daily values, each as its two ends.
  local function PriceLines(details)
    local dashes, joins = {}, {}
    for _, line in ipairs(harness.createdLines) do
      if line.template == "ARTWORK" and line:IsShown() and IsInside(line, details) then
        local ends = {
          x1 = line.startPoint[3],
          y1 = line.startPoint[4],
          x2 = line.endPoint[3],
          y2 = line.endPoint[4],
        }
        table.insert(line.thickness == 1 and dashes or joins, ends)
      end
    end
    table.sort(dashes, function(left, right)
      return left.x1 < right.x1
    end)
    return dashes, joins
  end

  -- The chart's faint bars for units listed, left to right, each as its middle and height.
  local function UnitBars(details)
    local bars = {}
    for _, texture in ipairs(harness.createdTextures) do
      if
        texture.template == "BACKGROUND"
        and texture:IsShown()
        and IsInside(texture, details)
        and texture.color
        and texture.color[4] == 0.14
      then
        bars[#bars + 1] = { x = texture.points[1][4], height = texture.height }
      end
    end
    table.sort(bars, function(left, right)
      return left.x < right.x
    end)
    return bars
  end

  -- The chart's gridline labels, lowest first, without their coin icons.
  local function PriceLabels(details)
    local labels = {}
    for _, fontString in ipairs(harness.createdFontStrings) do
      if
        IsInside(fontString, details)
        and fontString.template == "GameFontDisableSmall"
        and fontString:IsShown()
        and fontString.justifyH == "RIGHT"
      then
        labels[#labels + 1] = { y = fontString.points[1][5], text = (fontString.text:gsub("|T.-|t", "")) }
      end
    end
    table.sort(labels, function(left, right)
      return left.y < right.y
    end)
    local texts = {}
    for index, label in ipairs(labels) do
      texts[index] = label.text
    end
    return texts
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    harness.SetCurrentTime(NOW)
    harness.itemInfo[100] = { "Flask", "item:100", 1, 1, 1, "", "", 20, "", 1000, 250 }
  end)

  describe("on the Database tab", function()
    local content, components, details

    local function OpenDatabaseTab()
      harness.ns.Window.Toggle()
      environment.ArbitrageWindow.Tabs[2]:Click()
      harness.RunAllTimers()
      content = harness.GetWindowContents()[2]
      components = harness.FindComponents(content)
      details = FindDetails(content)
    end

    local function FindRow(dbKey)
      for _, row in ipairs(components.scrollBox.frames) do
        if row:IsShown() and row.item.dbKey == dbKey then
          return row
        end
      end
      error("no visible row for " .. dbKey)
    end

    before_each(function()
      harness.databaseItems["100"] = { days = {}, latest = NOW - 60 * 60 }
      harness.marketValues["100"] =
        { value = 4800, scanCount = 3, dayCount = 2, isUncertain = true, reasons = { "fewer than 3 days of scans" } }
      harness.latestBuyouts["100"] = 4500
      harness.dailyValues["100"] = {
        { day = TODAY - 2, value = 4000, count = 2 },
        { day = TODAY, value = 5000, count = 1 },
      }
      harness.craftingCosts[100] = {
        cost = 4321.4,
        isUncertain = true,
        reasons = { "a material has limited scans" },
        recipeKey = "flask",
        outputQuantity = 2,
        leaves = { [101] = { itemID = 101, name = "Herb", quantity = 1.5, price = 2000, source = "auction" } },
      }
      harness.scanCraftingCosts[100] = {
        cost = 3900,
        isUncertain = false,
        reasons = {},
        recipeKey = "flask",
        outputQuantity = 2,
        leaves = {
          [101] = { itemID = 101, name = "Herb", quantity = 1.5, price = 1800, source = "auction" },
          [102] = { itemID = 102, name = "Empty Vial", quantity = 0.5, price = 40, source = "vendor" },
        },
      }
      harness.databaseItems["200"] = { days = {}, latest = NOW - 2 * DAY }
    end)

    it("opens beside the window when a row is clicked, and closes on a second click", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      assert.is_false(details:IsShown())
      assert.are.same({ "TOPLEFT", environment.ArbitrageWindow, "TOPRIGHT", 8, 0 }, details.points[1])
      assert.are.same({ "BOTTOMLEFT", environment.ArbitrageWindow, "BOTTOMRIGHT", 8, 0 }, details.points[2])

      FindRow("100"):Click()
      assert.is_true(details:IsShown())
      assert.are.equal("|cffffffffFlask|r", details.title)
      assert.are.equal(1100, details.portraitAsset)
      assert.are.equal("Item ID 100", FindText(details, "^Item ID").text)

      FindRow("100"):Click()
      assert.is_false(details:IsShown())
    end)

    it("lists the item's prices, its crafting costs, and the materials to buy, as Opportunities would", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      FindRow("100"):Click()

      local body = ReadBody(details)
      assert.are.same({ "Prices", "Crafting", "Materials" }, body.headers)
      assert.are.same({ "", "", "Per craft (x2), at Buyout prices" }, body.notes)
      assert.are.same({
        ["Market Value"] = "48s 00c",
        ["Buyout"] = "45s 00c",
        ["Vendor Sell Price"] = "2s 50c",
        ["Listed"] = "—",
        ["Last Seen"] = "1 hour ago",
        ["Craft Cost"] = "43s 21c",
        ["Buyout Craft Cost"] = "39s 00c",
        ["1x Empty Vial (Vendor)"] = "40c",
        ["3x Herb"] = "54s 00c",
      }, body.values)
      assert.are.same({ ["1x Empty Vial (Vendor)"] = 1102, ["3x Herb"] = 1101 }, body.icons)
      assert.are.same({ flask = true }, harness.scanCostRecipeKeys[100], "uses Craft Cost's recipe")
      assert.has_error(function()
        FindText(details, "Estimate")
      end, "no text matching Estimate")
    end)

    it("lists units listed, and TradeSkillMaster's region sales under their own header", function()
      setfenv(1, environment)
      harness.listed["100"] = 12795
      harness.sales[100] = { 2400, 0.887 }
      OpenDatabaseTab()
      FindRow("100"):Click()

      local body = ReadBody(details)
      assert.are.same({ "Prices", "Region Sales", "Crafting", "Materials" }, body.headers)
      assert.are.same({ "", "From TradeSkillMaster", "", "Per craft (x2), at Buyout prices" }, body.notes)
      assert.are.equal("12,795", body.values.Listed)
      assert.are.same({ "89%", "24s 00c" }, { body.values["Sale Rate"], body.values["Average Sale Price"] })
      assert.is_nil(body.values.Auctions, "lists no auctions")
      assert.is_nil(body.values["Sold Per Day"], "nor units sold a day")

      -- TradeSkillMaster may know only some figures.
      harness.listed["200"] = 4
      harness.sales[200] = { 0, 0.004 }
      FindRow("200"):Click()
      body = ReadBody(details)
      assert.are.same({ "Prices", "Region Sales" }, body.headers)
      assert.are.equal("4", body.values.Listed)
      assert.are.same({ "<1%", "—" }, { body.values["Sale Rate"], body.values["Average Sale Price"] })

      harness.sales[200] = nil
      harness.ns.DatabaseIndex.Invalidate()
      harness.RunAllTimers()
      assert.are.same({ "Prices" }, ReadBody(details).headers, "leaves the section out without sales")
    end)

    it("marks a Craft Cost with an unpriced material, and leaves out what no known recipe makes", function()
      setfenv(1, environment)
      harness.craftingCosts[100] = { isUnknown = true }
      harness.scanCraftingCosts[100] = nil
      OpenDatabaseTab()
      FindRow("100"):Click()

      local body = ReadBody(details)
      assert.are.same({ "Prices", "Crafting" }, body.headers)
      assert.are.equal("?", body.values["Craft Cost"])
      assert.are.equal("—", body.values["Buyout Craft Cost"])
      assert.are.equal("any", harness.scanCostRecipeKeys[100])

      FindRow("200"):Click()
      assert.are.same({ "Prices" }, ReadBody(details).headers)
    end)

    it("plots each day's value and a dashed line at Market Value, on round gridlines", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      FindRow("100"):Click()

      local markers = Markers(details)
      assert.are.equal(2, #markers)
      assert(markers[1].y < markers[2].y, "the cheaper day sits lower")
      assert.are.same({ "40", "45", "50" }, PriceLabels(details))
      assert.is_false(FindText(details, "^No scans"):IsShown())

      local dashes, joins = PriceLines(details)
      assert.are.same(
        { { x1 = markers[1].x, y1 = markers[1].y, x2 = markers[2].x, y2 = markers[2].y } },
        joins,
        "a line joins the days"
      )
      -- The gridlines span the plot.
      local plotWidth
      for _, line in ipairs(harness.createdLines) do
        if line.template == "BORDER" and line:IsShown() and IsInside(line, details) then
          plotWidth = line.endPoint[3]
        end
      end
      local marketValueY = markers[1].y + (markers[2].y - markers[1].y) * 0.8
      assert(#dashes > 10, "dashes the line at Market Value")
      assert.are.equal(0, dashes[1].x1, "from the plot's left edge")
      assert(plotWidth - dashes[#dashes].x2 < dashes[2].x1 - dashes[1].x1, "to within a dash of its right edge")
      for _, dash in ipairs(dashes) do
        assert.are.same({ marketValueY, marketValueY }, { dash.y1, dash.y2 })
      end
    end)

    it("plots each day's Buyout, a quick scan's included, over faint bars for the units listed", function()
      setfenv(1, environment)
      date = os.date
      harness.dailyValues["100"] = {
        { day = TODAY - 2, value = 4000, count = 2, buyout = 3600, buyoutCount = 3, quantity = 40, auctions = 4 },
        { day = TODAY - 1, buyout = 3000, buyoutCount = 1, quantity = 20 },
        { day = TODAY, value = 5000, count = 1, buyout = 4400, buyoutCount = 1, quantity = 10, auctions = 2 },
      }
      OpenDatabaseTab()
      FindRow("100"):Click()

      local values, buyouts = Markers(details), Markers(details, 0.35)
      assert.are.equal(2, #values)
      assert.are.equal(3, #buyouts)
      assert.are.same({ values[1].x, values[2].x }, { buyouts[1].x, buyouts[3].x }, "a day's markers share its x")
      assert(buyouts[2].y < buyouts[1].y and buyouts[1].y < values[1].y, "Buyouts sit on the same price scale")
      local _, joins = PriceLines(details)
      assert.are.equal(3, #joins, "a line joins each series' days")
      assert.are.equal("30", PriceLabels(details)[1], "the scale reaches the lowest Buyout")

      local bars = UnitBars(details)
      assert.are.equal(3, #bars)
      for index, bar in ipairs(bars) do
        assert.are.equal(buyouts[index].x, bar.x)
      end
      assert(bars[1].height < 88 / 2, "the tallest bar stays low in the plot")
      assert.are.same({ bars[1].height / 2, bars[1].height / 4 }, { bars[2].height, bars[3].height })

      local cursorX
      function GetCursorPosition()
        return cursorX, 0
      end
      local plot
      for _, frame in ipairs(harness.createdFrames) do
        if frame.mouseEnabled and IsInside(frame, details) then
          plot = frame
        end
      end
      function plot:GetLeft()
        return 0
      end
      function plot:GetEffectiveScale()
        return 1
      end
      local function HoverLines(x)
        local before = #harness.tooltipDoubleLines
        cursorX = x
        plot.scripts.OnUpdate(plot)
        local lines = {}
        for index = before + 1, #harness.tooltipDoubleLines do
          local line = harness.tooltipDoubleLines[index]
          lines[#lines + 1] = line[1] .. ": " .. harness.PlainMoney(line[2])
        end
        return lines
      end
      plot.scripts.OnEnter(plot)
      assert.are.same({
        "Daily value (2 scans): 40s 00c",
        "Buyout (3 scans): 36s 00c",
        "Units listed: 40",
        "Auctions: 4",
      }, HoverLines(values[1].x))
      assert.are.same({ "Buyout (1 scan): 30s 00c", "Units listed: 20" }, HoverLines(buyouts[2].x))
    end)

    it("names the price of the day nearest the cursor while hovering the chart", function()
      setfenv(1, environment)
      date = os.date
      local cursorX
      function GetCursorPosition()
        return cursorX, 0
      end
      OpenDatabaseTab()
      FindRow("100"):Click()
      local markers = Markers(details)
      local plot
      for _, frame in ipairs(harness.createdFrames) do
        if frame.mouseEnabled and IsInside(frame, details) then
          plot = frame
        end
      end
      function plot:GetLeft()
        return 500
      end
      function plot:GetEffectiveScale()
        return 1
      end

      plot.scripts.OnEnter(plot)
      cursorX = 500 + markers[2].x - 3
      plot.scripts.OnUpdate(plot)
      assert.are.equal(plot, GameTooltip.owner)
      -- Day 100 after the epoch.
      assert.are.equal("Apr 11 (today)", harness.tooltipLines[#harness.tooltipLines])
      assert.are.same(
        { "Daily value (1 scan)", "50s 00c" },
        { harness.tooltipDoubleLines[1][1], harness.PlainMoney(harness.tooltipDoubleLines[1][2]) }
      )

      -- Just left of the day two days ago, the nearest with a price.
      cursorX = 500 + markers[1].x - 10
      plot.scripts.OnUpdate(plot)
      assert.are.equal("Apr 9 (2 days ago)", harness.tooltipLines[#harness.tooltipLines])
      assert.are.same(
        { "Daily value (2 scans)", "40s 00c" },
        { harness.tooltipDoubleLines[2][1], harness.PlainMoney(harness.tooltipDoubleLines[2][2]) }
      )

      plot.scripts.OnLeave(plot)
      assert.is_nil(GameTooltip.owner)
      assert.is_nil(plot.scripts.OnUpdate)
    end)

    it("shows a dash for missing prices and says when there's nothing to plot", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      FindRow("200"):Click()

      assert.are.same(
        { ["Market Value"] = "—", ["Buyout"] = "—", ["Listed"] = "—", ["Last Seen"] = "2 days ago" },
        ReadBody(details).values
      )
      assert.are.same({}, Markers(details))
      assert.are.same({}, PriceLabels(details))
      local dashes, joins = PriceLines(details)
      assert.are.same({}, dashes)
      assert.are.same({}, joins)
      assert.is_true(FindText(details, "^No scans in the last 14 days"):IsShown())
    end)

    it("closes from its close button and clears the row's selection", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      local row = FindRow("100")
      row:Click()
      details.CloseButton:Click()
      assert.is_false(details:IsShown())
      assert.is_false(row.selectedHighlight:IsShown())

      row:Click()
      assert.is_true(details:IsShown())
    end)

    it("follows the item when the database is read again, and closes when the item is gone", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      FindRow("100"):Click()

      harness.marketValues["100"] = { value = 6000, scanCount = 4, dayCount = 3, isUncertain = false, reasons = {} }
      harness.ns.DatabaseIndex.Invalidate()
      harness.RunAllTimers()
      assert.is_true(details:IsShown())
      assert.are.equal("60s 00c", ReadBody(details).values["Market Value"])

      -- A search hiding the row leaves its details open.
      components.searchBox:Type("200")
      assert.is_true(details:IsShown())
      components.searchBox:SetText("")

      harness.databaseItems["100"] = nil
      harness.ns.DatabaseIndex.Invalidate()
      harness.RunAllTimers()
      assert.is_false(details:IsShown())
    end)

    it("scrolls back to the top for another item, but not when the same item refreshes", function()
      setfenv(1, environment)
      OpenDatabaseTab()
      local scrollFrame
      for _, frame in ipairs(harness.createdFrames) do
        if frame.frameType == "ScrollFrame" and IsInside(frame, details) then
          scrollFrame = frame
        end
      end
      assert.is_true(scrollFrame.scrollBar.hideIfUnscrollable)
      FindRow("100"):Click()
      assert.are.equal(0, scrollFrame.verticalScroll)

      scrollFrame:SetVerticalScroll(30)
      harness.ns.DatabaseIndex.Invalidate()
      harness.RunAllTimers()
      assert.are.equal(30, scrollFrame.verticalScroll)

      FindRow("200"):Click()
      assert.are.equal(0, scrollFrame.verticalScroll)
    end)
  end)

  describe("on the Opportunities tab", function()
    local components, details

    local function OpenOpportunities()
      harness.ns.Window.Toggle()
      components = harness.FindComponents(harness.GetWindowContents()[1])
      details = FindDetails(components.content)
    end

    local function FindRow(name)
      for _, row in ipairs(components.scrollBox.frames) do
        if row:IsShown() and row.itemName.text == name then
          return row
        end
      end
      error("no visible row for " .. name)
    end

    it("lists the craft's costs and the materials to buy, without its profits or crafters", function()
      setfenv(1, environment)
      harness.marketValues["100"] = { value = 200, scanCount = 9, dayCount = 4, isUncertain = false, reasons = {} }
      OpenOpportunities()
      FindRow("Flask (x2)"):Click()

      local body = ReadBody(details)
      assert.are.same({ "Prices", "Crafting", "Materials" }, body.headers)
      assert.are.same({ "", "", "Per craft (x2), at Buyout prices" }, body.notes)
      assert.are.same({
        ["Market Value"] = "2s 00c",
        ["Buyout"] = "—",
        ["Vendor Sell Price"] = "2s 50c",
        ["Listed"] = "—",
        ["Last Seen"] = "—",
        ["Craft Cost"] = "80c",
        ["Buyout Craft Cost"] = "70c",
        ["1x Empty Vial (Vendor)"] = "40c",
        ["3x Herb"] = "90c",
      }, body.values)
      assert.are.same({ ["1x Empty Vial (Vendor)"] = 1102, ["3x Herb"] = 1101 }, body.icons)
      assert.has_error(function()
        FindText(details, "Alchemy")
      end, "no text matching Alchemy")
    end)

    it("names an item still loading until it loads, and lists materials at Market Value without Buyouts", function()
      setfenv(1, environment)
      OpenOpportunities()
      FindRow("Item #200"):Click()

      assert.are.equal("|cffffffffItem #200|r", details.title)
      local body = ReadBody(details)
      assert.are.equal("Per craft, at Market Value", body.notes[3])
      assert.are.equal("90c", body.values["2x Iron Bar"])

      harness.itemInfo[200] = { "Iron Bar", "item:200", 2, 1, 1, "", "", 20, "", 2000, 0 }
      harness.FireEvent("GET_ITEM_INFO_RECEIVED", 200, true)
      assert.are.equal("|cff1eff00Iron Bar|r", details.title)
    end)

    it("updates as Opportunities refresh, and closes when the craft drops out", function()
      setfenv(1, environment)
      OpenOpportunities()
      FindRow("Flask (x2)"):Click()

      local function Result(craftCost)
        local items = {}
        if craftCost then
          items[1] = {
            itemID = 100,
            outputQuantity = 1,
            saleMethod = "auction",
            craftCost = craftCost,
            profit = 5,
            sources = {},
            reasons = {},
            isUncertain = false,
          }
        end
        return { totalCount = 1, pricedCount = 1, profitableCount = 1, items = items }
      end
      harness.SetOpportunityResult(Result(700))
      harness.ns.OpportunityPanel.Refresh()
      assert.is_true(details:IsShown())
      assert.are.equal("7s 00c", ReadBody(details).values["Craft Cost"])

      harness.SetOpportunityResult(Result(nil))
      harness.ns.OpportunityPanel.Refresh()
      assert.is_false(details:IsShown())
    end)

    it("gives the Auction House tab its own panel beside the Auction House", function()
      setfenv(1, environment)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      local auctionHouse = harness.FindComponents()
      auctionHouse.tab:Click()
      local auctionHouseDetails = FindDetails(auctionHouse.content)
      assert.are.same({ "TOPLEFT", harness.auctionHouseFrame, "TOPRIGHT", 8, 0 }, auctionHouseDetails.points[1])

      auctionHouse.scrollBox.frames[1]:Click()
      assert.is_true(auctionHouseDetails:IsShown())
    end)
  end)
end)

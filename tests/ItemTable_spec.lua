local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ItemTable", function()
  local environment
  local harness

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
  end)

  describe("money", function()
    it("uses the game's 12-pixel coin icons", function()
      setfenv(1, environment)
      assert.are.equal(
        "1|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t 07|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
        harness.ns.ItemTable.FormatMoney(107)
      )
      assert.are.equal(
        "1|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t 05|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t",
        harness.ns.ItemTable.FormatMoney(10507)
      )
    end)

    it("pads every coin after the first to two digits and drops copper from 1 gold up", function()
      setfenv(1, environment)
      local cases = {
        [0] = "0c",
        [7] = "7c",
        [99] = "99c",
        [100] = "1s 00c",
        [105] = "1s 05c",
        [9999] = "99s 99c",
        [10000] = "1g 00s",
        [10507] = "1g 05s",
        [10599] = "1g 05s",
        [990000] = "99g 00s",
        [12345678] = "1234g 56s",
      }
      for copper, expected in pairs(cases) do
        assert.are.equal(expected, harness.PlainMoney(harness.ns.ItemTable.FormatMoney(copper)))
      end
      assert.are.equal("1s 90c", harness.PlainMoney(harness.ns.ItemTable.FormatMoney(190.9)))
    end)

    it("signs losses and gains with the same padding", function()
      setfenv(1, environment)
      assert.are.equal("-1g 05s", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(-10507)))
      assert.are.equal("+50s 00c", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(5000)))
      assert.are.equal("+0c", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(0)))
    end)
  end)

  describe("counts and shares", function()
    it("groups a count's thousands", function()
      setfenv(1, environment)
      local cases = {
        [0] = "0",
        [4] = "4",
        [999] = "999",
        [1000] = "1,000",
        [12795] = "12,795",
        [1234567] = "1,234,567",
      }
      for count, expected in pairs(cases) do
        assert.are.equal(expected, harness.ns.ItemTable.FormatCount(count), count)
      end
    end)

    it("rounds a share to a whole percent, and one above zero that rounds to none to under 1%", function()
      setfenv(1, environment)
      local cases = { [0] = "0%", [0.004] = "<1%", [0.005] = "1%", [0.412] = "41%", [0.887] = "89%", [1] = "100%" }
      for share, expected in pairs(cases) do
        assert.are.equal(expected, harness.ns.ItemTable.FormatPercent(share), share)
      end
    end)
  end)

  describe("sorting", function()
    -- A table with one column, Value, over items given as { itemID, link?, value, name }.
    local function Sort(entries, options)
      setfenv(1, environment)
      options = options or {}
      local parent = CreateFrame("Frame")
      local itemTable = harness.ns.ItemTable.Create(parent, {
        itemLabel = "Item",
        itemWidth = 100,
        nameWidth = 80,
        columns = { { key = "value", label = "Value", x = 120, width = 80 } },
        defaultSortKey = "value",
        populateRow = function(row, _, itemName)
          row.itemName:SetText(itemName)
        end,
        profileName = "Test Table",
        identityOrdered = options.identityOrdered,
        sortName = options.sortName,
      })
      local items = {}
      for index, entry in ipairs(entries) do
        items[index] = { itemID = entry[1], link = entry[2], value = entry[3], name = entry[4] }
      end
      itemTable.SetItems(items)
      local components = harness.FindComponents(parent)
      local function Order()
        local order = {}
        for _, row in ipairs(components.scrollBox.frames) do
          if row:IsShown() then
            order[#order + 1] = row.item.link or row.item.itemID
          end
        end
        return order
      end
      return Order, components.headers
    end

    local VARIANT_A = "item:300::::::::1:1485:::1:12722"
    local VARIANT_B = "item:300::::::::1:1485:::1:12723"

    it("breaks ties by item ID and link in either direction, and lists items without a value last", function()
      setfenv(1, environment)
      local Order, headers = Sort({
        { 400, nil, 50 },
        { 300, VARIANT_B, 50 },
        { 200, nil, nil },
        { 300, VARIANT_A, 50 },
        { 100, nil, 90 },
        { 150, nil, nil },
      })
      assert.are.same({ 100, VARIANT_A, VARIANT_B, 400, 150, 200 }, Order())
      headers.Value:Click()
      assert.are.same({ VARIANT_A, VARIANT_B, 400, 100, 150, 200 }, Order())
    end)

    it("sorts values it can't pack into one number, like fractions, the same way", function()
      setfenv(1, environment)
      local Order, headers = Sort({
        { 400, nil, 50.5 },
        { 300, VARIANT_B, 50.5 },
        { 200, nil, nil },
        { 300, VARIANT_A, 50.5 },
        { 100, nil, 90.25 },
        { 500, nil, -3 },
      })
      assert.are.same({ 100, VARIANT_A, VARIANT_B, 400, 500, 200 }, Order())
      headers.Value:Click()
      assert.are.same({ 500, VARIANT_A, VARIANT_B, 400, 100, 200 }, Order())
    end)

    it("packs negative and zero values with their ties in order", function()
      setfenv(1, environment)
      local Order, headers = Sort({ { 400, nil, -7 }, { 300, nil, 0 }, { 200, nil, -7 }, { 100, nil, 12 } })
      assert.are.same({ 100, 300, 200, 400 }, Order())
      headers.Value:Click()
      assert.are.same({ 200, 400, 300, 100 }, Order())
    end)

    it("sorts by the names items keep, ties by identity in either direction, unnamed last", function()
      setfenv(1, environment)
      local Order, headers = Sort({
        { 400, nil, 1, "flask" },
        { 300, VARIANT_B, 1, "sword" },
        { 200, nil, 1, nil },
        { 300, VARIANT_A, 1, "sword" },
        { 100, nil, 1, "flask of the titans" },
      }, {
        sortName = function(item)
          return item.name
        end,
      })
      headers.Item:Click()
      assert.are.same({ 400, 100, VARIANT_A, VARIANT_B, 200 }, Order())
      headers.Item:Click()
      assert.are.same({ VARIANT_A, VARIANT_B, 100, 400, 200 }, Order())
    end)

    it("keeps the order items arrive in for ties when they come in identity order", function()
      setfenv(1, environment)
      local Order, headers = Sort({ { 300, VARIANT_B, 5 }, { 300, VARIANT_A, 5 }, { 100, nil, 5 } }, {
        identityOrdered = true,
      })
      assert.are.same({ VARIANT_B, VARIANT_A, 100 }, Order())
      headers.Value:Click()
      assert.are.same({ VARIANT_B, VARIANT_A, 100 }, Order())
    end)
  end)

  describe("row tooltips", function()
    it("leaves Arbitrage's item pricing out of Opportunities rows but keeps it on Database rows", function()
      setfenv(1, environment)
      harness.databaseItems["100"] = { days = {}, latest = 100 }
      harness.ns.Window.Toggle()

      local opportunityRow = harness.FindComponents(harness.GetWindowContents()[1]).scrollBox.frames[1]
      opportunityRow.scripts.OnEnter(opportunityRow)
      assert.are.equal("item:100", GameTooltip.hyperlink)
      assert.is_true(GameTooltip.owner.arbitrageReplacesItemPricing)
      opportunityRow.scripts.OnLeave(opportunityRow)

      _G.ArbitrageWindow.Tabs[2]:Click()
      harness.RunAllTimers()
      local databaseRow = harness.FindComponents(harness.GetWindowContents()[2]).scrollBox.frames[1]
      databaseRow.scripts.OnEnter(databaseRow)
      assert.are.equal("item:100", GameTooltip.hyperlink)
      assert.is_nil(GameTooltip.owner.arbitrageReplacesItemPricing)
      databaseRow.scripts.OnLeave(databaseRow)
    end)
  end)

  describe("column layout", function()
    local function AssertColumnsApart(content)
      local headers = {}
      for label, header in pairs(harness.FindComponents(content).headers) do
        headers[#headers + 1] = { label = label, x = header.points[1][4], width = header.width }
      end
      table.sort(headers, function(left, right)
        return left.x < right.x
      end)
      for index, header in ipairs(headers) do
        local nextX = headers[index + 1] and headers[index + 1].x or 741
        assert(header.x + header.width < nextX, header.label .. " ends before the next column")
      end
      return headers
    end

    -- The Database columns' labels, left to right.
    local function DatabaseColumns()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      _G.ArbitrageWindow.Tabs[2]:Click()
      local content = harness.GetWindowContents()[2]
      local labels = {}
      for _, header in ipairs(AssertColumnsApart(content)) do
        labels[#labels + 1] = header.label
      end
      return labels, harness.FindComponents(content).headers
    end

    it("keeps Database columns apart and gives each price room for 4-digit gold", function()
      setfenv(1, environment)
      local labels, headers = DatabaseColumns()
      assert.are.same({ "Item", "Market Value", "Buyout", "Craft Cost", "Listed", "Last Seen" }, labels)
      for _, label in ipairs({ "Market Value", "Buyout", "Craft Cost" }) do
        assert(headers[label].width >= 96, label .. " fits 9999g 99s")
      end
      assert(headers.Item.width >= 240, "gives names the room Sale Rate would take")
    end)

    it("adds a Sale Rate column only when the Companion brought region-wide sales", function()
      setfenv(1, environment)
      harness.sales[2589] = { 1250, 0.412 }
      local labels, headers = DatabaseColumns()
      assert.are.same({ "Item", "Market Value", "Buyout", "Craft Cost", "Listed", "Sale Rate", "Last Seen" }, labels)
      assert(headers.Item.width >= 170, "still gives names room")
    end)

    it("keeps the Opportunities columns apart and inside the table, with room for names and 4-digit gold", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      local content = harness.GetWindowContents()[1]
      local headers = AssertColumnsApart(content)
      assert.are.same(
        { "Item", "Craft Cost", "Profit", "Buyout Craft Cost", "Buyout Profit" },
        { headers[1].label, headers[2].label, headers[3].label, headers[4].label, headers[5].label }
      )
      local components = harness.FindComponents(content)
      for _, label in ipairs({ "Craft Cost", "Profit", "Buyout Craft Cost", "Buyout Profit" }) do
        assert(components.headers[label].width >= 96, label .. " fits +9999g 99s")
      end
      local row = components.scrollBox.frames[1]
      assert(row.itemName.width >= 200, "gives item names most of the item column")
      assert(row.saleMethod.points[1][4] >= 18 + row.itemName.width, "keeps the sale method clear of the name")
      assert(row.saleMethod.points[1][4] + row.saleMethod.width < components.headers.Item.width, "ends in the column")
      for index, key in ipairs({ "craftCost", "profit", "buyoutCraftCost", "buyoutProfit" }) do
        assert.are.equal(headers[index + 1].x - 4, row[key].points[1][4], key .. " sits under its header")
      end
    end)
  end)

  describe("row clicks", function()
    local FLASK_LINK = "|cffffffff|Hitem:100::::::::::::|h[Flask]|h|r"

    -- The Opportunities rows by item name: the harness lists Flask and item 200, whose data is not loaded.
    local function OpenOpportunities()
      harness.itemInfo[100] = { "Flask", FLASK_LINK, 1, 1, 1, "", "", 20, "", 1000 }
      harness.ns.Window.Toggle()
      local rows = {}
      for _, row in ipairs(harness.FindComponents(harness.GetWindowContents()[1]).scrollBox.frames) do
        if row:IsShown() then
          rows[row.itemName.text] = row
        end
      end
      return rows
    end

    it("links the item in chat on Shift-click", function()
      setfenv(1, environment)
      local rows = OpenOpportunities()
      harness.SetHeldModifier("SHIFT")
      rows["Flask (x2)"]:Click()
      assert.are.same({ FLASK_LINK }, harness.chatLinks)
    end)

    it("links the random-suffix variant a Database row lists", function()
      setfenv(1, environment)
      local swordLink = "|cff1eff00|Hitem:300::::::::1:1485:::1:12722|h[Sword of the Bear]|h|r"
      harness.itemInfo["item:300::::::::1:1485:::1:12722"] = { "Sword of the Bear", swordLink, 2 }
      harness.itemInfo[300] = { "Sword", "|cff1eff00|Hitem:300::::::::::::|h[Sword]|h|r", 2 }
      harness.databaseItems["equip:300:12722"] = { days = {}, latest = 100 }
      harness.ns.Window.Toggle()
      _G.ArbitrageWindow.Tabs[2]:Click()
      harness.RunAllTimers()

      harness.SetHeldModifier("SHIFT")
      harness.FindComponents(harness.GetWindowContents()[2]).scrollBox.frames[1]:Click()
      assert.are.same({ swordLink }, harness.chatLinks)
    end)

    it("links nothing for an item still loading or a plain click", function()
      setfenv(1, environment)
      local rows = OpenOpportunities()
      rows["Flask (x2)"]:Click()
      harness.SetHeldModifier("SHIFT")
      rows["Item #200"]:Click()
      assert.are.same({}, harness.chatLinks)
    end)

    -- The names of the rows marked selected.
    local function SelectedRows()
      local selected = {}
      for _, row in ipairs(harness.FindComponents(harness.GetWindowContents()[1]).scrollBox.frames) do
        if row:IsShown() and row.selectedHighlight:IsShown() then
          selected[#selected + 1] = row.itemName.text
        end
      end
      return selected
    end

    it("selects a row on a plain click and clears it on a second", function()
      setfenv(1, environment)
      local rows = OpenOpportunities()
      assert.are.equal("auctionhouse-ui-row-select", rows["Flask (x2)"].selectedHighlight.atlas)
      assert.are.same({}, SelectedRows())

      rows["Flask (x2)"]:Click()
      assert.are.same({ "Flask (x2)" }, SelectedRows())
      rows["Item #200"]:Click()
      assert.are.same({ "Item #200" }, SelectedRows())
      rows["Item #200"]:Click()
      assert.are.same({}, SelectedRows())
    end)

    it("leaves the selection alone on modified clicks", function()
      setfenv(1, environment)
      local rows = OpenOpportunities()
      rows["Flask (x2)"]:Click()
      harness.SetHeldModifier("SHIFT")
      rows["Flask (x2)"]:Click()
      rows["Item #200"]:Click()
      assert.are.same({ FLASK_LINK }, harness.chatLinks)
      assert.are.same({ "Flask (x2)" }, SelectedRows())
    end)

    it("keeps the selected item marked as the list re-sorts, searches, and refreshes", function()
      setfenv(1, environment)
      local rows = OpenOpportunities()
      local components = harness.FindComponents(harness.GetWindowContents()[1])
      rows["Flask (x2)"]:Click()

      components.headers["Craft Cost"]:Click()
      assert.are.equal("Item #200", components.scrollBox.frames[1].itemName.text)
      assert.are.same({ "Flask (x2)" }, SelectedRows())

      components.searchBox:Type("200")
      assert.are.same({}, SelectedRows())
      components.searchBox:SetText("")
      assert.are.same({ "Flask (x2)" }, SelectedRows())

      -- A refresh lists new copies of the crafts.
      local function Craft(itemID, outputQuantity, profit)
        return {
          itemID = itemID,
          outputQuantity = outputQuantity,
          saleMethod = "auction",
          craftCost = 10,
          profit = profit,
          sources = {},
          reasons = {},
          isUncertain = false,
        }
      end
      harness.SetOpportunityResult({
        totalCount = 2,
        pricedCount = 2,
        profitableCount = 2,
        items = { Craft(300, 1, 500), Craft(100, 2, 50) },
      })
      harness.ns.OpportunityPanel.Refresh()
      assert.are.same({ "Flask (x2)" }, SelectedRows())
    end)
  end)
end)

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
        minItemWidth = 100,
        layoutKey = "databaseColumns",
        columns = {
          {
            key = "value",
            label = "Value",
            width = 80,
            format = function(item)
              return item.value and tostring(item.value)
            end,
          },
        },
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
      assert.are.same({ "Item", "Typical", "Current", "Typical Craft Cost", "Listed", "Last Seen" }, labels)
      for _, label in ipairs({ "Typical", "Current", "Typical Craft Cost" }) do
        assert(headers[label].width >= 96, label .. " fits 9999g 99s")
      end
      assert(headers.Item.width >= 240, "gives names the room Sale Rate would take")
    end)

    it("adds a Sale Rate column only when the Companion brought region-wide sales", function()
      setfenv(1, environment)
      harness.sales[2589] = { 1250, 0.412 }
      local labels, headers = DatabaseColumns()
      assert.are.same(
        { "Item", "Typical", "Current", "Typical Craft Cost", "Listed", "Sale Rate", "Last Seen" },
        labels
      )
      assert(headers.Item.width >= 170, "still gives names room")
    end)

    it("keeps the Opportunities columns apart and inside the table, with room for names and 4-digit gold", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      local content = harness.GetWindowContents()[1]
      local headers = AssertColumnsApart(content)
      assert.are.same(
        { "Item", "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit" },
        { headers[1].label, headers[2].label, headers[3].label, headers[4].label, headers[5].label }
      )
      assert.are.equal(5, #headers, "has no Sale Rate column without the Companion's sales")
      local components = harness.FindComponents(content)
      for _, label in ipairs({ "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit" }) do
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

    it("ends the Opportunities columns with Sale Rate when the Companion brought region-wide sales", function()
      setfenv(1, environment)
      harness.sales[2589] = { 1250, 0.412 }
      harness.ns.Window.Toggle()
      local content = harness.GetWindowContents()[1]
      local headers = AssertColumnsApart(content)
      local labels = {}
      for index, header in ipairs(headers) do
        labels[index] = header.label
      end
      assert.are.same(
        { "Item", "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit", "Sale Rate" },
        labels
      )
      local components = harness.FindComponents(content)
      local row = components.scrollBox.frames[1]
      assert(row.itemName.width >= 130, "still gives item names room")
      assert(row.saleMethod.points[1][4] >= 18 + row.itemName.width, "keeps the sale method clear of the name")
      assert(row.saleMethod.points[1][4] + row.saleMethod.width < components.headers.Item.width, "ends in the column")
      for index, key in ipairs({ "craftCost", "profit", "buyoutCraftCost", "buyoutProfit", "saleRate" }) do
        assert.are.equal(headers[index + 1].x - 4, row[key].points[1][4], key .. " sits under its header")
      end
    end)
  end)

  describe("customizing columns", function()
    local DEFAULT_COLUMNS = { "Item", "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit" }
    local components

    -- Finds the window's Opportunities components again, with headers made since for columns shown.
    local function Refresh()
      components = harness.FindComponents(harness.GetWindowContents()[1])
      return components
    end

    -- Opens the window's Opportunities tab, which reads the saved layout as it's made.
    local function OpenOpportunities()
      harness.ns.Window.Toggle()
      Refresh()
    end

    -- The shown headers' labels, left to right, in the window unless other components are given.
    local function ShownColumns(found)
      local shown = {}
      for label, header in pairs((found or Refresh()).headers) do
        if header:IsShown() then
          shown[#shown + 1] = { label = label, x = header.points[1][4] }
        end
      end
      table.sort(shown, function(left, right)
        return left.x < right.x
      end)
      local labels = {}
      for index, header in ipairs(shown) do
        labels[index] = header.label
      end
      return labels
    end

    -- The column menu a header's right-click opens, or the columns button's without a label.
    local function OpenMenu(label)
      if label then
        components.headers[label]:Click("RightButton")
      else
        components.columnsButton:Click()
      end
      return harness.contextMenus[#harness.contextMenus]
    end

    -- The menu's columns in order, and whether each is checked.
    local function Checklist(menu)
      local labels, checked = {}, {}
      for _, entry in ipairs(menu.entries) do
        if entry.IsSelected then
          labels[#labels + 1] = entry.label
          checked[entry.label] = entry.IsSelected()
        end
      end
      return labels, checked
    end

    it("opens the same column menu from a header's right-click and from the columns button", function()
      setfenv(1, environment)
      OpenOpportunities()
      local menu = OpenMenu("Typical Profit")
      assert.are.equal(components.headers["Typical Profit"], menu.owner)
      assert.are.equal("Columns", menu.entries[1].title)
      local labels, checked = Checklist(menu)
      assert.are.same({
        "Typical",
        "Typical Craft Cost",
        "Typical Profit",
        "Typical ROI",
        "Current",
        "Current Craft Cost",
        "Current Profit",
        "Current ROI",
      }, labels, "lists every column but Sale Rate, which needs the Companion's sales")
      assert.are.same({
        ["Typical"] = false,
        ["Typical Craft Cost"] = true,
        ["Typical Profit"] = true,
        ["Typical ROI"] = false,
        Current = false,
        ["Current Craft Cost"] = true,
        ["Current Profit"] = true,
        ["Current ROI"] = false,
      }, checked)
      assert.is_false(menu:Find("Reset Columns"):IsEnabled(), "has nothing to reset at first")
      assert.are.equal(#labels + 3, #menu.entries, "adds only a title, a divider, and Reset Columns")

      local buttonMenu = OpenMenu()
      assert.are.equal(components.columnsButton, buttonMenu.owner)
      assert.are.same(labels, (Checklist(buttonMenu)))
      assert.are.equal(#menu.entries, #buttonMenu.entries)

      components.columnsButton.scripts.OnEnter(components.columnsButton)
      assert.are.same({
        "Columns",
        "Choose which columns show. Drag a column's header to move it, and the edge between two headers to resize the columns either side.",
      }, { unpack(harness.tooltipLines, #harness.tooltipLines - 1) })
    end)

    it("hides a column, giving its room to the Item column, and saves only what changed", function()
      setfenv(1, environment)
      OpenOpportunities()
      local row = components.scrollBox.frames[1]
      local itemWidth, nameWidth = components.headers.Item.width, row.itemName.width

      OpenMenu("Typical Profit"):Find("Current Craft Cost").Pick()
      assert.are.same({ "Item", "Typical Craft Cost", "Typical Profit", "Current Profit" }, ShownColumns())
      assert.are.equal(itemWidth + 125, components.headers.Item.width)
      assert.are.equal(nameWidth + 125, row.itemName.width, "gives the room to names")
      assert.is_false(row.buyoutCraftCost:IsShown())
      assert.are.equal(components.headers["Current Profit"].points[1][4] - 4, row.buyoutProfit.points[1][4])
      assert.are.same({ shown = { buyoutCraftCost = false } }, ARBITRAGE_CONFIG.opportunityColumns)

      local menu = OpenMenu()
      assert.is_true(menu:Find("Reset Columns"):IsEnabled())
      menu:Find("Current Craft Cost").Pick()
      assert.are.same(DEFAULT_COLUMNS, ShownColumns())
      assert.is_true(row.buyoutCraftCost:IsShown())
      assert.are.same({}, ARBITRAGE_CONFIG.opportunityColumns, "forgets a choice put back to its default")
    end)

    it("shows a column that fits and disables one that doesn't, saying why", function()
      setfenv(1, environment)
      OpenOpportunities()
      local menu = OpenMenu()
      menu:Find("Typical").Pick()
      assert.are.same(
        { "Item", "Typical", "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit" },
        ShownColumns()
      )
      assert.are.equal(178, components.headers.Item.width)

      -- The menu stays open as columns are checked, so its entries ask again what fits.
      local buyout = menu:Find("Current")
      assert.is_false(buyout:IsEnabled())
      assert.are.same({
        "Current",
        "The item's cheapest listing price in the latest scan.",
        "Not enough room. Hide or narrow another column first.",
      }, buyout.ShowTooltip())
      buyout.Pick()
      assert.is_false(buyout.IsSelected())
      assert.is_true(menu:Find("Typical Profit"):IsEnabled(), "can always hide a shown column")

      menu:Find("Current Craft Cost").Pick()
      assert.is_true(buyout:IsEnabled(), "fits once another column makes room")
      assert.are.same({ "Current", "The item's cheapest listing price in the latest scan." }, buyout.ShowTooltip())
      buyout.Pick()
      assert.are.same(
        { "Item", "Typical", "Typical Craft Cost", "Typical Profit", "Current", "Current Profit" },
        ShownColumns()
      )
    end)

    it("makes room for a column from columns widened past their default, once the Item column has none", function()
      setfenv(1, environment)
      OpenOpportunities()
      harness.DragResizeHandle(components.headers["Typical Craft Cost"].ResizeHandle, -100)
      assert.are.same({ 179, 220 }, { components.headers.Item.width, components.headers["Typical Craft Cost"].width })

      local menu = OpenMenu()
      assert.is_true(menu:Find("Typical"):IsEnabled(), "counts the room Typical Craft Cost was widened by")
      menu:Find("Typical").Pick()
      assert.are.same(
        { "Item", "Typical", "Typical Craft Cost", "Typical Profit", "Current Craft Cost", "Current Profit" },
        ShownColumns()
      )
      assert.are.same({ 170, 128 }, { components.headers.Item.width, components.headers["Typical Craft Cost"].width })
      assert.are.same(
        { shown = { marketValue = true }, widths = { craftCost = 128 } },
        ARBITRAGE_CONFIG.opportunityColumns
      )

      -- Only 8 pixels past its default are left to give.
      assert.is_false(menu:Find("Typical ROI"):IsEnabled())
    end)

    it("drags the edge between two columns to trade width between them, leaving the rest in place", function()
      setfenv(1, environment)
      OpenOpportunities()
      local headers = components.headers
      local row = components.scrollBox.frames[1]
      local craftCostX, profitX = headers["Typical Craft Cost"].points[1][4], headers["Typical Profit"].points[1][4]
      local handle = headers["Typical Profit"].ResizeHandle
      assert.is_nil(headers.Item.ResizeHandle)

      assert.is_false(handle.Grip:IsShown())
      handle.scripts.OnEnter(handle)
      assert.is_true(handle.Grip:IsShown(), "marks the edge as one to drag sideways")
      harness.DragResizeHandle(handle, -20)
      assert.is_false(handle.Grip:IsShown(), "clears the mark once let go away from the handle")
      assert.is_nil(handle.scripts.OnUpdate, "stops following the mouse once let go")

      assert.are.same({ 100, 116 }, { headers["Typical Craft Cost"].width, headers["Typical Profit"].width })
      assert.are.equal(profitX - 20, headers["Typical Profit"].points[1][4], "moves the edge with the mouse")
      assert.are.equal(craftCostX, headers["Typical Craft Cost"].points[1][4], "leaves the other edges in place")
      assert.are.equal(279, headers.Item.width)
      assert.are.equal(
        headers["Typical Profit"].points[1][4] - 4,
        row.profit.points[1][4],
        "moves cells with their header"
      )
      assert.are.equal(116, row.profit.width)
      assert.are.same({ widths = { craftCost = 100, profit = 116 } }, ARBITRAGE_CONFIG.opportunityColumns)

      harness.DragResizeHandle(handle, -500)
      assert.are.same(
        { 40, 176 },
        { headers["Typical Craft Cost"].width, headers["Typical Profit"].width },
        "keeps room for a short price"
      )
      assert.are.equal(279, headers.Item.width)

      harness.DragResizeHandle(handle, 500)
      assert.are.same({ 176, 40 }, { headers["Typical Craft Cost"].width, headers["Typical Profit"].width })
      assert.are.equal(18, headers["Typical Profit"].Text.width, "truncates a label too long for its header")

      -- Let go away from the handle, which then hears nothing until its next frame.
      harness.SetCursorX(400)
      harness.SetMouseButtonDown(true)
      handle.scripts.OnMouseDown(handle, "LeftButton")
      harness.SetCursorX(390)
      handle.scripts.OnUpdate(handle, 0.016)
      assert.are.equal(50, headers["Typical Profit"].width)
      assert.are.same(
        { widths = { craftCost = 176, profit = 40 } },
        ARBITRAGE_CONFIG.opportunityColumns,
        "saves once let go"
      )
      harness.SetMouseButtonDown(false)
      handle.scripts.OnUpdate(handle, 0.016)
      assert.is_nil(handle.scripts.OnUpdate)
      assert.are.same({ widths = { craftCost = 166, profit = 50 } }, ARBITRAGE_CONFIG.opportunityColumns)
    end)

    it(
      "takes room from the Item column only at its own edge, and resizes the others once it's at its minimum",
      function()
        setfenv(1, environment)
        OpenOpportunities()
        local headers = components.headers
        harness.DragResizeHandle(headers["Typical Craft Cost"].ResizeHandle, -500)
        assert.are.same(
          { 170, 229 },
          { headers.Item.width, headers["Typical Craft Cost"].width },
          "keeps the Item column's minimum"
        )

        local profitX = headers["Typical Profit"].points[1][4]
        harness.DragResizeHandle(headers["Typical Profit"].ResizeHandle, -30)
        assert.are.same(
          { 170, 199, 126 },
          { headers.Item.width, headers["Typical Craft Cost"].width, headers["Typical Profit"].width }
        )
        assert.are.equal(profitX - 30, headers["Typical Profit"].points[1][4])

        harness.DragResizeHandle(headers["Typical Craft Cost"].ResizeHandle, 50)
        assert.are.same(
          { 220, 149 },
          { headers.Item.width, headers["Typical Craft Cost"].width },
          "gives the room back"
        )
      end
    )

    it("moves a column by dragging its header, marking where it will drop, and resets every column", function()
      setfenv(1, environment)
      OpenOpportunities()
      local headers = components.headers
      assert.is_nil(headers.Item.scripts.OnDragStart, "keeps the Item column first")
      local marker
      for _, texture in ipairs(harness.createdTextures) do
        if texture.parent == components.tableBackground and texture.color then
          marker = texture
        end
      end

      -- Past Typical Profit's middle and short of Current Craft Cost's, so between them.
      local craftCost = headers["Typical Craft Cost"]
      harness.SetCursorX(500)
      craftCost.scripts.OnDragStart(craftCost)
      craftCost.scripts.OnUpdate(craftCost, 0.016)
      assert.are.equal(0.5, craftCost.alpha)
      assert.is_true(marker:IsShown())
      assert.are.same(
        { "TOP", components.tableBackground, "TOPLEFT", headers["Current Craft Cost"].points[1][4] - 2.5, -1 },
        marker.points[1]
      )
      local handle = headers["Typical Profit"].ResizeHandle
      handle.scripts.OnEnter(handle)
      assert.is_false(handle.Grip:IsShown(), "leaves out resize grips while moving a column")
      craftCost.scripts.OnDragStop(craftCost)
      assert.are.equal(1, craftCost.alpha)
      assert.is_false(marker:IsShown())
      assert.is_nil(craftCost.scripts.OnUpdate)
      assert.are.same(
        { "Item", "Typical Profit", "Typical Craft Cost", "Current Craft Cost", "Current Profit" },
        ShownColumns()
      )
      assert.are.same({
        order = {
          "marketValue",
          "profit",
          "roi",
          "buyout",
          "craftCost",
          "buyoutCraftCost",
          "buyoutProfit",
          "buyoutRoi",
          "saleRate",
        },
      }, ARBITRAGE_CONFIG.opportunityColumns)

      harness.DragHeader(headers["Current Profit"], 0)
      assert.are.same(
        { "Item", "Current Profit", "Typical Profit", "Typical Craft Cost", "Current Craft Cost" },
        ShownColumns()
      )

      -- Before itself, before the column already after it, and past the last when it's last.
      local saved = ARBITRAGE_CONFIG.opportunityColumns
      harness.DragHeader(headers["Typical Profit"], headers["Typical Profit"].points[1][4] + 10)
      harness.DragHeader(headers["Typical Profit"], headers["Typical Craft Cost"].points[1][4] + 10)
      harness.DragHeader(headers["Current Craft Cost"], 760)
      assert.are.equal(saved, ARBITRAGE_CONFIG.opportunityColumns, "saves nothing for a column dropped where it is")

      OpenMenu("Typical Profit"):Find("Typical").Pick()
      harness.DragResizeHandle(components.headers["Typical Profit"].ResizeHandle, -5)
      OpenMenu("Typical Profit"):Find("Reset Columns").Pick()
      assert.are.same(DEFAULT_COLUMNS, ShownColumns())
      assert.are.equal(96, components.headers["Typical Profit"].width)
      assert.are.same({}, ARBITRAGE_CONFIG.opportunityColumns)
    end)

    it("remembers the last sort chosen, and sorts by Profit while the chosen column is hidden", function()
      setfenv(1, environment)
      ARBITRAGE_CONFIG.opportunityColumns = { sortKey = "craftCost", sortAscending = false }
      OpenOpportunities()
      local headers = components.headers
      assert.is_true(headers["Typical Craft Cost"].Arrow.shown)
      assert.are.equal("Item #200", components.scrollBox.frames[1].itemName.text)

      headers["Typical Profit"]:Click()
      assert.are.equal("Flask (x2)", components.scrollBox.frames[1].itemName.text)
      assert.are.same({}, ARBITRAGE_CONFIG.opportunityColumns, "saves nothing for the default sort")
      headers["Typical Craft Cost"]:Click()
      headers["Typical Craft Cost"]:Click()
      assert.are.same({ sortKey = "craftCost", sortAscending = true }, ARBITRAGE_CONFIG.opportunityColumns)

      OpenMenu("Typical Craft Cost"):Find("Typical Craft Cost").Pick()
      assert.is_true(headers["Typical Profit"].Arrow.shown)
      assert.is_false(headers["Typical Craft Cost"].Arrow.shown)
      assert.are.same(
        { shown = { craftCost = false }, sortKey = "craftCost", sortAscending = true },
        ARBITRAGE_CONFIG.opportunityColumns
      )
      OpenMenu():Find("Typical Craft Cost").Pick()
      assert.is_true(headers["Typical Craft Cost"].Arrow.shown, "sorts by the column again once it shows")
    end)

    it("shares the columns between the Auction House tab and the window, each keeping its own sort", function()
      setfenv(1, environment)
      OpenOpportunities()
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      local auctionHouse = harness.FindComponents()
      auctionHouse.tab:Click()

      components.headers["Current Profit"]:Click()
      assert.is_true(auctionHouse.headers["Typical Profit"].Arrow.shown, "leaves the other table's sort alone")

      OpenMenu("Typical Profit"):Find("Typical Craft Cost").Pick()
      assert.are.same({ "Item", "Typical Profit", "Current Craft Cost", "Current Profit" }, ShownColumns(auctionHouse))
      harness.DragResizeHandle(auctionHouse.headers["Typical Profit"].ResizeHandle, -10)
      assert.are.equal(106, components.headers["Typical Profit"].width)
      assert.is_true(components.headers["Current Profit"].Arrow.shown)
    end)

    it("ignores what a saved layout gets wrong and keeps the rest", function()
      setfenv(1, environment)
      ARBITRAGE_CONFIG.opportunityColumns = {
        order = { "buyoutProfit", "bogus", 7, "profit", "buyoutProfit" },
        shown = { craftCost = "yes", buyoutCraftCost = false },
        widths = { profit = "wide", craftCost = 0 / 0, buyoutProfit = 10 },
        sortKey = "bogus",
        sortAscending = true,
      }
      OpenOpportunities()
      assert.are.same({ "Item", "Current Profit", "Typical Profit", "Typical Craft Cost" }, ShownColumns())
      assert.are.same({ 96, 120, 40 }, {
        components.headers["Typical Profit"].width,
        components.headers["Typical Craft Cost"].width,
        components.headers["Current Profit"].width,
      })
      assert.is_true(components.headers["Typical Profit"].Arrow.shown)
      assert.are.same({ 0, 1, 0, 1 }, components.headers["Typical Profit"].Arrow.texCoord, "sorts Profit largest first")
    end)

    it("leaves out the rightmost columns of a saved layout too wide to fit, until something changes", function()
      setfenv(1, environment)
      local saved = { shown = { marketValue = true, buyout = true } }
      ARBITRAGE_CONFIG.opportunityColumns = saved
      OpenOpportunities()
      assert.are.same(
        { "Item", "Typical", "Typical Craft Cost", "Typical Profit", "Current", "Current Craft Cost" },
        ShownColumns()
      )
      assert.are.equal(178, components.headers.Item.width)
      assert.are.equal(saved, ARBITRAGE_CONFIG.opportunityColumns)

      local menu = OpenMenu()
      assert.is_false(menu:Find("Current Profit").IsSelected())
      assert.is_false(menu:Find("Current Profit"):IsEnabled())
      menu:Find("Current").Pick()
      assert.are.same({ shown = { marketValue = true, buyoutProfit = false } }, ARBITRAGE_CONFIG.opportunityColumns)
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

      components.headers["Typical Craft Cost"]:Click()
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

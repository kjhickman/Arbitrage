local NewEnvironment = dofile("tests/support/Environment.lua")

describe("DatabasePanel", function()
  local DAY = 24 * 60 * 60
  local NOW = 100 * DAY
  local environment
  local harness
  local content
  local components

  local function AddItem(dbKey, item)
    harness.databaseItems[dbKey] = { scans = { [item.lastSeen] = item.marketValue or 1 } }
    harness.marketValues[dbKey] = item.market
    harness.latestBuyouts[dbKey] = item.latestBuyout
  end

  local function OpenDatabaseTab()
    harness.ns.Window.Toggle()
    environment.ArbitrageWindow.Tabs[2]:Click()
    content = harness.GetWindowContents()[2]
    components = harness.FindComponents(content)
  end

  local function VisibleKeys()
    local keys = {}
    for _, row in ipairs(components.scrollBox.frames) do
      if row:IsShown() then
        keys[#keys + 1] = row:GetElementData().dbKey
      end
    end
    return keys
  end

  local function FindRow(dbKey)
    for _, row in ipairs(components.scrollBox.frames) do
      if row:IsShown() and row:GetElementData().dbKey == dbKey then
        return row
      end
    end
    error("no visible row for " .. dbKey)
  end

  local function SummaryText()
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.parent == content and fontString.template == "GameFontHighlightSmall" then
        return fontString.text
      end
    end
  end

  local function EmptyMessage()
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.parent == components.tableBackground and fontString.template == "GameFontHighlight" then
        return fontString:IsShown() and fontString.text or nil
      end
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    harness.SetCurrentTime(NOW)

    harness.itemInfo[100] = { "Flask", "item:100", 1, 1, 1, "", "", 20, "", 1000, 250 }
    harness.itemInfo[200] = { "Iron Bar", "item:200", 1, 1, 1, "", "", 20, "", 2000, 0 }
    harness.itemInfo[300] = { "Sword", "item:300", 2, 1, 1, "", "", 1, "", 3000, 500 }
    harness.itemInfo["item:300::::::-35"] =
      { "Sword of the Bear", "item:300::::::-35", 2, 1, 1, "", "", 1, "", 3000, 500 }
    harness.itemClasses[100] = 0
    harness.itemClasses[200] = 7
    harness.itemClasses[300] = 2
    harness.itemClasses[400] = 7

    AddItem("100", {
      lastSeen = NOW - 60 * 60,
      market = { value = 5000, scanCount = 6, isUncertain = false, reasons = {} },
      latestBuyout = 4500,
    })
    AddItem("200", {
      lastSeen = NOW - 2 * DAY,
      market = { value = 120, scanCount = 2, isUncertain = true, reasons = { "limited scans" } },
    })
    AddItem("equip:300:-35", { lastSeen = NOW - 20 * DAY })
    -- The client has not loaded this item's name yet.
    AddItem("400", {
      lastSeen = NOW - 60 * 60,
      market = { value = 900, scanCount = 4, isUncertain = false, reasons = {} },
    })
  end)

  it("reads the database in the background and lists every stored item, priciest first", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    assert.are.equal("Reading the price database...", SummaryText())
    assert.are.equal("Reading the price database...", EmptyMessage())
    assert.are.same({}, VisibleKeys())

    harness.RunAllTimers()
    assert.are.same({ "100", "400", "200", "equip:300:-35" }, VisibleKeys())
    assert.are.equal("4 items | Last scan: 1 hour ago", SummaryText())
    assert.is_nil(EmptyMessage())
    assert.is_true(components.headers["Market Value"].Arrow.shown)
  end)

  it("shows every price column with explicit missing values and yellow uncertain prices", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local explanations = {
      ["Market Value"] = "Estimated low-end Auction House price from the last 14 days of scans; recent days count more. Yellow values have limited, stale, or volatile data.",
      ["Min Buyout"] = "Cheapest per-unit buyout in the latest full scan. Blank when the item was not listed.",
      ["Vendor Sell"] = "What a vendor pays for one.",
      Scans = "Scans that priced this item in the last 14 days. Fewer than three makes Market Value uncertain.",
      ["Last Seen"] = "When a scan last priced this item. Scans older than 30 days are discarded.",
    }
    assert(components.headers.Item, "creates the item header")
    for label, explanation in pairs(explanations) do
      local header = assert(components.headers[label], "creates the " .. label .. " header")
      header.scripts.OnEnter(header)
      assert.are.equal(explanation, harness.tooltipLines[#harness.tooltipLines])
      header.scripts.OnLeave(header)
    end

    local flask = FindRow("100")
    assert.are.equal("Flask", flask.itemName.text)
    assert.are.equal("50s 00c", harness.PlainMoney(flask.market.text))
    assert.are.equal(1, flask.market.textColor[2])
    assert.are.equal("45s 00c", harness.PlainMoney(flask.minBuyout.text))
    assert.are.equal("2s 50c", harness.PlainMoney(flask.vendorSell.text))
    assert.are.equal("6", flask.scans.text)
    assert.are.equal("1 hour ago", flask.lastSeen.text)

    local ironBar = FindRow("200")
    assert.are.equal("1s 20c", harness.PlainMoney(ironBar.market.text))
    assert.are.equal(0.82, ironBar.market.textColor[2])
    assert.are.equal("—", ironBar.minBuyout.text)
    assert.are.equal("—", ironBar.vendorSell.text)

    local sword = FindRow("equip:300:-35")
    assert.are.equal("Sword of the Bear", sword.itemName.text)
    assert.are.equal("—", sword.market.text)
    assert.are.equal("0", sword.scans.text)
    assert.are.equal("20 days ago", sword.lastSeen.text)

    assert.are.equal("Item #400", FindRow("400").itemName.text)
  end)

  it("shows the item's own tooltip and explains uncertain prices on hover", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local sword = FindRow("equip:300:-35")
    sword.scripts.OnEnter(sword)
    assert.are.equal("item:300::::::-35", GameTooltip.hyperlink)
    sword.scripts.OnLeave(sword)

    local ironBar = FindRow("200")
    ironBar.scripts.OnEnter(ironBar)
    assert.are.equal("item:200", GameTooltip.hyperlink)
    assert.are.equal("Estimate: limited scans", harness.tooltipLines[#harness.tooltipLines])
  end)

  it("searches item names regardless of case and matches item IDs", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    components.searchBox:Type("FLA")
    assert.are.same({ "100" }, VisibleKeys())
    assert.are.equal("1 of 4 items | Last scan: 1 hour ago", SummaryText())

    components.searchBox:Type(" bear ")
    assert.are.same({ "equip:300:-35" }, VisibleKeys())

    components.searchBox:Type("200")
    assert.are.same({ "200" }, VisibleKeys())

    components.searchBox:Type("400")
    assert.are.same({ "400" }, VisibleKeys())

    components.searchBox:Type("zzz")
    assert.are.same({}, VisibleKeys())
    assert.are.equal(
      "No items match yet. 1 item name is still loading; search by item ID to find them now.",
      EmptyMessage()
    )

    components.searchBox:SetText("")
    assert.are.equal(4, #VisibleKeys())
    assert.is_nil(EmptyMessage())
  end)

  it("requests missing names a batch per frame and finds items once their names load", function()
    setfenv(1, environment)
    for itemID = 500, 619 do
      AddItem(tostring(itemID), { lastSeen = NOW - DAY })
    end
    OpenDatabaseTab()

    local function CountRequested(first, last)
      local seen = {}
      local count = 0
      for _, itemID in ipairs(harness.requestedItemIDs) do
        if itemID >= first and itemID <= last and not seen[itemID] then
          seen[itemID] = true
          count = count + 1
        end
      end
      return count
    end

    harness.RunTimers()
    assert(CountRequested(500, 619) < 120, "spreads name requests across frames")
    harness.RunAllTimers()
    assert.are.equal(120, CountRequested(500, 619))
    assert.are.equal(1, CountRequested(400, 400))

    components.searchBox:Type("herb")
    assert.are.same({}, VisibleKeys())
    assert.are.equal(
      "No items match yet. 121 item names are still loading; search by item ID to find them now.",
      EmptyMessage()
    )

    harness.itemInfo[400] = { "Mystery Herb", "item:400", 1, 1, 1, "", "", 20, "", 4000, 10 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 400, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 501, false)
    harness.RunAllTimers()
    assert.are.same({ "400" }, VisibleKeys())
    assert.are.equal("10c", harness.PlainMoney(FindRow("400").vendorSell.text))

    components.searchBox:Type("zzz")
    assert.are.equal(
      "No items match yet. 119 item names are still loading; search by item ID to find them now.",
      EmptyMessage()
    )
  end)

  it("does not refresh a search for unrelated or unsearched name loads", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    assert.are.equal(0, #harness.timers)

    harness.itemInfo[400] = { "Mystery Herb", "item:400", 1, 1, 1, "", "", 20, "", 4000, 10 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 400, true)
    assert.are.equal(0, #harness.timers)
  end)

  it("filters by category and uncertain prices and resets both filters", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local menu = components.filterDropdown:OpenMenu()
    local categoryMenu = menu.entries[1]
    assert.are.equal("Category", categoryMenu.label)
    local labels = {}
    for _, entry in ipairs(categoryMenu.entries) do
      labels[#labels + 1] = entry.label
    end
    assert.are.same({ "All categories", "Consumable", "Tradeskill", "Weapon" }, labels)
    assert.is_true(categoryMenu.entries[1]:IsSelected())
    assert.is_false(components.filterDropdown.ResetButton.shown)

    categoryMenu.entries[3]:Pick()
    assert.are.same({ "400", "200" }, VisibleKeys())
    assert.is_true(categoryMenu.entries[3]:IsSelected())
    assert.is_true(components.filterDropdown.ResetButton.shown)

    local hideUncertain = menu.entries[2]
    assert.are.equal("Hide uncertain prices", hideUncertain.label)
    hideUncertain:Pick()
    assert.are.same({ "400" }, VisibleKeys())

    categoryMenu.entries[1]:Pick()
    assert.are.same({ "100", "400" }, VisibleKeys())

    components.filterDropdown.ResetButton:Click()
    assert.are.equal(4, #VisibleKeys())
    assert.is_false(hideUncertain:IsSelected())
  end)

  it("builds rows a few at a time and keeps showing the previous rows while a scan is read", function()
    setfenv(1, environment)
    harness.SetProfileStep(5)
    OpenDatabaseTab()
    harness.RunTimers()
    assert.are.equal("Reading the price database...", SummaryText())
    assert(harness.RunAllTimers() >= 3, "spreads the build across frames")
    assert.are.equal(4, #VisibleKeys())

    harness.marketValues["100"] = { value = 9000, scanCount = 7, isUncertain = false, reasons = {} }
    harness.ns.DatabaseIndex.Invalidate()
    assert.are.equal("4 items | Last scan: 1 hour ago | Updating...", SummaryText())
    assert.are.equal("50s 00c", harness.PlainMoney(FindRow("100").market.text))

    harness.RunAllTimers()
    assert.are.equal("4 items | Last scan: 1 hour ago", SummaryText())
    assert.are.equal("90s 00c", harness.PlainMoney(FindRow("100").market.text))
  end)

  it("waits until the tab is shown to reread a changed database", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()
    _G.ArbitrageWindow.Tabs[1]:Click()

    harness.marketValues["100"] = { value = 9000, scanCount = 7, isUncertain = false, reasons = {} }
    harness.ns.DatabaseIndex.Invalidate()
    assert.are.equal(0, #harness.timers)

    _G.ArbitrageWindow.Tabs[2]:Click()
    assert.are.equal(1, #harness.timers)
    harness.RunAllTimers()
    assert.are.equal("90s 00c", harness.PlainMoney(FindRow("100").market.text))
  end)

  it("explains an empty database", function()
    setfenv(1, environment)
    for dbKey in pairs(harness.databaseItems) do
      harness.databaseItems[dbKey] = nil
    end
    OpenDatabaseTab()
    harness.RunAllTimers()

    assert.are.equal("0 items | Last scan: unknown", SummaryText())
    assert.are.equal(
      "No Auction House scan data. Run a full scan at the Auction House to fill the database.",
      EmptyMessage()
    )
  end)
end)

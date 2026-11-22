local NewEnvironment = dofile("tests/support/Environment.lua")

describe("DatabasePanel", function()
  local DAY = 24 * 60 * 60
  local NOW = 100 * DAY
  local environment
  local harness
  local content
  local components

  local function AddItem(dbKey, item)
    harness.databaseItems[dbKey] = { days = {}, latest = item.lastSeen }
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
        keys[#keys + 1] = row.item.dbKey
      end
    end
    return keys
  end

  local function FindRow(dbKey)
    for _, row in ipairs(components.scrollBox.frames) do
      if row:IsShown() and row.item.dbKey == dbKey then
        return row
      end
    end
    error("no visible row for " .. dbKey)
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
    harness.databaseStatus.latestScan = NOW - 60 * 60

    harness.itemInfo[100] = { "Flask", "item:100", 1, 1, 1, "", "", 20, "", 1000, 250 }
    harness.itemInfo[200] = { "Iron Bar", "item:200", 1, 1, 1, "", "", 20, "", 2000, 0 }
    harness.itemInfo[300] = { "Sword", "item:300", 2, 1, 1, "", "", 1, "", 3000, 500 }
    harness.itemInfo["item:300::::::::1:1485:::1:12722"] =
      { "Sword of the Bear", "item:300::::::::1:1485:::1:12722", 2, 1, 1, "", "", 1, "", 3000, 500 }
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
    AddItem("equip:300:12722", { lastSeen = NOW - 20 * DAY })
    -- The client has not loaded this item's name yet.
    AddItem("400", {
      lastSeen = NOW - 60 * 60,
      market = { value = 900, scanCount = 4, isUncertain = false, reasons = {} },
    })
    harness.craftingCosts[100] = { cost = 4321.4, isUncertain = false, reasons = {}, leaves = {} }
    harness.craftingCosts[200] = { isUnknown = true }
    harness.craftingCosts[400] = { cost = 7510.6, isUncertain = true, reasons = { "limited days" }, leaves = {} }
  end)

  it("puts the tab's name in the control row and starts the table at the top of the panel", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    local heading
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.parent == content and fontString.template == "GameFontNormalLarge" then
        heading = fontString
      end
    end
    assert.are.equal("Database", assert(heading, "titles the panel").text)
    assert.are.equal(environment.ArbitrageWindow.Tabs[2].text, heading.text)
    -- The control row is 22 pixels tall from 38 below the window's top, so its middle is at 49.
    assert.are.same({ "LEFT", environment.ArbitrageWindow, "TOPLEFT", 66, -49 }, heading.points[1])
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 16, -4 }, components.tableBackground.points[1])
  end)

  it("reads the database in the background and lists every stored item, priciest first", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    assert.are.equal("Reading the price database...", EmptyMessage())
    assert.are.same({}, VisibleKeys())

    harness.RunAllTimers()
    assert.are.same({ "100", "400", "200", "equip:300:12722" }, VisibleKeys())
    assert.is_nil(EmptyMessage())
    assert.is_true(components.headers["Market Value"].Arrow.shown)
  end)

  it("reads the database as long each frame as Scan Work Per Frame allows", function()
    setfenv(1, environment)
    for itemID = 501, 520 do
      AddItem(tostring(itemID), { lastSeen = NOW })
    end
    harness.SetProfileStep(1)
    -- A read after the first keeps showing the old rows, so this waits for new ones.
    local function FramesToRead()
      local previous = harness.ns.DatabaseIndex.Get().rows
      local frames = 0
      repeat
        harness.RunTimers()
        frames = frames + 1
        assert(frames < 100, "the read finishes")
      until harness.ns.DatabaseIndex.Get().rows ~= previous
      return frames
    end

    ARBITRAGE_CONFIG.scanWorkBudget = 4
    OpenDatabaseTab()
    local slowFrames = FramesToRead()
    ARBITRAGE_CONFIG.scanWorkBudget = 20
    harness.ns.DatabaseIndex.Invalidate()
    local fastFrames = FramesToRead()
    assert.is_true(fastFrames < slowFrames, fastFrames .. " frames at 20 ms, " .. slowFrames .. " at 4 ms")
  end)

  it("hides grey historical items, including ones whose quality loads later", function()
    setfenv(1, environment)
    harness.itemInfo[100][3] = 0
    OpenDatabaseTab()
    harness.RunAllTimers()
    assert.are.same({ "400", "200", "equip:300:12722" }, VisibleKeys())

    harness.itemInfo[400] = { "Junk", "item:400", 0 }
    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 400, true)
    harness.RunAllTimers()
    assert.are.same({ "200", "equip:300:12722" }, VisibleKeys())
  end)

  it("gathers the refreshes for items that load in the background", function()
    setfenv(1, environment)
    AddItem("401", { lastSeen = NOW })
    AddItem("402", { lastSeen = NOW })
    OpenDatabaseTab()
    harness.RunAllTimers()
    local Refresh, refreshes = harness.ns.DatabasePanel.Refresh, 0
    harness.ns.DatabasePanel.Refresh = function(...)
      refreshes = refreshes + 1
      return Refresh(...)
    end

    for _, itemID in ipairs({ 401, 402 }) do
      harness.itemInfo[itemID] = { "Junk", "item:" .. itemID, 0 }
      harness.FireEvent("ITEM_DATA_LOAD_RESULT", itemID, true)
      harness.RunTimers()
    end
    assert.are.equal(0, refreshes)
    harness.RunAllTimers()
    assert.are.equal(1, refreshes)
    assert.are.same({ "100", "400", "200", "equip:300:12722" }, VisibleKeys())
  end)

  it("leaves the rows alone when a refresh changes nothing shown", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()
    local SetDataProvider, redraws = components.scrollBox.SetDataProvider, 0
    components.scrollBox.SetDataProvider = function(...)
      redraws = redraws + 1
      return SetDataProvider(...)
    end

    harness.ns.DatabasePanel.Refresh(true)
    assert.are.equal(0, redraws)
    components.searchBox:Type("flask")
    assert.are.equal(1, redraws)
    assert.are.same({ "100" }, VisibleKeys())
  end)

  it("refreshes when gear stats finish only for a Stats filter", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    repeat
      harness.RunTimers()
    until harness.ns.DatabaseIndex.Get().rows
    local Refresh, refreshes = harness.ns.DatabasePanel.Refresh, 0
    harness.ns.DatabasePanel.Refresh = function(...)
      refreshes = refreshes + 1
      return Refresh(...)
    end

    harness.RunAllTimers()
    assert.are.equal(0, refreshes)
  end)

  it("keeps an item's name and icon on a redraw while the client briefly has no data for it", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()
    harness.itemInfo[100] = nil

    components.searchBox:Type("fla")
    local flask = FindRow("100")
    assert.are.equal("Flask", flask.itemName.text)
    assert.are.equal(1000, flask.icon.texture)
  end)

  it("refreshes for an item that loads as grey once a row shows it", function()
    setfenv(1, environment)
    -- More items than rows on screen, all priced above the grey one, which sorts to the bottom.
    for itemID = 501, 520 do
      AddItem(tostring(itemID), {
        lastSeen = NOW,
        market = { value = itemID * 100, scanCount = 5, isUncertain = false, reasons = {} },
      })
    end
    AddItem("401", { lastSeen = NOW })
    OpenDatabaseTab()
    harness.RunAllTimers()
    local Refresh, refreshes = harness.ns.DatabasePanel.Refresh, 0
    harness.ns.DatabasePanel.Refresh = function(...)
      refreshes = refreshes + 1
      return Refresh(...)
    end

    harness.itemInfo[401] = { "Junk", "item:401", 0 }
    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 401, true)
    harness.RunAllTimers()
    assert.are.equal(0, refreshes)

    local function ShowsGreyItem()
      for _, dbKey in ipairs(VisibleKeys()) do
        if dbKey == "401" then
          return true
        end
      end
      return false
    end
    components.scrollBox:SetScrollOffset(9)
    assert.is_true(ShowsGreyItem())
    harness.RunAllTimers()
    assert.are.equal(1, refreshes)
    assert.is_false(ShowsGreyItem())
  end)

  it("hides an item that loads as grey after the read without sorting the table again", function()
    setfenv(1, environment)
    local sort, rowSorts = table.sort, 0
    environment.table = setmetatable({
      sort = function(list, ...)
        if type(list[1]) == "table" and list[1].dbKey then
          rowSorts = rowSorts + 1
        end
        return sort(list, ...)
      end,
    }, { __index = table })
    OpenDatabaseTab()
    harness.RunAllTimers()
    assert.are.equal(1, rowSorts)

    harness.itemInfo[400] = { "Junk", "item:400", 0 }
    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 400, true)
    harness.RunAllTimers()
    assert.are.same({ "100", "200", "equip:300:12722" }, VisibleKeys())
    assert.are.equal(1, rowSorts)
  end)

  it("drops a grey item that loads mid-read without starting the read over", function()
    setfenv(1, environment)
    local reads = 0
    local GetItemKeys = harness.ns.Database.GetItemKeys
    harness.ns.Database.GetItemKeys = function()
      reads = reads + 1
      return GetItemKeys()
    end
    harness.SetProfileStep(10)
    OpenDatabaseTab()
    -- One row a frame: 100, 200, then 400, which waits on item data.
    harness.RunTimers()
    harness.RunTimers()
    harness.RunTimers()
    assert.are.equal("Reading the price database...", EmptyMessage())

    harness.itemInfo[400] = { "Junk", "item:400", 0 }
    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 400, true)
    harness.RunAllTimers()
    assert.are.equal(1, reads)
    assert.are.same({ "100", "200", "equip:300:12722" }, VisibleKeys())
  end)

  it("shows every price column with explicit missing values and yellow uncertain prices", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local explanations = {
      ["Market Value"] = "Typical price over the last 14 days; recent days count more. Yellow values have limited, stale, or volatile data.",
      ["Buyout"] = "Cheapest listing in the latest scan, per item. Blank when it wasn't listed.",
      ["Craft Cost"] = "Cheapest way to make one at Market Value with your characters' recipes, including unlimited-stock vendors and intermediate crafts. Blank when no known recipe makes it; ? when a material has no price.",
      ["Last Seen"] = "When a scan last listed this item. Scans older than 30 days are discarded.",
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
    assert.are.equal("50s 00c", harness.PlainMoney(flask.marketValue.text))
    assert.are.equal(1, flask.marketValue.textColor[2])
    assert.are.equal("45s 00c", harness.PlainMoney(flask.latestBuyout.text))
    assert.are.equal("43s 21c", harness.PlainMoney(flask.craftCost.text))
    assert.are.equal(1, flask.craftCost.textColor[2])
    assert.are.equal("1 hour ago", flask.lastSeen.text)

    local ironBar = FindRow("200")
    assert.are.equal("1s 20c", harness.PlainMoney(ironBar.marketValue.text))
    assert.are.equal(0.82, ironBar.marketValue.textColor[2])
    assert.are.equal("—", ironBar.latestBuyout.text)
    assert.are.equal("?", ironBar.craftCost.text)

    local sword = FindRow("equip:300:12722")
    assert.are.equal("Sword of the Bear", sword.itemName.text)
    assert.are.same({ 0.12, 1, 0 }, sword.itemName.textColor)
    assert.are.equal("—", sword.marketValue.text)
    assert.are.equal("—", sword.craftCost.text)
    assert.are.equal("20 days ago", sword.lastSeen.text)

    local herb = FindRow("400")
    assert.are.equal("Item #400", herb.itemName.text)
    assert.are.same({ 1, 1, 1 }, herb.itemName.textColor)

    -- A reused row drops the previous item's rarity color.
    components.searchBox:Type("bear")
    local row = components.scrollBox.frames[1]
    assert.are.same({ 0.12, 1, 0 }, row.itemName.textColor)
    components.searchBox:Type("400")
    assert.are.equal(row, components.scrollBox.frames[1])
    assert.are.same({ 1, 1, 1 }, row.itemName.textColor)
    assert.are.equal("75s 11c", harness.PlainMoney(herb.craftCost.text))
    assert.are.equal(0.82, herb.craftCost.textColor[2])
  end)

  it("sorts craftable items by crafting cost ahead of items nothing known can make", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    components.headers["Craft Cost"]:Click()
    assert.are.same({ "400", "100", "200", "equip:300:12722" }, VisibleKeys())
    components.headers["Craft Cost"]:Click()
    assert.are.same({ "100", "400", "200", "equip:300:12722" }, VisibleKeys())
  end)

  it("lists random-suffix variants instead of the base item that blends them all", function()
    setfenv(1, environment)
    -- Every scan of a variant also prices the base item ID.
    AddItem("300", { lastSeen = NOW - 20 * DAY, market = { value = 999999, scanCount = 9, isUncertain = false } })
    OpenDatabaseTab()
    harness.RunAllTimers()

    assert.are.same({ "100", "400", "200", "equip:300:12722" }, VisibleKeys())
  end)

  it("shows the item's own tooltip and explains uncertain prices on hover", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local sword = FindRow("equip:300:12722")
    sword.scripts.OnEnter(sword)
    assert.are.equal("item:300::::::::1:1485:::1:12722", GameTooltip.hyperlink)
    sword.scripts.OnLeave(sword)

    local ironBar = FindRow("200")
    ironBar.scripts.OnEnter(ironBar)
    assert.are.equal("item:200", GameTooltip.hyperlink)
    assert.are.equal("Estimate: limited scans", harness.tooltipLines[#harness.tooltipLines])
    ironBar.scripts.OnLeave(ironBar)

    local herb = FindRow("400")
    herb.scripts.OnEnter(herb)
    assert.are.equal("Craft Cost estimate: limited days", harness.tooltipLines[#harness.tooltipLines])
  end)

  it("searches item names regardless of case and matches item IDs", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    components.searchBox:Type("FLA")
    assert.are.same({ "100" }, VisibleKeys())

    components.searchBox:Type(" bear ")
    assert.are.same({ "equip:300:12722" }, VisibleKeys())

    components.searchBox:Type("200")
    assert.are.same({ "200" }, VisibleKeys())

    components.searchBox:Type("400")
    assert.are.same({ "400" }, VisibleKeys())

    components.searchBox:Type("zzz")
    assert.are.same({}, VisibleKeys())
    assert.are.equal("No items match the current search and filters.", EmptyMessage())

    components.searchBox:SetText("")
    assert.are.equal(4, #VisibleKeys())
    assert.is_nil(EmptyMessage())
  end)

  it("filters and searches without sorting the list again", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local sort = table.sort
    local sorts = 0
    environment.table = setmetatable({
      sort = function(...)
        sorts = sorts + 1
        return sort(...)
      end,
    }, { __index = table })

    components.searchBox:Type("fla")
    components.searchBox:Type("")
    harness.ns.DatabasePanel.Refresh()
    assert.are.equal(0, sorts)

    components.headers["Craft Cost"]:Click()
    assert.are.equal(1, sorts)
    environment.table = nil
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

    harness.itemInfo[400] = { "Mystery Herb", "item:400", 1, 1, 1, "", "", 20, "", 4000 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 400, true)
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 501, false)
    harness.RunAllTimers()
    assert.are.same({ "400" }, VisibleKeys())
    assert.are.equal("Mystery Herb", FindRow("400").itemName.text)
  end)

  it("adds stored fish to the active name search when requested item data loads", function()
    setfenv(1, environment)
    harness.itemInfo[6289] = { "Raw Longjaw Mud Snapper", "item:6289", 1, 1, 1 }
    AddItem("6289", { lastSeen = NOW, latestBuyout = 10 })
    AddItem("6308", { lastSeen = NOW, latestBuyout = 20 })
    OpenDatabaseTab()
    harness.RunAllTimers()

    components.searchBox:Type("6308")
    assert.are.equal("Item #6308", FindRow("6308").itemName.text)
    components.searchBox:Type("raw")
    assert.are.same({ "6289" }, VisibleKeys())

    harness.itemInfo[6308] = { "Raw Bristle Whisker Catfish", "item:6308", 1, 1, 1 }
    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 6308, true)
    harness.RunAllTimers()
    assert.are.same({ "6289", "6308" }, VisibleKeys())
    assert.are.equal("Raw Bristle Whisker Catfish", FindRow("6308").itemName.text)
  end)

  it("keeps waiting for a name if a notification arrives before the name is available", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()
    components.searchBox:Type("herb")

    harness.FireEvent("ITEM_DATA_LOAD_RESULT", 400, true)
    harness.RunAllTimers()
    assert.are.same({}, VisibleKeys())

    harness.itemInfo[400] = { "Mystery Herb", "item:400", 1, 1, 1, "", "", 20, "", 4000 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 400, true)
    harness.RunAllTimers()
    assert.are.same({ "400" }, VisibleKeys())
  end)

  it("asks again for names still missing when the database is reread", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    local function CountRequests()
      local count = 0
      for _, itemID in ipairs(harness.requestedItemIDs) do
        count = count + (itemID == 400 and 1 or 0)
      end
      return count
    end
    local before = CountRequests()
    harness.ns.DatabaseIndex.Invalidate()
    harness.RunAllTimers()
    assert.are.equal(before + 1, CountRequests())
  end)

  it("does not refresh a search for unrelated or unsearched name loads", function()
    setfenv(1, environment)
    OpenDatabaseTab()
    harness.RunAllTimers()

    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
    assert.are.equal(0, #harness.timers)

    harness.itemInfo[400] = { "Mystery Herb", "item:400", 1, 1, 1, "", "", 20, "", 4000 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 400, true)
    assert.are.equal(0, #harness.timers)
  end)

  it("builds rows a few at a time and keeps showing the previous rows while a scan is read", function()
    setfenv(1, environment)
    harness.SetProfileStep(10)
    OpenDatabaseTab()
    harness.RunTimers()
    assert.are.equal("Reading the price database...", EmptyMessage())
    assert(harness.RunAllTimers() >= 3, "spreads the build across frames")
    assert.are.equal(4, #VisibleKeys())

    harness.marketValues["100"] = { value = 9000, scanCount = 7, isUncertain = false, reasons = {} }
    harness.ns.DatabaseIndex.Invalidate()
    assert.are.equal("50s 00c", harness.PlainMoney(FindRow("100").marketValue.text))

    harness.RunAllTimers()
    assert.are.equal("90s 00c", harness.PlainMoney(FindRow("100").marketValue.text))
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
    harness.RunAllTimers()
    assert.are.equal("90s 00c", harness.PlainMoney(FindRow("100").marketValue.text))
  end)

  it("explains an empty database", function()
    setfenv(1, environment)
    for dbKey in pairs(harness.databaseItems) do
      harness.databaseItems[dbKey] = nil
    end
    harness.databaseStatus.latestScan = nil
    OpenDatabaseTab()
    harness.RunAllTimers()

    assert.are.equal(
      "No Auction House scan data. Run a full scan at the Auction House to fill the database.",
      EmptyMessage()
    )
  end)
end)

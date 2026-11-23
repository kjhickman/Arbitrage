local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Database", function()
  local DAY = 24 * 60 * 60
  local HOUR = 60 * 60
  local VALUES = { marketValue = 1, buyout = 2, quantity = 3, auctions = 4 }
  local environment
  local ns, faction, realm

  local function LoadDatabase()
    setfenv(1, environment)
    ns = {}
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
    assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
    assert(loadfile("src/Database.lua"), "loads Database.lua")("Arbitrage", ns)
    ns.Database.Init()
  end

  -- The summed value and number of scans the view holds for the day of a timestamp: its market
  -- value unless another value is named.
  local function Day(dbKey, timestamp, value)
    local history = ns.Database.Get(dbKey)
    if not history then
      return nil
    end
    local day = math.floor(timestamp / DAY)
    for index = 2, #history, 5 do
      if history[index] == day then
        local packed = history[index + VALUES[value or "marketValue"]]
        if packed > 0 then
          return ns.Database.UnpackDay(packed)
        end
        return nil
      end
    end
  end

  -- A scan's columns from maps of each value by key; keys any map names are listed.
  local function Columns(values, buyouts, quantities, auctions)
    local keys, seen = {}, {}
    for _, map in ipairs({ values or {}, buyouts or {}, quantities or {}, auctions or {} }) do
      for key in pairs(map) do
        if not seen[key] then
          seen[key] = true
          keys[#keys + 1] = key
        end
      end
    end
    table.sort(keys)
    local columns = { keys = keys }
    for name, map in pairs({ marketValues = values, buyouts = buyouts, quantities = quantities, auctions = auctions }) do
      columns[name] = {}
      for index, key in ipairs(keys) do
        columns[name][index] = map[key] or 0
      end
    end
    return columns
  end

  local function SaveScan(values, at, buyouts, checkpoint)
    return ns.Database.SaveScan(Columns(values, buyouts or {}), at, checkpoint)
  end

  local function SaveQuickScan(buyouts, at, quantities)
    return ns.Database.SaveQuickScan(buyouts, quantities or {}, at)
  end

  local function SavedMarket(name)
    setfenv(1, environment)
    return ARBITRAGE_DATABASE.realms[realm].markets[name or faction]
  end

  -- What the account saved for one scan: its kind, and each key's values in column order.
  local function Saved(at, market)
    setfenv(1, environment)
    local scan = (market or SavedMarket()).scans[at]
    if not scan then
      return nil
    end
    local values = {}
    for index = 1, #scan do
      local lines = {}
      for line in scan[index]:gmatch("[^\n]+") do
        lines[#lines + 1] = line
      end
      local columns = {}
      for position = 2, #lines do
        local name, list = lines[position]:match("^(%a+)=(.*)$")
        columns[name] = {}
        for value in list:gmatch("[^,]+") do
          columns[name][#columns[name] + 1] = tonumber(value)
        end
      end
      local position = 0
      for key in lines[1]:gmatch("[^,]+") do
        position = position + 1
        values[key] = {}
        for column, name in ipairs({ "marketValues", "buyouts", "quantities", "auctions" }) do
          values[key][column] = columns[name] and columns[name][position] or nil
        end
      end
    end
    return { kind = scan.kind, pieces = #scan, values = values }
  end

  -- A version 4 import holding one market of the test realm.
  local function Import(market, extra)
    market.meta = market.meta or {}
    market.items = market.items or {}
    market.scans = market.scans or {}
    market.quickScans = market.quickScans or {}
    local import = {
      __version = 4,
      meta = {},
      realms = { [realm] = { region = 1, markets = { [faction] = market }, vendorPrices = {} } },
      regions = {},
    }
    for key, value in pairs(extra or {}) do
      import[key] = value
    end
    return import
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = nil
    ARBITRAGE_GREY_ITEMS = nil
    faction = "Alliance"
    realm = "Test Realm"

    function GetRealmName()
      return realm
    end

    function RegionalUniqueNamesEnabled()
      return false
    end

    function GetCurrentRegion()
      return 1
    end

    function time()
      return 100
    end

    function UnitFactionGroup()
      return faction
    end

    LoadDatabase()
  end)

  it("initializes versioned realm metadata and the active faction market", function()
    setfenv(1, environment)
    assert(ARBITRAGE_DATABASE.__version == 3, "initializes database version 3")
    assert(type(ARBITRAGE_DATABASE.meta) == "table", "initializes root metadata")
    assert(type(ARBITRAGE_DATABASE.realms[realm]) == "table", "stores realms under the root realm table")
    assert(ARBITRAGE_DATABASE.realms[realm].region == 1, "records the region on the realm")
    assert(SavedMarket().meta.lastPlayed == 100, "stamps when the faction market was last played")
    assert.are.same({}, SavedMarket().scans)
  end)

  it("lists the keys of every stored item in the active market", function()
    setfenv(1, environment)
    assert.are.same({}, ns.Database.GetItemKeys())
    SaveScan({ ["123"] = 50, ["equip:123:-35"] = 45 }, 100)
    local keys = ns.Database.GetItemKeys()
    table.sort(keys)
    assert.are.same({ "123", "equip:123:-35" }, keys)

    faction = "Horde"
    ns.Database.Init()
    assert.are.same({}, ns.Database.GetItemKeys())
  end)

  it("saves the account's full scans with every value, and suffix-specific latest buyouts", function()
    setfenv(1, environment)
    local columns = Columns(
      { ["123"] = 50, ["4306"] = 70 },
      { ["123"] = 60, ["equip:123:-35"] = 40 },
      { ["123"] = 12, ["equip:123:-35"] = 1 },
      { ["123"] = 3, ["equip:123:-35"] = 1 }
    )
    assert.are.equal(2, ns.Database.SaveScan(columns, 100), "counts the items with a market value")

    assert(ns.Database.GetLatestBuyout("equip:123:-35") == 40, "gets a suffix-specific minimum buyout")
    assert(ns.Database.GetLatestBuyout(123) == 60, "accepts numeric item IDs")
    assert.are.same({
      kind = "full",
      pieces = 1,
      values = {
        ["123"] = { 50, 60, 12, 3 },
        ["4306"] = { 70, 0, 0, 0 },
        ["equip:123:-35"] = { 0, 40, 1, 1 },
      },
    }, Saved(100))
    assert.are.same({ 12, 1 }, { Day("123", 100, "quantity") })
    assert.are.same({ 3, 1 }, { Day("123", 100, "auctions") })
    assert.is_nil(Day("equip:123:-35", 100), "a scan without a market value for the item adds none")
  end)

  it("reads its own saved scans back after a reload, and splits a large scan into pieces", function()
    setfenv(1, environment)
    local values, buyouts = {}, {}
    for index = 1, 20001 do
      values[tostring(index)], buyouts[tostring(index)] = index, index + 1
    end
    SaveScan(values, 100, buyouts)
    assert.are.equal(2, Saved(100).pieces, "writes a large scan a piece at a time")
    local firstLine = SavedMarket().scans[100][1]:match("^[^\n]+")
    assert.are.equal(19999, select(2, firstLine:gsub(",", ",")), "lists a piece's keys on its first line")

    LoadDatabase()
    assert.are.same({ 20001, 1 }, { Day("20001", 100) })
    assert.are.same({ 3, 1 }, { Day("2", 100, "buyout") })
    assert.are.equal(20002, ns.Database.GetLatestBuyout(20001))
    assert.are.equal(20001, ns.Database.GetStatus().itemCount)
  end)

  it("reads an item's quality from the client once it has loaded, and only once", function()
    setfenv(1, environment)
    SaveScan({ ["123"] = 50, ["124"] = 90 }, 100, { ["123"] = 60, ["equip:123:7"] = 55, ["124"] = 100 })
    Enum = { ItemQuality = { Poor = 0 } }
    local isCached, reads = false, {}
    C_Item = {
      IsItemDataCachedByID = function()
        return isCached
      end,
      GetItemInfo = function(itemID)
        reads[itemID] = (reads[itemID] or 0) + 1
        return "Item", nil, itemID == 123 and 0 or 1
      end,
    }
    -- Until the item loads, its quality is unknown, so it and its variants keep their prices.
    assert.are.equal(60, ns.Database.GetLatestBuyout(123))
    assert.are.equal(55, ns.Database.GetLatestBuyout("equip:123:7"))
    isCached = true
    assert.is_nil(ns.Database.Get(123))
    assert.is_nil(ns.Database.GetLatestBuyout(123))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:123:7"))
    assert.is_nil(ns.Database.Get(123))
    assert.are.equal(100, ns.Database.GetLatestBuyout(124))
    assert.are.equal(100, ns.Database.GetLatestBuyout(124))
    assert.are.same({ [123] = 1, [124] = 1 }, reads)
  end)

  it("remembers grey items across sessions and drops their prices before they load", function()
    setfenv(1, environment)
    SaveScan({ ["123"] = 50, ["124"] = 90, ["125"] = 70 }, 100, { ["123"] = 60, ["equip:123:7"] = 55, ["124"] = 100 })
    Enum = { ItemQuality = { Poor = 0 } }
    C_Item = {
      IsItemDataCachedByID = function(itemID)
        return itemID == 123
      end,
      GetItemInfo = function()
        return "Junk", nil, 0
      end,
    }
    assert.is_true(ns.Database.IsIgnoredItem(123))
    ns.Database.RecordGreyItem(125)

    -- The next session, before the client has loaded either item.
    C_Item.IsItemDataCachedByID = function()
      return false
    end
    LoadDatabase()
    assert.is_nil(ns.Database.Get(123))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:123:7"))
    assert.is_nil(ns.Database.Get(125))
    assert.are.equal(100, ns.Database.GetLatestBuyout(124))
  end)

  it("adds each day's scans into exact totals, even at thousands of gold", function()
    setfenv(1, environment)
    local price = 99990000 -- 9,999 gold
    SaveScan({ ["123"] = price }, 100)
    SaveScan({ ["123"] = price - 1 }, 200)
    SaveScan({ ["123"] = price + 1 }, 300)
    SaveScan({ ["123"] = 7 }, DAY + 100)

    assert.are.same({ 3 * price, 3 }, { Day("123", 100) })
    assert.are.same({ 7, 1 }, { Day("123", DAY + 100) })
    assert.are.equal(DAY + 100, ns.Database.Get("123")[1])
  end)

  it("keeps an item's days in order, and its list no longer than its days", function()
    setfenv(1, environment)
    function time()
      return 20 * DAY
    end
    SaveScan({ ["123"] = 100 }, 10 * DAY)
    SaveScan({ ["123"] = 70 }, 7 * DAY)
    SaveScan({ ["123"] = 90 }, 9 * DAY)
    SaveScan({ ["123"] = 110 }, 11 * DAY)

    local history = ns.Database.Get("123")
    assert.are.same(
      { 11 * DAY, 7, 70 * 1024 + 1, 0, 0, 0, 9, 90 * 1024 + 1, 0, 0, 0, 10, 100 * 1024 + 1, 0, 0, 0 },
      { unpack(history, 1, 16) }
    )
    assert.are.equal(21, #history)
    assert.are.equal(11, history[17])
  end)

  it("adds a quick scan's buyouts and units to history and covers item IDs, keeping the full scan", function()
    setfenv(1, environment)
    ns.Database.RecordReplicateScan(95)
    SaveScan({ ["2589"] = 500, ["4306"] = 700 }, 100, {
      ["2589"] = 450,
      ["4306"] = 650,
      ["999"] = 45,
      ["equip:999:12720"] = 50,
    })
    local history = ns.Database.Get(2589)
    assert.is_true(SaveQuickScan({ ["2589"] = 300, ["123"] = 15 }, 120, { ["2589"] = 7, ["123"] = 2 }))

    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))
    assert.is_nil(ns.Database.GetLatestBuyout(4306), "an absent, covered item has no current buyout")
    assert.is_nil(ns.Database.GetLatestBuyout(999), "a quick scan covers gear by item ID")
    assert.are.equal(50, ns.Database.GetLatestBuyout("equip:999:12720"), "gear variants keep the full scan")
    assert.are.equal(15, ns.Database.GetLatestBuyout(123))
    assert.are.same({ 450 + 300, 2 }, { Day("2589", 120, "buyout") })
    assert.are.same({ 7, 1 }, { Day("2589", 120, "quantity") })
    assert.are.same({ 500, 1 }, { Day("2589", 120) }, "a quick scan adds no market value")
    assert.is_nil(Day("123", 120), "a quick scan's item has no market value")
    assert.are.same({ 15, 1 }, { Day("123", 120, "buyout") })
    assert.are.equal(history, ns.Database.Get(2589))
    assert.are.equal(450, Saved(100).values["2589"][2], "keeps the full scan's saved buyouts")
    assert.are.same(
      { kind = "quick", pieces = 1, values = { ["123"] = { nil, 15, 2 }, ["2589"] = { nil, 300, 7 } } },
      Saved(120)
    )
    assert.are.equal(95, ns.Database.GetLastReplicateScan())
    assert.are.equal(120, ns.Database.GetLastSeen(2589), "a Buyout counts as a scan of the item")
    assert.are.equal(100, ns.Database.GetLastSeen(4306), "a quick scan without the item keeps its history")
    assert.are.equal(120, ns.Database.GetLastSeen(123))
    assert.is_nil(ns.Database.GetLastSeen(555))
    assert.are.same(
      { itemCount = 5, latestScan = 100, latestQuickScan = 120, recentScanCount = 1 },
      ns.Database.GetStatus()
    )
    assert.is_false(SaveQuickScan({}, 110))
    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))

    SaveScan({ ["2589"] = 500 }, 130, { ["2589"] = 465 })
    assert.are.equal(465, ns.Database.GetLatestBuyout(2589))
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan, "remembers the quick scan after a full scan")
    assert.is_nil(ns.Database.GetLatestBuyout(123))
    ns.Database.Init()
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan, "and after a reload")
    assert.is_nil(ns.Database.GetLatestBuyout(123))
    assert.are.same({ 450 + 300 + 465, 3 }, { Day("2589", 120, "buyout") }, "and reads it back into history")
  end)

  it("saves a quick scan before the view takes it whole, perhaps a frame later", function()
    setfenv(1, environment)
    SaveScan({ ["2589"] = 500 }, 100, { ["2589"] = 450 })
    local worker = coroutine.create(function()
      return ns.Database.SaveQuickScan({ ["2589"] = 300 }, { ["2589"] = 4 }, 120, coroutine.yield)
    end)

    assert(coroutine.resume(worker))
    assert.are.equal("quick", Saved(120).kind)
    assert.are.equal(450, ns.Database.GetLatestBuyout(2589))
    assert.is_nil(Day("2589", 120, "quantity"))
    local resumed, saved = coroutine.resume(worker)
    assert(resumed, saved)
    assert.is_true(saved)
    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))
    assert.are.same({ 4, 1 }, { Day("2589", 120, "quantity") })
  end)

  it("keeps the newest quick scan of each hour, at most 48, from the last fourteen days", function()
    setfenv(1, environment)
    local now = 100 * DAY
    function time()
      return now
    end
    LoadDatabase()
    local start = now - 60 * HOUR
    SaveQuickScan({ ["2589"] = 9 }, start - 13 * DAY)
    for hour = 0, 59 do
      SaveQuickScan({ ["2589"] = 10 }, start + hour * HOUR + 60)
      SaveQuickScan({ ["2589"] = 11 }, start + hour * HOUR + 120)
    end

    local kept = {}
    for at, scan in pairs(SavedMarket().scans) do
      assert.are.equal("quick", scan.kind)
      kept[#kept + 1] = at
    end
    table.sort(kept)
    assert.are.equal(48, #kept)
    assert.are.equal(start + 12 * HOUR + 120, kept[1], "drops the oldest hours past 48")
    assert.are.equal(start + 59 * HOUR + 120, kept[48])

    SaveQuickScan({ ["2589"] = 12 }, now + 15 * DAY)
    assert.are.same(
      { now + 15 * DAY },
      (function()
        local times = {}
        for at in pairs(SavedMarket().scans) do
          times[#times + 1] = at
        end
        return times
      end)(),
      "drops quick scans from before the window"
    )
  end)

  it("restores a quick scan only for its realm and faction, and only over older full buyouts", function()
    setfenv(1, environment)
    SaveScan({ ["2589"] = 510 }, 100, { ["2589"] = 450 })
    SaveQuickScan({ ["2589"] = 300 }, 120)
    faction = "Horde"
    ns.Database.Init()
    assert.is_nil(ns.Database.GetLatestBuyout(2589))
    faction = "Alliance"
    realm = "Another Realm"
    ns.Database.Init()
    assert.is_nil(ns.Database.GetLatestBuyout(2589))
    realm = "Test Realm"
    ns.Database.Init()
    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))

    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = 130 },
      scans = { 130 },
      buyouts = { items = { at = 130, prices = { ["2589"] = 420 } } },
    })
    ns.Database.Init()
    assert.are.equal(420, ns.Database.GetLatestBuyout(2589))
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan)
  end)

  it("lists each day's averages in the market value window, oldest first, as days age out", function()
    setfenv(1, environment)
    local now = 20 * DAY
    function time()
      return now
    end
    SaveScan({ ["123"] = 100 }, 18 * DAY + 10)
    SaveScan({ ["123"] = 201 }, 18 * DAY + 20)
    SaveScan({ ["123"] = 90 }, 10 * DAY)
    SaveScan({ ["123"] = 70 }, 7 * DAY)
    SaveQuickScan({ ["123"] = 60 }, 19 * DAY)

    assert.are.same({
      { day = 7, value = 70, count = 1 },
      { day = 10, value = 90, count = 1 },
      { day = 18, value = 151, count = 2 },
      { day = 19, buyout = 60, buyoutCount = 1 },
    }, ns.Database.GetDailyValues(123), "lists a day with only a quick scan's Buyout")

    now = 22 * DAY
    assert.are.same({
      { day = 10, value = 90, count = 1 },
      { day = 18, value = 151, count = 2 },
      { day = 19, buyout = 60, buyoutCount = 1 },
    }, ns.Database.GetDailyValues("123"))
    assert.are.same({}, ns.Database.GetDailyValues("555"))
  end)

  it("lists each day's Buyout, units, and auctions beside its Market Value", function()
    setfenv(1, environment)
    function time()
      return 20 * DAY
    end
    ns.Database.SaveScan(Columns({ ["123"] = 100 }, { ["123"] = 90 }, { ["123"] = 40 }, { ["123"] = 4 }), 18 * DAY)
    ns.Database.SaveScan(Columns({ ["123"] = 120 }, { ["123"] = 95 }, { ["123"] = 31 }, { ["123"] = 3 }), 18 * DAY + 60)
    SaveQuickScan({ ["123"] = 80 }, 18 * DAY + 120, { ["123"] = 20 })

    assert.are.same({
      { day = 18, value = 110, count = 2, buyout = 88, buyoutCount = 3, quantity = 30, auctions = 4 },
    }, ns.Database.GetDailyValues(123))
  end)

  it("says how many units the newest day in the window listed", function()
    setfenv(1, environment)
    local now = 20 * DAY
    function time()
      return now
    end
    ns.Database.SaveScan(Columns({ ["123"] = 100 }, { ["123"] = 90 }, { ["123"] = 40 }, { ["123"] = 4 }), 17 * DAY)
    ns.Database.SaveScan(Columns({ ["123"] = 100 }, { ["123"] = 90 }, { ["123"] = 31 }, { ["123"] = 3 }), 18 * DAY)
    ns.Database.SaveScan(Columns({ ["123"] = 100 }, { ["123"] = 90 }), 19 * DAY)
    SaveScan({ ["4306"] = 7 }, 19 * DAY)

    assert.are.equal(31, ns.Database.GetListed(123), "skips a newer day that counted nothing")
    SaveQuickScan({ ["123"] = 80 }, 19 * DAY + 60, { ["123"] = 25 })
    assert.are.equal(25, ns.Database.GetListed("123"), "counts a quick scan's units")
    assert.is_nil(ns.Database.GetListed("4306"))
    assert.is_nil(ns.Database.GetListed("555"))

    now = 34 * DAY
    assert.is_nil(ns.Database.GetListed(123), "leaves out days past the window")
  end)

  it("replaces latest buyouts even when the next scan is empty", function()
    setfenv(1, environment)
    SaveScan({ ["123"] = 50 }, 100, { ["123"] = 60 })
    SaveScan({}, 200, {})
    assert(ns.Database.GetLatestBuyout(123) == nil, "replaces latest buyouts on every scan")
    assert.are.same({ kind = "full", pieces = 0, values = {} }, Saved(200))
  end)

  it("persists the cheapest observed vendor price", function()
    setfenv(1, environment)
    ns.Database.RecordVendorPrice(200, 10)
    ns.Database.RecordVendorPrice(200, 12)
    ns.Database.RecordVendorPrice(200, 8)
    assert(ns.Database.GetVendorPrice(200) == 8, "keeps the cheapest observed vendor price")
    assert(ns.Database.CountVendorPrices() == 1, "counts learned vendor prices")
    assert(ARBITRAGE_DATABASE.realms[realm].vendorPrices.Alliance["200"] == 8, "saves the account's vendor prices")
  end)

  it("separates faction vendor prices while sharing the account replication timestamp", function()
    setfenv(1, environment)
    ns.Database.RecordVendorPrice(200, 8)
    ns.Database.RecordReplicateScan(250)
    faction = "Horde"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by faction")
    assert(ns.Database.GetLastReplicateScan() == 250, "shares the replication time across markets")

    faction = "Alliance"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the faction")
  end)

  it("separates realm vendor prices while sharing the account replication timestamp", function()
    setfenv(1, environment)
    ns.Database.RecordVendorPrice(200, 8)
    ns.Database.RecordReplicateScan(250)
    realm = "Other Realm"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by realm")
    assert(ns.Database.GetLastReplicateScan() == 250, "shares the replication time across realms")

    realm = "Test Realm"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the realm")
    assert(ns.Database.GetLastReplicateScan() == 250, "restores the account-wide replication time")
  end)

  it("falls back to an unstamped Unknown market for an unknown faction", function()
    setfenv(1, environment)
    faction = "Unknown"
    ns.Database.Init()
    assert(type(SavedMarket("Unknown")) == "table", "falls back to the Unknown market")
    assert(SavedMarket("Unknown").meta.lastPlayed == nil, "never stamps the Unknown market")
  end)

  it("resets an invalid persisted root to an empty version 3 database", function()
    setfenv(1, environment)
    SaveScan({ ["123"] = 50 }, 100)
    ARBITRAGE_DATABASE = "invalid"
    ns.Database.Init()
    assert(ns.Database.GetStatus().itemCount == 0, "resets an invalid persisted root")
    assert(ARBITRAGE_DATABASE.__version == 3, "uses version 3 after resetting the root")
    assert(
      type(ARBITRAGE_DATABASE.meta) == "table" and type(ARBITRAGE_DATABASE.realms) == "table",
      "uses the new root shape"
    )
  end)

  it("discards version 1 scans, vendor prices, and replication metadata", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 1,
      meta = { lastReplicateScan = 250 },
      realms = {
        [realm] = {
          markets = {
            Alliance = {
              meta = { lastScan = 100 },
              items = {
                legacy = { scans = { [100] = 50 } },
              },
              latestBuyouts = { legacy = 40 },
            },
          },
          vendorPrices = { [faction] = { ["100"] = 5 } },
        },
      },
    }
    ns.Database.Init()

    assert(ARBITRAGE_DATABASE.__version == 3, "resets a version 1 database to version 3")
    assert(ns.Database.Get("legacy") == nil, "discards old scan data instead of migrating it")
    assert(ns.Database.GetVendorPrice(100) == nil, "discards old vendor data instead of migrating it")
    assert(ns.Database.GetLastReplicateScan() == nil, "discards the old cooldown timestamp")
  end)

  it("resets a malformed saved market as a unit, and drops malformed saved scans", function()
    setfenv(1, environment)
    SavedMarket().scans = nil
    ns.Database.Init()
    local reset = SavedMarket()
    assert(type(reset.meta) == "table" and type(reset.scans) == "table", "resets a malformed saved market as a unit")

    reset.scans[100] = { kind = "slow", "2589\nbuyouts=5" }
    reset.scans.later = { kind = "full" }
    reset.scans[200] = {
      kind = "full",
      "2589,4306\nmarketValues=5",
      "2590\nmarketValues=5\nnot a value",
      "2591",
      "2592,2593\nmarketValues=6,7\nfuture=1,2",
    }
    ns.Database.Init()
    assert.are.equal(
      1,
      (function()
        local count = 0
        for _ in pairs(SavedMarket().scans) do
          count = count + 1
        end
        return count
      end)(),
      "drops saved scans of an unknown kind or time"
    )
    -- Pieces whose values don't line up with their keys are skipped, and unknown values ignored.
    local keys = ns.Database.GetItemKeys()
    table.sort(keys)
    assert.are.same({ "2592", "2593" }, keys)
  end)

  it("commits time-sliced scan preparation atomically after pruning old scans", function()
    setfenv(1, environment)
    SaveScan({ legacy = 50 }, 100, { legacy = 40 })
    SaveQuickScan({ legacy = 30 }, 150)

    local saveCount
    local resumeCount = 0
    local saveWorker = coroutine.create(function()
      saveCount = SaveScan({ fresh = 75 }, 4000000, { fresh = 70 }, function()
        coroutine.yield()
      end)
    end)
    local success, message = coroutine.resume(saveWorker)
    assert(success, message)
    resumeCount = resumeCount + 1
    assert(ns.Database.Get("fresh") == nil, "does not expose partially stored scan data")
    assert(ns.Database.GetStatus().latestScan == 100, "does not expose partial scan metadata")
    assert(ns.Database.GetLatestBuyout("legacy") == 40, "does not expose partial latest buyouts")
    assert(SavedMarket().scans[4000000] == nil, "does not save a partial scan")
    while coroutine.status(saveWorker) ~= "dead" do
      success, message = coroutine.resume(saveWorker)
      assert(success, message)
      resumeCount = resumeCount + 1
    end
    assert.are.equal(1, saveCount)
    assert.are.same({ 75, 1 }, { Day("fresh", 4000000) })
    assert(ns.Database.Get("legacy") == nil, "prunes old scans in the sliced save")
    assert(ns.Database.GetLatestBuyout("fresh") == 70, "commits latest buyouts with the scan")
    assert(resumeCount > 1, "time-slices database preparation")
    assert.are.equal("full", Saved(4000000).kind, "saves the completed sliced scan")
    assert.is_nil(SavedMarket().scans[100], "prunes the old full scan")
    assert.are.equal("quick", Saved(150).kind, "leaves quick scans to their own pruning")
  end)

  it("reads imports without persisting imported scans, buyouts, or vendor prices", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = 1000 },
      scans = { 1000 },
      items = { ["2589"] = { 1000, 0, 40 * 1024 + 1, 0, 0, 0 } },
      buyouts = { items = { at = 1000, prices = { ["2589"] = 40 } } },
    })
    ARBITRAGE_IMPORT.realms[realm].vendorPrices = { Alliance = { ["2589"] = 5 } }
    ns.Database.Init()
    assert.are.same({ 40, 1 }, { Day("2589", 1000) })
    assert(ns.Database.GetLatestBuyout("2589") == 40, "reads imported latest buyouts when the saved root is missing")
    assert(ns.Database.GetVendorPrice(2589) == 5, "reads imported vendor prices when the saved root is missing")
    assert(ns.Database.GetLastReplicateScan() == nil, "keeps the replicate scan local to the account")
    assert.are.same({ "2589" }, ns.Database.GetItemKeys())
    assert(ARBITRAGE_IMPORT == nil, "releases the loaded import")
    assert.are.same({}, SavedMarket().scans, "never saves imported scans or buyouts")
    assert(
      ARBITRAGE_DATABASE.realms["Test Realm"].vendorPrices.Alliance["2589"] == nil,
      "never saves imported vendor prices"
    )
  end)

  it("reads region-wide sales from the import, by item ID", function()
    setfenv(1, environment)
    ARBITRAGE_IMPORT = Import({}, {
      regions = {
        [1] = { at = 500, items = { [2589] = { 1250, 0.412, 85.5 } } },
        [3] = { at = 500, items = { [4306] = { 1, 1, 1 } } },
      },
    })
    ns.Database.Init()

    assert.are.same({ 1250, 0.412 }, { ns.Database.GetSales(2589) })
    assert.are.same({ 1250, 0.412 }, { ns.Database.GetSales("2589") }, "by key as well as item ID")
    assert.is_nil(ns.Database.GetSales("equip:2589:12720"), "nor for a random-enchant variant")
    assert.is_nil(ns.Database.GetSales(4306), "reads only the player's region")
    assert.is_true(ns.Database.HasSales())
    ns.Database.Init()
    assert.is_nil(ns.Database.GetSales(2589), "and only while the import is loaded")
    assert.is_false(ns.Database.HasSales())
  end)

  it("ignores imports from older Companions until they update", function()
    setfenv(1, environment)
    SaveScan({ ["2589"] = 30 }, 1000, { ["2589"] = 30 })
    for _, version in ipairs({ 2, 3 }) do
      ARBITRAGE_IMPORT = {
        __version = version,
        meta = {},
        realms = {
          [realm] = {
            region = 1,
            markets = {
              Alliance = {
                meta = { lastScan = 2000 },
                items = { ["4306"] = { latest = 2000, days = { [0] = 7 * 1024 + 1 } } },
                latestBuyouts = { ["2589"] = 12 },
                scans = { 2000 },
              },
            },
            vendorPrices = { Alliance = { ["2589"] = 5 } },
          },
        },
      }
      ns.Database.Init()
      assert.are.same({ "2589" }, ns.Database.GetItemKeys())
      assert.are.equal(30, ns.Database.GetLatestBuyout(2589))
      assert.is_nil(ns.Database.GetVendorPrice(2589))
      assert.is_nil(ARBITRAGE_IMPORT)
    end
  end)

  it("reads only prices from synced Buyout lists", function()
    setfenv(1, environment)
    SaveScan({}, 1000, { ["4306"] = 60 })
    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = 2000 },
      buyouts = {
        items = { at = 2000, prices = { ["2589"] = 12, ["2590"] = {} } },
        variants = { at = 1500, prices = { ["equip:15653:12720"] = true, ["equip:15653:12721"] = 500 } },
      },
    })
    ns.Database.Init()

    assert.are.equal(12, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("2590"))
    assert.are.equal(500, ns.Database.GetLatestBuyout("equip:15653:12721"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.is_nil(ns.Database.GetLastSeen("equip:15653:12720"))

    -- The import is read once, so after another login only the saved scan is left.
    ns.Database.Init()
    assert.are.equal(60, ns.Database.GetLatestBuyout("4306"))
    assert.is_nil(ns.Database.GetLatestBuyout("2589"))
  end)

  it("takes each kind of item's Buyouts from the newest synced or saved list that sees it", function()
    setfenv(1, environment)
    local function Load(lastScan, ownBuyouts, buyouts)
      ARBITRAGE_DATABASE = nil
      ns.Database.Init()
      SaveScan({}, lastScan, ownBuyouts)
      ARBITRAGE_IMPORT = Import({ meta = { lastScan = 2000 }, buyouts = buyouts })
      ns.Database.Init()
    end
    local fullScan = { ["2589"] = 40, ["4306"] = 60, ["15653"] = 700, ["equip:15653:12720"] = 900 }

    -- TradeSkillMaster is newest, so it decides item IDs, but it never sees random-enchant gear,
    -- which the Companion keeps from the full scan by variant and item ID.
    Load(1000, fullScan, {
      items = { at = 2000, prices = { ["2589"] = 12 } },
      variants = { at = 1000, prices = { ["15653"] = 700, ["equip:15653:12720"] = 900 } },
    })
    assert.are.equal(12, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("4306"), "TradeSkillMaster saw no listing")
    assert.are.equal(700, ns.Database.GetLatestBuyout("15653"))
    assert.are.equal(900, ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.are.equal(2000, ns.Database.GetLastSeen("2589"))
    assert.are.equal(1000, ns.Database.GetLastSeen("15653"), "keeps the full scan's time")
    assert.are.equal(1000, ns.Database.GetLastSeen("equip:15653:12720"))

    -- A quick scan sees every item ID, random-enchant gear included, but no variants.
    assert.is_true(SaveQuickScan({ ["2589"] = 11 }, 3000))
    assert.are.equal(11, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("15653"), "the quick scan saw no listing")
    assert.are.equal(900, ns.Database.GetLatestBuyout("equip:15653:12720"))

    -- A newer full scan from another PC decides the variants it saw and the ones it didn't.
    Load(1000, fullScan, {
      items = { at = 2000, prices = { ["2589"] = 12 } },
      variants = { at = 1500, prices = { ["equip:15653:12721"] = 500 } },
    })
    assert.is_nil(ns.Database.GetLatestBuyout("15653"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.are.equal(500, ns.Database.GetLatestBuyout("equip:15653:12721"))

    -- The account's own full scan, once newer than everything synced, decides everything.
    SaveScan({}, 2500, { ["4306"] = 65, ["equip:15653:12720"] = 950 })
    assert.is_nil(ns.Database.GetLatestBuyout("2589"))
    assert.are.equal(65, ns.Database.GetLatestBuyout("4306"))
    assert.are.equal(950, ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12721"))
    assert.are.equal(2500, ns.Database.GetLastSeen("4306"))

    -- The synced copy of the account's own scan ties with it, and the saved one is read.
    Load(2000, { ["2589"] = 40 }, { items = { at = 2000, prices = { ["2589"] = 41 } } })
    assert.are.equal(40, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12720"))
  end)

  it("adds only the account's scans that the import does not hold", function()
    setfenv(1, environment)
    SaveScan({ ["2589"] = 40, ["4306"] = 9 }, 1000, { ["2589"] = 38 })
    SaveScan({ ["2589"] = 20 }, 3000, { ["2589"] = 18 })
    SaveQuickScan({ ["2589"] = 17 }, 3100, { ["2589"] = 5 })
    SaveQuickScan({ ["2589"] = 16 }, 3700 + HOUR, { ["2589"] = 6 })
    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = 2000 },
      scans = { 1000, 2000 },
      quickScans = { 3100 },
      items = { ["2589"] = { 3100, 0, (40 + 12) * 1024 + 2, 17 * 1024 + 1, 5 * 1024 + 1, 0 } },
      buyouts = { items = { at = 2000, prices = { ["2589"] = 11 } } },
    })
    ARBITRAGE_IMPORT.realms[realm].vendorPrices = { Alliance = { ["2589"] = 5 } }
    ns.Database.Init()

    -- Scans 1000 and 3100 came back inside the import, so only scans 3000 and 7300 are added. 4306
    -- was not in the import's copy of scan 1000, which is the copy that counts.
    assert.are.same({ 40 + 12 + 20, 3 }, { Day("2589", 1000) })
    assert.are.same({ 17 + 18 + 16, 3 }, { Day("2589", 1000, "buyout") })
    assert.are.same({ 5 + 6, 2 }, { Day("2589", 1000, "quantity") })
    assert.are.equal(3700 + HOUR, ns.Database.Get("2589")[1])
    assert.is_nil(ns.Database.Get("4306"))
    assert.are.same(
      { itemCount = 1, latestScan = 3000, latestQuickScan = 3700 + HOUR, recentScanCount = 3 },
      ns.Database.GetStatus()
    )
    assert.are.equal(16, ns.Database.GetLatestBuyout("2589"))
    assert.are.equal(5, ns.Database.GetVendorPrice(2589))
    assert.is_nil(ARBITRAGE_IMPORT)

    -- A new scan saves beside the import's, and only the account's own scans are saved.
    SaveScan({ ["2589"] = 30 }, 8000, { ["2589"] = 29 })
    assert.are.same({ 40 + 12 + 20 + 30, 4 }, { Day("2589", 8000) })
    local saved = {}
    for at in pairs(SavedMarket().scans) do
      saved[#saved + 1] = at
    end
    table.sort(saved)
    assert.are.same({ 1000, 3000, 3100, 3700 + HOUR, 8000 }, saved)
  end)

  it("keeps the import's items seen within thirty days, and reads only its window's days", function()
    setfenv(1, environment)
    local now = 100 * DAY
    function time()
      return now
    end
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = now },
      scans = { 70 * DAY - 1, 85 * DAY, 86 * DAY, now, "not a time" },
      items = {
        ["2589"] = { now, 85, 30 * 1024 + 1, 0, 0, 0, 86, 20 * 1024 + 1, 0, 0, 0, 100, 10 * 1024 + 1, 0, 0, 0 },
        ["4306"] = { 85 * DAY, 85, 7 * 1024 + 1, 0, 0, 0 },
        ["2592"] = { 70 * DAY - 1 },
        ["bad"] = "not a list",
        ["empty"] = {},
      },
    })
    ns.Database.Init()

    -- Day 86 begins fourteen days before now; the cutoff is thirty days before the last scan.
    assert.are.same(
      { { day = 86, value = 20, count = 1 }, { day = 100, value = 10, count = 1 } },
      ns.Database.GetDailyValues("2589")
    )
    assert.are.same({}, ns.Database.GetDailyValues("4306"))
    assert.are.equal(85 * DAY, ns.Database.GetLastSeen("4306"))
    assert.is_nil(ns.Database.Get("2592"))
    assert.is_nil(ns.Database.Get("bad"))
    assert.is_nil(ns.Database.Get("empty"))
    assert.are.same({ itemCount = 2, latestScan = now, recentScanCount = 2 }, ns.Database.GetStatus())
  end)

  it("prunes merged scans against the inclusive thirty-day cutoff", function()
    setfenv(1, environment)
    local lastScan = 10000000
    SaveScan({ ["2589"] = 1 }, lastScan - 31 * DAY)
    SaveScan({ ["2589"] = 2 }, lastScan - 30 * DAY)
    ARBITRAGE_IMPORT = Import({ meta = { lastScan = lastScan } })
    ns.Database.Init()
    assert.is_nil(Day("2589", lastScan - 31 * DAY))
    assert.are.same({ 2, 1 }, { Day("2589", lastScan - 30 * DAY) })
    assert.are.equal(lastScan - 30 * DAY, ns.Database.Get("2589")[1])
  end)

  it("ignores an invalid import while retaining account scans", function()
    setfenv(1, environment)
    SaveScan({ ["2589"] = 30 }, 1000, { ["2589"] = 30 })
    ARBITRAGE_IMPORT = "nope"
    ns.Database.Init()
    assert.are.same({ 30, 1 }, { Day("2589", 1000) })
  end)

  it("repairs saved sub-copper vendor prices across every faction", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 3,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {},
          vendorPrices = {
            Alliance = { ["2512"] = 0.05, ["2589"] = 5 },
            Horde = { ["2516"] = 0.05 },
          },
        },
      },
    }
    ARBITRAGE_IMPORT = nil
    ns.Database.Init()
    local savedVendorPrices = ARBITRAGE_DATABASE.realms["Test Realm"].vendorPrices
    assert(ns.Database.GetVendorPrice(2512) == 1, "rounds a saved sub-copper vendor price up to whole copper")
    assert(ns.Database.GetVendorPrice(2589) == 5, "keeps a saved whole-copper vendor price")
    assert(savedVendorPrices.Alliance["2512"] == 1, "saves the repaired vendor price")
    assert(savedVendorPrices.Horde["2516"] == 1, "repairs saved vendor prices for other factions")
  end)

  it("keys Forever databases and imports by ruleset across backend shards", function()
    setfenv(1, environment)
    Enum = {
      GameRule = {
        HardcoreRuleset = 1,
        RPRuleset = 2,
        PvPRuleset = 3,
      },
    }
    C_GameRules = {
      IsGameRuleActive = function(rule)
        return rule == Enum.GameRule.PvPRuleset
      end,
    }
    function RegionalUniqueNamesEnabled()
      return true
    end

    ARBITRAGE_DATABASE = nil
    realm = "PvP"
    ARBITRAGE_IMPORT = Import({
      meta = { lastScan = 1000 },
      scans = { 1000 },
      items = { ["2589"] = { 1000, 0, 42 * 1024 + 1, 0, 0, 0 } },
    })

    realm = "CAMWOW US2 Realm 8 PvP"
    ns.Database.Init()
    ns.Database.RecordVendorPrice(200, 8)
    assert.are.same({ 42, 1 }, { Day("2589", 1000) })

    realm = "CAMWOW US2 Realm 3 PvP"
    ns.Database.Init()
    assert.are.equal(8, ns.Database.GetVendorPrice(200))
    assert.is_table(ARBITRAGE_DATABASE.realms.PvP)
    assert.is_nil(ARBITRAGE_DATABASE.realms["CAMWOW US2 Realm 8 PvP"])
  end)

  describe("migrating version 2", function()
    local function Version2(markets, vendorPrices)
      return {
        __version = 2,
        meta = { lastReplicateScan = 95 },
        realms = { [realm] = { region = 1, markets = markets, vendorPrices = vendorPrices or {} } },
      }
    end

    it("turns each item's scans into a saved scan per time, keeping every time exactly", function()
      setfenv(1, environment)
      local now = 100 * DAY
      function time()
        return now
      end
      ARBITRAGE_DATABASE = Version2({
        Alliance = {
          meta = { lastScan = now - 3600, lastPlayed = now - 60 },
          items = {
            ["2589"] = { scans = { [now - 20 * DAY] = 10, [now - 3600] = 20 } },
            ["4306"] = { scans = { [now - 20 * DAY] = 30 } },
            ["equip:15653:12720"] = { scans = { [now - 3600] = 900 } },
          },
          latestBuyouts = { ["2589"] = 18, ["equip:15653:12720"] = 850, ["15653"] = 800, ["2590"] = "x" },
        },
        Horde = { meta = {}, items = { ["2589"] = { scans = { [now - 7200] = 12 } } }, latestBuyouts = {} },
      })
      LoadDatabase()

      assert.are.equal(3, ARBITRAGE_DATABASE.__version)
      assert.are.equal(95, ns.Database.GetLastReplicateScan())
      assert.are.same({
        kind = "full",
        pieces = 1,
        values = {
          ["2589"] = { 20, 18 },
          ["equip:15653:12720"] = { 900, 850 },
          ["15653"] = { 0, 800 },
        },
      }, Saved(now - 3600))
      assert.are.same(
        { kind = "full", pieces = 1, values = { ["2589"] = { 10 }, ["4306"] = { 30 } } },
        Saved(now - 20 * DAY)
      )
      assert.are.same(
        { kind = "full", pieces = 1, values = { ["2589"] = { 12 } } },
        Saved(now - 7200, SavedMarket("Horde"))
      )
      assert.are.equal(now, SavedMarket().meta.lastPlayed)

      -- The view reads the migrated scans as it would have read the items.
      assert.is_nil(Day("2589", now - 20 * DAY))
      assert.are.same({ 20, 1 }, { Day("2589", now - 3600) })
      assert.are.same({ now - 20 * DAY }, ns.Database.Get("4306"))
      assert.are.equal(18, ns.Database.GetLatestBuyout(2589))
      assert.are.equal(850, ns.Database.GetLatestBuyout("equip:15653:12720"))
      assert.are.same({ itemCount = 4, latestScan = now - 3600, recentScanCount = 1 }, ns.Database.GetStatus())
    end)

    it("purges grey items, their variants, and their vendor prices", function()
      setfenv(1, environment)
      ARBITRAGE_GREY_ITEMS = { [3300] = true }
      ARBITRAGE_DATABASE = Version2({
        Alliance = {
          meta = { lastScan = 100 },
          items = {
            ["2589"] = { scans = { [100] = 20 } },
            ["3300"] = { scans = { [100] = 5 } },
            ["equip:3300:7"] = { scans = { [100] = 6 } },
          },
          latestBuyouts = { ["2589"] = 18, ["3300"] = 4 },
        },
      }, { Alliance = { ["2589"] = 3, ["3300"] = 1 } })
      LoadDatabase()

      assert.are.same({ kind = "full", pieces = 1, values = { ["2589"] = { 20, 18 } } }, Saved(100))
      assert.are.same({ ["2589"] = 3 }, ARBITRAGE_DATABASE.realms[realm].vendorPrices.Alliance)
    end)
  end)
end)

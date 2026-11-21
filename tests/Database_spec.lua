local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Database", function()
  local DAY = 24 * 60 * 60
  local environment
  local ns, faction, realm

  -- The summed price and number of scans the view holds for the day of a timestamp.
  local function Day(dbKey, timestamp)
    local history = ns.Database.Get(dbKey)
    local packed = history and history.days[math.floor(timestamp / DAY)]
    if packed then
      return ns.Database.UnpackDay(packed)
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = nil
    ARBITRAGE_QUICK_BUYOUTS = nil
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

    ns = {}
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
    assert(loadfile("src/Database.lua"), "loads Database.lua")("Arbitrage", ns)
    ns.Database.Init()
  end)

  it("initializes versioned realm metadata and the active faction market", function()
    setfenv(1, environment)
    assert(ARBITRAGE_DATABASE.__version == 2, "initializes database version 2")
    assert(type(ARBITRAGE_DATABASE.meta) == "table", "initializes root metadata")
    assert(type(ARBITRAGE_DATABASE.realms[realm]) == "table", "stores realms under the root realm table")
    assert(ARBITRAGE_DATABASE.realms[realm].region == 1, "records the region on the realm")
    assert(
      ARBITRAGE_DATABASE.realms[realm].markets.Alliance.meta.lastPlayed == 100,
      "stamps when the faction market was last played"
    )
  end)

  it("lists the keys of every stored item in the active market", function()
    setfenv(1, environment)
    assert.are.same({}, ns.Database.GetItemKeys())
    ns.Database.SaveScan({ ["123"] = 50, ["equip:123:-35"] = 45 }, 100)
    local keys = ns.Database.GetItemKeys()
    table.sort(keys)
    assert.are.same({ "123", "equip:123:-35" }, keys)

    faction = "Horde"
    ns.Database.Init()
    assert.are.same({}, ns.Database.GetItemKeys())
  end)

  it("saves account scans and suffix-specific latest buyouts", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ ["123"] = 50 }, 100, {
      ["equip:123:-35"] = 40,
      ["123"] = 60,
    })
    assert(ns.Database.GetLatestBuyout("equip:123:-35") == 40, "gets a suffix-specific minimum buyout")
    assert(ns.Database.GetLatestBuyout(123) == 60, "accepts numeric item IDs")
    assert(ns.Database.GetStatus().itemCount == 1, "counts stored items in database status")
    assert(
      ARBITRAGE_DATABASE.realms[realm].markets.Alliance.items["123"].scans[100] == 50,
      "saves the account's own scan"
    )
  end)

  it("does not price grey items from stored history", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ ["123"] = 50, ["124"] = 90 }, 100, { ["123"] = 60, ["124"] = 100 })
    Enum = { ItemQuality = { Poor = 0 } }
    C_Item = {
      IsItemDataCachedByID = function()
        return true
      end,
      GetItemInfo = function(itemID)
        return "Item", nil, itemID == 123 and 0 or 1
      end,
    }
    assert.is_nil(ns.Database.Get(123))
    assert.is_nil(ns.Database.GetLatestBuyout(123))
    assert.are.equal(100, ns.Database.GetLatestBuyout(124))
  end)

  it("adds each day's scans into exact totals, even at thousands of gold", function()
    setfenv(1, environment)
    local price = 99990000 -- 9,999 gold
    ns.Database.SaveScan({ ["123"] = price }, 100)
    ns.Database.SaveScan({ ["123"] = price - 1 }, 200)
    ns.Database.SaveScan({ ["123"] = price + 1 }, 300)
    ns.Database.SaveScan({ ["123"] = 7 }, DAY + 100)

    assert.are.same({ 3 * price, 3 }, { Day("123", 100) })
    assert.are.same({ 7, 1 }, { Day("123", DAY + 100) })
    assert.are.equal(DAY + 100, ns.Database.Get("123").latest)
  end)

  it("refreshes covered buyouts without touching account scans or history", function()
    setfenv(1, environment)
    ns.Database.RecordReplicateScan(95)
    ns.Database.SaveScan({ ["2589"] = 500, ["4306"] = 700 }, 100, {
      ["2589"] = 450,
      ["4306"] = 650,
      ["999"] = 45,
      ["equip:999:12720"] = 50,
    })
    local savedMarket = ARBITRAGE_DATABASE.realms[realm].markets.Alliance
    local history = ns.Database.Get(2589)
    assert.is_true(ns.Database.SaveQuickBuyouts({ ["2589"] = 300, ["123"] = 15 }, 120))

    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))
    assert.is_nil(ns.Database.GetLatestBuyout(4306), "an absent, covered item has no current buyout")
    assert.is_nil(ns.Database.GetLatestBuyout(999), "a quick scan covers gear by item ID")
    assert.are.equal(50, ns.Database.GetLatestBuyout("equip:999:12720"), "gear variants keep the full scan")
    assert.are.equal(15, ns.Database.GetLatestBuyout(123))
    assert.is_nil(ns.Database.Get(123), "a buyout is not a Market Value history entry")
    assert.are.equal(history, ns.Database.Get(2589))
    assert.are.equal(450, savedMarket.latestBuyouts["2589"])
    assert.are.equal(100, savedMarket.meta.lastScan)
    assert.are.equal(95, ns.Database.GetLastReplicateScan())
    assert.are.equal(120, ns.Database.GetLastSeen(2589), "a Buyout counts as a scan of the item")
    assert.are.equal(100, ns.Database.GetLastSeen(4306), "a quick scan without the item keeps its history")
    assert.are.equal(120, ns.Database.GetLastSeen(123))
    assert.is_nil(ns.Database.GetLastSeen(555))
    assert.are.same(
      { itemCount = 2, latestScan = 100, latestQuickScan = 120, recentScanCount = 1 },
      ns.Database.GetStatus()
    )
    assert.is_false(ns.Database.SaveQuickBuyouts({}, 110))
    assert.are.equal(300, ns.Database.GetLatestBuyout(2589))

    ns.Database.SaveScan({ ["2589"] = 500 }, 130, { ["2589"] = 465 })
    assert.are.equal(465, ns.Database.GetLatestBuyout(2589))
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan, "remembers the quick scan after a full scan")
    assert.is_nil(ns.Database.GetLatestBuyout(123))
    ns.Database.Init()
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan, "and after a reload")
    assert.is_nil(ns.Database.GetLatestBuyout(123))
  end)

  it("restores a quick scan only for its realm and faction, and only over older full buyouts", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ ["2589"] = 510 }, 100, { ["2589"] = 450 })
    ns.Database.SaveQuickBuyouts({ ["2589"] = 300 }, 120)
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

    ARBITRAGE_IMPORT = {
      __version = 3,
      meta = {},
      realms = {
        [realm] = {
          markets = { Alliance = { meta = { lastScan = 130 }, latestBuyouts = { ["2589"] = 420 }, scans = { 130 } } },
        },
      },
    }
    ns.Database.Init()
    assert.are.equal(420, ns.Database.GetLatestBuyout(2589))
    assert.are.equal(120, ns.Database.GetStatus().latestQuickScan)
  end)

  it("keeps only the market value window as days but remembers when older items were seen", function()
    setfenv(1, environment)
    local now = 100 * DAY
    function time()
      return now
    end
    ARBITRAGE_DATABASE = {
      __version = 2,
      meta = {},
      realms = {
        [realm] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = now - 3600 },
              items = {
                ["2589"] = { scans = { [now - 20 * DAY] = 10, [now - 3600] = 20 } },
                ["4306"] = { scans = { [now - 20 * DAY] = 30 } },
              },
              latestBuyouts = {},
            },
          },
          vendorPrices = {},
        },
      },
    }
    ns.Database.Init()

    assert.is_nil(Day("2589", now - 20 * DAY))
    assert.are.same({ 20, 1 }, { Day("2589", now - 3600) })
    assert.are.same({ days = {}, latest = now - 20 * DAY }, ns.Database.Get("4306"))
    assert.are.same({ itemCount = 2, latestScan = now - 3600, recentScanCount = 1 }, ns.Database.GetStatus())
  end)

  it("replaces latest buyouts even when the next scan is empty", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ ["123"] = 50 }, 100, { ["123"] = 60 })
    ns.Database.SaveScan({}, 200, {})
    assert(ns.Database.GetLatestBuyout(123) == nil, "replaces latest buyouts on every scan")
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

  it("separates and restores vendor prices when changing factions", function()
    setfenv(1, environment)
    ns.Database.RecordVendorPrice(200, 8)
    faction = "Horde"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by faction")

    faction = "Alliance"
    ns.Database.Init()
    assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the faction")
  end)

  it("shares the account replication timestamp across faction markets", function()
    setfenv(1, environment)
    ns.Database.RecordReplicateScan(250)
    faction = "Horde"
    ns.Database.Init()
    assert(ns.Database.GetLastReplicateScan() == 250, "shares the replication time across markets")
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
    assert(type(ARBITRAGE_DATABASE.realms[realm].markets.Unknown) == "table", "falls back to the Unknown market")
    assert(ARBITRAGE_DATABASE.realms[realm].markets.Unknown.meta.lastPlayed == nil, "never stamps the Unknown market")
  end)

  it("resets an invalid persisted root to an empty version 2 database", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ ["123"] = 50 }, 100)
    ARBITRAGE_DATABASE = "invalid"
    ns.Database.Init()
    assert(ns.Database.GetStatus().itemCount == 0, "resets an invalid persisted root")
    assert(ARBITRAGE_DATABASE.__version == 2, "uses version 2 after resetting the root")
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

    assert(ARBITRAGE_DATABASE.__version == 2, "resets a version 1 database to version 2")
    assert(ns.Database.Get("legacy") == nil, "discards old scan data instead of migrating it")
    assert(ns.Database.GetVendorPrice(100) == nil, "discards old vendor data instead of migrating it")
    assert(ns.Database.GetLastReplicateScan() == nil, "discards the old cooldown timestamp")
  end)

  it("resets a malformed saved market as a unit", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE.realms[realm].markets.Alliance = { items = {} }
    ns.Database.Init()
    local reset = ARBITRAGE_DATABASE.realms[realm].markets.Alliance
    assert(
      type(reset.meta) == "table" and type(reset.latestBuyouts) == "table",
      "resets a malformed saved market as a unit"
    )
  end)

  it("commits time-sliced scan preparation atomically after pruning old scans", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ legacy = 50 }, 100, { legacy = 40 })

    local saveCount
    local resumeCount = 0
    local saveWorker = coroutine.create(function()
      saveCount = ns.Database.SaveScan({ fresh = 75 }, 4000000, { fresh = 70 }, function()
        coroutine.yield()
      end)
    end)
    local success, message = coroutine.resume(saveWorker)
    assert(success, message)
    resumeCount = resumeCount + 1
    assert.are.same({ 50, 1 }, { Day("legacy", 100) })
    assert(ns.Database.Get("fresh") == nil, "does not expose partially stored scan data")
    assert(ns.Database.GetStatus().latestScan == 100, "does not expose partial scan metadata")
    assert(ns.Database.GetLatestBuyout("legacy") == 40, "does not expose partial latest buyouts")
    assert(ARBITRAGE_DATABASE.realms[realm].markets.Alliance.items.fresh == nil, "does not save a partial scan")
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
    local savedAlliance = ARBITRAGE_DATABASE.realms[realm].markets.Alliance
    assert(
      savedAlliance.items.fresh.scans[4000000] == 75 and savedAlliance.items.legacy == nil,
      "saves the completed sliced scan"
    )
  end)

  it("reads imports without persisting imported scans, buyouts, or vendor prices", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = {
      __version = 2,
      meta = { lastReplicateScan = 50 },
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 1000 },
              items = {
                ["2589"] = { scans = { [1000] = 40 } },
              },
              latestBuyouts = { ["2589"] = 40 },
            },
          },
          vendorPrices = { Alliance = { ["2589"] = 5 } },
        },
      },
    }
    ns.Database.Init()
    assert.are.same({ 40, 1 }, { Day("2589", 1000) })
    assert(ns.Database.GetLatestBuyout("2589") == 40, "reads imported latest buyouts when the saved root is missing")
    assert(ns.Database.GetVendorPrice(2589) == 5, "reads imported vendor prices when the saved root is missing")
    assert(ns.Database.GetLastReplicateScan() == nil, "keeps the replicate scan local to the account")
    assert.are.same({ "2589" }, ns.Database.GetItemKeys())
    assert(ARBITRAGE_IMPORT == nil, "releases the loaded import")
    local ownAlliance = ARBITRAGE_DATABASE.realms["Test Realm"].markets.Alliance
    assert(ownAlliance.items["2589"] == nil, "never saves imported scans")
    assert(next(ownAlliance.latestBuyouts) == nil, "never saves imported buyouts")
    assert(
      ARBITRAGE_DATABASE.realms["Test Realm"].vendorPrices.Alliance["2589"] == nil,
      "never saves imported vendor prices"
    )
  end)

  it("takes each kind of item's Buyouts from the newest synced or saved list that sees it", function()
    setfenv(1, environment)
    local function Load(own, buyouts)
      ARBITRAGE_DATABASE = {
        __version = 2,
        meta = {},
        realms = { [realm] = { region = 1, markets = { Alliance = own }, vendorPrices = {} } },
      }
      ARBITRAGE_IMPORT = {
        __version = 3,
        meta = {},
        realms = {
          [realm] = {
            markets = {
              Alliance = { meta = { lastScan = 2000 }, items = {}, latestBuyouts = {}, buyouts = buyouts, scans = {} },
            },
          },
        },
      }
      ns.Database.Init()
    end
    local fullScan = { ["2589"] = 40, ["4306"] = 60, ["15653"] = 700, ["equip:15653:12720"] = 900 }

    -- TradeSkillMaster is newest, so it decides item IDs, but it never sees random-enchant gear,
    -- which the Companion keeps from the full scan by variant and item ID.
    Load({ meta = { lastScan = 1000 }, items = {}, latestBuyouts = fullScan }, {
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
    assert.is_true(ns.Database.SaveQuickBuyouts({ ["2589"] = 11 }, 3000))
    assert.are.equal(11, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("15653"), "the quick scan saw no listing")
    assert.are.equal(900, ns.Database.GetLatestBuyout("equip:15653:12720"))

    -- A newer full scan from another PC decides the variants it saw and the ones it didn't.
    ARBITRAGE_QUICK_BUYOUTS = nil
    Load({ meta = { lastScan = 1000 }, items = {}, latestBuyouts = fullScan }, {
      items = { at = 2000, prices = { ["2589"] = 12 } },
      variants = { at = 1500, prices = { ["equip:15653:12721"] = 500 } },
    })
    assert.is_nil(ns.Database.GetLatestBuyout("15653"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.are.equal(500, ns.Database.GetLatestBuyout("equip:15653:12721"))

    -- The account's own full scan, once newer than everything synced, decides everything.
    ns.Database.SaveScan({}, 2500, { ["4306"] = 65, ["equip:15653:12720"] = 950 })
    assert.is_nil(ns.Database.GetLatestBuyout("2589"))
    assert.are.equal(65, ns.Database.GetLatestBuyout("4306"))
    assert.are.equal(950, ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12721"))
    assert.are.equal(2500, ns.Database.GetLastSeen("4306"))

    -- The synced copy of the account's own scan ties with it, and the saved one is read.
    Load({ meta = { lastScan = 2000 }, items = {}, latestBuyouts = { ["2589"] = 40 } }, {
      items = { at = 2000, prices = { ["2589"] = 41 } },
    })
    assert.are.equal(40, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12720"))
  end)

  it("reads one synced Buyout list from older Companions", function()
    setfenv(1, environment)
    local function Market(lastScan, latestBuyouts)
      return { meta = { lastScan = lastScan }, items = {}, latestBuyouts = latestBuyouts }
    end
    local function Load(own, imported)
      ARBITRAGE_DATABASE = {
        __version = 2,
        meta = {},
        realms = { [realm] = { region = 1, markets = { Alliance = own }, vendorPrices = {} } },
      }
      ARBITRAGE_IMPORT =
        { __version = 2, meta = {}, realms = { [realm] = { region = 1, markets = { Alliance = imported } } } }
      ns.Database.Init()
    end

    -- A list without variants saw item IDs only, so the older full scan keeps its variants. These
    -- Companions don't say which item IDs are random-enchant gear, so those follow the newer list.
    Load(Market(1000, { ["2589"] = 40, ["15653"] = 700, ["equip:15653:12720"] = 900 }), Market(2000, { ["2589"] = 12 }))
    assert.are.equal(12, ns.Database.GetLatestBuyout("2589"))
    assert.is_nil(ns.Database.GetLatestBuyout("15653"))
    assert.are.equal(900, ns.Database.GetLatestBuyout("equip:15653:12720"))

    -- A newer scan that saw variants, such as one synced from another PC, replaces them all.
    Load(
      Market(1000, { ["equip:15653:12720"] = 900, ["equip:15653:12721"] = 500 }),
      Market(2000, { ["equip:15653:12720"] = 800 })
    )
    assert.are.equal(800, ns.Database.GetLatestBuyout("equip:15653:12720"))
    assert.is_nil(ns.Database.GetLatestBuyout("equip:15653:12721"), "a variant the newer scan missed isn't listed")
  end)

  it("merges imported scans and newer buyouts while saving only account scans", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 1000 },
              items = {
                ["2589"] = { scans = { [1000] = 30 } },
              },
              latestBuyouts = { ["2589"] = 40 },
            },
          },
          vendorPrices = {},
        },
      },
    }
    ARBITRAGE_IMPORT = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 2000 },
              items = {
                ["2589"] = { scans = { [1000] = 40, [2000] = 12 } },
              },
              latestBuyouts = { ["2589"] = 12, ["4306"] = 7 },
            },
          },
          vendorPrices = {},
        },
      },
    }
    ns.Database.Init()
    -- The import holds the account's synced scans, so the scan both hold counts once, as imported.
    assert.are.same({ 40 + 12, 2 }, { Day("2589", 1000) })
    assert.are.same({ itemCount = 1, latestScan = 2000, recentScanCount = 2 }, ns.Database.GetStatus())
    assert(ns.Database.GetLatestBuyout("2589") == 12, "takes the newer buyout snapshot for 2589")
    assert(ns.Database.GetLatestBuyout("4306") == 7, "takes the newer buyout snapshot for 4306")
    local keptAlliance = ARBITRAGE_DATABASE.realms["Test Realm"].markets.Alliance
    assert(keptAlliance.items["2589"].scans[2000] == nil, "keeps imported scans out of the saved database")
    assert(keptAlliance.latestBuyouts["2589"] == 40, "keeps the saved buyout snapshot")
    ns.Database.SaveScan({ ["2589"] = 20 }, 3000, { ["2589"] = 18 })
    assert(keptAlliance.items["2589"].scans[3000] == 20, "saves a new own scan beside the import")
    assert(keptAlliance.items["2589"].scans[2000] == nil, "does not save imported scans with a new scan")
    assert.are.same({ 40 + 12 + 20, 3 }, { Day("2589", 3000) })
    assert.are.same({ itemCount = 1, latestScan = 3000, recentScanCount = 3 }, ns.Database.GetStatus())
  end)

  it("adds only the account's scans that the daily import does not hold", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 3000 },
              items = {
                ["2589"] = { scans = { [1000] = 40, [3000] = 20 } },
                ["4306"] = { scans = { [1000] = 9 } },
              },
              latestBuyouts = { ["2589"] = 18 },
            },
          },
          vendorPrices = {},
        },
      },
    }
    ARBITRAGE_IMPORT = {
      __version = 3,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 2000 },
              scans = { 1000, 2000 },
              items = {
                ["2589"] = { latest = 2000, days = { [0] = (40 + 12) * 1024 + 2 } },
              },
              latestBuyouts = { ["2589"] = 11 },
            },
          },
          vendorPrices = { Alliance = { ["2589"] = 5 } },
        },
      },
    }
    ns.Database.Init()

    -- Scan 1000 came back inside the import, so only scan 3000 is added. 4306 was not in the
    -- import's copy of scan 1000, which is the copy that counts.
    assert.are.same({ 40 + 12 + 20, 3 }, { Day("2589", 1000) })
    assert.are.equal(3000, ns.Database.Get("2589").latest)
    assert.is_nil(ns.Database.Get("4306"))
    assert.are.same({ itemCount = 1, latestScan = 3000, recentScanCount = 3 }, ns.Database.GetStatus())
    assert.are.equal(18, ns.Database.GetLatestBuyout("2589"))
    assert.are.equal(5, ns.Database.GetVendorPrice(2589))
    assert.is_nil(ARBITRAGE_IMPORT)
  end)

  it("keeps the daily import's window days and its items seen within thirty days", function()
    setfenv(1, environment)
    local now = 100 * DAY
    function time()
      return now
    end
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = {
      __version = 3,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = now },
              scans = { 70 * DAY - 1, 85 * DAY, 86 * DAY, now, "not a time" },
              items = {
                ["2589"] = {
                  latest = now,
                  days = { [85] = 30 * 1024 + 1, [86] = 20 * 1024 + 1, [100] = 10 * 1024 + 1 },
                },
                ["4306"] = { latest = 85 * DAY, days = { [85] = 7 * 1024 + 1 } },
                ["2592"] = { latest = 70 * DAY - 1, days = {} },
                ["bad"] = { latest = now, days = "not days" },
              },
              latestBuyouts = {},
            },
          },
          vendorPrices = {},
        },
      },
    }
    ns.Database.Init()

    -- Day 86 begins fourteen days before now; the cutoff is thirty days before the last scan.
    assert.is_nil(Day("2589", 85 * DAY))
    assert.are.same({ 20, 1 }, { Day("2589", 86 * DAY) })
    assert.are.same({ 10, 1 }, { Day("2589", now) })
    assert.are.same({ days = {}, latest = 85 * DAY }, ns.Database.Get("4306"))
    assert.is_nil(ns.Database.Get("2592"))
    assert.is_nil(ns.Database.Get("bad"))
    assert.are.same({ itemCount = 2, latestScan = now, recentScanCount = 2 }, ns.Database.GetStatus())
  end)

  it("prunes merged scans against the inclusive thirty-day cutoff", function()
    setfenv(1, environment)
    local lastScan = 10000000
    local day = 24 * 60 * 60
    ARBITRAGE_DATABASE = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = lastScan - day },
              items = {
                ["2589"] = {
                  scans = {
                    [lastScan - 31 * day] = 1,
                    [lastScan - 30 * day] = 2,
                  },
                },
              },
              latestBuyouts = {},
            },
          },
          vendorPrices = {},
        },
      },
    }
    ARBITRAGE_IMPORT = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = lastScan },
              items = {},
              latestBuyouts = {},
            },
          },
          vendorPrices = {},
        },
      },
    }
    ns.Database.Init()
    assert.is_nil(Day("2589", lastScan - 31 * day))
    assert.are.same({ 2, 1 }, { Day("2589", lastScan - 30 * day) })
    assert.are.equal(lastScan - 30 * day, ns.Database.Get("2589").latest)
  end)

  it("ignores an invalid import while retaining account scans", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 2,
      meta = {},
      realms = {
        ["Test Realm"] = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 1000 },
              items = {
                ["2589"] = { scans = { [1000] = 30 } },
              },
              latestBuyouts = { ["2589"] = 30 },
            },
          },
          vendorPrices = {},
        },
      },
    }
    ARBITRAGE_IMPORT = "nope"
    ns.Database.Init()
    assert.are.same({ 30, 1 }, { Day("2589", 1000) })
  end)

  it("repairs saved sub-copper vendor prices across every faction", function()
    setfenv(1, environment)
    ARBITRAGE_DATABASE = {
      __version = 2,
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
    ARBITRAGE_IMPORT = {
      __version = 2,
      meta = {},
      realms = {
        PvP = {
          region = 1,
          markets = {
            Alliance = {
              meta = { lastScan = 1000 },
              items = { ["2589"] = { scans = { [1000] = 42 } } },
              latestBuyouts = { ["2589"] = 39 },
            },
          },
          vendorPrices = {},
        },
      },
    }

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
end)

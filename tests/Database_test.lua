ARBITRAGE_DATABASE = nil
ARBITRAGE_IMPORT = nil
local faction = "Alliance"
local realm = "Test Realm"

function GetRealmName()
  return realm
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

local ns = {}
assert(loadfile("src/Database.lua"), "loads Database.lua")("Arbitrage", ns)
ns.Database.Init()
assert(ARBITRAGE_DATABASE.__version == 2, "initializes database version 2")
assert(type(ARBITRAGE_DATABASE.meta) == "table", "initializes root metadata")
assert(type(ARBITRAGE_DATABASE.realms[realm]) == "table", "stores realms under the root realm table")
assert(ARBITRAGE_DATABASE.realms[realm].region == 1, "records the region on the realm")
assert(ns.Database.GetMarket() == "Alliance", "reports the active faction market")
assert(
  ARBITRAGE_DATABASE.realms[realm].markets.Alliance.meta.lastPlayed == 100,
  "stamps when the faction market was last played"
)

ns.Database.SaveScan({ ["123"] = 50 }, 100, {
  ["equip:123:-35"] = 40,
  ["123"] = 60,
})
assert(ns.Database.GetLatestBuyout("equip:123:-35") == 40, "gets a suffix-specific minimum buyout")
assert(ns.Database.GetLatestBuyout(123) == 60, "accepts numeric item IDs")
assert(ns.Database.GetStatus().itemCount == 1, "counts stored items in database status")
assert(ARBITRAGE_DATABASE.realms[realm].markets.Alliance.items["123"].scans[100] == 50, "saves the account's own scan")

ns.Database.SaveScan({}, 200, {})
assert(ns.Database.GetLatestBuyout(123) == nil, "replaces latest buyouts on every scan")

ns.Database.RecordVendorPrice(200, 10)
ns.Database.RecordVendorPrice(200, 12)
ns.Database.RecordVendorPrice(200, 8)
assert(ns.Database.GetVendorPrice(200) == 8, "keeps the cheapest observed vendor price")
assert(ns.Database.CountVendorPrices() == 1, "counts learned vendor prices")
assert(ARBITRAGE_DATABASE.realms[realm].vendorPrices.Alliance["200"] == 8, "saves the account's vendor prices")

faction = "Horde"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by faction")

faction = "Alliance"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the faction")

ns.Database.SetMarket("Neutral")
assert(ns.Database.GetMarket() == "Neutral", "reports a selected neutral market")
ns.Database.SaveScan({ ["999"] = 90 }, 300, { ["999"] = 80 })
assert(ns.Database.Get("999").scans[300] == 90, "stores neutral auction data separately")
assert(ARBITRAGE_DATABASE.realms[realm].markets.Neutral.meta.lastPlayed == nil, "does not stamp a visited market")

ns.Database.SetMarket("Alliance")
assert(ns.Database.Get("999") == nil, "does not expose neutral data in the Alliance market")
assert(ns.Database.Get("123").scans[100] == 50, "restores Alliance auction data")

ns.Database.RecordReplicateScan(250)
ns.Database.SetMarket("Neutral")
assert(ns.Database.GetLastReplicateScan() == 250, "shares the replication time across markets")
ns.Database.Init()
assert(ns.Database.GetLastReplicateScan() == 250, "restores the replication time")

realm = "Other Realm"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by realm")
assert(ns.Database.GetLastReplicateScan() == 250, "shares the replication time across realms")

realm = "Test Realm"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the realm")
assert(ns.Database.GetLastReplicateScan() == 250, "restores the account-wide replication time")

faction = "Unknown"
ns.Database.Init()
assert(ns.Database.GetMarket() == "Unknown", "falls back to the Unknown market")
assert(ARBITRAGE_DATABASE.realms[realm].markets.Unknown.meta.lastPlayed == nil, "never stamps the Unknown market")
faction = "Alliance"

ARBITRAGE_DATABASE = "invalid"
ns.Database.Init()
assert(ns.Database.GetStatus().itemCount == 0, "resets an invalid persisted root")
assert(ARBITRAGE_DATABASE.__version == 2, "uses version 2 after resetting the root")
assert(
  type(ARBITRAGE_DATABASE.meta) == "table" and type(ARBITRAGE_DATABASE.realms) == "table",
  "uses the new root shape"
)

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

ARBITRAGE_DATABASE.realms[realm].markets.Alliance = { items = {} }
ns.Database.SetMarket("Alliance")
local reset = ARBITRAGE_DATABASE.realms[realm].markets.Alliance
assert(
  type(reset.meta) == "table" and type(reset.latestBuyouts) == "table",
  "resets a malformed saved market as a unit"
)
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
assert(ns.Database.Get("legacy").scans[100] == 50, "does not expose partially pruned scan data")
assert(ns.Database.Get("fresh") == nil, "does not expose partially stored scan data")
assert(ns.Database.GetStatus().latestScan == 100, "does not expose partial scan metadata")
assert(ns.Database.GetLatestBuyout("legacy") == 40, "does not expose partial latest buyouts")
assert(ARBITRAGE_DATABASE.realms[realm].markets.Alliance.items.fresh == nil, "does not save a partial scan")
while coroutine.status(saveWorker) ~= "dead" do
  success, message = coroutine.resume(saveWorker)
  assert(success, message)
  resumeCount = resumeCount + 1
end
assert(saveCount == 1 and ns.Database.Get("fresh").scans[4000000] == 75, "commits a completed sliced save")
assert(ns.Database.Get("legacy") == nil, "prunes old scans in the sliced save")
assert(ns.Database.GetLatestBuyout("fresh") == 70, "commits latest buyouts with the scan")
assert(resumeCount > 1, "time-slices database preparation")
local savedAlliance = ARBITRAGE_DATABASE.realms[realm].markets.Alliance
assert(
  savedAlliance.items.fresh.scans[4000000] == 75 and savedAlliance.items.legacy == nil,
  "saves the completed sliced scan"
)

realm = "Test Realm"
faction = "Alliance"
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
assert(ns.Database.Get("2589").scans[1000] == 40, "reads imported scans when the saved root is missing")
assert(ns.Database.GetLatestBuyout("2589") == 40, "reads imported latest buyouts when the saved root is missing")
assert(ns.Database.GetVendorPrice(2589) == 5, "reads imported vendor prices when the saved root is missing")
assert(ns.Database.GetLastReplicateScan() == nil, "keeps the replicate scan local to the account")
assert(ARBITRAGE_IMPORT == nil, "releases the loaded import")
local ownAlliance = ARBITRAGE_DATABASE.realms["Test Realm"].markets.Alliance
assert(ownAlliance.items["2589"] == nil, "never saves imported scans")
assert(next(ownAlliance.latestBuyouts) == nil, "never saves imported buyouts")
assert(
  ARBITRAGE_DATABASE.realms["Test Realm"].vendorPrices.Alliance["2589"] == nil,
  "never saves imported vendor prices"
)

realm = "Test Realm"
faction = "Alliance"
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
assert(ns.Database.Get("2589").scans[1000] == 30, "keeps the lower copper on a shared scan")
assert(ns.Database.Get("2589").scans[2000] == 12, "unions scans from the import")
assert(ns.Database.GetLatestBuyout("2589") == 12, "takes the newer buyout snapshot for 2589")
assert(ns.Database.GetLatestBuyout("4306") == 7, "takes the newer buyout snapshot for 4306")
local keptAlliance = ARBITRAGE_DATABASE.realms["Test Realm"].markets.Alliance
assert(keptAlliance.items["2589"].scans[2000] == nil, "keeps imported scans out of the saved database")
assert(keptAlliance.latestBuyouts["2589"] == 40, "keeps the saved buyout snapshot")
ns.Database.SaveScan({ ["2589"] = 20 }, 3000, { ["2589"] = 18 })
assert(keptAlliance.items["2589"].scans[3000] == 20, "saves a new own scan beside the import")
assert(keptAlliance.items["2589"].scans[2000] == nil, "does not save imported scans with a new scan")
assert(ns.Database.Get("2589").scans[2000] == 12, "keeps imported scans in the view after a new scan")

realm = "Test Realm"
faction = "Alliance"
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
assert(ns.Database.Get("2589").scans[lastScan - 31 * day] == nil, "drops scans older than the thirty-day window")
assert(ns.Database.Get("2589").scans[lastScan - 30 * day] == 2, "keeps scans on the inclusive thirty-day cutoff")

realm = "Test Realm"
faction = "Alliance"
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
assert(ns.Database.Get("2589").scans[1000] == 30, "ignores an invalid import root")

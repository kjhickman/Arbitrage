ARBITRAGE_DATABASE = nil
local faction = "Alliance"
local realm = "Test Realm"

function GetRealmName()
  return realm
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
assert(ARBITRAGE_DATABASE.__version == 1, "initializes database version 1")
assert(type(ARBITRAGE_DATABASE.meta) == "table", "initializes root metadata")
assert(type(ARBITRAGE_DATABASE.realms[realm]) == "table", "stores realms under the root realm table")

ns.Database.SaveScan({ ["123"] = 50 }, 100, {
  ["equip:123:-35"] = 40,
  ["123"] = 60,
})
assert(ns.Database.GetLatestBuyout({ "equip:123:-35", "123" }) == 40, "uses exact minimum buyout")
assert(ns.Database.GetLatestBuyout({ "equip:123:-36", "123" }) == 60, "uses generic minimum fallback")

ns.Database.SaveScan({}, 200, {})
assert(ns.Database.GetLatestBuyout({ "123" }) == nil, "replaces latest buyouts on every scan")

ns.Database.RecordVendorPrice(200, 10)
ns.Database.RecordVendorPrice(200, 12)
ns.Database.RecordVendorPrice(200, 8)
assert(ns.Database.GetVendorPrice(200) == 8, "keeps the cheapest observed vendor price")
assert(ns.Database.CountVendorPrices() == 1, "counts learned vendor prices")

faction = "Horde"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by faction")

faction = "Alliance"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the faction")

ns.Database.SetMarket("Neutral")
ns.Database.SaveScan({ ["999"] = 90 }, 300, { ["999"] = 80 })
assert(ns.Database.Get("999").scans[300] == 90, "stores neutral auction data separately")

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

ARBITRAGE_DATABASE = "invalid"
ns.Database.Init()
assert(ns.Database.Count() == 0, "resets an invalid persisted root")
assert(ARBITRAGE_DATABASE.__version == 1, "uses version 1 after resetting the root")
assert(
  type(ARBITRAGE_DATABASE.meta) == "table" and type(ARBITRAGE_DATABASE.realms) == "table",
  "uses the new root shape"
)

ARBITRAGE_DATABASE = {
  __version = 4,
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
    lastKnownScan = 250,
  },
}
ns.Database.Init()

assert(ARBITRAGE_DATABASE.__version == 1, "resets an old database to version 1")
assert(ns.Database.Get("legacy") == nil, "discards old scan data instead of migrating it")
assert(ns.Database.GetVendorPrice(100) == nil, "discards old vendor data instead of migrating it")
assert(ns.Database.GetLastReplicateScan() == nil, "discards the old cooldown timestamp")

ARBITRAGE_DATABASE = {
  __version = 1,
  [realm] = {
    markets = {},
    vendorPrices = {},
  },
}
ns.Database.Init()
assert(type(ARBITRAGE_DATABASE.realms) == "table", "rejects the historical version 1 root shape")
assert(ARBITRAGE_DATABASE[realm] == nil, "does not retain historical root-level realms")

ARBITRAGE_DATABASE.realms[realm].markets.Alliance = { items = {} }
ns.Database.SetMarket("Alliance")
assert(ns.Database.Count() == 0, "resets a malformed market as a unit")
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
assert(ns.Database.GetLatestBuyout({ "legacy" }) == 40, "does not expose partial latest buyouts")
while coroutine.status(saveWorker) ~= "dead" do
  success, message = coroutine.resume(saveWorker)
  assert(success, message)
  resumeCount = resumeCount + 1
end
assert(saveCount == 1 and ns.Database.Get("fresh").scans[4000000] == 75, "commits a completed sliced save")
assert(ns.Database.Get("legacy") == nil, "prunes old scans in the sliced save")
assert(ns.Database.GetLatestBuyout({ "fresh" }) == 70, "commits latest buyouts with the scan")
assert(resumeCount > 1, "time-slices database preparation")

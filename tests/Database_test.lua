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

realm = "Other Realm"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == nil, "separates vendor prices by realm")

realm = "Test Realm"
ns.Database.Init()
assert(ns.Database.GetVendorPrice(200) == 8, "restores vendor prices for the realm")

ARBITRAGE_DATABASE = "invalid"
ns.Database.Init()
assert(ns.Database.Count() == 0, "resets an invalid persisted root")

ARBITRAGE_DATABASE = {
  __version = 3,
  [realm] = {
    meta = { lastScan = 0 / 0, lastScanItems = math.huge },
    items = {
      broken = true,
      missingScans = {},
      malformedScans = { scans = { invalid = "invalid", nan = 0 / 0 } },
      mixedScans = { scans = { [100] = 50, invalid = "invalid" } },
      [100] = { scans = { [100] = 60 } },
    },
    latestBuyouts = { valid = 10, invalid = "invalid", free = 0, nan = 0 / 0, [100] = 20 },
    vendorPrices = { [faction] = { ["100"] = 5, ["200"] = "invalid", ["300"] = 0, ["400"] = 0 / 0, [500] = 6 } },
  },
}
ns.Database.Init()

assert(ARBITRAGE_DATABASE.__version == 4, "migrates the version 3 database")
assert(ARBITRAGE_DATABASE[realm].items == nil, "removes the legacy realm-level market fields")
assert(type(ARBITRAGE_DATABASE[realm].markets.Unknown) == "table", "preserves legacy prices as an unknown market")
assert(ns.Database.Count() == 1, "discards malformed persisted items and keys")
assert(ns.Database.Get("mixedScans").scans.invalid == nil, "prunes malformed persisted scans")
assert(ns.Database.GetStatus().latestScan == 100, "discards malformed persisted metadata")
assert(ns.Database.GetLatestBuyout({ "valid" }) == 10, "keeps valid persisted buyouts")
assert(ns.Database.GetLatestBuyout({ "invalid", "free", "nan", "100" }) == nil, "discards malformed persisted buyouts")
assert(ns.Database.GetVendorPrice(100) == 5, "keeps valid persisted vendor prices")
assert(ns.Database.CountVendorPrices() == 1, "discards malformed persisted vendor prices")

ns.Database.SetMarket("Alliance")
assert(ns.Database.Count() == 0, "does not assign migrated prices to the current faction")
ns.Database.SetMarket("Unknown")
assert(ns.Database.Count() == 1, "keeps migrated prices available in the unknown market")

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
assert(ns.Database.Get("mixedScans").scans[100] == 50, "does not expose partially pruned scan data")
assert(ns.Database.Get("fresh") == nil, "does not expose partially stored scan data")
assert(ns.Database.GetStatus().latestScan == 100, "does not expose partial scan metadata")
assert(ns.Database.GetLatestBuyout({ "valid" }) == 10, "does not expose partial latest buyouts")
while coroutine.status(saveWorker) ~= "dead" do
  success, message = coroutine.resume(saveWorker)
  assert(success, message)
  resumeCount = resumeCount + 1
end
assert(saveCount == 1 and ns.Database.Get("fresh").scans[4000000] == 75, "commits a completed sliced save")
assert(ns.Database.Get("mixedScans") == nil, "prunes old scans in the sliced save")
assert(ns.Database.GetLatestBuyout({ "fresh" }) == 70, "commits latest buyouts with the scan")
assert(resumeCount > 1, "time-slices database preparation")

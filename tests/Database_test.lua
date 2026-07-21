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

assert(ns.Database.Count() == 1, "discards malformed persisted items and keys")
assert(ns.Database.Get("mixedScans").scans.invalid == nil, "prunes malformed persisted scans")
assert(ns.Database.GetStatus().latestScan == 100, "discards malformed persisted metadata")
assert(ns.Database.GetLatestBuyout({ "valid" }) == 10, "keeps valid persisted buyouts")
assert(ns.Database.GetLatestBuyout({ "invalid", "free", "nan", "100" }) == nil, "discards malformed persisted buyouts")
assert(ns.Database.GetVendorPrice(100) == 5, "keeps valid persisted vendor prices")
assert(ns.Database.CountVendorPrices() == 1, "discards malformed persisted vendor prices")

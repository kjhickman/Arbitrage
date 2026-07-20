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
assert(loadfile("Database.lua"), "loads Database.lua")("Arbitrage", ns)
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

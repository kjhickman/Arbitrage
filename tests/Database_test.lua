ARBITRAGE_DATABASE = nil

function GetRealmName()
  return "Test Realm"
end

function time()
  return 100
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

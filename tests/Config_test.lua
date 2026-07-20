ARBITRAGE_CONFIG = "invalid"

local ns = {}
assert(loadfile("Config.lua"), "loads Config.lua")("Arbitrage", ns)
ns.Config.Init()

assert(type(ARBITRAGE_CONFIG) == "table", "resets an invalid persisted root")

ARBITRAGE_CONFIG = { showTooltips = "invalid" }
ns.Config.Init()

assert(ARBITRAGE_CONFIG.showTooltips == true, "resets invalid persisted values")
assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")

ns.Config.Set("showTooltips", false)
assert(ns.Config.Get("showTooltips") == false, "gets and sets config values")

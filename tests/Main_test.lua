local onEvent

function CreateFrame()
  return {
    RegisterEvent = function() end,
    UnregisterEvent = function() end,
    SetScript = function(_, _, callback)
      onEvent = callback
    end,
  }
end

SlashCmdList = {}

function print() end

local scanProcessor
local groups
local savedResults
local savedTimestamp
local savedBuyouts
local saveCount = 0
local returnKeys = true

local function Noop() end

local ns = {
  Config = { Init = Noop, RegisterOptionsPanel = Noop },
  Database = {
    Init = Noop,
    SaveScan = function(results, timestamp, latestBuyouts)
      saveCount = saveCount + 1
      savedResults = results
      savedTimestamp = timestamp
      savedBuyouts = latestBuyouts
      return 1
    end,
  },
  Keys = {
    FromLink = function()
      return returnKeys and { "100" } or {}
    end,
  },
  MarketValue = {
    CalculateAll = function(value)
      groups = value
      return { ["100"] = 55 }
    end,
  },
  RecipeBook = { Init = Noop },
  RecipeCapture = { Register = Noop },
  RollingMarketValue = { Get = function() end },
  Scan = {
    Init = function(process)
      scanProcessor = process
    end,
    RegisterAuctionator = Noop,
  },
  Tooltip = { Register = Noop },
  Vendor = { Register = Noop },
}

function time()
  return 123
end

assert(loadfile("src/Main.lua"), "loads Main.lua")("Arbitrage", ns)
onEvent(nil, "ADDON_LOADED", "Arbitrage")

scanProcessor({
  { itemLink = "item:100", quantity = 2, buyout = 101 },
  { itemLink = "item:100", quantity = 1, buyout = 60 },
})

assert(groups["100"][1].price == 51 and groups["100"][1].quantity == 2, "normalizes per-unit prices")
assert(groups["100"][2].price == 60 and groups["100"][2].quantity == 1, "keeps each auction quantity")
assert(savedResults["100"] == 55, "stores calculated market values")
assert(savedTimestamp == 123, "timestamps the completed scan")
assert(savedBuyouts["100"] == 51, "stores the lowest per-unit buyout")

scanProcessor({}, 2)
assert(saveCount == 1, "keeps previous data when a non-empty scan has no usable auctions")

returnKeys = false
scanProcessor({ { itemLink = "invalid", quantity = 1, buyout = 10 } }, 1)
assert(saveCount == 1, "keeps previous data when auction links produce no database keys")

local NewEnvironment = dofile("tests/support/Environment.lua")

describe("RollingMarketValue", function()
  local environment
  local DAY = 24 * 60 * 60
  local ns, now

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    now = 20 * DAY + DAY / 2
    ARBITRAGE_DATABASE = nil
    ARBITRAGE_IMPORT = nil

    function GetRealmName()
      return "Test Realm"
    end

    function UnitFactionGroup()
      return "Alliance"
    end

    function GetCurrentRegion()
      return 1
    end

    function time()
      return now
    end

    ns = {}
    assert(loadfile("src/Database.lua"), "loads Database.lua")("Arbitrage", ns)
    assert(loadfile("src/RollingMarketValue.lua"), "loads RollingMarketValue.lua")("Arbitrage", ns)
    ns.Database.Init()

    ns.Database.SaveScan({ item = 100 }, now - 100)
    ns.Database.SaveScan({ item = 300 }, now - 200)
    ns.Database.SaveScan({ item = 100 }, now - 2 * DAY)
  end)

  it("averages daily scans before weighting days and reports limited coverage", function()
    setfenv(1, environment)
    local result = assert(ns.RollingMarketValue.Get({ "item" }))
    assert(result.value == 167, "averages scans within a day before weighting days")
    assert(result.dayCount == 2 and result.scanCount == 3, "reports contributing days and scans")
    assert(result.reasons[1] == "limited days", "reports insufficient day coverage")
  end)

  it("reports when a generic fallback key supplies the market value", function()
    setfenv(1, environment)
    local result = assert(ns.RollingMarketValue.Get({ "missing", "item" }))
    assert(result.usedFallback and result.reasons[2] == "generic fallback", "reports fallback-key usage")
  end)

  it("reports the age and staleness of the latest observation", function()
    setfenv(1, environment)
    now = 25 * DAY + DAY / 2
    local result = assert(ns.RollingMarketValue.Get({ "item" }))
    assert(result.latestAgeDays == 5, "reports the age of the latest observation")
    assert(table.concat(result.reasons, ","):match("stale"), "reports stale market data")
  end)
end)

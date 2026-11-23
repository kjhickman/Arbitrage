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

    function RegionalUniqueNamesEnabled()
      return false
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
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
    assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
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
    assert.are.same({ "fewer than 3 days of scans" }, result.reasons)
    assert.is_true(result.isUncertain)
  end)

  it("rounds a half-copper estimate consistently as time passes without new scans", function()
    setfenv(1, environment)
    local latest = 20000 * DAY
    now = latest
    ns.Database.SaveScan({ tie = 10001 }, latest - 2 * DAY)
    ns.Database.SaveScan({ tie = 10002 }, latest - 2 * DAY + 1)
    ns.Database.SaveScan({ tie = 10000 }, latest)

    -- The older day's 10001.5 gets half the weight, giving an average of exactly 10000.5.
    for _, elapsed in ipairs({ 0, 4, DAY }) do
      now = latest + elapsed
      assert.are.equal(10001, assert(ns.RollingMarketValue.Get({ "tie" })).value)
    end
  end)

  it("explains too few scans and prices that swing from day to day", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ swing = 100 }, now - 300)
    ns.Database.SaveScan({ swing = 300 }, now - DAY - 300)
    local result = assert(ns.RollingMarketValue.Get({ "swing" }))
    assert.are.same({ "fewer than 3 days of scans", "fewer than 3 scans", "prices swing a lot" }, result.reasons)
  end)

  it("prices each item from its own days, whatever was priced before it", function()
    setfenv(1, environment)
    ns.Database.SaveScan({ swing = 100 }, now - 300)
    ns.Database.SaveScan({ swing = 300 }, now - DAY - 300)
    ns.Database.SaveScan({ steady = 200 }, now - 300)
    assert(ns.RollingMarketValue.Get({ "swing" }))
    local result = assert(ns.RollingMarketValue.Get({ "steady" }))
    assert.are.equal(1, result.dayCount)
    assert.are.equal(0, result.volatility)
  end)

  it("counts whole days back to the one fourteen days ago", function()
    setfenv(1, environment)
    -- Fourteen days before day 20's noon falls on day 6, so all of day 6 counts and day 5 does not.
    ns.Database.SaveScan({ edge = 50 }, 6 * DAY + 60)
    ns.Database.SaveScan({ outside = 50 }, 6 * DAY - 60)
    assert.are.equal(50, assert(ns.RollingMarketValue.Get({ "edge" })).value)
    assert.is_nil(ns.RollingMarketValue.Get({ "outside" }))
  end)

  it("reports when a generic fallback key supplies the market value", function()
    setfenv(1, environment)
    local result = assert(ns.RollingMarketValue.Get({ "missing", "item" }))
    assert.are.equal(167, result.value)
    assert.are.same({ "fewer than 3 days of scans", "priced from the base item" }, result.reasons)
  end)

  it("reports the time, age and staleness of the latest observation", function()
    setfenv(1, environment)
    local latest = now - 100
    now = 25 * DAY + DAY / 2
    local result = assert(ns.RollingMarketValue.Get({ "item" }))
    assert.are.equal(latest, result.latest)
    assert(result.latestAgeDays == 5, "reports the age of the latest observation")
    assert.are.same({ "fewer than 3 days of scans", "last seen over 3 days ago" }, result.reasons)
  end)
end)

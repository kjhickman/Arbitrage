local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Time", function()
  local environment
  local ns
  local currentTime

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ns = {}
    currentTime = 1000000

    function time()
      return currentTime
    end

    assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
  end)

  ---@param secondsAgo number
  local function Since(secondsAgo)
    return ns.Time.Since(currentTime - secondsAgo)
  end

  it("reports anything under a minute as just now", function()
    setfenv(1, environment)
    assert.are.equal("just now", Since(0))
    assert.are.equal("just now", Since(59))
  end)

  it("counts whole minutes, hours, and days", function()
    setfenv(1, environment)
    assert.are.equal("31 minutes ago", Since(31 * 60))
    assert.are.equal("59 minutes ago", Since(60 * 60 - 1))
    assert.are.equal("2 hours ago", Since(2 * 60 * 60))
    assert.are.equal("23 hours ago", Since(24 * 60 * 60 - 1))
    assert.are.equal("29 days ago", Since(29 * 24 * 60 * 60))
  end)

  it("drops the plural for a single unit", function()
    setfenv(1, environment)
    assert.are.equal("1 minute ago", Since(60))
    assert.are.equal("1 hour ago", Since(60 * 60))
    assert.are.equal("1 day ago", Since(24 * 60 * 60))
  end)

  it("treats a timestamp from the future as now", function()
    setfenv(1, environment)
    assert.are.equal("just now", Since(-600))
  end)
end)

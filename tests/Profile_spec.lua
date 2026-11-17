local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Profile", function()
  local environment
  local ns
  local clock
  local memory

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    clock = 0
    memory = { used = 40960, retained = 10240 }
    function debugprofilestop()
      return clock
    end
    function UpdateAddOnMemoryUsage() end
    function GetAddOnMemoryUsage(name)
      assert.are.equal("Arbitrage", name)
      return memory.used
    end
    function collectgarbage(option)
      assert.are.equal("collect", option)
      memory.used = memory.retained
    end
    ns = {}
    assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
  end)

  it("measures nothing until enabled", function()
    setfenv(1, environment)
    ns.Profile.Begin("sort")
    clock = 50
    ns.Profile.End("sort")
    assert.is_false(ns.Profile.IsEnabled())

    ns.Profile.Enable()
    assert.are.same(
      { "Nothing measured; use the Database tab while profiling.", "Memory: 40.0 MB, 10.0 MB after collecting garbage" },
      ns.Profile.Report()
    )
  end)

  it("reports calls, total, and slowest call per measurement, largest total first", function()
    setfenv(1, environment)
    ns.Profile.Enable()
    for _, duration in ipairs({ 2, 6 }) do
      ns.Profile.Begin("sort")
      clock = clock + duration
      ns.Profile.End("sort")
    end
    ns.Profile.Begin("rebuild")
    clock = clock + 30
    ns.Profile.End("rebuild")

    assert.are.same({
      "rebuild: 1 calls, 30 ms total, 30.0 ms max",
      "sort: 2 calls, 8 ms total, 6.0 ms max",
      "Memory: 40.0 MB, 10.0 MB after collecting garbage",
    }, ns.Profile.Report())
    assert.is_false(ns.Profile.IsEnabled())
  end)
end)

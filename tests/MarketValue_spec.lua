local NewEnvironment = dofile("tests/support/Environment.lua")

describe("MarketValue", function()
  local environment
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    ns = {}
    assert(loadfile("src/MarketValue.lua"), "loads MarketValue.lua")("Arbitrage", ns)
  end)

  it("returns no value for an empty market", function()
    setfenv(1, environment)
    assert(ns.MarketValue.Calculate({}) == nil, "returns no value for an empty market")
  end)

  it("values a single listing", function()
    setfenv(1, environment)
    assert(ns.MarketValue.Calculate({ { price = 100, quantity = 1 } }) == 100, "values a single listing")
  end)

  it("includes prices below the jump threshold up to the quantity cap", function()
    setfenv(1, environment)
    local belowJump = ns.MarketValue.Calculate({
      { price = 100, quantity = 1 },
      { price = 119, quantity = 9 },
    })
    assert(belowJump == 113, "includes prices below the jump threshold up to the quantity cap")
  end)

  it("stops at the exact jump threshold after the minimum quantity", function()
    setfenv(1, environment)
    local atJump = ns.MarketValue.Calculate({
      { price = 100, quantity = 1 },
      { price = 120, quantity = 9 },
    })
    assert(atJump == 100, "stops at the exact jump threshold after the minimum quantity")
  end)

  it("reports each group processed but keeps only calculable groups", function()
    setfenv(1, environment)
    local progress = {}
    local values = ns.MarketValue.CalculateAll({
      valid = { { price = 50, quantity = 1 } },
      empty = {},
    }, function(completed, total)
      if completed then
        progress[#progress + 1] = { completed, total }
      end
    end)
    assert(values.valid == 50 and values.empty == nil, "keeps only calculable groups")
    assert.are.same({ { 1, 2 }, { 2, 2 } }, progress)
  end)

  it("sorts listings by price", function()
    setfenv(1, environment)
    assert(
      ns.MarketValue.Calculate({ { price = 200, quantity = 1 }, { price = 100, quantity = 1 } }) == 100,
      "sorts listings by price"
    )
  end)
end)

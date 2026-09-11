local ns = {}
assert(loadfile("src/MarketValue.lua"), "loads MarketValue.lua")("Arbitrage", ns)

assert(ns.MarketValue.Calculate({}) == nil, "returns no value for an empty market")
assert(ns.MarketValue.Calculate({ { price = 100, quantity = 1 } }) == 100, "values a single listing")

local belowJump = ns.MarketValue.Calculate({
  { price = 100, quantity = 1 },
  { price = 119, quantity = 9 },
})
assert(belowJump == 113, "includes prices below the jump threshold up to the quantity cap")

local atJump = ns.MarketValue.Calculate({
  { price = 100, quantity = 1 },
  { price = 120, quantity = 9 },
})
assert(atJump == 100, "stops at the exact jump threshold after the minimum quantity")

local values = ns.MarketValue.CalculateAll({
  valid = { { price = 50, quantity = 1 } },
  empty = {},
})
assert(values.valid == 50 and values.empty == nil, "keeps only calculable groups")

local synchronousRecords = {}
local slicedRecords = {}
for price = 40, 1, -1 do
  local quantity = price % 3 + 1
  synchronousRecords[#synchronousRecords + 1] = { price = price, quantity = quantity }
  slicedRecords[#slicedRecords + 1] = { price = price, quantity = quantity }
end
local synchronousValue = ns.MarketValue.Calculate(synchronousRecords)
local slicedValue
local resumeCount = 0
local worker = coroutine.create(function()
  slicedValue = ns.MarketValue.Calculate(slicedRecords, function()
    coroutine.yield()
  end)
end)
while coroutine.status(worker) ~= "dead" do
  local success, message = coroutine.resume(worker)
  assert(success, message)
  resumeCount = resumeCount + 1
end
assert(slicedValue == synchronousValue, "preserves market values when calculation is time-sliced")
assert(resumeCount > #slicedRecords, "time-slices sorting within a heavily listed item")

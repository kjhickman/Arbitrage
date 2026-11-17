local addonName, ns = ...

-- Temporary timings for the Database tab's slow paths: /arb profile starts measuring and running
-- it again reports. Measurements do nothing while profiling is off.
ns.Profile = {}

---@class ArbitrageTiming
---@field calls number
---@field total number milliseconds
---@field max number milliseconds

local enabled = false
---@type table<string, ArbitrageTiming>
local timings = {}
---@type table<string, number>
local started = {}

---@return boolean
function ns.Profile.IsEnabled()
  return enabled
end

function ns.Profile.Enable()
  enabled = true
  timings = {}
  started = {}
end

---@param name string
function ns.Profile.Begin(name)
  if enabled then
    started[name] = debugprofilestop()
  end
end

---@param name string
function ns.Profile.End(name)
  local begin = enabled and started[name]
  if not begin then
    return
  end
  started[name] = nil
  local elapsed = debugprofilestop() - begin
  local timing = timings[name]
  if not timing then
    timing = { calls = 0, total = 0, max = 0 }
    timings[name] = timing
  end
  timing.calls = timing.calls + 1
  timing.total = timing.total + elapsed
  timing.max = math.max(timing.max, elapsed)
end

-- Stops profiling and describes each measurement, largest total first, then memory use.
---@return string[]
function ns.Profile.Report()
  enabled = false
  local names = {}
  for name in pairs(timings) do
    names[#names + 1] = name
  end
  table.sort(names, function(left, right)
    return timings[left].total > timings[right].total
  end)

  local lines = {}
  for _, name in ipairs(names) do
    local timing = timings[name]
    lines[#lines + 1] =
      string.format("%s: %d calls, %.0f ms total, %.1f ms max", name, timing.calls, timing.total, timing.max)
  end
  if #lines == 0 then
    lines[1] = "Nothing measured; use the Database tab while profiling."
  end

  UpdateAddOnMemoryUsage()
  local used = GetAddOnMemoryUsage(addonName)
  collectgarbage("collect")
  UpdateAddOnMemoryUsage()
  lines[#lines + 1] = string.format(
    "Memory: %.1f MB, %.1f MB after collecting garbage",
    used / 1024,
    GetAddOnMemoryUsage(addonName) / 1024
  )
  return lines
end

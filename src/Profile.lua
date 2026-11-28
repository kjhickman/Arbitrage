local addonName, ns = ...

ns.Profile = {}

-- Times what Arbitrage does at login, in scans, and in its tables, for /arb profile and the
-- command-line benchmark. A job reads the clock only when it starts, changes stage, pauses at the
-- end of a frame, and finishes, and reads the heap's size once a frame, so it is always on without
-- costing anything a player could notice. Memory is measured only while tracing, which collects
-- garbage at the start of every stage and so hitches; no timing counts that time.

---@class ArbitrageProfileMemory
---@field heapKB number the whole interface's Lua heap
---@field addonKB number? Arbitrage's share, which only the game reports
---@field dataKB number? Arbitrage_Data's share, which only the game reports

---@class ArbitrageProfileStage
---@field name string
---@field ms number time spent working
---@field maxFrameMs number its longest stretch of work in one frame
---@field memory ArbitrageProfileMemory? held as it began, after collecting garbage, while tracing

---@class ArbitrageProfileRun
---@field at number when it started
---@field ms number time spent working
---@field frames number frames it worked in
---@field maxFrameMs number its longest frame
---@field elapsedMs number? from start to finish, frames between included
---@field heapPeakKB number the largest heap at the end of one of its frames, garbage included
---@field finished boolean? nil when it stopped early, like a cancelled scan
---@field stages ArbitrageProfileStage[] in the order they began
---@field memory ArbitrageProfileMemory? held once it finished, after collecting garbage, while tracing
---@field size number? how much it worked through, such as a scan's auctions
---@field unit string? what size counts, such as "auctions"

---@class ArbitrageProfileState
---@field run ArbitrageProfileRun
---@field stage ArbitrageProfileStage
---@field stagesByName table<string, ArbitrageProfileStage>
---@field running boolean whether it is working in the current frame
---@field startedAt number
---@field frameStartedAt number
---@field stretchStartedAt number when the current stage last began working

---@class ArbitrageBenchmarkResult
---@field name string
---@field count number lookups made
---@field ms number
---@field allocatedKB number

---@class ArbitrageBenchmarkRun
---@field at number
---@field results ArbitrageBenchmarkResult[]

local DATA_ADDON = "Arbitrage_Data"
-- The order /arb profile lists jobs in; any others follow by name.
local JOB_ORDER = {
  "Login",
  "Full Scan",
  "Quick Scan",
  "Opportunities",
  "Opportunities Table",
  "Database Index",
  "Database Table",
}
-- Benchmarks pause the garbage collector, so they work in bursts of about this long per frame.
local BENCHMARK_FRAME_MS = 50
-- Benchmark lookups between clock reads, so reading the clock costs little next to the lookups.
local LOOKUPS_PER_CLOCK_READ = 16

---@type table<string, ArbitrageProfileRun>
local runs = {}
---@type table<string, ArbitrageProfileState>
local states = {}
local tracing = false
-- Time spent measuring memory, which every timing leaves out, even of a job running around it.
local probeMs = 0
local benchmarking = false

local Print = ns.Print

-- The clock without the time spent measuring memory.
---@return number
local function Now()
  return debugprofilestop() - probeMs
end

---@param collect boolean whether to collect garbage first, so only what is held counts
---@return ArbitrageProfileMemory
local function MeasureMemory(collect)
  local started = debugprofilestop()
  if collect then
    collectgarbage("collect")
  end
  local memory = { heapKB = collectgarbage("count") }
  if UpdateAddOnMemoryUsage then
    UpdateAddOnMemoryUsage()
    memory.addonKB = GetAddOnMemoryUsage(addonName)
    if C_AddOns.IsAddOnLoaded(DATA_ADDON) then
      memory.dataKB = GetAddOnMemoryUsage(DATA_ADDON)
    end
  end
  probeMs = probeMs + debugprofilestop() - started
  return memory
end

---@param state ArbitrageProfileState
---@param now number
local function EndStretch(state, now)
  local stage = state.stage
  local ms = now - state.stretchStartedAt
  stage.ms = stage.ms + ms
  if ms > stage.maxFrameMs then
    stage.maxFrameMs = ms
  end
end

---@param state ArbitrageProfileState
---@param name string
local function EnterStage(state, name)
  local stage = state.stagesByName[name]
  if not stage then
    stage = { name = name, ms = 0, maxFrameMs = 0 }
    if tracing then
      stage.memory = MeasureMemory(true)
    end
    state.stagesByName[name] = stage
    local stages = state.run.stages
    stages[#stages + 1] = stage
  end
  state.stage = stage
  state.stretchStartedAt = Now()
end

-- Begins a new run of the job in its first stage, replacing its last run, and counts the work that
-- follows until it pauses or finishes.
---@param job string
---@param stage string
function ns.Profile.Start(job, stage)
  local run = { at = time(), ms = 0, frames = 0, maxFrameMs = 0, heapPeakKB = 0, stages = {} }
  runs[job] = run
  local state = { run = run, stagesByName = {}, running = true }
  states[job] = state
  EnterStage(state, stage)
  state.startedAt = state.stretchStartedAt
  state.frameStartedAt = state.stretchStartedAt
end

-- Moves the job on to another stage, which may be one it has been in before.
---@param job string
---@param stage string
function ns.Profile.Stage(job, stage)
  local state = states[job]
  if not state then
    return
  end
  if state.running then
    EndStretch(state, Now())
  end
  EnterStage(state, stage)
end

-- Counts the job's work again, in a new frame.
---@param job string
---@param clock number? a reading of debugprofilestop() the caller just took
function ns.Profile.Resume(job, clock)
  local state = states[job]
  if not state or state.running then
    return
  end
  local now = clock and clock - probeMs or Now()
  state.running = true
  state.frameStartedAt = now
  state.stretchStartedAt = now
end

-- Stops counting the job's work until it resumes, as it yields until the next frame.
---@param job string
function ns.Profile.Pause(job)
  local state = states[job]
  if not state or not state.running then
    return
  end
  local now = Now()
  EndStretch(state, now)
  local run = state.run
  local ms = now - state.frameStartedAt
  run.ms = run.ms + ms
  run.frames = run.frames + 1
  if ms > run.maxFrameMs then
    run.maxFrameMs = ms
  end
  local heapKB = collectgarbage("count")
  if heapKB > run.heapPeakKB then
    run.heapPeakKB = heapKB
  end
  state.running = false
end

---@param job string
function ns.Profile.Finish(job)
  local state = states[job]
  if not state then
    return
  end
  ns.Profile.Pause(job)
  states[job] = nil
  local run = state.run
  run.elapsedMs = Now() - state.startedAt
  run.finished = true
  if tracing then
    run.memory = MeasureMemory(true)
  end
end

-- Notes how much the running job works through, so runs of different sizes can be compared.
---@param job string
---@param size number
---@param unit string such as "auctions"
function ns.Profile.Size(job, size, unit)
  local state = states[job]
  if state then
    state.run.size, state.run.unit = size, unit
  end
end

-- The job's latest run, finished or not.
---@param job string
---@return ArbitrageProfileRun?
function ns.Profile.GetRun(job)
  return runs[job]
end

-- How long measuring memory has taken, which the benchmark leaves out of what it times itself.
---@return number
function ns.Profile.GetProbeMs()
  return probeMs
end

---@param enabled boolean
function ns.Profile.SetTracing(enabled)
  tracing = enabled
  if type(ARBITRAGE_PROFILE) == "table" then
    ARBITRAGE_PROFILE.trace = enabled or nil
  end
end

---@param memory any
---@return boolean
local function IsMemory(memory)
  return memory == nil or (type(memory) == "table" and type(memory.heapKB) == "number")
end

-- Runs are only shown, but one saved by another version must not break showing them.
---@param run any
---@return boolean
local function IsRun(run)
  if
    type(run) ~= "table"
    or type(run.at) ~= "number"
    or type(run.ms) ~= "number"
    or type(run.frames) ~= "number"
    or type(run.maxFrameMs) ~= "number"
    or type(run.stages) ~= "table"
    or not IsMemory(run.memory)
    or (run.size ~= nil and (type(run.size) ~= "number" or type(run.unit) ~= "string"))
  then
    return false
  end
  for _, stage in ipairs(run.stages) do
    if
      type(stage) ~= "table"
      or type(stage.name) ~= "string"
      or type(stage.ms) ~= "number"
      or type(stage.maxFrameMs) ~= "number"
      or not IsMemory(stage.memory)
    then
      return false
    end
  end
  return true
end

---@param benchmarks any
---@return boolean
local function IsBenchmarkRun(benchmarks)
  if type(benchmarks) ~= "table" or type(benchmarks.at) ~= "number" or type(benchmarks.results) ~= "table" then
    return false
  end
  for _, result in ipairs(benchmarks.results) do
    if
      type(result) ~= "table"
      or type(result.name) ~= "string"
      or type(result.count) ~= "number"
      or type(result.ms) ~= "number"
      or type(result.allocatedKB) ~= "number"
    then
      return false
    end
  end
  return true
end

-- Keeps each job's last run and the last benchmarks across sessions, so they can be compared
-- after a reload.
function ns.Profile.Init()
  local saved = type(ARBITRAGE_PROFILE) == "table" and ARBITRAGE_PROFILE or {}
  local savedRuns = type(saved.runs) == "table" and saved.runs or {}
  for job, run in pairs(savedRuns) do
    if type(job) ~= "string" or not IsRun(run) then
      savedRuns[job] = nil
    end
  end
  runs = savedRuns
  tracing = saved.trace == true
  ARBITRAGE_PROFILE = {
    trace = saved.trace == true or nil,
    runs = runs,
    benchmarks = IsBenchmarkRun(saved.benchmarks) and saved.benchmarks or nil,
  }
  if tracing then
    Print("Tracing memory, which slows logins, scans, and tables. Type /arb profile trace to stop.")
  end
end

---@param ms number
---@return string
local function FormatMs(ms)
  if ms >= 100 then
    return ("%d ms"):format(math.floor(ms + 0.5))
  end
  return ("%.1f ms"):format(ms)
end

---@param kb number
---@return string
local function FormatMB(kb)
  return ("%.1f MB"):format(kb / 1024)
end

---@param count number
---@return string
local function FormatCount(count)
  local text = tostring(math.floor(count))
  local grouped
  repeat
    text, grouped = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until grouped == 0
  return text
end

---@param memory ArbitrageProfileMemory
---@return string
local function FormatMemory(memory)
  if not memory.addonKB then
    return "heap " .. FormatMB(memory.heapKB)
  end
  local text = "Arbitrage " .. FormatMB(memory.addonKB)
  if memory.dataKB then
    text = text .. ", Arbitrage_Data " .. FormatMB(memory.dataKB)
  end
  return text
end

---@param job string
---@param run ArbitrageProfileRun
local function PrintRun(job, run)
  local text = job .. ", " .. ns.Time.Since(run.at)
  if run.size then
    text = text .. ", " .. FormatCount(run.size) .. " " .. run.unit
  end
  text = text .. ": " .. FormatMs(run.ms)
  local spread = run.frames > 1
  if spread then
    text = text .. " over " .. FormatCount(run.frames) .. " frames, longest " .. FormatMs(run.maxFrameMs)
    if run.elapsedMs then
      text = text .. ("; %.1f s start to finish"):format(run.elapsedMs / 1000)
    end
  end
  if not run.finished then
    text = text .. " (stopped early)"
  end
  Print(text)
  for _, stage in ipairs(run.stages) do
    local line = "  " .. stage.name .. ": " .. FormatMs(stage.ms)
    if spread then
      line = line .. ", longest " .. FormatMs(stage.maxFrameMs)
    end
    if stage.memory then
      line = line .. "; " .. FormatMemory(stage.memory) .. " as it began"
    end
    Print(line)
  end
  if run.memory then
    Print("  Afterwards: " .. FormatMemory(run.memory))
  end
end

---@param result ArbitrageBenchmarkResult
---@return string
local function FormatBenchmark(result)
  local text = result.name .. ": " .. FormatCount(result.count) .. " in " .. FormatMs(result.ms)
  text = text .. ", " .. FormatMB(result.allocatedKB) .. " allocated"
  if result.count > 1 then
    local thousands = result.count / 1000
    text = text
      .. (" (%.1f ms and %s KB per 1,000)"):format(
        result.ms / thousands,
        FormatCount(result.allocatedKB / thousands + 0.5)
      )
  end
  return text
end

local function Report()
  local listed = {}
  for _, job in ipairs(JOB_ORDER) do
    if runs[job] then
      listed[#listed + 1] = job
    end
  end
  local ordered = {}
  for _, job in ipairs(JOB_ORDER) do
    ordered[job] = true
  end
  local others = {}
  for job in pairs(runs) do
    if not ordered[job] then
      others[#others + 1] = job
    end
  end
  table.sort(others)
  for _, job in ipairs(others) do
    listed[#listed + 1] = job
  end

  if #listed == 0 then
    Print("Nothing timed yet.")
  end
  for _, job in ipairs(listed) do
    PrintRun(job, runs[job])
  end
  local benchmarks = ARBITRAGE_PROFILE and ARBITRAGE_PROFILE.benchmarks
  if benchmarks then
    Print("Benchmarks, " .. ns.Time.Since(benchmarks.at) .. ":")
    for _, result in ipairs(benchmarks.results) do
      Print("  " .. FormatBenchmark(result))
    end
  end
  Print("Memory now: " .. FormatMemory(MeasureMemory(false)) .. ", garbage included")
  Print(
    "Tracing memory is "
      .. (tracing and "on" or "off")
      .. "; /arb profile trace turns it "
      .. (tracing and "off" or "on")
  )
end

-- Calls each(item) on every item until the deadline, reading the clock every few items.
---@param each fun(item: any)
---@param items any[]
---@param first number
---@param deadline number
---@return number next the next item to look up
local function LookUpUntil(each, items, first, deadline)
  local index = first
  while index <= #items do
    local last = math.min(#items, index + LOOKUPS_PER_CLOCK_READ - 1)
    for item = index, last do
      each(items[item])
    end
    index = last + 1
    if debugprofilestop() >= deadline then
      break
    end
  end
  return index
end

-- Looks items up for about a frame with the garbage collector paused, so the heap's growth is what
-- the lookups allocated. Collection restarts even when a lookup fails.
---@param benchmark { each: fun(item: any), items: any[] }
---@param first number
---@return number next, number ms, number allocatedKB
local function RunBurst(benchmark, first)
  collectgarbage("stop")
  local heapKB = collectgarbage("count")
  local started = debugprofilestop()
  local ok, nextOrError = pcall(LookUpUntil, benchmark.each, benchmark.items, first, started + BENCHMARK_FRAME_MS)
  local ms = debugprofilestop() - started
  local allocatedKB = collectgarbage("count") - heapKB
  collectgarbage("restart")
  if not ok then
    error(nextOrError, 0)
  end
  return nextOrError, ms, allocatedKB
end

-- The lookups tooltips, the tables, and the details panel make, over every item they could ask about.
local function Benchmarks()
  local keys = ns.Database.GetItemKeys()
  local craftable = {}
  for _, output in ipairs(ns.RecipeBook.GetCraftableOutputs()) do
    craftable[#craftable + 1] = output.outputItemID
  end
  return {
    {
      name = "Market Value",
      items = keys,
      each = function(dbKey)
        ns.RollingMarketValue.Get({ dbKey })
      end,
    },
    {
      name = "Buyout and Last Seen",
      items = keys,
      each = function(dbKey)
        ns.Database.GetLatestBuyout(dbKey)
        ns.Database.GetLastSeen(dbKey)
      end,
    },
    { name = "Daily values", items = keys, each = ns.Database.GetDailyValues },
    { name = "Craft Cost", items = craftable, each = ns.Crafting.GetCostForItemID },
    { name = "Opportunities", items = { true }, each = ns.Opportunities.Get },
  }
end

-- Times each benchmark over as many frames as it needs, then hands over the results.
---@param onDone fun(results: ArbitrageBenchmarkResult[])
---@return boolean started false when benchmarks are already running
function ns.Profile.RunBenchmarks(onDone)
  if benchmarking then
    return false
  end
  benchmarking = true

  local worker = coroutine.create(function()
    local results = {}
    for _, benchmark in ipairs(Benchmarks()) do
      local result = { name = benchmark.name, count = #benchmark.items, ms = 0, allocatedKB = 0 }
      local index = 1
      while index <= #benchmark.items do
        local ms, allocatedKB
        index, ms, allocatedKB = RunBurst(benchmark, index)
        result.ms = result.ms + ms
        result.allocatedKB = result.allocatedKB + allocatedKB
        coroutine.yield()
      end
      results[#results + 1] = result
    end
    return results
  end)

  local function Step()
    local ok, results = coroutine.resume(worker)
    if not ok then
      benchmarking = false
      error(results, 0)
    elseif coroutine.status(worker) == "dead" then
      benchmarking = false
      onDone(results)
    else
      C_Timer.After(0, Step)
    end
  end
  C_Timer.After(0, Step)
  return true
end

---@param argument string
function ns.Profile.HandleCommand(argument)
  if argument == "" then
    Report()
  elseif argument == "gc" then
    Print("Memory held after collecting garbage: " .. FormatMemory(MeasureMemory(true)))
  elseif argument == "trace" then
    ns.Profile.SetTracing(not tracing)
    if tracing then
      Print("Tracing memory at every stage from now on, and at login. It slows scans and tables until you turn it off.")
    else
      Print("Stopped tracing memory.")
    end
  elseif argument == "bench" then
    local started = ns.Profile.RunBenchmarks(function(results)
      -- Kept for /arb profile, and in saved variables to compare against later.
      if type(ARBITRAGE_PROFILE) == "table" then
        ARBITRAGE_PROFILE.benchmarks = { at = time(), results = results }
      end
      for _, result in ipairs(results) do
        Print(FormatBenchmark(result))
      end
    end)
    Print(started and "Running benchmarks..." or "Benchmarks are already running")
  else
    Print("/arb profile - Show how long logging in, scans, and tables took, and memory now")
    Print("/arb profile gc - Collect garbage, then show the memory still held")
    Print("/arb profile trace - Measure memory at every stage, collecting garbage each time")
    Print("/arb profile bench - Time the price lookups over every item")
  end
end

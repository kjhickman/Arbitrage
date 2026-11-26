-- Benchmarks Arbitrage the way a session uses it, running the addon's own files in a fake game
-- client: logging in, a Full Scan and a Quick Scan, the Opportunities and Database tabs, then the
-- price lookups /arb profile bench times. Timings come from the jobs /arb profile records, with
-- memory traced at every stage. It reads your saved data when given it, and otherwise makes up
-- data of the same shape; saved data is only ever read.
package.path = "scripts/bench/?.lua;" .. package.path

local Client = require("Client")
local Data = require("Data")

-- The client takes over print for the addon's chat, so the report keeps its own.
local Print = print

local ADDON = "Arbitrage"
-- Share of the market's items the client has loaded at login. WoW keeps item data between
-- sessions, and at three quarters a Full Scan's auctions waiting on item data hold about what a
-- real one's did: 50 MB in game, where Lua's tables take about a third more memory than here.
local CACHED_FRACTION = 0.75
-- How far a comparison may move before it is called out: slower by both, or holding more by both.
-- One run's timings wander by about a tenth, so compare medians of several runs.
local SLOWER_PERCENT, SLOWER_MS = 15, 2
local MORE_MEMORY_PERCENT, MORE_MEMORY_MB = 2, 0.25
local USAGE = [[
Usage: lua scripts/bench/Bench.lua [options]

  --runs N          Run N times and report each value's median (default 1)
  --out FILE        Save the results, to compare later runs against
  --compare FILE    Compare with saved results; exits with 1 when anything got slower or bigger
  --saved FILE      Your WTF/Account/<account>/SavedVariables/Arbitrage.lua
  --data FILE       Your Interface/AddOns/Arbitrage_Data/Database.lua
  --verbose         Show what the addon printed to chat

Without --saved, the benchmark makes up data shaped like one player's. ARBITRAGE_SAVED_VARIABLES
and ARBITRAGE_DATA name the files when --saved and --data don't.]]

---@class BenchRow
---@field label string
---@field key string what compares it with the same row of another run
---@field ms number? time spent working
---@field frames number?
---@field longest number? the longest frame
---@field heldMB number? memory held after collecting garbage
---@field allocatedMB number?

---@class BenchResults
---@field meta table<string, string|number>
---@field rows BenchRow[]

local FIELDS = { "ms", "frames", "longest", "heldMB", "allocatedMB" }

---@return table
local function ParseArguments()
  local function Environment(name)
    local value = os.getenv(name)
    return value ~= "" and value or nil
  end
  local options = { runs = 1, saved = Environment("ARBITRAGE_SAVED_VARIABLES"), data = Environment("ARBITRAGE_DATA") }
  local index = 1
  while index <= #arg do
    local flag, value = arg[index], arg[index + 1]
    if flag == "--verbose" or flag == "--child" then
      options[flag:sub(3)] = true
      index = index + 1
    elseif flag == "--runs" or flag == "--out" or flag == "--compare" or flag == "--saved" or flag == "--data" then
      assert(value, flag .. " needs a value")
      options[flag:sub(3)] = flag == "--runs" and assert(tonumber(value), "--runs needs a number") or value
      index = index + 2
    else
      Print(USAGE)
      os.exit(flag == "--help" and 0 or 2)
    end
  end
  return options
end

---@param value any
---@return any
local function Copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, entry in pairs(value) do
    copy[key] = Copy(entry)
  end
  return copy
end

---@param set table?
---@return number
local function CountKeys(set)
  local count = 0
  for _ in pairs(set or {}) do
    count = count + 1
  end
  return count
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

---@param options table
---@return BenchResults
local function RunOnce(options)
  local meta, rows = {}, {}
  local function Row(row)
    rows[#rows + 1] = row
  end

  collectgarbage("collect")
  local loadStarted = os.clock()
  if options.saved then
    assert(loadfile(options.saved), "reads " .. options.saved)()
    if options.data then
      assert(loadfile(options.data), "reads " .. options.data)()
    end
    meta.source = "your saved data"
  else
    Data.Synthesize()
    meta.source = "synthetic data"
  end
  local loadMs = (os.clock() - loadStarted) * 1000
  collectgarbage("collect")
  Row({
    label = options.saved and "Load saved variables" or "Make saved variables",
    key = "load",
    ms = loadMs,
    heldMB = collectgarbage("count") / 1024,
  })

  local realm, faction, region, market = Data.ChooseMarket()
  local knownItems, gearItems = Data.Items(market, realm, faction)
  local greyItems = {}
  for itemID in pairs(ARBITRAGE_GREY_ITEMS or {}) do
    greyItems[itemID] = true
  end
  local synced = ARBITRAGE_IMPORT and ARBITRAGE_IMPORT.realms and ARBITRAGE_IMPORT.realms[realm]
  synced = synced and synced.markets and synced.markets[faction]
  meta.market = realm .. " " .. faction
  meta.ownKeys = CountKeys(Data.OwnKeys(market))
  meta.syncedKeys = CountKeys(synced and synced.items)

  local client = Client.Install({
    now = Data.SessionTime(market, realm, faction),
    realm = realm,
    faction = faction,
    region = region,
    character = "Bench",
    cachedFraction = CACHED_FRACTION,
    knownItems = knownItems,
    gearItems = gearItems,
    greyItems = greyItems,
  })
  knownItems = nil

  -- The addon's files, in the order the game loads them.
  local ns = {}
  for line in io.lines("Arbitrage.toc") do
    local path = line:match("^(src/.+%.lua)%s*$")
    if path then
      assert(loadfile(path), "loads " .. path)(ADDON, ns)
    end
  end
  -- The options panel needs the game's Settings API, which the client doesn't model.
  ns.Config.RegisterOptionsPanel = function() end
  ARBITRAGE_PROFILE = { trace = true }

  -- Every run a job finishes, so a scenario reports its own even when a later run replaces it.
  local finished = {}
  local Finish = ns.Profile.Finish
  ns.Profile.Finish = function(job)
    local run = ns.Profile.GetRun(job)
    local active = run and not run.finished
    Finish(job)
    if active and run.finished then
      finished[#finished + 1] = { job = job, run = Copy(run) }
    end
  end

  ---@param key string
  ---@param label string
  ---@param run ArbitrageProfileRun
  local function JobRows(key, label, run)
    key = key .. " > " .. label
    local mostHeld = run.memory and run.memory.heapKB or 0
    for _, stage in ipairs(run.stages) do
      mostHeld = math.max(mostHeld, stage.memory and stage.memory.heapKB or 0)
    end
    Row({
      label = "  " .. label,
      key = key,
      ms = run.ms,
      frames = run.frames,
      longest = run.maxFrameMs,
      heldMB = mostHeld / 1024,
    })
    for _, stage in ipairs(run.stages) do
      Row({
        label = "    " .. stage.name,
        key = key .. " > " .. stage.name,
        ms = stage.ms,
        longest = stage.maxFrameMs,
        heldMB = stage.memory and stage.memory.heapKB / 1024,
      })
    end
  end

  -- Runs one part of the session, then reports its time and what it left held, and the slowest
  -- run of each job it names: a table first draws empty while its rows are read, for one.
  ---@param name string
  ---@param jobs string[]
  ---@param action fun()
  local function Scenario(name, jobs, action)
    finished = {}
    collectgarbage("collect")
    local probeMs, started, frames = ns.Profile.GetProbeMs(), os.clock(), client.frames
    action()
    local ms = (os.clock() - started) * 1000 - (ns.Profile.GetProbeMs() - probeMs)
    collectgarbage("collect")
    Row({ label = name, key = name, ms = ms, frames = client.frames - frames, heldMB = collectgarbage("count") / 1024 })
    for _, job in ipairs(jobs) do
      local slowest
      for _, entry in ipairs(finished) do
        if entry.job == job and (not slowest or entry.run.ms > slowest.ms) then
          slowest = entry.run
        end
      end
      if slowest then
        JobRows(name, job, slowest)
      end
    end
    if options.verbose then
      for _, message in ipairs(client.messages) do
        Print("    | " .. message)
      end
    end
    client.messages = {}
  end

  local function IsIdle()
    return ns.Scan.GetStatus().phase == "idle"
  end

  Scenario("Login", { "Login" }, function()
    client.FireEvent("ADDON_LOADED", ADDON)
    client.Settle()
  end)

  Scenario("Opportunities tab", { "Opportunities", "Opportunities Table" }, function()
    ns.Window.Toggle()
    client.Settle()
    ns.Window.Toggle()
  end)

  local auctions = Data.Auctions(market, greyItems)
  meta.auctions = auctions.count
  Scenario("Full Scan", { "Full Scan" }, function()
    client.SetAuctionHouseOpen(true)
    client.FireEvent("AUCTION_HOUSE_SHOW")
    _G.ArbitrageAuctionHouseFrame:Show()
    ns.Scan.Start()
    -- Blizzard takes a while to answer.
    client.RunFrames(60)
    client.SetReplicate(auctions)
    client.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    client.RunUntil(IsIdle, 200000)
    client.Settle()
  end)

  local browseResults = Data.BrowseResults(auctions, greyItems)
  client.SetReplicate(nil)
  auctions = nil
  Scenario("Quick Scan", { "Quick Scan" }, function()
    client.Advance(120)
    ns.Scan.StartQuick()
    client.SetBrowseResults(browseResults)
    client.RunFrames(30)
    client.FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    client.RunUntil(IsIdle, 200000)
    client.Settle()
    client.FireEvent("AUCTION_HOUSE_CLOSED")
    client.SetAuctionHouseOpen(false)
    _G.ArbitrageAuctionHouseFrame:Hide()
  end)
  client.SetBrowseResults(nil)
  browseResults = nil

  local window, databaseTab
  Scenario("Database tab", { "Database Index", "Database Table" }, function()
    ns.Window.Toggle()
    window = _G.ArbitrageWindow
    databaseTab = client.FindFrames(window, function(frame)
      return rawget(frame, "parent") == window and frame.frameType == "Frame" and frame.template == nil
    end)[2]
    local tab = _G.ArbitrageWindowTab2
    tab:GetScript("OnClick")(tab)
    client.RunUntil(function()
      local run = ns.Profile.GetRun("Database Index")
      return run ~= nil and run.finished == true
    end, 200000)
    client.Settle()
  end)

  -- Sorting by each column, then searching, each from the table as the last left it.
  Scenario("Sorting and searching", {}, function()
    local function Act(label, action)
      local first = #finished + 1
      action()
      client.Settle()
      for index = first, #finished do
        if finished[index].job == "Database Table" then
          finished[index].job = "Database Table: " .. label
          break
        end
      end
    end
    for _, column in ipairs({
      ns.Terminology.current.label,
      ns.Terminology.typicalCraftCost.label,
      "Last Seen",
      ns.Terminology.typical.label,
      "Item",
    }) do
      local header = client.FindFrames(databaseTab, function(frame)
        return frame.template == "ColumnDisplayButtonShortTemplate" and frame.text == column
      end)[1]
      Act("sort by " .. column, function()
        header:GetScript("OnClick")(header)
      end)
    end
    local searchBox = client.FindFrames(databaseTab, function(frame)
      return frame.template == "SearchBoxTemplate"
    end)[1]
    Act("search", function()
      searchBox:SetText("of the")
    end)
    Act("clear search", function()
      searchBox:SetText("")
    end)
    ns.Window.Toggle()
  end)
  for _, entry in ipairs(finished) do
    if entry.job:find("^Database Table: ") then
      JobRows("Sorting and searching", entry.job, entry.run)
    end
  end

  -- A scan or a vendor visit changes prices while the window is closed, as it does in play.
  Scenario("Prices change while closed", {}, function()
    ns.DatabaseIndex.Invalidate()
    client.Settle()
  end)

  local benchmarks
  Scenario("Lookups", {}, function()
    ns.Profile.RunBenchmarks(function(results)
      benchmarks = results
    end)
    client.RunUntil(function()
      return benchmarks ~= nil
    end, 200000)
  end)
  for _, result in ipairs(benchmarks) do
    Row({
      label = "  " .. result.name .. " (" .. FormatCount(result.count) .. ")",
      key = "Lookups > " .. result.name,
      ms = result.ms,
      allocatedMB = result.allocatedKB / 1024,
    })
  end

  meta.lua = _VERSION
  meta.date = os.date("!%Y-%m-%d %H:%M UTC")
  return { meta = meta, rows = rows }
end

-- Results ----------------------------------------------------------------------------------------

---@param value any
---@return string
local function Serialize(value)
  if type(value) == "table" then
    local parts = {}
    for key, entry in pairs(value) do
      local name = type(key) == "number" and "[" .. key .. "]" or "[" .. string.format("%q", key) .. "]"
      parts[#parts + 1] = name .. " = " .. Serialize(entry)
    end
    table.sort(parts)
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
  elseif type(value) == "number" then
    return string.format("%.17g", value)
  end
  return string.format("%q", tostring(value))
end

---@param path string
---@param results BenchResults
local function Save(path, results)
  local file = assert(io.open(path, "w"))
  file:write("return ", Serialize(results), "\n")
  file:close()
end

---@param path string
---@return BenchResults
local function Load(path)
  return assert(loadfile(path), "reads " .. path)()
end

-- Each value's median across the runs, which ran the same session.
---@param runs BenchResults[]
---@return BenchResults
local function Median(runs)
  local merged = runs[1]
  for rowIndex, row in ipairs(merged.rows) do
    for _, field in ipairs(FIELDS) do
      if row[field] then
        local values = {}
        for _, run in ipairs(runs) do
          values[#values + 1] = run.rows[rowIndex][field]
        end
        table.sort(values)
        local middle = math.floor((#values + 1) / 2)
        row[field] = #values % 2 == 1 and values[middle] or (values[middle] + values[middle + 1]) / 2
      end
    end
  end
  merged.meta.runs = #runs
  return merged
end

---@param options table
---@return BenchResults
local function RunAll(options)
  if options.runs <= 1 then
    return RunOnce(options)
  end
  local interpreter = arg[-1] or "lua"
  local runs = {}
  for run = 1, options.runs do
    io.stderr:write(("run %d of %d\n"):format(run, options.runs))
    local path = os.tmpname()
    local command = ('%s scripts/bench/Bench.lua --child --out "%s"'):format(interpreter, path)
    if options.saved then
      command = command .. (' --saved "%s"'):format(options.saved)
    end
    if options.data then
      command = command .. (' --data "%s"'):format(options.data)
    end
    local status = os.execute(command)
    assert(status == 0 or status == true, "run " .. run .. " failed")
    runs[run] = Load(path)
    os.remove(path)
  end
  return Median(runs)
end

-- Report -----------------------------------------------------------------------------------------

---@param value number?
---@param decimals number
---@return string
local function Cell(value, decimals)
  if value == nil then
    return ""
  end
  return decimals == 0 and FormatCount(value) or ("%." .. decimals .. "f"):format(value)
end

-- How a value moved from the baseline, and whether that's worth calling out.
---@param field string
---@param now number?
---@param before number?
---@return string change, string? warning
local function Change(field, now, before)
  if not now or not before or field == "frames" then
    return ""
  end
  local percent = before ~= 0 and (now - before) / before * 100 or 0
  local text = math.abs(percent) < 0.5 and "" or ("%+.0f%%"):format(percent)
  local isMemory = field == "heldMB" or field == "allocatedMB"
  if isMemory and percent > MORE_MEMORY_PERCENT and now - before > MORE_MEMORY_MB then
    return text, "more memory"
  elseif not isMemory and percent > SLOWER_PERCENT and now - before > SLOWER_MS then
    return text, "slower"
  end
  return text
end

---@param results BenchResults
---@param baseline BenchResults?
---@return number regressions
local function Report(results, baseline)
  local meta = results.meta
  Print(
    ("Arbitrage benchmark: %s, %s (%s own keys, %s synced keys, %s auctions)%s"):format(
      meta.source,
      meta.market,
      FormatCount(meta.ownKeys),
      FormatCount(meta.syncedKeys),
      FormatCount(meta.auctions),
      meta.runs and ", median of " .. meta.runs .. " runs" or ""
    )
  )
  local before = {}
  if baseline then
    Print(("Compared with %s from %s"):format(baseline.meta.source, baseline.meta.date))
    for _, row in ipairs(baseline.rows) do
      before[row.key] = row
    end
  end

  local width = baseline and 17 or 11
  local columns = {
    { "ms", "Work ms", 1 },
    { "frames", "Frames", 0 },
    { "longest", "Longest ms", 1 },
    { "heldMB", "Held MB", 1 },
    { "allocatedMB", "Alloc MB", 1 },
  }
  local header = ("%-46s"):format("")
  for _, column in ipairs(columns) do
    header = header .. ("%" .. width .. "s"):format(column[2])
  end
  Print(header)

  local regressions = 0
  for _, row in ipairs(results.rows) do
    local line = ("%-46s"):format(row.label)
    local warnings = {}
    for _, column in ipairs(columns) do
      local field = column[1]
      local text = Cell(row[field], column[3])
      local baseRow = before[row.key]
      if baseRow then
        local change, warning = Change(field, row[field], baseRow[field])
        text = text .. (change ~= "" and " " .. ("%5s"):format(change) or "      ")
        if warning and not warnings[warning] then
          warnings[warning] = true
          warnings[#warnings + 1] = warning
        end
      end
      line = line .. ("%" .. width .. "s"):format(text)
    end
    if #warnings > 0 then
      regressions = regressions + 1
      line = line .. "  <- " .. table.concat(warnings, ", ")
    end
    Print(line)
  end
  Print("")
  Print("Work ms leaves out the time spent measuring memory. Held MB is the whole Lua heap after collecting")
  Print("garbage: after each scenario, at the start of each stage, and for a job the most held at any stage.")
  Print("Lookups pause the garbage collector, so Alloc MB is everything they allocated.")
  if baseline then
    Print(regressions == 0 and "Nothing got slower or bigger." or regressions .. " rows got slower or bigger.")
  end
  return regressions
end

local options = ParseArguments()
local results = RunAll(options)
if options.out then
  Save(options.out, results)
end
if not options.child then
  local baseline = options.compare and Load(options.compare)
  local regressions = Report(results, baseline)
  if baseline and regressions > 0 then
    os.exit(1)
  end
end

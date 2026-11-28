local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Profile", function()
  local environment
  local ns
  local clock
  local collections
  local gcState
  local timers

  -- Steps the clock forward, as work or a wait between frames would.
  local function Spend(milliseconds)
    clock = clock + milliseconds
  end

  local function RunTimers()
    while #timers > 0 do
      table.remove(timers, 1)()
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    clock = 0
    collections = 0
    gcState = "running"
    timers = {}

    function debugprofilestop()
      return clock
    end

    function time()
      return 5000
    end

    function print() end

    -- Collecting garbage takes 40 ms, which no timing should count.
    function collectgarbage(option)
      if option == "collect" then
        collections = collections + 1
        clock = clock + 40
      elseif option == "stop" then
        gcState = "stopped"
      elseif option == "restart" then
        gcState = "running"
      end
      return 2048
    end

    C_Timer = {
      After = function(_, callback)
        timers[#timers + 1] = callback
      end,
    }

    ns = {}
    assert(loadfile("src/Terminology.lua"), "loads Terminology.lua")("Arbitrage", ns)
    assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
  end)

  it("counts the work in each frame but not the wait between frames", function()
    setfenv(1, environment)
    ns.Profile.Start("Full Scan", "Reading")
    Spend(6)
    ns.Profile.Pause("Full Scan")
    Spend(100)
    ns.Profile.Resume("Full Scan")
    Spend(4)
    ns.Profile.Finish("Full Scan")

    local run = ns.Profile.GetRun("Full Scan")
    assert.are.equal(10, run.ms)
    assert.are.equal(2, run.frames)
    assert.are.equal(6, run.maxFrameMs)
    assert.are.equal(110, run.elapsedMs)
    assert.is_true(run.finished)
  end)

  it("splits a frame between the stages it worked in", function()
    setfenv(1, environment)
    ns.Profile.Start("Full Scan", "Pricing")
    Spend(3)
    ns.Profile.Stage("Full Scan", "Saving")
    Spend(5)
    ns.Profile.Pause("Full Scan")
    ns.Profile.Resume("Full Scan")
    Spend(2)
    ns.Profile.Finish("Full Scan")

    local run = ns.Profile.GetRun("Full Scan")
    assert.are.same({ "Pricing", "Saving" }, { run.stages[1].name, run.stages[2].name })
    assert.are.equal(3, run.stages[1].ms)
    assert.are.equal(7, run.stages[2].ms)
    assert.are.equal(5, run.stages[2].maxFrameMs)
    assert.are.equal(8, run.maxFrameMs)
  end)

  it("measures memory at every stage while tracing, without timing the collections", function()
    setfenv(1, environment)
    ns.Profile.SetTracing(true)
    ns.Profile.Start("Login", "Database")
    Spend(3)
    ns.Profile.Stage("Login", "Recipes")
    Spend(2)
    ns.Profile.Finish("Login")

    local run = ns.Profile.GetRun("Login")
    assert.are.equal(3, collections)
    assert.are.equal(2048, run.stages[1].memory.heapKB)
    assert.are.equal(2048, run.memory.heapKB)
    assert.are.equal(3, run.stages[1].ms)
    assert.are.equal(5, run.ms)
    assert.are.equal(5, run.elapsedMs)
  end)

  it("keeps a nested job's collections out of the job around it", function()
    setfenv(1, environment)
    ns.Profile.Start("Full Scan", "Refreshing")
    ns.Profile.SetTracing(true)
    Spend(1)
    ns.Profile.Start("Opportunities", "Pricing")
    Spend(2)
    ns.Profile.Finish("Opportunities")
    ns.Profile.Finish("Full Scan")

    assert.are.equal(3, ns.Profile.GetRun("Full Scan").ms)
  end)

  it("keeps each job's last run across sessions and drops runs it can't show", function()
    setfenv(1, environment)
    local login = {
      at = 10,
      ms = 812,
      frames = 1,
      maxFrameMs = 812,
      stages = { { name = "Database", ms = 640, maxFrameMs = 640 } },
    }
    ARBITRAGE_PROFILE = { trace = true, runs = { Login = login, Broken = { ms = "slow" } } }

    ns.Profile.Init()

    assert.are.equal(login, ns.Profile.GetRun("Login"))
    assert.is_nil(ns.Profile.GetRun("Broken"))
    assert.is_true(ARBITRAGE_PROFILE.trace)
  end)

  it("notes how much a run worked through, and keeps it across sessions", function()
    setfenv(1, environment)
    ns.Profile.Start("Full Scan", "Reading")
    ns.Profile.Size("Full Scan", 84213, "auctions")
    ns.Profile.Finish("Full Scan")
    ns.Profile.Size("Full Scan", 1, "auctions")

    local run = ns.Profile.GetRun("Full Scan")
    assert.are.same({ 84213, "auctions" }, { run.size, run.unit })

    ARBITRAGE_PROFILE =
      { runs = { ["Full Scan"] = run, Broken = { at = 1, ms = 1, frames = 1, maxFrameMs = 1, stages = {}, size = 5 } } }
    ns.Profile.Init()
    assert.are.equal(run, ns.Profile.GetRun("Full Scan"))
    assert.is_nil(ns.Profile.GetRun("Broken"))
  end)

  it("saves the benchmarks so they can be compared after a reload", function()
    setfenv(1, environment)
    ns.Time = {
      Since = function()
        return "just now"
      end,
    }
    ns.Database = {
      GetItemKeys = function()
        return { "2589", "4306" }
      end,
    }
    ns.RecipeBook = {
      GetCraftableOutputs = function()
        return {}
      end,
    }
    ns.RollingMarketValue = { Get = function() end }
    ns.Database.GetLatestBuyout = function() end
    ns.Database.GetLastSeen = function() end
    ns.Database.GetDailyValues = function() end
    ns.Crafting = { GetCostForItemID = function() end }
    ns.Opportunities = { Get = function() end }
    ns.Profile.Init()

    ns.Profile.HandleCommand("bench")
    RunTimers()

    local saved = ARBITRAGE_PROFILE.benchmarks
    assert.are.equal(5000, saved.at)
    assert.are.same({ "Market Value", 2 }, { saved.results[1].name, saved.results[1].count })
    ns.Profile.Init()
    assert.are.equal(saved, ARBITRAGE_PROFILE.benchmarks)

    ARBITRAGE_PROFILE.benchmarks = { at = 1, results = { { name = "Market Value" } } }
    ns.Profile.Init()
    assert.is_nil(ARBITRAGE_PROFILE.benchmarks)
  end)

  it("restarts garbage collection when a benchmark's lookup fails", function()
    setfenv(1, environment)
    ns.Database = {
      GetItemKeys = function()
        return { "2589" }
      end,
    }
    ns.RecipeBook = {
      GetCraftableOutputs = function()
        return {}
      end,
    }
    ns.RollingMarketValue = {
      Get = function()
        error("bad price")
      end,
    }
    ns.Crafting = { GetCostForItemID = function() end }
    ns.Opportunities = { Get = function() end }

    ns.Profile.RunBenchmarks(function() end)

    assert.has_error(RunTimers, "bad price")
    assert.are.equal("running", gcState)
  end)
end)

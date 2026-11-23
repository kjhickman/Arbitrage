local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Main", function()
  local environment
  local onEvent
  local messages
  local startFullScan
  local quickScanProcessor
  local groups
  local savedResults
  local savedTimestamp
  local savedBuyouts
  local saveCount
  local returnKeys
  local opportunityPanelRegisterCount
  local opportunityPanelRefreshCount
  local windowToggleCount
  local craftingWindowRegisterCount
  local craftingWindowRefreshCount
  local minimapButtonRegisterCount
  local databaseInvalidateCount
  local settingsOpenCount
  local forgottenCharacter
  local knownCharacters
  local ns

  -- Adds the entries to a new full scan the way the scan reads them, then finishes it.
  local function ProcessScan(entries, rawCount, checkpoint)
    local pricing = startFullScan()
    for _, entry in ipairs(entries) do
      pricing.Add(entry.itemID, entry.itemLink, entry.quantity, entry.buyout)
    end
    return pricing.Finish(rawCount, checkpoint)
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    messages = {}
    startFullScan = nil
    quickScanProcessor = nil
    groups = nil
    savedResults = nil
    savedTimestamp = nil
    savedBuyouts = nil
    saveCount = 0
    returnKeys = true
    opportunityPanelRegisterCount = 0
    opportunityPanelRefreshCount = 0
    windowToggleCount = 0
    craftingWindowRegisterCount = 0
    craftingWindowRefreshCount = 0
    minimapButtonRegisterCount = 0
    databaseInvalidateCount = 0
    settingsOpenCount = 0
    forgottenCharacter = nil
    knownCharacters = { "Hammer Homie", "Zug Zugzwang" }

    function CreateFrame()
      return {
        RegisterEvent = function() end,
        UnregisterEvent = function() end,
        SetScript = function(_, _, callback)
          onEvent = callback
        end,
      }
    end

    SlashCmdList = {}

    function print(message)
      messages[#messages + 1] = message
    end

    local function Noop() end

    ns = {
      OpportunityPanel = {
        Refresh = function()
          opportunityPanelRefreshCount = opportunityPanelRefreshCount + 1
        end,
        Register = function()
          opportunityPanelRegisterCount = opportunityPanelRegisterCount + 1
        end,
      },
      Window = {
        Toggle = function()
          windowToggleCount = windowToggleCount + 1
        end,
      },
      Config = {
        Init = Noop,
        OpenOptionsPanel = function()
          settingsOpenCount = settingsOpenCount + 1
        end,
        RegisterOptionsPanel = Noop,
      },
      Database = {
        CountVendorPrices = function()
          return 2
        end,
        GetStatus = function()
          return { itemCount = 3, latestScan = nil, recentScanCount = 4 }
        end,
        Init = Noop,
        SaveScan = function(results, timestamp, latestBuyouts, checkpoint)
          checkpoint()
          saveCount = saveCount + 1
          savedResults = results
          savedTimestamp = timestamp
          savedBuyouts = latestBuyouts
          return 1
        end,
      },
      Keys = {
        FromLink = function()
          return returnKeys and { "100" } or {}
        end,
        FromItemID = function(itemID)
          return returnKeys and { tostring(itemID) } or {}
        end,
      },
      RecipeBook = {
        ForgetCharacter = function(name)
          forgottenCharacter = name
          if name:lower() == "zug zugzwang" then
            return "Zug Zugzwang"
          end
          return nil
        end,
        GetCharacterNames = function()
          return knownCharacters
        end,
        GetStatus = function()
          return { recipeCount = 5, characterCount = 1 }
        end,
        Init = Noop,
      },
      RecipeCapture = { Register = Noop },
      TrainerWindow = { Register = Noop, Refresh = Noop },
      CraftingWindow = {
        Register = function()
          craftingWindowRegisterCount = craftingWindowRegisterCount + 1
        end,
        Refresh = function()
          craftingWindowRefreshCount = craftingWindowRefreshCount + 1
        end,
      },
      DatabaseIndex = {
        Invalidate = function()
          databaseInvalidateCount = databaseInvalidateCount + 1
        end,
      },
      Scan = {
        Init = function(startPricing, processQuick)
          startFullScan = startPricing
          quickScanProcessor = processQuick
        end,
      },
      MinimapButton = {
        Register = function()
          minimapButtonRegisterCount = minimapButtonRegisterCount + 1
        end,
      },
      Tooltip = { Register = Noop },
      Vendor = { Register = Noop },
    }

    assert(loadfile("src/Profile.lua"), "loads Profile.lua")("Arbitrage", ns)
    -- Auctions are grouped into real listings; only the calculation is stubbed.
    assert(loadfile("src/MarketValue.lua"), "loads MarketValue.lua")("Arbitrage", ns)
    function ns.MarketValue.CalculateAll(value, checkpoint)
      groups = value
      checkpoint()
      checkpoint(1, 2)
      checkpoint(2, 2)
      return { ["100"] = 55 }
    end

    function time()
      return 123
    end

    function strtrim(value)
      return value:match("^%s*(.-)%s*$")
    end

    strlower = string.lower

    assert(loadfile("src/Main.lua"), "loads Main.lua")("Arbitrage", ns)
    onEvent(nil, "ADDON_LOADED", "Arbitrage")
  end)

  it("registers the opportunity panel and the /arb command", function()
    setfenv(1, environment)
    assert(opportunityPanelRegisterCount == 1, "registers the opportunity panel")
    assert.are.equal(1, craftingWindowRegisterCount)
    assert.are.equal(1, minimapButtonRegisterCount)
    assert(SLASH_ARBITRAGE1 == "/arb", "registers the /arb command")
  end)

  it("toggles the standalone window on bare /arb and prints command help on /arb help", function()
    setfenv(1, environment)
    SlashCmdList.ARBITRAGE("")
    assert.are.equal(1, windowToggleCount)
    assert.are.equal(0, #messages)

    SlashCmdList.ARBITRAGE("help")
    assert.are.equal(1, windowToggleCount)
    assert.are.equal(5, #messages)
    assert(messages[1]:find("/arb - Toggle the Arbitrage window", 1, true), "lists the bare window toggle first")
    assert(messages[2]:find("/arb help", 1, true), "lists help on its own line")
    assert(messages[3]:find("/arb status", 1, true), "lists status on its own line")
    assert(messages[4]:find("/arb settings", 1, true), "lists settings on its own line")
    assert(messages[5]:find("/arb forget <character>", 1, true), "lists forget on its own line")
  end)

  it("forgets a character's recipes or lists known characters when missing", function()
    setfenv(1, environment)
    SlashCmdList.ARBITRAGE("forget")
    assert(
      messages[#messages]:find("Usage: /arb forget <character> (known: Hammer Homie, Zug Zugzwang)", 1, true),
      "prints usage with known characters"
    )

    SlashCmdList.ARBITRAGE("forget Unknown Alt")
    assert.are.equal("Unknown Alt", forgottenCharacter)
    assert(
      messages[#messages]:find("No stored recipes for Unknown Alt (known: Hammer Homie, Zug Zugzwang)", 1, true),
      "reports unknown character with known characters"
    )

    SlashCmdList.ARBITRAGE("forget zug zugzwang")
    assert.are.equal("zug zugzwang", forgottenCharacter)
    assert.are.equal(1, opportunityPanelRefreshCount)
    assert.are.equal(1, craftingWindowRefreshCount)
    assert.are.equal(1, databaseInvalidateCount)
    assert(
      messages[#messages]:find("Removed stored recipes for Zug Zugzwang", 1, true),
      "confirms removing the canonical character name"
    )
  end)

  it("opens Arbitrage settings from its slash command", function()
    setfenv(1, environment)
    SlashCmdList.ARBITRAGE("settings")
    assert(settingsOpenCount == 1, "opens Arbitrage settings")
  end)

  it("reports only stored data and recent scans", function()
    setfenv(1, environment)
    SlashCmdList.ARBITRAGE("status")
    local prefix = "|cff00ccffArbitrage:|r "
    assert.are.same({
      prefix .. "Stored items: 3",
      prefix .. "Known vendor prices: 2",
      prefix .. "Known recipes: 5 across 1 characters",
      prefix .. "Last full scan: never",
      prefix .. "Last quick scan: never",
      prefix .. "Scans in last 14 days: 4",
    }, messages)
  end)

  it("reports when the last full and quick scans ran", function()
    setfenv(1, environment)
    assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
    ns.Database.GetStatus = function()
      return { itemCount = 3, latestScan = 3, latestQuickScan = 123, recentScanCount = 4 }
    end
    SlashCmdList.ARBITRAGE("status")
    local status = table.concat(messages, "\n")
    assert(status:find("Last full scan: 2 minutes ago", 1, true))
    assert(status:find("Last quick scan: just now", 1, true))
  end)

  it("refreshes price views when, and only when, a quick snapshot is saved", function()
    setfenv(1, environment)
    local buyouts = { ["2589"] = 345 }
    local shouldSave = false
    ns.Database.SaveQuickBuyouts = function(prices, at)
      assert.are.equal(buyouts, prices)
      assert.are.equal(122, at)
      return shouldSave
    end

    assert.is_false(quickScanProcessor(buyouts, 122))
    assert.are.equal(0, opportunityPanelRefreshCount)
    shouldSave = true
    assert.is_true(quickScanProcessor(buyouts, 122))
    assert.are.equal(1, opportunityPanelRefreshCount)
    assert.are.equal(1, craftingWindowRefreshCount)
    assert.are.equal(1, databaseInvalidateCount)
    assert.are.equal(0, saveCount)
    assert.is_nil(groups, "market values are not calculated")
  end)

  it("keys linked and item-ID auctions, normalizes prices, saves market values, and refreshes views", function()
    setfenv(1, environment)
    local outcome = ProcessScan({
      { itemID = 100, quantity = 2, buyout = 101 },
      { itemLink = "item:100", quantity = 1, buyout = 60 },
    })

    assert(groups["100"].quantities[51] == 2, "keys an item-ID auction and normalizes per-unit prices")
    assert(groups["100"].quantities[60] == 1, "keys a linked auction alongside it")
    assert(savedResults["100"] == 55, "stores calculated market values")
    assert(savedTimestamp == 123, "timestamps the completed scan")
    assert(savedBuyouts["100"] == 51, "stores the lowest per-unit buyout")
    assert(outcome:find("Full scan done", 1, true), "reports successful scan completion")
    assert(opportunityPanelRefreshCount == 1, "refreshes the Auction House status after saving a scan")
    assert.are.equal(1, craftingWindowRefreshCount)
    assert.are.equal(1, databaseInvalidateCount)
  end)

  it("reports progress while pricing and holds at 99% through saving", function()
    setfenv(1, environment)
    local progressHistory = {}
    local entries = {
      { itemID = 100, quantity = 2, buyout = 100 },
      { itemID = 200, quantity = 1, buyout = 60 },
    }
    ProcessScan(entries, #entries, function(progress)
      if not progress then
        return
      end
      local previous = progressHistory[#progressHistory] or 0
      if progress ~= previous then
        progressHistory[#progressHistory + 1] = progress
      end
    end)
    assert.are.same({ 49.5, 99 }, progressHistory)
    assert.are.equal(1, saveCount)
    assert.are.equal(1, opportunityPanelRefreshCount)
  end)

  describe("with a previously saved scan", function()
    before_each(function()
      setfenv(1, environment)
      ProcessScan({
        { itemLink = "item:100", quantity = 2, buyout = 101 },
        { itemLink = "item:100", quantity = 1, buyout = 60 },
      })
    end)

    it("keeps previous data when a non-empty scan has no usable auctions", function()
      setfenv(1, environment)
      assert(ProcessScan({}, 2):find("previous data kept", 1, true), "says the previous data was kept")
      assert(saveCount == 1, "keeps previous data when a non-empty scan has no usable auctions")
      assert(opportunityPanelRefreshCount == 1, "does not refresh status when scan data is kept")
      assert.are.equal(1, craftingWindowRefreshCount)
      assert.are.equal(1, databaseInvalidateCount)
    end)

    it("keeps previous data when auction links have no database keys", function()
      setfenv(1, environment)
      returnKeys = false
      ProcessScan({ { itemLink = "invalid", quantity = 1, buyout = 10 } }, 1)
      assert(saveCount == 1, "keeps previous data when auction links produce no database keys")
    end)

    it("defers saving until the sliced scan worker completes", function()
      setfenv(1, environment)
      local worker = coroutine.create(function()
        ProcessScan({ { itemLink = "item:100", quantity = 1, buyout = 75 } }, 1, function()
          coroutine.yield()
        end)
      end)
      local success, message = coroutine.resume(worker)
      assert(success, message)
      assert(saveCount == 1, "does not save before sliced calculation completes")
      while coroutine.status(worker) ~= "dead" do
        success, message = coroutine.resume(worker)
        assert(success, message)
      end
      assert(saveCount == 2, "passes the scan worker through calculation and saving")
    end)
  end)
end)

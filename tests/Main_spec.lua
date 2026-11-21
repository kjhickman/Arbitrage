local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Main", function()
  local environment
  local onEvent
  local messages
  local scanProcessor
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
  local databaseInvalidateCount
  local settingsOpenCount
  local forgottenCharacter
  local knownCharacters
  local settings
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    messages = {}
    scanProcessor = nil
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

    settings = {
      showMarketValue = true,
      showBuyout = false,
      showCraftingCost = true,
      showMinimumCraftCost = true,
      showCraftProfit = false,
      tooltipDetails = "shift",
      showCraftingWindowProfits = true,
      showUncertainOpportunities = true,
      minimumProfit = 250000,
      craftingWindowMinimumProfit = 5000,
    }

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
        Get = function(key)
          return settings[key]
        end,

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
        GetImportStatus = function()
          return false
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
      MarketValue = {
        CalculateAll = function(value, checkpoint)
          groups = value
          checkpoint()
          checkpoint(1, 2)
          checkpoint(2, 2)
          return { ["100"] = 55 }
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
        Init = function(process, processQuick)
          scanProcessor = process
          quickScanProcessor = processQuick
        end,
      },
      Tooltip = { Register = Noop },
      Vendor = { Register = Noop },
    }

    C_CurrencyInfo = {
      GetCoinTextureString = function(value)
        return tostring(value) .. "c"
      end,
    }

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

  it("reports stored data and every pricing visibility setting", function()
    setfenv(1, environment)
    local statusStart = #messages + 1
    SlashCmdList.ARBITRAGE("status")
    local status = table.concat(messages, "\n", statusStart)
    assert(status:find("Stored items: 3", 1, true), "keeps the status command")
    assert(status:find("Market Value: shown", 1, true), "reports the Market Value setting")
    assert(status:find("Buyout: hidden", 1, true), "reports the Buyout setting")
    assert(status:find("Craft Cost: shown", 1, true), "reports the Craft Cost setting")
    assert(status:find("Buyout Craft Cost: shown", 1, true), "reports the Buyout Craft Cost setting")
    assert(status:find("Craft Profit: hidden", 1, true), "reports the Craft Profit setting")
    assert(status:find("Pricing details: Hold Shift", 1, true), "reports the pricing detail mode")
    assert(status:find("Crafting window profits: shown", 1, true), "reports the crafting window profits setting")
    assert(status:find("Auction House minimum profit: 250000c", 1, true), "reports the Auction House threshold")
    assert(status:find("Crafting window minimum profit: 5000c", 1, true), "reports the crafting-window threshold")
    assert(status:find("Uncertain opportunities: shown", 1, true), "reports the uncertain opportunity setting")
    assert.is_nil(status:find("Best-case", 1, true))
  end)

  it("reports the Never pricing detail mode", function()
    setfenv(1, environment)
    settings.tooltipDetails = "compact"
    SlashCmdList.ARBITRAGE("status")
    assert(table.concat(messages, "\n"):find("Pricing details: Never", 1, true))
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

  it("reports when uncertain opportunities are hidden", function()
    setfenv(1, environment)
    settings.showUncertainOpportunities = false
    SlashCmdList.ARBITRAGE("status")
    local status = table.concat(messages, "\n")
    assert(status:find("Uncertain opportunities: hidden", 1, true))
  end)

  it("reports Craft Profit visibility independently of Craft Cost", function()
    setfenv(1, environment)
    settings.showCraftingCost = false
    settings.showCraftProfit = true
    SlashCmdList.ARBITRAGE("status")
    local status = table.concat(messages, "\n")
    assert(status:find("Craft Cost: hidden", 1, true), "reports a hidden Craft Cost")
    assert(status:find("Buyout Craft Cost: shown", 1, true), "keeps Buyout Craft Cost visible")
    assert(status:find("Craft Profit: shown", 1, true), "reports Craft Profit as shown")
    assert.is_nil(status:find("Vendor Profit", 1, true))
  end)

  it("reports disabled profit thresholds independently", function()
    setfenv(1, environment)
    settings.minimumProfit = 0
    SlashCmdList.ARBITRAGE("status")
    local status = table.concat(messages, "\n")
    assert(status:find("Auction House minimum profit: none, all crafts shown", 1, true))
    assert(status:find("Crafting window minimum profit: 5000c", 1, true))

    messages = {}
    settings.minimumProfit = 250000
    settings.craftingWindowMinimumProfit = 0
    SlashCmdList.ARBITRAGE("status")
    status = table.concat(messages, "\n")
    assert(status:find("Auction House minimum profit: 250000c", 1, true))
    assert(status:find("Crafting window minimum profit: none, all crafts shown", 1, true))
  end)

  it("reports how long ago the companion synced the prices the game loaded", function()
    setfenv(1, environment)
    assert(loadfile("src/Time.lua"), "loads Time.lua")("Arbitrage", ns)
    SlashCmdList.ARBITRAGE("status")
    assert(table.concat(messages, "\n"):find("Companion prices: none loaded", 1, true))

    messages = {}
    ns.Database.GetImportStatus = function()
      return true, time() - 2 * 60 * 60
    end
    SlashCmdList.ARBITRAGE("status")
    assert(table.concat(messages, "\n"):find("Companion prices: synced 2 hours ago", 1, true))

    messages = {}
    ns.Database.GetImportStatus = function()
      return true
    end
    SlashCmdList.ARBITRAGE("status")
    assert(table.concat(messages, "\n"):find("Companion prices: loaded, sync time unknown", 1, true))
  end)

  it("normalizes auction prices, saves market values, and refreshes the panel", function()
    setfenv(1, environment)
    local outcome = scanProcessor({
      { itemLink = "item:100", quantity = 2, buyout = 101 },
      { itemLink = "item:100", quantity = 1, buyout = 60 },
    })

    assert(groups["100"][1].price == 51 and groups["100"][1].quantity == 2, "normalizes per-unit prices")
    assert(groups["100"][2].price == 60 and groups["100"][2].quantity == 1, "keeps each auction quantity")
    assert(savedResults["100"] == 55, "stores calculated market values")
    assert(savedTimestamp == 123, "timestamps the completed scan")
    assert(savedBuyouts["100"] == 51, "stores the lowest per-unit buyout")
    assert(outcome:find("Full scan done", 1, true), "reports successful scan completion")
    assert(opportunityPanelRefreshCount == 1, "refreshes the Auction House status after saving a scan")
    assert.are.equal(1, craftingWindowRefreshCount)
    assert.are.equal(1, databaseInvalidateCount)
  end)

  it("keys auctions that carry an item ID instead of a link", function()
    setfenv(1, environment)
    scanProcessor({
      { itemID = 100, quantity = 2, buyout = 101 },
      { itemLink = "item:100", quantity = 1, buyout = 60 },
    })

    assert(groups["100"][1].price == 51, "keys an item-ID auction alongside a linked one")
    assert(groups["100"][2].price == 60, "keeps both auctions under the same key")
  end)

  it("reports progress while pricing and holds at 99% through saving", function()
    setfenv(1, environment)
    local progressHistory = {}
    local entries = {
      { itemID = 100, quantity = 2, buyout = 100 },
      { itemID = 200, quantity = 1, buyout = 60 },
    }
    scanProcessor(entries, #entries, function(progress)
      if not progress then
        return
      end
      local previous = progressHistory[#progressHistory] or 0
      if progress ~= previous then
        progressHistory[#progressHistory + 1] = progress
      end
    end)
    assert.are.same({ 10, 20, 59.5, 99 }, progressHistory)
    assert.are.equal(1, saveCount)
    assert.are.equal(1, opportunityPanelRefreshCount)
  end)

  describe("with a previously saved scan", function()
    before_each(function()
      setfenv(1, environment)
      scanProcessor({
        { itemLink = "item:100", quantity = 2, buyout = 101 },
        { itemLink = "item:100", quantity = 1, buyout = 60 },
      })
    end)

    it("keeps previous data when a non-empty scan has no usable auctions", function()
      setfenv(1, environment)
      assert(scanProcessor({}, 2):find("previous data kept", 1, true), "says the previous data was kept")
      assert(saveCount == 1, "keeps previous data when a non-empty scan has no usable auctions")
      assert(opportunityPanelRefreshCount == 1, "does not refresh status when scan data is kept")
      assert.are.equal(1, craftingWindowRefreshCount)
      assert.are.equal(1, databaseInvalidateCount)
    end)

    it("keeps previous data when auction links have no database keys", function()
      setfenv(1, environment)
      returnKeys = false
      scanProcessor({ { itemLink = "invalid", quantity = 1, buyout = 10 } }, 1)
      assert(saveCount == 1, "keeps previous data when auction links produce no database keys")
    end)

    it("defers saving until the sliced scan worker completes", function()
      setfenv(1, environment)
      local worker = coroutine.create(function()
        scanProcessor({ { itemLink = "item:100", quantity = 1, buyout = 75 } }, 1, function()
          coroutine.yield()
        end)
      end)
      local success, message = coroutine.resume(worker)
      assert(success, message)
      assert(saveCount == 1, "does not save before sliced grouping completes")
      while coroutine.status(worker) ~= "dead" do
        success, message = coroutine.resume(worker)
        assert(success, message)
      end
      assert(saveCount == 2, "passes the scan worker through grouping, calculation, and saving")
    end)
  end)
end)

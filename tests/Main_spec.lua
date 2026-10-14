local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Main", function()
  local environment
  local onEvent
  local messages
  local scanProcessor
  local groups
  local savedResults
  local savedTimestamp
  local savedBuyouts
  local saveCount
  local returnKeys
  local auctionHouseRegisterCount
  local auctionHouseRefreshCount
  local craftingWindowRegisterCount
  local craftingWindowRefreshCount
  local settingsOpenCount
  local settings
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    messages = {}
    scanProcessor = nil
    groups = nil
    savedResults = nil
    savedTimestamp = nil
    savedBuyouts = nil
    saveCount = 0
    returnKeys = true
    auctionHouseRegisterCount = 0
    auctionHouseRefreshCount = 0
    craftingWindowRegisterCount = 0
    craftingWindowRefreshCount = 0
    settingsOpenCount = 0

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
      showTooltips = true,
      showMarketValue = true,
      showCraftingCost = true,
      showMinimumCraftCost = true,
      tooltipDetails = "shift",
      includeBestCaseOnly = true,
      showUncertainOpportunities = true,
    }

    local function Noop() end

    ns = {
      AuctionHouse = {
        Refresh = function()
          auctionHouseRefreshCount = auctionHouseRefreshCount + 1
        end,
        Register = function()
          auctionHouseRegisterCount = auctionHouseRegisterCount + 1
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
      },
      MarketValue = {
        CalculateAll = function(value, checkpoint)
          groups = value
          checkpoint()
          return { ["100"] = 55 }
        end,
      },
      RecipeBook = {
        GetStatus = function()
          return { recipeCount = 5, characterCount = 1 }
        end,
        Init = Noop,
      },
      RecipeCapture = { Register = Noop },
      CraftingWindow = {
        Register = function()
          craftingWindowRegisterCount = craftingWindowRegisterCount + 1
        end,
        Refresh = function()
          craftingWindowRefreshCount = craftingWindowRefreshCount + 1
        end,
      },
      Scan = {
        Init = function(process)
          scanProcessor = process
        end,
      },
      Tooltip = { Register = Noop },
      Vendor = { Register = Noop },
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

  it("registers the Auction House panel and only the /arb alias", function()
    setfenv(1, environment)
    assert(auctionHouseRegisterCount == 1, "registers the Auction House panel")
    assert.are.equal(1, craftingWindowRegisterCount)
    assert(SLASH_ARBITRAGE1 == "/arb" and SLASH_ARBITRAGE2 == nil, "registers only the /arb alias")
  end)

  it("shows the same command help for /arb and /arb help", function()
    setfenv(1, environment)
    SlashCmdList.ARBITRAGE("")
    local emptyHelpStart = #messages - 2
    SlashCmdList.ARBITRAGE("help")
    for index = 0, 2 do
      assert(
        messages[emptyHelpStart + index] == messages[#messages - 2 + index],
        "/arb and /arb help show the same help"
      )
    end
    assert(messages[#messages - 2]:find("/arb help", 1, true), "lists help on its own line")
    assert(messages[#messages - 1]:find("/arb status", 1, true), "lists status on its own line")
    assert(messages[#messages]:find("/arb settings", 1, true), "lists settings on its own line")
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
    assert(status:find("Item tooltips: enabled", 1, true), "reports the tooltip master setting")
    assert(status:find("Market Value: shown", 1, true), "reports the Market Value setting")
    assert(status:find("Crafting Cost: shown", 1, true), "reports the Crafting Cost setting")
    assert(status:find("Best-case Crafting Cost: shown", 1, true), "reports the Best-case Crafting Cost setting")
    assert(status:find("Pricing details: Hold Shift", 1, true), "reports the pricing detail mode")
    assert(status:find("Best-case-only opportunities: included", 1, true), "reports the best-case-only setting")
    assert(status:find("Uncertain opportunities: shown", 1, true), "reports the uncertain opportunity setting")
  end)

  it("normalizes auction prices, saves market values, and refreshes the panel", function()
    setfenv(1, environment)
    scanProcessor({
      { itemLink = "item:100", quantity = 2, buyout = 101 },
      { itemLink = "item:100", quantity = 1, buyout = 60 },
    })

    assert(groups["100"][1].price == 51 and groups["100"][1].quantity == 2, "normalizes per-unit prices")
    assert(groups["100"][2].price == 60 and groups["100"][2].quantity == 1, "keeps each auction quantity")
    assert(savedResults["100"] == 55, "stores calculated market values")
    assert(savedTimestamp == 123, "timestamps the completed scan")
    assert(savedBuyouts["100"] == 51, "stores the lowest per-unit buyout")
    assert(messages[#messages]:find("Full scan done", 1, true), "reports successful scan completion")
    assert(auctionHouseRefreshCount == 1, "refreshes the Auction House status after saving a scan")
    assert.are.equal(1, craftingWindowRefreshCount)
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
      scanProcessor({}, 2)
      assert(saveCount == 1, "keeps previous data when a non-empty scan has no usable auctions")
      assert(auctionHouseRefreshCount == 1, "does not refresh status when scan data is kept")
      assert.are.equal(1, craftingWindowRefreshCount)
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

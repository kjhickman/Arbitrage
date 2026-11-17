local NewEnvironment = dofile("tests/support/Environment.lua")

describe("AuctionHousePanel", function()
  local environment
  local harness
  local components
  local tab
  local panel
  local tableBackground
  local scanButton
  local filterDropdown
  local settingsButton
  local glossaryButton
  local auctionHouseFrame

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness =
      assert(environment.loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    components = nil
    tab = nil
    panel = nil
    tableBackground = nil
    scanButton = nil
    filterDropdown = nil
    settingsButton = nil
    glossaryButton = nil
    auctionHouseFrame = nil
  end)

  it("waits for the load-on-demand Auction House UI", function()
    setfenv(1, environment)
    assert(harness.events.AUCTION_HOUSE_SHOW, "waits for the load-on-demand Auction House UI")
  end)

  describe("when the Auction House opens", function()
    before_each(function()
      setfenv(1, environment)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      components = harness.FindComponents()
      tab = components.tab
      panel = components.panel
      tableBackground = components.tableBackground
      scanButton = components.scanButton
      filterDropdown = components.filterDropdown
      settingsButton = components.settingsButton
      glossaryButton = components.glossaryButton
      auctionHouseFrame = harness.auctionHouseFrame
    end)

    it("registers and sizes a LibAHTab tab on Forever without tainting native tabs", function()
      setfenv(1, environment)
      assert(tab and tab.parent.parent == auctionHouseFrame, "creates a LibAHTab-managed Auction House tab")
      assert(tab.text == "Arbitrage", "labels the tab")
      assert(
        tab.parent.points[1][2] == auctionHouseFrame.AuctionsTab
          and tab.points[1][2] == tab.parent
          and tab.points[1][4] == 3,
        "leaves space after the Auctions tab on Forever"
      )
      assert(tab.hitRectInsets[1] == 0 and tab.hitRectInsets[2] == 0, "keeps the full Forever tab clickable")
      assert(LibStub("LibAHTab-1-0"):GetButton("Arbitrage") == tab, "registers the tab with LibAHTab")
      assert(harness.GetResizedTab().tab == tab, "sizes the dynamic tab like Blizzard tabs")
      assert(
        #auctionHouseFrame.Tabs == 3 and next(auctionHouseFrame.tabsForDisplayMode) == nil,
        "does not taint Blizzard's native tab registration"
      )
    end)

    it("creates a hidden panel with the native Auction House table artwork and inset", function()
      setfenv(1, environment)
      assert(panel and panel.shown == false, "creates a hidden Arbitrage panel")
      assert(tableBackground and tableBackground.parent == panel, "creates a native Auction House table background")
      assert(
        tableBackground.Background.atlas == "auctionhouse-background-index",
        "uses the native Auction House list artwork"
      )
      assert(
        tableBackground.NineSlice.points[1][1] == "TOPLEFT"
          and tableBackground.NineSlice.points[1][3] == -19
          and tableBackground.NineSlice.points[2][1] == "BOTTOMRIGHT"
          and tableBackground.NineSlice.points[2][2] == -22
          and tableBackground.Background.points[2][1] == "BOTTOMRIGHT"
          and tableBackground.Background.points[2][2] == -25,
        "places the native inset below the headers and outside the scrollbar"
      )
    end)

    it("places scan, filter, settings, and glossary controls in the Auction House panel", function()
      setfenv(1, environment)
      assert(
        scanButton and scanButton.parent == panel and scanButton.text == "Full Scan",
        "creates the full scan button"
      )
      assert(scanButton.width == 132 and scanButton.height == 22, "sizes full scan like the Buy tab search button")
      assert(
        scanButton.points[1][1] == "TOPRIGHT"
          and scanButton.points[1][2] == auctionHouseFrame
          and scanButton.points[1][3] == "TOPRIGHT"
          and scanButton.points[1][4] == -12
          and scanButton.points[1][5] == -38,
        "places full scan where the Buy tab places Search"
      )
      assert(
        filterDropdown
          and filterDropdown.parent == panel
          and filterDropdown.frameType == "DropdownButton"
          and filterDropdown.width == 93,
        "creates a native filter dropdown sized like the Buy tab filter button"
      )
      assert(
        filterDropdown.points[1][1] == "RIGHT"
          and filterDropdown.points[1][2] == scanButton
          and filterDropdown.points[1][3] == "LEFT"
          and filterDropdown.points[1][4] == -10,
        "places filter immediately left of full scan"
      )
      assert(
        settingsButton and settingsButton.parent == panel and settingsButton.text == "Settings",
        "creates the settings button"
      )
      assert(
        settingsButton.points[1][1] == "RIGHT"
          and settingsButton.points[1][2] == filterDropdown
          and settingsButton.points[1][3] == "LEFT"
          and settingsButton.points[1][4] == -10,
        "places settings immediately left of filter"
      )
      assert(glossaryButton and glossaryButton.parent == panel, "creates a pricing glossary button")
    end)

    it("filters minimum profit, best-case, and uncertain opportunities live and resets to defaults", function()
      setfenv(1, environment)
      tab:Click()
      local callsBefore = harness.GetOpportunityCalls()
      local menu = filterDropdown:OpenMenu()
      assert.are.equal("MENU_ARBITRAGE_OPPORTUNITIES_FILTER", menu.tag)
      assert.are.equal(3, #menu.entries)
      assert.is_false(filterDropdown.ResetButton.shown)

      local profitMenu = menu.entries[1]
      local bestCaseCheckbox = menu.entries[2]
      local uncertainCheckbox = menu.entries[3]
      local labels = {}
      for _, option in ipairs(profitMenu.entries) do
        labels[option.value] = option.label
      end
      assert.are.equal("Show all crafts", labels[0])
      assert.are.equal("Any profit", labels[1])
      assert.are.equal("200c", labels[200])
      assert.are.equal("500c", labels[500])
      assert.are.equal("1000000c", labels[1000000])
      assert.is_true(profitMenu.entries[2]:IsSelected())

      profitMenu.entries[4]:Pick()
      assert.are.equal(500, harness.ns.Config.Get("minimumProfit"))
      assert.is_true(filterDropdown.ResetButton.shown)
      assert.are.equal(callsBefore + 1, harness.GetOpportunityCalls())
      assert.are.equal(1, harness.GetCraftingRefreshCalls())

      bestCaseCheckbox:Pick()
      uncertainCheckbox:Pick()
      assert.is_false(harness.ns.Config.Get("includeBestCaseOnly"))
      assert.is_false(harness.ns.Config.Get("showUncertainOpportunities"))
      assert.are.equal(callsBefore + 3, harness.GetOpportunityCalls())

      filterDropdown.ResetButton:Click()
      assert.are.equal(1, harness.ns.Config.Get("minimumProfit"))
      assert.is_true(harness.ns.Config.Get("includeBestCaseOnly"))
      assert.is_true(harness.ns.Config.Get("showUncertainOpportunities"))
      assert.is_false(filterDropdown.ResetButton.shown)
      assert.are.equal(callsBefore + 4, harness.GetOpportunityCalls())
    end)

    it("explains pricing and excluded costs in a glossary that hides on leave", function()
      setfenv(1, environment)
      local glossaryStart = #harness.tooltipLines
      glossaryButton.scripts.OnEnter(glossaryButton)
      local glossary = table.concat(harness.tooltipLines, "\n", glossaryStart + 1)
      assert(glossary:find("Market Value", 1, true), "defines Market Value in the glossary")
      assert(glossary:find("Crafting Cost", 1, true), "defines Crafting Cost in the glossary")
      assert(glossary:find("Best-case Crafting Cost", 1, true), "defines Best-case Crafting Cost in the glossary")
      assert(glossary:find("vendor sell value", 1, true), "explains vendor evaluation in the glossary")
      assert(glossary:find("Yellow values", 1, true), "explains uncertain values in the glossary")
      assert(glossary:find("deposits", 1, true), "lists excluded costs in the glossary")
      assert(GameTooltip.owner == glossaryButton, "anchors the glossary to its button")

      local glossaryHideCalls = harness.GetTooltipHideCalls()
      glossaryButton.scripts.OnLeave(glossaryButton)
      assert(harness.GetTooltipHideCalls() == glossaryHideCalls + 1, "hides the pricing glossary")
    end)

    it("switches between Arbitrage and native Auction House content", function()
      setfenv(1, environment)
      tab:Click()
      assert(
        type(harness.GetSelectedDisplayMode()) == "table" and #harness.GetSelectedDisplayMode() == 0,
        "hides native Auction House content"
      )
      assert(tab.selected and panel.shown, "selects the Arbitrage tab and panel")
      assert(harness.GetWindowTitle() == "Arbitrage", "updates the Auction House title")

      auctionHouseFrame:SetDisplayMode({ "BuyFrame" })
      assert(not tab.selected and not panel.shown, "returns to native Auction House tabs")
    end)

    it("shows compact recipe and scan status with an uncertainty explanation", function()
      setfenv(1, environment)
      tab:Click()
      local heading
      local summaryText
      local uncertaintyText
      for _, fontString in ipairs(harness.createdFontStrings) do
        if fontString.text == "Craft Opportunities" then
          heading = fontString
        elseif fontString.text and fontString.text:find("4 known crafts", 1, true) then
          summaryText = fontString
        elseif fontString.text == "Yellow values are uncertain; more market data is needed." then
          uncertaintyText = fontString
        end
      end
      assert(heading, "labels the opportunities page")
      assert(
        summaryText.text == "4 known crafts | 2 profitable | Last scan: 1 minute ago | 2 scans / 14 days",
        "shows compact recipe and scan status"
      )
      assert(summaryText.points[2][1] == "TOPRIGHT", "keeps the compact summary at its top anchor")
      assert(uncertaintyText and uncertaintyText.textColor[2] == 0.82, "explains the yellow uncertainty color")
    end)

    it("starts full scans and opens settings from the panel", function()
      setfenv(1, environment)
      tab:Click()
      scanButton:Click()
      assert(harness.GetScanCalls() == 1, "starts a full scan from the panel")
      settingsButton:Click()
      assert(harness.GetSettingsCalls() == 1, "opens Arbitrage settings from the panel")
    end)

    it("updates scan button state and summary text across scan phases and cooldowns", function()
      setfenv(1, environment)
      tab:Click()
      local summaryText
      for _, fontString in ipairs(harness.createdFontStrings) do
        if fontString.text and fontString.text:find("4 known crafts", 1, true) then
          summaryText = fontString
        end
      end
      local opportunityCallsBefore = harness.GetOpportunityCalls()

      harness.SetScanStatus({ phase = "waiting" })
      harness.ns.AuctionHouse.RefreshScanStatus()
      assert(not scanButton:IsEnabled(), "disables the scan button while waiting for the server")
      assert.are.equal("Scanning...", scanButton.text)
      assert.are.equal(
        "Scanning Auction House — waiting for server... Keep the Auction House open.",
        summaryText.text
      )

      harness.SetScanStatus({ phase = "reading", progress = 42 })
      harness.ns.AuctionHouse.RefreshScanStatus()
      assert(not scanButton:IsEnabled(), "keeps the scan button disabled while reading rows")
      assert.are.equal("Scanning... 42%", scanButton.text)
      assert.are.equal(
        "Scanning Auction House — reading auctions (42%)... Keep the Auction House open.",
        summaryText.text
      )

      harness.SetScanStatus({ phase = "pricing" })
      harness.ns.AuctionHouse.RefreshScanStatus()
      assert(not scanButton:IsEnabled(), "keeps the scan button disabled while pricing")
      assert.are.equal("Scanning...", scanButton.text)
      assert.are.equal(
        "Scanning Auction House — calculating prices... Keep the Auction House open.",
        summaryText.text
      )

      harness.SetScanStatus({ phase = "idle", cooldownRemainingMinutes = 8 })
      harness.ns.AuctionHouse.RefreshScanStatus()
      assert(not scanButton:IsEnabled(), "disables the scan button during the local cooldown")
      assert.are.equal("Full Scan (8m)", scanButton.text)
      assert.are.equal("4 known crafts | 2 profitable | Last scan: 1 minute ago | 2 scans / 14 days", summaryText.text)
      scanButton:Click()
      assert.are.equal(0, harness.GetScanCalls())

      harness.SetScanStatus({ phase = "idle" })
      harness.ns.AuctionHouse.RefreshScanStatus()
      assert(scanButton:IsEnabled(), "re-enables the scan button once the cooldown expires")
      assert.are.equal("Full Scan", scanButton.text)
      assert.are.equal(opportunityCallsBefore, harness.GetOpportunityCalls())
    end)

    describe("empty-state guidance", function()
      local emptyText
      local summaryText

      before_each(function()
        setfenv(1, environment)
        emptyText = nil
        summaryText = nil
        harness.SetOpportunityResult({ totalCount = 0, pricedCount = 0, profitableCount = 0, items = {} })
        harness.ns.AuctionHouse.Refresh()
        for _, fontString in ipairs(harness.createdFontStrings) do
          if fontString.text and fontString.text:find("No known recipes", 1, true) then
            emptyText = fontString
          elseif fontString.text and fontString.text:find("0 known crafts", 1, true) then
            summaryText = fontString
          end
        end
      end)

      it("explains how to populate an empty recipe book at the table's top anchor", function()
        setfenv(1, environment)
        assert(emptyText, "explains how to populate an empty recipe book")
        assert(emptyText.points[1][4] == 12, "indents empty-state guidance from the table edge")
        assert(emptyText.points[2][1] == "TOPRIGHT", "keeps empty-state guidance at its top anchor")
      end)

      it("changes from requesting a scan to explaining incomplete prices when scan data appears", function()
        setfenv(1, environment)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 0, profitableCount = 0, items = {} })
        harness.databaseStatus.latestScan = nil
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
          "prompts for a scan when known recipes have no market data"
        )

        harness.databaseStatus.latestScan = 123
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No known crafts have complete output and material prices." and emptyText.shown,
          "explains when scanned recipes still cannot be priced"
        )
      end)

      it("distinguishes an unprofitable market from opportunities hidden by filters", function()
        setfenv(1, environment)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 4, profitableCount = 0, items = {} })
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No known crafts are currently profitable." and emptyText.shown,
          "explains when all priced crafts are unprofitable"
        )

        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 4, profitableCount = 2, items = {} })
        harness.ns.AuctionHouse.Refresh()
        assert(
          summaryText.text:find("2 profitable", 1, true)
            and emptyText.text == "No crafts match the current filters."
            and emptyText.shown,
          "distinguishes filtered opportunities from an unprofitable market"
        )
      end)

      it("requests a new scan when the last scan has expired", function()
        setfenv(1, environment)
        harness.SetCurrentTime(123 + 15 * 24 * 60 * 60)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 0, profitableCount = 0, items = {} })
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
          "prompts for a scan when the last scan has expired"
        )
      end)

      it("explains unprofitable and filtered vendor crafts without demanding an AH scan", function()
        setfenv(1, environment)
        harness.databaseStatus.latestScan = nil
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 1, profitableCount = 0, items = {} })
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No known crafts are currently profitable.",
          "does not demand an AH scan when vendor crafts are already priced"
        )
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 1, profitableCount = 1, items = {} })
        harness.ns.AuctionHouse.Refresh()
        assert(
          emptyText.text == "No crafts match the current filters.",
          "explains filtered vendor opportunities without an AH scan"
        )
      end)

      it("replaces empty-state prompts with a scanning notice while a scan is running", function()
        setfenv(1, environment)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 0, profitableCount = 0, items = {} })
        harness.databaseStatus.latestScan = nil
        harness.ns.AuctionHouse.Refresh()
        assert.are.equal("No Auction House scan data. Run a full scan to price known crafts.", emptyText.text)

        harness.SetScanStatus({ phase = "waiting" })
        harness.ns.AuctionHouse.RefreshScanStatus()
        assert.are.equal("Scanning Auction House... Results will appear when the scan finishes.", emptyText.text)
        assert(emptyText.shown, "keeps the empty notice visible while scanning with an empty table")

        harness.SetScanStatus({ phase = "idle" })
        harness.ns.AuctionHouse.RefreshScanStatus()
        assert.are.equal("No Auction House scan data. Run a full scan to price known crafts.", emptyText.text)
      end)
    end)

    it("creates the tab only once across repeated Auction House openings", function()
      setfenv(1, environment)
      tab:Click()
      local createdCount = #harness.createdFrames
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert(#harness.createdFrames == createdCount, "creates the tab only once")
    end)
  end)
end)

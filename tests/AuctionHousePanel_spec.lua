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

    local function FindFontString(text)
      for _, fontString in ipairs(harness.createdFontStrings) do
        if fontString.text == text then
          return fontString
        end
      end
    end

    it("adds an Arbitrage tab to the Auction House", function()
      setfenv(1, environment)
      assert(tab and tab.text == "Arbitrage", "labels the tab")
    end)

    it("creates a hidden panel with the native Auction House table artwork and inset", function()
      setfenv(1, environment)
      assert(panel and panel.shown == false, "creates a hidden Arbitrage panel")
      assert(
        tableBackground and tableBackground.parent == components.content,
        "creates a native Auction House table background"
      )
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

    it("names its views with tabs above the table, which starts at the top of the panel", function()
      setfenv(1, environment)
      local heading
      for _, fontString in ipairs(harness.createdFontStrings) do
        if fontString.text == "Opportunities" then
          heading = fontString
        end
      end
      -- The window titles the panel in the control row; here the tabs name it instead.
      assert.is_false(assert(heading, "titles the panel"):IsShown())
      local viewTabs = assert(components.viewTabs)
      assert.are.same({ "Opportunities", "Shopping List" }, { viewTabs[1].text, viewTabs[2].text })
      assert.are.same({ "BOTTOMLEFT", panel, "TOPLEFT", 60, -2 }, viewTabs[1].points[1])
      assert.are.same({ "LEFT", viewTabs[1], "RIGHT", -3, 0 }, viewTabs[2].points[1])
      assert.are.same({ "TOPLEFT", components.content, "TOPLEFT", 16, -4 }, tableBackground.points[1])
      assert.are.same({ "RIGHT", filterDropdown, "LEFT", -12, 0 }, components.searchBox.points[1])
      assert.are.same({ { "RIGHT", components.searchBox, "LEFT", -10, 0 } }, glossaryButton.points)
    end)

    it("puts the scan buttons in the footer and keeps the other controls in the top row", function()
      setfenv(1, environment)
      assert(
        scanButton and scanButton.parent == components.content and scanButton.text == "Full Scan",
        "creates the full scan button"
      )
      assert.are.same({ "BOTTOMRIGHT", auctionHouseFrame, "BOTTOMRIGHT", -12, 9 }, scanButton.points[1])
      assert(
        filterDropdown
          and filterDropdown.parent == components.content
          and filterDropdown.frameType == "DropdownButton"
          and filterDropdown.width == 93,
        "creates a native filter dropdown sized like the Buy tab filter button"
      )
      local quickScanButton = assert(components.quickScanButton)
      assert.are.same({ scanButton.width, scanButton.height }, { quickScanButton.width, quickScanButton.height })
      assert.are.same({ "RIGHT", scanButton, "LEFT", -8, 0 }, quickScanButton.points[1])
      assert.are.same({ "RIGHT", settingsButton, "LEFT", -10, 0 }, filterDropdown.points[1])
      assert(
        settingsButton and settingsButton.parent == components.content and settingsButton.text == "Settings",
        "creates the settings button"
      )
      assert.are.same({ "RIGHT", auctionHouseFrame, "TOPRIGHT", -12, -49 }, settingsButton.points[1])
      assert(glossaryButton and glossaryButton.parent == components.content, "creates a pricing glossary button")
    end)

    describe("filters and search", function()
      local function MenuEntry(menu, label)
        for _, entry in ipairs(menu.entries) do
          if entry.label == label then
            return entry
          end
        end
        error("no menu entry labeled " .. label)
      end

      local function Labels(menu)
        local labels = {}
        for index, entry in ipairs(menu.entries) do
          labels[index] = entry.label
        end
        return labels
      end

      local function VisibleNames()
        local names = {}
        for _, row in ipairs(components.scrollBox.frames) do
          if row:IsShown() then
            names[#names + 1] = row.itemName.text
          end
        end
        return names
      end

      -- The line above the table; empty while every filter is at its default.
      local function FilterLine()
        for _, fontString in ipairs(harness.createdFontStrings) do
          if fontString.parent == components.content and fontString.template == "GameFontHighlightSmall" then
            return fontString.text
          end
        end
      end

      local function TableTop()
        return tableBackground.points[1][5]
      end

      before_each(function()
        setfenv(1, environment)
        tab:Click()
      end)

      it("lists the active filters above the table, moving it down a row", function()
        setfenv(1, environment)
        assert.are.equal("", FilterLine())
        assert.are.equal(-4, TableTop())

        local menu = filterDropdown:OpenMenu()
        MenuEntry(MenuEntry(menu, "Minimum profit"), "500c"):Pick()
        assert.are.equal("Filters: Minimum profit 500c", FilterLine())
        assert.are.equal(-24, TableTop())

        -- A search narrows the crafts, but the line stays about the filters.
        components.searchBox:Type("fla")
        assert.are.equal("Filters: Minimum profit 500c", FilterLine())
        components.searchBox:SetText("")

        MenuEntry(MenuEntry(menu, "Profession"), "Alchemy"):Pick()
        MenuEntry(MenuEntry(menu, "Crafter"), "Current character (Main)"):Pick()
        MenuEntry(MenuEntry(menu, "Sell to"), "Vendor"):Pick()
        MenuEntry(menu, "Hide uncertain opportunities"):Pick()
        assert.are.equal(
          "Filters: Minimum profit 500c · Alchemy · Crafted by current character (Main) · "
            .. "Sell to vendor · Hide uncertain opportunities",
          FilterLine()
        )

        filterDropdown.ResetButton:Click()
        assert.are.equal("", FilterLine())
        assert.are.equal(-4, TableTop())

        MenuEntry(MenuEntry(menu, "Minimum profit"), "Show all crafts"):Pick()
        assert.are.equal("Filters: Including losses", FilterLine())
        filterDropdown.ResetButton:Click()

        -- Searching alone shows in the search box, so it leaves the table where it is.
        components.searchBox:Type("fla")
        assert.are.equal("", FilterLine())
        assert.are.equal(-4, TableTop())
      end)

      it("names a saved crafter or profession the filter menu no longer lists", function()
        setfenv(1, environment)
        -- Saved last session, before Bob was forgotten and the Tailoring recipes with him.
        ARBITRAGE_CONFIG.opportunityProfession = "Tailoring"
        ARBITRAGE_CONFIG.opportunityCrafter = "Bob"
        harness.ns.OpportunityPanel.Refresh()

        local menu = filterDropdown:OpenMenu()
        assert.are.same({ "All professions", "Alchemy", "Blacksmithing" }, Labels(MenuEntry(menu, "Profession")))
        assert.are.same(
          { "All characters", "Current character (Main)", "Alt", "Main" },
          Labels(MenuEntry(menu, "Crafter"))
        )
        assert.are.equal("Filters: Tailoring · Crafted by Bob", FilterLine())
        assert.are.equal(-24, TableTop())
      end)

      it("filters minimum profit, hides uncertain crafts live, and resets to defaults", function()
        setfenv(1, environment)
        ARBITRAGE_CONFIG.craftingWindowMinimumProfit = 5000
        local callsBefore = harness.GetOpportunityCalls()
        local menu = filterDropdown:OpenMenu()
        assert.are.equal("MENU_ARBITRAGE_OPPORTUNITIES_FILTER", menu.tag)
        assert.is_false(filterDropdown.ResetButton.shown)

        local profitMenu = MenuEntry(menu, "Minimum profit")
        assert.are.equal(
          "Hides crafts whose Typical Profit and Current Profit are both less than this per item.",
          profitMenu.tooltipText
        )
        local labels = {}
        for _, option in ipairs(profitMenu.entries) do
          labels[option.value] = option.label
        end
        assert.are.equal("Show all crafts", labels[0])
        assert.are.equal("Any profit", labels[1])
        assert.are.equal("200c", labels[200])
        assert.are.equal("500c", labels[500])
        assert.are.equal("1000000c", labels[1000000])
        assert.is_true(MenuEntry(profitMenu, "Any profit"):IsSelected())

        MenuEntry(profitMenu, "500c"):Pick()
        assert.are.equal(500, harness.ns.Config.Get("minimumProfit"))
        assert.is_true(filterDropdown.ResetButton.shown)
        assert.are.equal(callsBefore + 1, harness.GetOpportunityCalls())
        assert.are.equal(5000, harness.ns.Config.Get("craftingWindowMinimumProfit"))

        local hideUncertain = MenuEntry(menu, "Hide uncertain opportunities")
        assert.is_false(hideUncertain:IsSelected())
        hideUncertain:Pick()
        assert.is_true(hideUncertain:IsSelected())
        assert.is_false(harness.ns.Config.Get("showUncertainOpportunities"))
        assert.are.equal(callsBefore + 2, harness.GetOpportunityCalls())

        hideUncertain:Pick()
        assert.is_false(hideUncertain:IsSelected())
        assert.is_true(harness.ns.Config.Get("showUncertainOpportunities"))
        hideUncertain:Pick()

        filterDropdown.ResetButton:Click()
        assert.are.equal(1, harness.ns.Config.Get("minimumProfit"))
        assert.is_true(harness.ns.Config.Get("showUncertainOpportunities"))
        assert.is_false(hideUncertain:IsSelected())
        assert.is_false(filterDropdown.ResetButton.shown)
        assert.are.equal(callsBefore + 5, harness.GetOpportunityCalls())
        assert.are.equal(5000, harness.ns.Config.Get("craftingWindowMinimumProfit"))
      end)

      it("filters by profession, crafter, and sale method and resets them to defaults", function()
        setfenv(1, environment)
        local callsBefore = harness.GetOpportunityCalls()
        local menu = filterDropdown:OpenMenu()

        local professionMenu = MenuEntry(menu, "Profession")
        assert.are.same({ "All professions", "Alchemy", "Blacksmithing" }, Labels(professionMenu))
        assert.is_true(MenuEntry(professionMenu, "All professions"):IsSelected())
        MenuEntry(professionMenu, "Alchemy"):Pick()
        assert.are.equal("Alchemy", harness.ns.Config.Get("opportunityProfession"))

        local crafterMenu = MenuEntry(menu, "Crafter")
        assert.are.same({ "All characters", "Current character (Main)", "Alt", "Main" }, Labels(crafterMenu))
        MenuEntry(crafterMenu, "Current character (Main)"):Pick()
        assert.are.equal(harness.ns.Config.CURRENT_CHARACTER, harness.ns.Config.Get("opportunityCrafter"))

        local saleMenu = MenuEntry(menu, "Sell to")
        assert.are.same({ "Auction House or vendor", "Auction House", "Vendor" }, Labels(saleMenu))
        MenuEntry(saleMenu, "Vendor"):Pick()
        assert.are.equal("vendor", harness.ns.Config.Get("opportunitySaleMethod"))

        assert.are.equal(callsBefore + 3, harness.GetOpportunityCalls())
        assert.is_true(filterDropdown.ResetButton.shown)

        filterDropdown.ResetButton:Click()
        assert.are.equal("", harness.ns.Config.Get("opportunityProfession"))
        assert.are.equal("", harness.ns.Config.Get("opportunityCrafter"))
        assert.are.equal("", harness.ns.Config.Get("opportunitySaleMethod"))
        assert.is_false(filterDropdown.ResetButton.shown)
      end)

      it("searches its crafts by name or item ID without evaluating them again", function()
        setfenv(1, environment)
        local callsBefore = harness.GetOpportunityCalls()
        local searchBox = components.searchBox

        searchBox:Type("FLA")
        assert.are.same({ "Flask (x2)" }, VisibleNames())

        searchBox:Type(" 200 ")
        assert.are.same({ "Item #200" }, VisibleNames())

        searchBox:Type("zzz")
        assert.are.same({}, VisibleNames())
        local emptyText = FindFontString("No crafts match the current search and filters.")
        assert(emptyText and emptyText.shown, "explains that the search hides every craft")

        searchBox:SetText("")
        assert.are.same({ "Flask (x2)", "Item #200" }, VisibleNames())
        assert.is_false(emptyText.shown)
        assert.are.equal(callsBefore, harness.GetOpportunityCalls())
      end)
    end)

    it("defines the price terms in a short glossary that hides on leave", function()
      setfenv(1, environment)
      local glossaryStart = #harness.tooltipLines
      glossaryButton.scripts.OnEnter(glossaryButton)
      assert.are.same({
        "Arbitrage Pricing",
        "Typical: The item's usual price over the last 14 days.",
        "Current: The item's cheapest listing price in the latest scan.",
        "Profits are per item.",
        "Yellow values are uncertain.",
      }, { unpack(harness.tooltipLines, glossaryStart + 1) })
      assert(GameTooltip.owner == glossaryButton, "anchors the glossary to its button")

      local glossaryHideCalls = harness.GetTooltipHideCalls()
      glossaryButton.scripts.OnLeave(glossaryButton)
      assert(harness.GetTooltipHideCalls() == glossaryHideCalls + 1, "hides the pricing glossary")
    end)

    it("titles the Auction House window Arbitrage on its tab", function()
      setfenv(1, environment)
      tab:Click()
      assert(harness.GetWindowTitle() == "Arbitrage", "updates the Auction House title")
    end)

    it("starts full scans and opens settings from the panel", function()
      setfenv(1, environment)
      tab:Click()
      scanButton:Click()
      assert(harness.GetScanCalls() == 1, "starts a full scan from the panel")
      settingsButton:Click()
      assert(harness.GetSettingsCalls() == 1, "opens Arbitrage settings from the panel")
    end)

    it("shows elapsed wait time and then progress over the results table", function()
      setfenv(1, environment)
      tab:Click()
      local opportunityCallsBefore = harness.GetOpportunityCalls()
      local spinner
      for _, frame in ipairs(harness.createdFrames) do
        if frame.template == "SpinnerTemplate" then
          spinner = frame
        end
      end
      assert(spinner, "creates a native loading indicator")
      local overlay = spinner.parent
      local progressBar = overlay.progressBar
      assert.are.equal("ColoredProgressBarTemplate", progressBar.template)
      assert.are.equal(tableBackground, overlay.parent)
      assert.is_true(overlay.allPoints)
      assert.is_true(overlay.mouseEnabled)
      assert.is_true(overlay.mouseWheelEnabled)
      assert.is_false(overlay:IsShown())
      assert.is_true(components.scrollBox.frames[1]:IsShown())

      local function SetActivePhase(status)
        harness.SetScanStatus(status)
        harness.ns.OpportunityPanel.RefreshScanStatus()
        assert.is_true(overlay:IsShown())
        assert.is_false(scanButton:IsEnabled())
        assert.is_false(components.quickScanButton:IsEnabled())
        assert.are.equal("Full Scan", scanButton.text)
      end

      SetActivePhase({ phase = "waiting", elapsedSeconds = 14 })
      assert.is_true(spinner:IsShown())
      assert.is_false(progressBar:IsShown())
      local guidance = overlay.guidance
      assert.are.equal("Waiting for a response from Blizzard... 0:14", overlay.statusText.text)
      assert.are.equal("This usually takes about 20 seconds. Keep the Auction House open.", guidance.text)
      SetActivePhase({ phase = "waiting", elapsedSeconds = 22 })
      assert.are.equal("This usually takes about 20 seconds. Keep the Auction House open.", guidance.text)
      -- A full scan usually waits 18 seconds.
      SetActivePhase({ phase = "waiting", elapsedSeconds = 23 })
      assert.are.equal("This is taking longer than usual. Keep the Auction House open.", guidance.text)
      SetActivePhase({ phase = "waiting", elapsedSeconds = 59 })
      assert.are.equal("This is taking longer than usual. Keep the Auction House open.", guidance.text)
      SetActivePhase({ phase = "waiting", elapsedSeconds = 60 })
      assert.are.equal(
        "This is taking much longer than usual. Consider cancelling and trying again in 15 minutes.",
        guidance.text
      )
      SetActivePhase({ phase = "waiting", elapsedSeconds = 61 })
      assert.are.equal("Waiting for a response from Blizzard... 1:01", overlay.statusText.text)
      local cancelButton = overlay.cancelButton
      assert.is_true(cancelButton:IsShown())
      assert.are.equal("Cancel Scan", cancelButton.text)
      cancelButton:Click()
      assert.are.equal(1, harness.GetCancelCalls())

      SetActivePhase({ phase = "reading", progress = 42 })
      assert.is_false(cancelButton:IsShown())
      assert.is_false(spinner:IsShown())
      assert.is_true(progressBar:IsShown())
      assert.are.equal(0.42, progressBar.fillFraction)
      assert.are.equal("Reading auctions... 42%", overlay.statusText.text)
      assert.are.equal(
        "This can take a minute. Keep the Auction House open; closing it cancels the scan.",
        guidance.text
      )

      SetActivePhase({ phase = "pricing", progress = 0 })
      assert.is_true(progressBar:IsShown())
      assert.are.equal(0, progressBar.fillFraction)
      SetActivePhase({ phase = "pricing", progress = 81 })
      assert.are.equal(0.81, progressBar.fillFraction)
      assert.are.equal("Calculating and saving Typical prices... 81%", overlay.statusText.text)
      assert.are.equal("The auctions are read, so closing the Auction House now won't cancel the scan.", guidance.text)
      SetActivePhase({ kind = "quick", phase = "waiting", elapsedSeconds = 5 })
      assert.are.equal("Waiting for a response from Blizzard... 0:05", overlay.statusText.text)
      assert.are.equal("This usually takes about 30 seconds. Keep the Auction House open.", guidance.text)
      -- A quick scan usually waits 32 seconds, and has no cooldown to wait out.
      SetActivePhase({ kind = "quick", phase = "waiting", elapsedSeconds = 36 })
      assert.are.equal("This usually takes about 30 seconds. Keep the Auction House open.", guidance.text)
      SetActivePhase({ kind = "quick", phase = "waiting", elapsedSeconds = 37 })
      assert.are.equal("This is taking longer than usual. Keep the Auction House open.", guidance.text)
      SetActivePhase({ kind = "quick", phase = "waiting", elapsedSeconds = 59 })
      assert.are.equal("This is taking longer than usual. Keep the Auction House open.", guidance.text)
      SetActivePhase({ kind = "quick", phase = "waiting", elapsedSeconds = 60 })
      assert.are.equal("This is taking much longer than usual. Consider cancelling and trying again.", guidance.text)
      SetActivePhase({ kind = "quick", phase = "pricing", progress = 60 })
      assert.are.equal("Refreshing Current prices... 60%", overlay.statusText.text)
      settingsButton:Click()
      assert.are.equal(1, harness.GetSettingsCalls())

      harness.SetScanStatus({ phase = "idle", cooldownRemainingMinutes = 8 })
      harness.ns.OpportunityPanel.RefreshScanStatus()
      assert.is_false(overlay:IsShown())
      assert(not scanButton:IsEnabled(), "disables the scan button during the local cooldown")
      assert.are.equal("Full Scan (8m)", scanButton.text)
      scanButton:Click()
      assert.are.equal(0, harness.GetScanCalls())
      assert.is_true(components.quickScanButton:IsEnabled())
      components.quickScanButton:Click()
      assert.are.equal(1, harness.GetQuickScanCalls())

      harness.SetScanStatus({ phase = "idle" })
      harness.ns.OpportunityPanel.RefreshScanStatus()
      assert(scanButton:IsEnabled(), "re-enables the scan button once the cooldown expires")
      assert.are.equal("Full Scan", scanButton.text)
      assert.are.equal(opportunityCallsBefore, harness.GetOpportunityCalls())
    end)

    it("shows only an explanation at a neutral Auction House and refuses to scan there", function()
      setfenv(1, environment)
      local content = components.content
      local notice
      for _, fontString in ipairs(harness.createdFontStrings) do
        if fontString.text and fontString.text:find("only works with your faction's Auction House", 1, true) then
          notice = fontString
        end
      end
      assert(notice and notice.parent == panel, "explains neutral Auction Houses on the tab itself")
      assert.is_false(notice:IsShown())
      assert.is_true(content:IsShown())

      harness.SetAtNeutralAuctionHouse(true)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert.is_true(notice:IsShown())
      assert.is_false(content:IsShown())
      assert.is_false(components.viewTabs[1]:IsShown(), "has no views to choose between")
      assert.is_false(components.viewTabs[2]:IsShown())
      assert.is_false(scanButton:IsEnabled())
      assert.is_false(components.quickScanButton:IsEnabled())
      local start = #harness.tooltipLines
      scanButton.scripts.OnEnter(scanButton)
      assert.are.equal("Arbitrage only scans your faction's Auction House.", harness.tooltipLines[start + 1])

      harness.SetAtNeutralAuctionHouse(false)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert.is_false(notice:IsShown())
      assert.is_true(content:IsShown())
      assert.is_true(components.viewTabs[1]:IsShown())
      assert.is_true(scanButton:IsEnabled())
    end)

    it("describes each scan, when it last ran, why it is disabled, and how this session's latest one ended", function()
      setfenv(1, environment)
      local function LinesSince(start)
        return { unpack(harness.tooltipLines, start + 1) }
      end
      local FULL = "Runs a slower, full scan that contributes to Typical prices and refreshes Current prices."
      local QUICK = "Runs a faster scan that only refreshes Current prices, except for random-enchant gear."

      -- The age comes from the database, so it shows after a reload with no scan this session.
      local start = #harness.tooltipLines
      scanButton.scripts.OnEnter(scanButton)
      assert.are.equal(scanButton, GameTooltip.owner)
      assert.are.same({ FULL, "Last full scan: 1 minute ago" }, LinesSince(start))

      -- A scan that stored prices reports moments after saving them, so its time isn't repeated.
      harness.SetLastScanOutcome({ message = "Full scan done: stored Typical prices for 12 items", at = 125 })
      start = #harness.tooltipLines
      scanButton.scripts.OnEnter(scanButton)
      assert.are.same(
        { FULL, "Last full scan: 1 minute ago", "Full scan done: stored Typical prices for 12 items" },
        LinesSince(start)
      )

      harness.SetLastScanOutcome({ message = "Full scan cancelled: Auction House closed", at = 190 })
      start = #harness.tooltipLines
      harness.FireEvent("AUCTION_HOUSE_CLOSED")
      assert.are.same({
        "Open the Auction House to run a scan.",
        FULL,
        "Last full scan: 1 minute ago",
        "Last attempt, just now",
        "Full scan cancelled: Auction House closed",
      }, LinesSince(start))

      harness.SetLastScanOutcome(nil)
      harness.databaseStatus.latestScan = nil
      start = #harness.tooltipLines
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert.are.equal(scanButton, GameTooltip.owner)
      assert.are.same({ FULL, "Last full scan: never" }, LinesSince(start))

      local quickScanButton = components.quickScanButton
      harness.databaseStatus.latestQuickScan = 187
      start = #harness.tooltipLines
      quickScanButton.scripts.OnEnter(quickScanButton)
      assert.are.same({ QUICK, "Last quick scan: just now" }, LinesSince(start))
    end)

    describe("empty-state guidance", function()
      local emptyText

      before_each(function()
        setfenv(1, environment)
        emptyText = nil
        harness.SetOpportunityResult({ totalCount = 0, pricedCount = 0, profitableCount = 0, items = {} })
        -- The guidance shows on the tab, which only prices crafts while it can be seen.
        tab:Click()
        harness.ns.OpportunityPanel.Refresh()
        for _, fontString in ipairs(harness.createdFontStrings) do
          if fontString.text and fontString.text:find("No known recipes", 1, true) then
            emptyText = fontString
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
        harness.databaseStatus.latestQuickScan = nil
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
          "prompts for a scan when known recipes have no market data"
        )

        -- A Quick Scan alone counts as scan data.
        harness.databaseStatus.latestQuickScan = 123
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No known crafts have complete output and material prices." and emptyText.shown,
          "explains when scanned recipes still cannot be priced"
        )
      end)

      it("distinguishes an unprofitable market from opportunities hidden by filters", function()
        setfenv(1, environment)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 4, profitableCount = 0, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No known crafts are profitable at these prices." and emptyText.shown,
          "explains when all priced crafts are unprofitable"
        )

        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 4, profitableCount = 2, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No crafts match the current filters." and emptyText.shown,
          "distinguishes filtered opportunities from an unprofitable market"
        )
      end)

      it("explains that uncertain prices firm up when hiding them leaves nothing to list", function()
        setfenv(1, environment)
        ARBITRAGE_CONFIG.showUncertainOpportunities = false
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 4, profitableCount = 2, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert.are.equal(
          "Uncertain opportunities are hidden. Prices firm up after scans on 3 separate days, "
            .. "or sooner with Arbitrage Companion's synced prices.",
          emptyText.text
        )
        assert.is_true(emptyText.shown)

        components.searchBox:Type("zzz")
        assert.are.equal("No crafts match the current search and filters.", emptyText.text)
      end)

      it("requests a new scan when the last scan has expired", function()
        setfenv(1, environment)
        harness.SetCurrentTime(123 + 15 * 24 * 60 * 60)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 0, profitableCount = 0, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No Auction House scan data. Run a full scan to price known crafts." and emptyText.shown,
          "prompts for a scan when the last scan has expired"
        )
      end)

      it("explains unprofitable and filtered vendor crafts without demanding an AH scan", function()
        setfenv(1, environment)
        harness.databaseStatus.latestScan = nil
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 1, profitableCount = 0, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No known crafts are profitable at these prices.",
          "does not demand an AH scan when vendor crafts are already priced"
        )
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 1, profitableCount = 1, items = {} })
        harness.ns.OpportunityPanel.Refresh()
        assert(
          emptyText.text == "No crafts match the current filters.",
          "explains filtered vendor opportunities without an AH scan"
        )
      end)

      it("hides empty-state prompts while scanning and restores them afterward", function()
        setfenv(1, environment)
        harness.SetOpportunityResult({ totalCount = 4, pricedCount = 0, profitableCount = 0, items = {} })
        harness.databaseStatus.latestScan = nil
        harness.databaseStatus.latestQuickScan = nil
        harness.ns.OpportunityPanel.Refresh()
        assert.are.equal("No Auction House scan data. Run a full scan to price known crafts.", emptyText.text)

        harness.SetScanStatus({ phase = "waiting" })
        harness.ns.OpportunityPanel.RefreshScanStatus()
        assert.is_false(emptyText.shown)

        harness.SetScanStatus({ phase = "idle" })
        harness.ns.OpportunityPanel.RefreshScanStatus()
        assert.is_true(emptyText.shown)
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

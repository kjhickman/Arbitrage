local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Window", function()
  local environment
  local harness

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
  end)

  it("defers creating the window until first opened and works before AuctionHouseFrame loads", function()
    setfenv(1, environment)
    AuctionHouseFrame = nil
    assert.is_nil(_G.ArbitrageWindow)
    assert.are.equal(0, #UISpecialFrames)
    assert.are.equal(0, harness.GetOpportunityCalls())

    harness.ns.Window.Toggle()
    local window = assert(_G.ArbitrageWindow, "creates the global standalone window")
    assert.is_true(window:IsShown())
    assert.are.equal(1, harness.GetOpportunityCalls())
    assert.are.equal("ArbitrageWindow", UISpecialFrames[1])

    local createdCount = #harness.createdFrames
    harness.ns.Window.Toggle()
    assert.is_false(window:IsShown())
    assert.are.equal(1, harness.GetOpportunityCalls())

    harness.ns.Window.Toggle()
    assert.is_true(window:IsShown())
    assert.are.equal(2, harness.GetOpportunityCalls())
    assert.are.equal(createdCount, #harness.createdFrames)
  end)

  it("configures a movable, combat-safe PortraitFrameTemplate window with Escape support", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow

    assert.are.equal(UIParent, window.parent)
    assert.are.equal("PortraitFrameTemplate", window.template)
    assert.are.equal(800, window.width)
    assert.are.equal(512, window.height)
    assert.are.equal("CENTER", window.points[1][1])
    assert.is_true(window.toplevel)
    assert.is_true(window.mouseEnabled)
    assert.is_true(window.movable)
    assert.is_true(window.clampedToScreen)
    assert.are.same({ "LeftButton" }, window.dragButtons)
    assert.are.equal("Arbitrage", window.title)
    assert.are.equal("Interface\\AddOns\\Arbitrage\\media\\icon", window.portraitAsset)

    window.scripts.OnDragStart(window)
    assert.is_true(window.moving)
    window.scripts.OnDragStop(window)
    assert.is_false(window.moving)

    -- Default PortraitFrameTemplate CloseButton calls HideUIPanel; our override hides directly.
    window.CloseButton:Click()
    assert.is_false(window:IsShown())
  end)

  it("disables Full Scan away from the Auction House with a tooltip and enables it while the AH is open", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow
    local components = harness.FindComponents(window)
    local scanButton = assert(components.scanButton, "creates Full Scan in the standalone window")

    assert.is_true(scanButton.motionScriptsWhileDisabled)
    assert.is_false(scanButton:IsEnabled())
    assert.are.equal("Full Scan", scanButton.text)

    local lineCount = #harness.tooltipLines
    scanButton.scripts.OnEnter(scanButton)
    assert.are.equal(scanButton, GameTooltip.owner)
    assert.are.equal("Open the Auction House to run a full scan.", harness.tooltipLines[lineCount + 1])

    harness.SetScanStatus({ phase = "idle", cooldownRemainingMinutes = 8 })
    harness.ns.OpportunityPanel.RefreshScanStatus()
    assert.is_false(scanButton:IsEnabled())
    assert.are.equal("Full Scan (8m)", scanButton.text)

    harness.SetScanStatus({ phase = "idle" })
    local callsBeforeAH = harness.GetOpportunityCalls()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    assert.are.equal(callsBeforeAH + 1, harness.GetOpportunityCalls())
    assert.is_true(scanButton:IsEnabled())
    assert.is_nil(GameTooltip.owner)

    scanButton:Click()
    assert.are.equal(1, harness.GetScanCalls())

    harness.FireEvent("AUCTION_HOUSE_CLOSED")
    assert.is_false(scanButton:IsEnabled())
    scanButton.scripts.OnEnter(scanButton)
    assert.are.equal(scanButton, GameTooltip.owner)
    local hideCalls = harness.GetTooltipHideCalls()
    scanButton.scripts.OnLeave(scanButton)
    assert.are.equal(hideCalls + 1, harness.GetTooltipHideCalls())
  end)

  it("adds Opportunities and Database tabs below the window and opens on Opportunities", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow
    local tabs = window.Tabs

    assert.are.equal(2, #tabs)
    assert.are.equal(2, window.numTabs)
    assert.are.equal("Opportunities", tabs[1].text)
    assert.are.equal("Database", tabs[2].text)
    assert.are.same({ "TOPLEFT", window, "BOTTOMLEFT", 5, 2 }, tabs[1].points[1])
    assert.are.equal(_G.ArbitrageWindowTab2, tabs[2])
    assert.are.equal(1, window.selectedTab)
    assert.is_true(tabs[1].selected)
    assert.is_false(tabs[2].selected)

    local contents = harness.GetWindowContents()
    assert.is_true(contents[1]:IsShown())
    assert.is_false(contents[2]:IsShown())
  end)

  it("switches between tab contents and remembers the selected tab while the window is closed", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow
    local contents = harness.GetWindowContents()
    local opportunityCalls = harness.GetOpportunityCalls()

    window.Tabs[2]:Click()
    assert.are.same({ 841 }, harness.playedSounds)
    assert.are.equal(2, window.selectedTab)
    assert.is_false(contents[1]:IsShown())
    assert.is_true(contents[2]:IsShown())
    assert.are.equal(opportunityCalls, harness.GetOpportunityCalls())

    harness.ns.Window.Toggle()
    assert.is_false(contents[1]:IsShown())
    assert.is_false(contents[2]:IsShown())

    harness.ns.Window.Toggle()
    assert.is_false(contents[1]:IsShown())
    assert.is_true(contents[2]:IsShown())
    assert.are.equal(opportunityCalls, harness.GetOpportunityCalls())

    window.Tabs[1]:Click()
    assert.is_true(contents[1]:IsShown())
    assert.is_false(contents[2]:IsShown())
    assert.are.equal(opportunityCalls + 1, harness.GetOpportunityCalls())
  end)

  it("toggles the window from the Addon Compartment callback", function()
    setfenv(1, environment)
    Arbitrage_OnAddonCompartmentClick()
    assert.is_true(_G.ArbitrageWindow:IsShown())

    Arbitrage_OnAddonCompartmentClick()
    assert.is_false(_G.ArbitrageWindow:IsShown())
  end)

  it("syncs shared filters with the Auction House tab while keeping independent column sorts", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    local ahComponents = harness.FindComponents()
    ahComponents.tab:Click()
    local windowComponents = harness.FindComponents(harness.GetWindowContents()[1])

    windowComponents.headers["Craft Cost"]:Click()
    assert.are.equal(200, windowComponents.scrollBox.frames[1].item.itemID)
    assert.are.equal(100, ahComponents.scrollBox.frames[1].item.itemID)

    harness.SetOpportunityResult({
      totalCount = 4,
      pricedCount = 3,
      profitableCount = 3,
      items = {
        {
          itemID = 300,
          outputQuantity = 1,
          saleMethod = "auction",
          saleProceeds = 1000,
          craftCost = 999,
          profit = 1,
          roi = 0.001,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
        {
          itemID = 100,
          outputQuantity = 2,
          saleMethod = "auction",
          saleProceeds = 190,
          craftCost = 80,
          profit = 110,
          roi = 1.375,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
      },
    })

    local callsBefore = harness.GetOpportunityCalls()
    local menu = windowComponents.filterDropdown:OpenMenu()
    menu.entries[3]:Pick()
    assert.are.equal(callsBefore + 1, harness.GetOpportunityCalls())
    assert.is_false(harness.ns.Config.Get("showUncertainOpportunities"))
    assert.is_true(windowComponents.filterDropdown.ResetButton.shown)
    assert.is_true(ahComponents.filterDropdown.ResetButton.shown)
    assert.are.equal(300, windowComponents.scrollBox.frames[1].item.itemID)
    assert.are.equal(100, ahComponents.scrollBox.frames[1].item.itemID)

    ahComponents.filterDropdown.ResetButton:Click()
    assert.are.equal(callsBefore + 2, harness.GetOpportunityCalls())
    assert.is_true(harness.ns.Config.Get("showUncertainOpportunities"))
    assert.is_false(windowComponents.filterDropdown.ResetButton.shown)
    assert.is_false(ahComponents.filterDropdown.ResetButton.shown)
  end)
end)

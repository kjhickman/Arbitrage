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

  it("prices crafts only while an Opportunities panel can be seen", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    harness.FindComponents().tab:Click()
    harness.ns.Window.Toggle()
    local calls = harness.GetOpportunityCalls()
    harness.ns.OpportunityPanel.Refresh()
    assert.are.equal(calls + 1, harness.GetOpportunityCalls(), "the Auction House tab still shows")

    -- The tab stays shown when the Auction House closes, but nobody can see it.
    harness.FireEvent("AUCTION_HOUSE_CLOSED")
    harness.ns.OpportunityPanel.Refresh()
    assert.are.equal(calls + 1, harness.GetOpportunityCalls())

    harness.ns.Window.Toggle()
    assert.are.equal(calls + 2, harness.GetOpportunityCalls(), "a panel refreshes as it shows")
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

  it("fills the standalone Opportunities window without reserving space for scan buttons", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local callsBeforeAH = harness.GetOpportunityCalls()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    assert.are.equal(callsBeforeAH + 1, harness.GetOpportunityCalls())
    local components = harness.FindComponents(harness.GetWindowContents()[1])
    assert.is_nil(components.scanButton)
    assert.is_nil(components.quickScanButton)
    assert.are.same({ "BOTTOMRIGHT", components.content, "BOTTOMRIGHT", -5, 8 }, components.tableBackground.points[2])
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

  it("syncs shared filters with the Auction House tab while keeping independent sorts and searches", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    harness.FireEvent("AUCTION_HOUSE_SHOW")
    local ahComponents = harness.FindComponents()
    ahComponents.tab:Click()
    local windowComponents = harness.FindComponents(harness.GetWindowContents()[1])

    windowComponents.headers["Craft Cost"]:Click()
    assert.are.equal("Item #200", windowComponents.scrollBox.frames[1].itemName.text)
    assert.are.equal("Flask (x2)", ahComponents.scrollBox.frames[1].itemName.text)

    windowComponents.searchBox:Type("200")
    assert.is_false(windowComponents.scrollBox.frames[2]:IsShown())
    assert.is_true(ahComponents.scrollBox.frames[2]:IsShown())
    windowComponents.searchBox:SetText("")

    harness.SetOpportunityResult({
      totalCount = 4,
      pricedCount = 3,
      profitableCount = 3,
      items = {
        {
          itemID = 300,
          outputQuantity = 1,
          saleMethod = "auction",
          craftCost = 999,
          profit = 1,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
        {
          itemID = 100,
          outputQuantity = 2,
          saleMethod = "auction",
          craftCost = 80,
          profit = 110,
          sources = {},
          reasons = {},
          isUncertain = false,
        },
      },
    })

    local callsBefore = harness.GetOpportunityCalls()
    local menu = windowComponents.filterDropdown:OpenMenu()
    for _, entry in ipairs(menu.entries) do
      if entry.label == "Hide uncertain opportunities" then
        entry:Pick()
      end
    end
    assert.are.equal(callsBefore + 1, harness.GetOpportunityCalls())
    assert.is_false(harness.ns.Config.Get("showUncertainOpportunities"))
    assert.is_true(windowComponents.filterDropdown.ResetButton.shown)
    assert.is_true(ahComponents.filterDropdown.ResetButton.shown)
    assert.are.equal("Item #300", windowComponents.scrollBox.frames[1].itemName.text)
    assert.are.equal("Flask (x2)", ahComponents.scrollBox.frames[1].itemName.text)

    ahComponents.filterDropdown.ResetButton:Click()
    assert.are.equal(callsBefore + 2, harness.GetOpportunityCalls())
    assert.is_true(harness.ns.Config.Get("showUncertainOpportunities"))
    assert.is_false(windowComponents.filterDropdown.ResetButton.shown)
    assert.is_false(ahComponents.filterDropdown.ResetButton.shown)
  end)
end)

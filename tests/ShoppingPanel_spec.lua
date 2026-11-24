local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingPanel", function()
  local environment
  local harness

  local function IsDescendantOf(region, ancestor)
    local current = region and region.parent
    while current do
      if current == ancestor then
        return true
      end
      current = current.parent
    end
    return false
  end

  -- The shopping list inside root: its content, the crafts list and the materials list in the
  -- order they're made, the Clear button, and the total.
  local function FindShopping(root)
    local found = { lists = {} }
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.text == "Shopping List" and fontString.parent.parent == root then
        found.content = fontString.parent
        found.heading = fontString
      end
    end
    assert(found.content, "has a shopping list")
    for _, frame in ipairs(harness.createdFrames) do
      if IsDescendantOf(frame, found.content) then
        if frame.template == "WowScrollBoxList" then
          found.lists[#found.lists + 1] = frame
        elseif frame.template == "UIPanelButtonTemplate" and frame.text == "Clear" then
          found.clearButton = frame
        end
      end
    end
    for _, fontString in ipairs(harness.createdFontStrings) do
      if IsDescendantOf(fontString, found.content) and fontString.text and fontString.text:find("^Left to buy") then
        found.total = fontString
      end
    end
    found.crafts, found.materials = found.lists[1], found.lists[2]
    return found
  end

  local function VisibleRows(scrollBox)
    local rows = {}
    for _, row in ipairs(scrollBox.frames) do
      if row:IsShown() then
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  -- Each visible material as "name need have cost".
  local function MaterialLines(scrollBox)
    local lines = {}
    for index, row in ipairs(VisibleRows(scrollBox)) do
      lines[index] = table.concat({
        row.itemName.text,
        row.values[1].text,
        row.values[2].text,
        harness.PlainMoney(row.values[3].text),
      }, " | ")
    end
    return lines
  end

  local function FindFontString(text)
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.text == text then
        return fontString
      end
    end
  end

  -- The details footer's button with this text.
  local function FooterButton(text)
    for _, frame in ipairs(harness.createdFrames) do
      if
        frame.text == text
        and frame.parent
        and frame.parent.parent
        and frame.parent.parent.template == "PortraitFrameTemplate"
      then
        return frame
      end
    end
  end

  local function Opportunity(itemID)
    for _, frame in ipairs(harness.FindComponents().scrollBox.frames) do
      if frame.item and frame.item.itemID == itemID then
        return frame.item
      end
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
  end)

  describe("in the Auction House", function()
    local components

    before_each(function()
      setfenv(1, environment)
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      components = harness.FindComponents()
      components.tab:Click()
    end)

    it("switches between Opportunities and the shopping list, remembering the choice", function()
      setfenv(1, environment)
      local opportunities, shopping = components.viewTabs[1], components.viewTabs[2]
      assert.are.equal(1, components.panel.selectedTab)
      assert.is_true(opportunities.selected)

      local calls = harness.GetOpportunityCalls()
      shopping:Click()
      assert.are.same({ 841 }, harness.playedSounds)
      assert.are.equal(2, components.panel.selectedTab)
      assert.is_false(components.content:IsShown())
      local found = FindShopping(components.panel)
      assert.is_true(found.content:IsShown())
      assert.is_false(found.heading:IsShown(), "the tab names the view")

      -- Hidden Opportunities aren't priced when prices change.
      harness.ns.OpportunityPanel.Refresh()
      assert.are.equal(calls, harness.GetOpportunityCalls())

      harness.FireEvent("AUCTION_HOUSE_CLOSED")
      harness.FireEvent("AUCTION_HOUSE_SHOW")
      assert.is_false(components.content:IsShown())
      assert.is_true(found.content:IsShown())

      opportunities:Click()
      assert.are.equal(calls + 1, harness.GetOpportunityCalls())
      assert.is_true(components.content:IsShown())
      assert.is_false(found.content:IsShown())
    end)

    it("adds crafts from the details and a row's menu, counting them on the tab", function()
      setfenv(1, environment)
      local shoppingTab = components.viewTabs[2]
      components.scrollBox.frames[1]:Click()
      assert.are.equal(100, components.scrollBox.frames[1].item.itemID)

      local plus = assert(FooterButton("+"), "offers more crafts")
      plus:Click()
      harness.SetHeldModifier("SHIFT")
      plus:Click()
      harness.SetHeldModifier(nil)
      assert(FindFontString("12"), "counts ten more on Shift")
      FooterButton("Add to List"):Click()
      assert.are.equal(12, harness.ns.ShoppingList.GetCount(100))
      -- Flask's details listed materials at Buyout prices.
      assert.are.same({ itemID = 100, recipeKey = "shared", atBuyout = true }, harness.choiceRequests[1])
      assert.are.equal("Shopping List (1)", shoppingTab.text)
      assert.is_true(FindFontString("On Shopping List"):IsShown())
      assert(FindFontString("12 crafts"), "shows how many are on the list")

      components.scrollBox.frames[2]:Click("RightButton")
      local menu = assert(harness.contextMenus[1])
      assert.are.equal(components.scrollBox.frames[2], menu.owner)
      assert.are.equal("Add to Shopping List", menu.entries[1].label)
      menu.entries[1].Pick()
      assert.are.equal(1, harness.ns.ShoppingList.GetCount(200))
      assert.are.same({ itemID = 200, recipeKey = "item-200", atBuyout = false }, harness.choiceRequests[2])
      assert.are.equal("Shopping List (2)", shoppingTab.text)

      -- A right-click opens the menu without changing the details.
      assert.are.equal(100, components.scrollBox.frames[1].item.itemID)
      assert.are.equal(1, #harness.contextMenus)
    end)

    it("starts each item at one craft", function()
      setfenv(1, environment)
      components.scrollBox.frames[1]:Click()
      FooterButton("+"):Click()
      assert(FindFontString("2"))
      components.scrollBox.frames[2]:Click()
      FooterButton("Add to List"):Click()
      assert.are.equal(1, harness.ns.ShoppingList.GetCount(200))
    end)

    describe("with crafts on the list", function()
      local found

      before_each(function()
        setfenv(1, environment)
        harness.latestBuyouts["101"] = 30
        harness.vendorPrices[102] = 40
        harness.ownedItems[101] = 1
        harness.ns.ShoppingList.Add(Opportunity(100), 2)
        components.viewTabs[2]:Click()
        found = FindShopping(components.panel)
      end)

      it("lists the crafts and what's left to buy", function()
        setfenv(1, environment)
        local craftRows = VisibleRows(found.crafts)
        assert.are.equal(1, #craftRows)
        assert.are.equal("Flask (x2)", craftRows[1].itemName.text)
        assert.are.equal("2", craftRows[1].count.text)

        -- Two crafts use six Herbs, one owned, and two Empty Vials from a vendor.
        assert.are.same({
          "Empty Vial (Vendor) | 2 | 0 | 80c",
          "Herb | 6 | 1 | 1s 50c",
        }, MaterialLines(found.materials))
        assert.are.equal("Left to buy: 2s 30c", harness.PlainMoney(found.total.text))

        harness.ns.ShoppingList.Add(Opportunity(200), 1)
        assert.are.same({
          "Empty Vial (Vendor) | 2 | 0 | 80c",
          "Herb | 6 | 1 | 1s 50c",
          "Iron Bar | 2 | 0 | —",
        }, MaterialLines(found.materials))
        assert.are.equal("Left to buy: 2s 30c + 1 unpriced", harness.PlainMoney(found.total.text))
      end)

      it("checks off what you have enough of as your bags change", function()
        setfenv(1, environment)
        local herb = VisibleRows(found.materials)[2]
        assert.is_false(herb.check:IsShown())

        harness.ownedItems[101] = 6
        harness.FireEvent("BAG_UPDATE_DELAYED")
        harness.FireEvent("BAG_UPDATE_DELAYED")
        assert.are.equal(1, #harness.timers, "waits for the frame to end, once")
        harness.RunTimers()
        assert.are.same({ "Empty Vial (Vendor) | 2 | 0 | 80c", "Herb | 6 | 6 | " }, MaterialLines(found.materials))
        assert.is_true(herb.check:IsShown())
        assert.are.same({ 0.5, 0.5, 0.5 }, herb.itemName.textColor)
        assert.are.equal("Left to buy: 80c", harness.PlainMoney(found.total.text))
      end)

      it("changes counts, removes crafts, and clears after asking", function()
        setfenv(1, environment)
        local row = VisibleRows(found.crafts)[1]
        row.plus:Click()
        assert.are.equal(3, harness.ns.ShoppingList.GetCount(100))
        assert.are.equal("3", row.count.text)
        assert.are.same("Herb | 9 | 1 | 2s 40c", MaterialLines(found.materials)[2])

        harness.SetHeldModifier("SHIFT")
        row.plus:Click()
        row.minus:Click()
        harness.SetHeldModifier(nil)
        assert.are.equal(3, harness.ns.ShoppingList.GetCount(100))
        row.minus:Click()
        assert.are.equal(2, harness.ns.ShoppingList.GetCount(100))
        row.minus:Click()
        assert.are.equal(1, harness.ns.ShoppingList.GetCount(100))
        assert.is_false(row.minus:IsEnabled(), "keeps at least one craft; removing takes the other button")

        row.remove:Click()
        assert.are.equal(0, #VisibleRows(found.crafts))
        assert.are.equal("Shopping List", components.viewTabs[2].text)
        assert(
          FindFontString("Your shopping list is empty. Click a craft in Opportunities, then choose Add to List."):IsShown()
        )

        harness.ns.ShoppingList.Add(Opportunity(100), 1)
        found.clearButton:Click()
        assert.are.equal(1, harness.ns.ShoppingList.GetCraftCount(), "asks first")
        local dialog = assert(harness.shownDialogs[1])
        assert.are.equal("Remove every craft from your shopping list?", dialog.text)
        dialog.Accept()
        assert.are.equal(0, harness.ns.ShoppingList.GetCraftCount())
        assert.are.equal(0, #VisibleRows(found.materials))
      end)

      it("explains a craft whose recipe no character knows any more", function()
        setfenv(1, environment)
        harness.recipes[100] = nil
        harness.ns.ShoppingPanel.Refresh()
        local row = VisibleRows(found.crafts)[1]
        assert.are.equal("Flask", row.itemName.text)
        assert.are.same({ 0.5, 0.5, 0.5 }, row.itemName.textColor)
        assert.are.equal(0, #VisibleRows(found.materials))
        assert(FindFontString("No character on this realm knows these recipes any more."):IsShown())
      end)
    end)
  end)

  it("has a tab of its own in the window, drawn as it shows", function()
    setfenv(1, environment)
    harness.ns.Window.Toggle()
    local window = _G.ArbitrageWindow
    local found = FindShopping(harness.GetWindowContents()[3])
    assert.are_not.equal(false, found.heading.shown, "titles the tab, as the window's others are")
    assert.are.same({ "LEFT", window, "TOPLEFT", 66, -49 }, found.heading.points[1])
    assert.are.equal(0, #VisibleRows(found.crafts))

    harness.ns.ShoppingList.Add({ itemID = 200, recipeKey = "item-200" }, 1)
    assert.are.equal(0, #VisibleRows(found.crafts), "waits until it shows")
    window.Tabs[3]:Click()
    assert.are.equal("Item #200", VisibleRows(found.crafts)[1].itemName.text)
    assert.are.same({ "Iron Bar | 2 | 0 | —" }, MaterialLines(found.materials))
  end)
end)

local NewEnvironment = dofile("tests/support/Environment.lua")

describe("AuctionHouseBuy", function()
  local environment
  local harness

  -- The buttons Arbitrage put on Blizzard's Buy tab, by the frame each belongs to.
  local function Buttons()
    local buttons = {}
    for _, frame in ipairs(harness.createdFrames) do
      if frame.text == "Add to Shopping List" then
        buttons[frame.parent] = buttons[frame.parent] or {}
        table.insert(buttons[frame.parent], frame)
      end
    end
    return buttons
  end

  -- Opens a menu the way Blizzard does on a result: its own Favorites entry, then what addons add.
  local function OpenFavoritesMenu(owner)
    return environment.MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
      rootDescription:SetTag("MENU_AUCTION_HOUSE_FAVORITE")
      rootDescription:CreateButton("Set Favorite", function() end)
    end)
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    harness.itemInfo[101] = { "Herb", "|Hitem:101|h[Herb]|h", 1 }
    harness.FireEvent("AUCTION_HOUSE_SHOW")
  end)

  it("adds the commodity being bought, as many as are typed beside Buy Now", function()
    setfenv(1, environment)
    local display = AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay
    local button = Buttons()[display][1]
    assert.are.same({ "TOP", display.BuyButton, "BOTTOM", 0, -8 }, button.points[1])
    assert.are.same({ 196, 22 }, { button.width, button.height }, "as wide as Buy Now")

    display.itemID, display.quantity = 101, 20
    button:Click()
    assert.are.equal(20, harness.ns.ShoppingList.GetItemCount(101))
    assert.are.equal(
      "|cff00ccffArbitrage:|r Added |Hitem:101|h[Herb]|h x20 to your shopping list.",
      harness.chatMessages[#harness.chatMessages]
    )

    -- An empty quantity box still adds one.
    display.quantity = 0
    button:Click()
    assert.are.equal(21, harness.ns.ShoppingList.GetItemCount(101))
  end)

  it("adds any other item being bought, one at a time, from beside your gold", function()
    setfenv(1, environment)
    local itemBuyFrame = AuctionHouseFrame.ItemBuyFrame
    local button = Buttons()[itemBuyFrame][1]
    assert.are.same({ "LEFT", AuctionHouseFrame.MoneyFrameBorder, "RIGHT", 10, 0 }, button.points[1])

    itemBuyFrame.ItemDisplay.itemKey = { itemID = 300, itemLevel = 200 }
    button:Click()
    button:Click()
    assert.are.equal(2, harness.ns.ShoppingList.GetItemCount(300))
    assert.are.equal("|cff00ccffArbitrage:|r Added item 300 x1 to your shopping list.", harness.chatMessages[2])

    itemBuyFrame.ItemDisplay.itemKey = nil
    button:Click()
    assert.are.equal(2, #harness.chatMessages, "adds nothing without an item")
  end)

  it("adds a result from the menu a right-click opens, after Blizzard's Favorites", function()
    setfenv(1, environment)
    local row = {
      GetRowData = function()
        return { itemKey = { itemID = 101 } }
      end,
    }
    local menu = OpenFavoritesMenu(row)
    assert.are.same({ "Set Favorite", true, "Add to Shopping List" }, {
      menu.entries[1].label,
      menu.entries[2].divider,
      menu.entries[3].label,
    })
    menu.entries[3].Pick()
    assert.are.equal(1, harness.ns.ShoppingList.GetItemCount(101))

    -- The item at the top of the Buy tab opens the same menu, with its own item key.
    local itemDisplay = {
      GetItemKey = function()
        return { itemID = 300 }
      end,
    }
    OpenFavoritesMenu(itemDisplay).entries[3].Pick()
    assert.are.equal(1, harness.ns.ShoppingList.GetItemCount(300))

    -- Without an item, and in other menus, it adds nothing.
    assert.are.equal(1, #OpenFavoritesMenu({}).entries)
    local other = MenuUtil.CreateContextMenu(row, function(_, rootDescription)
      rootDescription:SetTag("MENU_SOMETHING_ELSE")
    end)
    assert.are.same({}, other.entries)
  end)
end)

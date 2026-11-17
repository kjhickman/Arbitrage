local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ItemTable", function()
  local environment
  local harness

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
  end)

  describe("money", function()
    it("uses the game's 12-pixel coin icons", function()
      setfenv(1, environment)
      assert.are.equal(
        "1|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
          .. " 05|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
          .. " 07|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
        harness.ns.ItemTable.FormatMoney(10507)
      )
    end)

    it("pads every coin after the first to two digits so lengths depend only on gold digits", function()
      setfenv(1, environment)
      local cases = {
        [0] = "0c",
        [7] = "7c",
        [99] = "99c",
        [100] = "1s 00c",
        [105] = "1s 05c",
        [9999] = "99s 99c",
        [10000] = "1g 00s 00c",
        [10507] = "1g 05s 07c",
        [990000] = "99g 00s 00c",
        [12345678] = "1234g 56s 78c",
      }
      for copper, expected in pairs(cases) do
        assert.are.equal(expected, harness.PlainMoney(harness.ns.ItemTable.FormatMoney(copper)))
      end
      assert.are.equal("1s 90c", harness.PlainMoney(harness.ns.ItemTable.FormatMoney(190.9)))
    end)

    it("signs losses and gains with the same padding", function()
      setfenv(1, environment)
      assert.are.equal("-1g 05s 07c", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(-10507)))
      assert.are.equal("+50s 00c", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(5000)))
      assert.are.equal("+0c", harness.PlainMoney(harness.ns.ItemTable.FormatSignedMoney(0)))
    end)
  end)

  describe("column layout", function()
    local function AssertColumnsApart(content)
      local headers = {}
      for label, header in pairs(harness.FindComponents(content).headers) do
        headers[#headers + 1] = { label = label, x = header.points[1][4], width = header.width }
      end
      table.sort(headers, function(left, right)
        return left.x < right.x
      end)
      for index, header in ipairs(headers) do
        local nextX = headers[index + 1] and headers[index + 1].x or 741
        assert(header.x + header.width < nextX, header.label .. " ends before the next column")
      end
      return headers
    end

    it("keeps Database columns apart and gives each price room for 4-digit gold", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      _G.ArbitrageWindow.Tabs[2]:Click()
      local content = harness.GetWindowContents()[2]
      assert.are.equal(5, #AssertColumnsApart(content))
      -- 104 pixels cut off 9999g 99s 99c in game.
      local headers = harness.FindComponents(content).headers
      for _, label in ipairs({ "Market Value", "Min Buyout", "Craft Cost" }) do
        assert(headers[label].width >= 130, label .. " fits 9999g 99s 99c")
      end
    end)

    it("keeps the Opportunities columns apart and inside the table", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      assert.are.equal(7, #AssertColumnsApart(harness.GetWindowContents()[1]))
    end)
  end)
end)

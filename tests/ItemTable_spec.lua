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
    -- Number14FontWhite (Arial Narrow 14) advances, measured with CoreText; a coin icon is 12
    -- pixels plus its 2-pixel gap. The game draws wider than this: 104 pixels still cut off a
    -- 9999g 99s 99c estimated at 100, so columns need room beyond the estimate.
    local ADVANCES = { [" "] = 3.2, ["+"] = 6.7, ["-"] = 3.8, g = 14, s = 14, c = 14 }
    local HEADROOM = 1.3

    local function EstimateWidth(plain)
      local width = 0
      for character in plain:gmatch(".") do
        width = width + (ADVANCES[character] or (character:match("%d") and 6.4) or error(character))
      end
      return width
    end

    local function ReadHeaders(content)
      local headers = {}
      for label, header in pairs(harness.FindComponents(content).headers) do
        headers[#headers + 1] = { label = label, x = header.points[1][4], width = header.width }
      end
      table.sort(headers, function(left, right)
        return left.x < right.x
      end)
      return headers
    end

    local function AssertLayout(content, widest)
      local headers = ReadHeaders(content)
      local byLabel = {}
      for index, header in ipairs(headers) do
        byLabel[header.label] = header
        local nextHeader = headers[index + 1]
        if nextHeader then
          assert(header.x + header.width < nextHeader.x, header.label .. " ends before " .. nextHeader.label)
        else
          assert(header.x + header.width <= 740, header.label .. " ends before the scrollbar")
        end
      end
      for label, plain in pairs(widest or {}) do
        local header = assert(byLabel[label], "has a " .. label .. " column")
        local needed = EstimateWidth(plain) * HEADROOM
        assert(needed <= header.width, label .. " (" .. header.width .. "px) fits " .. plain .. " (" .. needed .. "px)")
      end
      return byLabel
    end

    it("fits 4-digit gold prices in every Database money column", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      _G.ArbitrageWindow.Tabs[2]:Click()
      AssertLayout(harness.GetWindowContents()[2], {
        ["Market Value"] = "9999g 99s 99c",
        ["Min Buyout"] = "9999g 99s 99c",
        ["Craft Cost"] = "9999g 99s 99c",
      })
    end)

    it("keeps the Opportunities columns apart and inside the table", function()
      setfenv(1, environment)
      harness.ns.Window.Toggle()
      local count = 0
      for _ in pairs(AssertLayout(harness.GetWindowContents()[1])) do
        count = count + 1
      end
      assert.are.equal(7, count)
    end)
  end)
end)

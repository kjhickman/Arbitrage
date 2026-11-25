local NewEnvironment = dofile("tests/support/Environment.lua")

describe("WhatsTraining", function()
  local environment
  local ns, onProfessionsLoaded, initialized, timers, scrollBox, rows, settings
  local previews, opportunities, previewCalls, tooltip

  local function RunTimers()
    local pending = timers
    timers = {}
    for _, callback in ipairs(pending) do
      callback()
    end
  end

  -- A row of What's Training's recipe list, as its own initializer leaves it before ours runs.
  local function NewRow(data, nameWidth)
    local row = {
      data = data,
      hooks = {},
      cells = {
        {
          GetObjectType = function()
            return "FontString"
          end,
          GetUnboundedStringWidth = function()
            return nameWidth or 100
          end,
          GetWidth = function()
            return 200
          end,
        },
      },
      HookScript = function(self, name, callback)
        self.hooks[name] = callback
      end,
      CreateFontString = function()
        return {
          SetPoint = function(self, ...)
            self.point = { ... }
          end,
          SetText = function(self, text)
            self.text = text
          end,
          SetTextColor = function(self, r, g, b)
            self.color = { r, g, b }
          end,
          GetStringWidth = function(self)
            return #self.text * 6
          end,
          Show = function(self)
            self.visible = true
          end,
          Hide = function(self)
            self.visible = false
          end,
          -- Shown until hidden, as in the game.
          visible = true,
        }
      end,
    }
    rows[#rows + 1] = row
    return row
  end

  local function AddRow(data, nameWidth)
    local row = NewRow(data, nameWidth)
    initialized(nil, row, {})
    return row
  end

  local function Recipe(spell, creates)
    return { recipe = { spell = spell, creates = creates } }
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    rows, timers, previewCalls = {}, {}, 0
    initialized = nil
    settings = { showCraftingWindowProfits = true, craftingWindowMinimumProfit = 1 }
    previews = { [10] = { { recipeKey = "ten:a" }, { recipeKey = "ten:b" } }, [20] = { { recipeKey = "twenty" } } }
    opportunities = {
      ["ten:a"] = { profit = 35, craftCost = 60, saleMethod = "auction", outputQuantity = 1, reasons = {} },
      ["ten:b"] = { profit = 20, craftCost = 75, saleMethod = "auction", outputQuantity = 1, reasons = {} },
      twenty = { profit = -5, craftCost = 50, saleMethod = "vendor", outputQuantity = 1, reasons = {} },
    }
    scrollBox = {
      visible = true,
      hooks = {},
      IsVisible = function(self)
        return self.visible
      end,
      ForEachFrame = function(_, callback)
        for _, row in ipairs(rows) do
          callback(row, {})
        end
      end,
      HookScript = function(self, name, callback)
        self.hooks[name] = callback
      end,
    }
    EventUtil = {
      ContinueOnAddOnLoaded = function(addonName, callback)
        assert.are.equal("Blizzard_Professions", addonName)
        onProfessionsLoaded = callback
      end,
    }
    C_Timer = {
      After = function(_, callback)
        timers[#timers + 1] = callback
      end,
    }
    ScrollUtil = {
      AddInitializedFrameCallback = function(box, callback)
        assert.are.equal(scrollBox, box)
        initialized = callback
      end,
    }
    C_CurrencyInfo = {
      GetCoinTextureString = function(amount)
        return amount .. "c"
      end,
    }
    WHITE_FONT_COLOR = {
      GetRGB = function()
        return 1, 1, 1
      end,
    }
    tooltip = {
      lines = {},
      IsOwned = function(self, owner)
        return self.owner == owner
      end,
      AddLine = function(self, text)
        self.lines[#self.lines + 1] = { text }
      end,
      AddDoubleLine = function(self, left, right)
        self.lines[#self.lines + 1] = { left, right }
      end,
      Show = function() end,
    }
    GameTooltip = tooltip
    ns = {
      Config = {
        Get = function(key)
          return settings[key]
        end,
      },
      RecipeParser = {
        Preview = function(recipeID)
          previewCalls = previewCalls + 1
          if recipeID == 30 then
            return nil, "incomplete"
          end
          return previews[recipeID], previews[recipeID] == nil and "skip" or nil
        end,
      },
      Opportunities = {
        GetForRecipe = function(recipe)
          return opportunities[recipe.recipeKey]
        end,
      },
    }
    assert(loadfile("src/Terminology.lua"))("Arbitrage", ns)
    assert(loadfile("src/CraftingWindow.lua"))("Arbitrage", ns)
    assert(loadfile("src/WhatsTraining.lua"))("Arbitrage", ns)
  end)

  -- What's Training builds its tab once Blizzard_Professions loads.
  local function Attach()
    ns.WhatsTraining.Register()
    environment.WhatsTrainingCraftingScrollBox = scrollBox
    onProfessionsLoaded()
    RunTimers()
  end

  it("waits for What's Training's tab, then prices each recipe row by its best variant", function()
    setfenv(1, environment)
    ns.WhatsTraining.Register()
    onProfessionsLoaded()
    environment.WhatsTrainingCraftingScrollBox = scrollBox
    assert.is_nil(initialized, "waits a frame for What's Training to build its tab")
    RunTimers()
    assert.is_function(initialized)

    local row = AddRow(Recipe(10, 99))
    local label = row.arbitrageProfit
    assert.are.equal("+35c", label.text)
    assert.are.same({ 0.2, 1, 0.2 }, label.color)
    assert.is_true(label.visible)
    assert.are.same({ "RIGHT", row.cells[1], "RIGHT" }, label.point, "ends where the name's column does")

    local loss = AddRow(Recipe(20, 98)).arbitrageProfit
    assert.is_false(loss.visible, "leaves a loss blank at the default minimum, like the crafting window")
    settings.craftingWindowMinimumProfit = 0
    ns.WhatsTraining.Refresh()
    assert.are.equal("-5c", loss.text)
    assert.are.same({ 1, 0.2, 0.2 }, loss.color)
    assert.is_true(loss.visible)
  end)

  it("leaves a long name its room and adds the costs below What's Training's tooltip", function()
    setfenv(1, environment)
    Attach()
    local row = AddRow(Recipe(10, 99), 180)
    assert.is_false(row.arbitrageProfit.visible)

    tooltip.lines = { { "Elixir of Testing" } }
    tooltip.owner = row
    row.hooks.OnEnter(row)
    assert.are.same({ "Elixir of Testing" }, tooltip.lines[1])
    assert.are.same({ " " }, tooltip.lines[2])
    assert.are.same({ "Typical Craft Cost", "60c" }, tooltip.lines[3])
    assert.are.same({ "Typical Profit (AH)", "+35c" }, tooltip.lines[4])

    -- What's Training lays the row out again as it resizes.
    row.cells[1].GetUnboundedStringWidth = function()
      return 100
    end
    row.hooks.OnSizeChanged(row, 400, 30)
    assert.is_true(row.arbitrageProfit.visible)

    tooltip.lines, tooltip.owner = {}, nil
    row.hooks.OnEnter(row)
    assert.are.same({}, tooltip.lines, "leaves tooltips it doesn't own alone")
  end)

  it("leaves rank-ups and rows it doesn't recognize alone, and clears recycled rows", function()
    setfenv(1, environment)
    Attach()
    assert.is_nil(AddRow({ recipe = { spell = 40, rank = "Journeyman" } }).arbitrageProfit)
    assert.is_nil(AddRow({ profession = "Alchemy" }).arbitrageProfit)
    local cellless = NewRow(Recipe(10, 99))
    cellless.cells = nil
    initialized(nil, cellless, {})
    assert.is_nil(cellless.arbitrageProfit)
    for _, cell in ipairs({ {}, {
      GetObjectType = function()
        return "Frame"
      end,
    } }) do
      local reshaped = NewRow(Recipe(10, 99))
      reshaped.cells = { cell }
      initialized(nil, reshaped, {})
      assert.is_nil(reshaped.arbitrageProfit, "skips a name cell that isn't a font string")
    end
    assert.is_nil(AddRow(Recipe(50, 97)).arbitrageProfit, "skips recipes Arbitrage can't record")

    local row = AddRow(Recipe(10, 99))
    row.data = { profession = "Alchemy" }
    initialized(nil, row, {})
    assert.is_false(row.arbitrageProfit.visible)
    tooltip.owner = row
    row.hooks.OnEnter(row)
    assert.are.same({}, tooltip.lines)
  end)

  it("marks recipes it can't price yet, blanks profits under the minimum, and follows the setting", function()
    setfenv(1, environment)
    Attach()
    local row = AddRow(Recipe(30, 96))
    assert.are.equal("?", row.arbitrageProfit.text)
    assert.is_true(row.arbitrageProfit.visible)
    tooltip.owner = row
    row.hooks.OnEnter(row)
    assert.are.same(
      { "Profit unknown. Scan the Auction House and visit reagent vendors for prices." },
      tooltip.lines[2]
    )

    settings.craftingWindowMinimumProfit = 50
    ns.WhatsTraining.Refresh()
    assert.is_true(row.arbitrageProfit.visible, "the minimum leaves an unknown profit marked")

    local below = AddRow(Recipe(10, 99))
    assert.is_false(below.arbitrageProfit.visible, "blanks a profit under the minimum")
    tooltip.lines, tooltip.owner = {}, below
    below.hooks.OnEnter(below)
    assert.are.same({ "Typical Profit (AH)", "+35c" }, tooltip.lines[3], "still shows it on hover")

    settings.showCraftingWindowProfits = false
    ns.WhatsTraining.Refresh()
    assert.is_false(below.arbitrageProfit.visible)
    assert.is_nil(below.arbitrageEstimate)
  end)

  it("prices each recipe once until prices change, and again as the tab shows", function()
    setfenv(1, environment)
    Attach()
    AddRow(Recipe(10, 99))
    AddRow(Recipe(10, 99))
    assert.are.equal(1, previewCalls)

    opportunities["ten:a"].profit = 70
    ns.WhatsTraining.Refresh()
    assert.are.equal(2, previewCalls)
    assert.are.equal("+70c", rows[1].arbitrageProfit.text)

    scrollBox.visible = false
    ns.WhatsTraining.Refresh()
    assert.are.equal(2, previewCalls, "waits while the tab is hidden")
    scrollBox.visible = true
    scrollBox.hooks.OnShow(scrollBox)
    assert.are.equal(3, previewCalls)
  end)

  it("leaves the professions window alone without What's Training's scroll list", function()
    setfenv(1, environment)
    ns.WhatsTraining.Register()
    onProfessionsLoaded()
    RunTimers()
    assert.is_nil(initialized)
    ns.WhatsTraining.Refresh()

    -- Another kind of frame under the list's name, such as a classic scroll frame.
    environment.WhatsTrainingCraftingScrollBox = { HookScript = error }
    onProfessionsLoaded()
    RunTimers()
    assert.is_nil(initialized)
  end)
end)

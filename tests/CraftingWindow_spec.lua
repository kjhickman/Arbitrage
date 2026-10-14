local NewEnvironment = dofile("tests/support/Environment.lua")

describe("CraftingWindow", function()
  local environment, ns, frame, scrollBox, rows, timers, initialized, owner
  local recipes, estimates, captureCount, estimateCount, dataSourceChanging

  local function FontString(text, width)
    return {
      text = text or "",
      width = width or 0,
      shown = true,
      SetText = function(self, value)
        self.text = value
      end,
      GetStringWidth = function(self)
        return #self.text * 6
      end,
      GetWidth = function(self)
        return self.width
      end,
      SetWidth = function(self, value)
        self.width = value
      end,
      SetTextColor = function(self, ...)
        self.color = { ... }
      end,
      SetJustifyH = function() end,
      ClearAllPoints = function() end,
      SetPoint = function(self, ...)
        self.point = { ... }
      end,
      Show = function(self)
        self.shown = true
      end,
      Hide = function(self)
        self.shown = false
      end,
      IsShown = function(self)
        return self.shown
      end,
    }
  end

  local function RecipeRow(recipeID)
    local node = {
      data = { recipeInfo = { recipeID = recipeID, name = "Recipe " .. recipeID, learned = true } },
      GetData = function(self)
        return self.data
      end,
    }
    return {
      node = node,
      Label = FontString("A long recipe name", 110),
      Count = FontString(" [2] "),
      SkillUps = FontString("", 26),
      LockedIcon = FontString("", 17),
      hooks = {},
      fontCount = 0,
      GetWidth = function()
        return 260
      end,
      GetElementData = function(self)
        return self.node
      end,
      CreateFontString = function(self)
        self.fontCount = self.fontCount + 1
        return FontString()
      end,
      HookScript = function(self, script, callback)
        self.hooks[script] = callback
      end,
    }
  end

  local function FlushTimers()
    local pending = timers
    timers = {}
    for _, callback in ipairs(pending) do
      callback()
    end
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    rows, timers, recipes, estimates = {}, {}, {}, {}
    captureCount, estimateCount = 0, 0
    dataSourceChanging = false
    initialized, owner = nil, nil
    frame = {
      events = {},
      RegisterEvent = function(self, event)
        self.events[event] = true
      end,
      SetScript = function(self, script, callback)
        self[script] = callback
      end,
    }
    function CreateFrame()
      return frame
    end
    scrollBox = {
      visible = true,
      IsVisible = function(self)
        return self.visible
      end,
      ForEachFrame = function(_, callback)
        for _, row in ipairs(rows) do
          callback(row, row.node)
        end
      end,
      HookScript = function(self, script, callback)
        self[script] = callback
      end,
    }
    ProfessionsFrame = { CraftingPage = { RecipeList = { ScrollBox = scrollBox } } }
    Professions = {
      GetHighestLearnedRecipe = function(info)
        return info.highestLearnedRecipe
      end,
    }
    ScrollUtil = {
      AddInitializedFrameCallback = function(box, callback, callbackOwner, iterateExisting)
        assert.are.equal(scrollBox, box)
        initialized, owner = callback, callbackOwner
        if iterateExisting then
          for _, row in ipairs(rows) do
            callback(row, row.node)
          end
        end
      end,
    }
    C_Timer = {
      After = function(_, callback)
        timers[#timers + 1] = callback
      end,
    }
    C_TradeSkillUI = {
      IsDataSourceChanging = function()
        return dataSourceChanging
      end,
      IsNPCCrafting = function()
        return false
      end,
      IsRuneforging = function()
        return false
      end,
    }
    C_CurrencyInfo = {
      GetCoinTextureString = function(value)
        assert(value >= 0, "money formatting receives an unsigned amount")
        return value .. "c"
      end,
    }
    WHITE_FONT_COLOR = {
      GetRGB = function()
        return 1, 1, 1
      end,
    }
    NORMAL_FONT_COLOR = {
      GetRGB = function()
        return 1, 0.82, 0
      end,
    }
    GameTooltip = {
      lines = {},
      SetOwner = function(self, value)
        self.owner = value
        self.lines = {}
      end,
      AddLine = function(self, text)
        self.lines[#self.lines + 1] = { text }
      end,
      AddDoubleLine = function(self, left, right)
        self.lines[#self.lines + 1] = { left, right }
      end,
      Show = function(self)
        self.shown = true
      end,
    }
    ns = {
      RecipeParser = {
        Capture = function(recipeID)
          captureCount = captureCount + 1
          return recipes[recipeID], recipes[recipeID] and nil or "skip"
        end,
      },
      Opportunities = {
        GetForRecipe = function(recipe)
          estimateCount = estimateCount + 1
          return estimates[recipe.recipeKey]
        end,
      },
    }
    recipes[1] = { { outputItemID = 100, recipeKey = "first" } }
    estimates.first = {
      profit = 150,
      craftCost = 800,
      minimumProfit = 200,
      saleMethod = "auction",
      isUncertain = false,
      reasons = {},
    }
    rows[1] = RecipeRow(1)
    rows[1].LockedIcon:Hide()
    assert(loadfile("src/CraftingWindow.lua"))("Arbitrage", ns)
  end)

  it("adds signed profit to existing rows without replacing their click handlers", function()
    setfenv(1, environment)
    ns.CraftingWindow.Register()
    local row = rows[1]
    assert.are.equal("+150c", row.arbitrageProfit.text)
    assert.same({ 0.2, 1, 0.2 }, row.arbitrageProfit.color)
    assert.are.equal(108, row.Label.width)
    assert.is_nil(row.hooks.OnClick)
    row.hooks.OnEnter(row)
    assert.same({ "Estimated Profit (AH, per craft)", "+150c" }, GameTooltip.lines[3])
    assert.same({ "Best-case Profit", "+200c" }, GameTooltip.lines[4])
  end)

  it("updates reused rows for losses, break-even crafts, and uncertainty", function()
    setfenv(1, environment)
    ns.CraftingWindow.Register()
    estimates.first.profit = -25
    estimates.first.saleMethod = "vendor"
    ns.CraftingWindow.Refresh()
    assert.are.equal("-25c", rows[1].arbitrageProfit.text)
    assert.same({ 1, 0.2, 0.2 }, rows[1].arbitrageProfit.color)
    estimates.first.profit = 0
    estimates.first.isUncertain = true
    ns.CraftingWindow.Refresh()
    assert.same({ 1, 0.82, 0 }, rows[1].arbitrageProfit.color)
    estimates.first.isUncertain = false
    ns.CraftingWindow.Refresh()
    assert.same({ 1, 1, 1 }, rows[1].arbitrageProfit.color)
    assert.are.equal(1, rows[1].fontCount)
  end)

  it("shows unknown prices but clears recycled rows for unsupported or unlearned recipes", function()
    setfenv(1, environment)
    estimates.first = nil
    ns.CraftingWindow.Register()
    local row = rows[1]
    assert.are.equal("?", row.arbitrageProfit.text)
    row.node.data.recipeInfo.recipeID = 2
    initialized(owner, row, row.node)
    assert.is_false(row.arbitrageProfit.shown)
    assert.are.equal(108, row.Label.width)
    row.node.data.recipeInfo.recipeID = 1
    row.node.data.recipeInfo.learned = false
    initialized(owner, row, row.node)
    assert.is_false(row.arbitrageProfit.shown)
    assert.are.equal(2, captureCount)
  end)

  it("uses the displayed learned rank and best supported reagent variant", function()
    setfenv(1, environment)
    rows[1].node.data.recipeInfo = {
      recipeID = 2,
      learned = false,
      highestLearnedRecipe = { recipeID = 1, learned = true },
    }
    recipes[1][2] = { outputItemID = 100, recipeKey = "second" }
    estimates.second = { profit = 170, saleMethod = "vendor", isUncertain = false }
    ns.CraftingWindow.Register()
    assert.are.equal("+170c", rows[1].arbitrageProfit.text)
  end)

  it("reserves space for profits, counts, and locks without shrinking names on every refresh", function()
    setfenv(1, environment)
    local row = rows[1]
    row.Label:SetText(string.rep("Long recipe name ", 5))
    row.LockedIcon:Show()
    ns.CraftingWindow.Register()
    local width = row.Label.width
    assert.are.equal(-21, row.arbitrageProfit.point[4])
    assert.are.equal(139, width)
    ns.CraftingWindow.Refresh()
    assert.are.equal(width, row.Label.width)
    row.node.data.recipeInfo.learned = false
    ns.CraftingWindow.Refresh()
    assert.are.equal(177, row.Label.width)
  end)

  it("prices a live recipe even when the saved profession snapshot is incomplete", function()
    setfenv(1, environment)
    recipes[1][1].outputQuantity = 2
    recipes[1][1].reagents = { { itemID = 700, quantity = 1 } }
    ns.RecipeBook = {
      GetRecipes = function()
        return {}
      end,
    }
    ns.Database = {
      GetVendorPrice = function() end,
      GetLatestBuyout = function(itemID)
        return itemID == 700 and 5000 or nil
      end,
      GetMarket = function()
        return "Alliance"
      end,
    }
    ns.RollingMarketValue = {
      Get = function(keys)
        if keys[1] == "100" or keys[1] == "700" then
          return { value = 10000, isUncertain = false, reasons = {} }
        end
      end,
    }
    ns.Vendor = {
      GetSellPrice = function()
        return 0
      end,
    }
    assert(loadfile("src/CraftingPlanner.lua"))("Arbitrage", ns)
    assert(loadfile("src/Crafting.lua"))("Arbitrage", ns)
    assert(loadfile("src/Opportunities.lua"))("Arbitrage", ns)

    ns.CraftingWindow.Register()
    assert.are.equal("+9000c", rows[1].arbitrageProfit.text)
    rows[1].hooks.OnEnter(rows[1])
    assert.same({ "Best-case Profit", "+14000c" }, GameTooltip.lines[4])
    recipes[1][1].outputQuantity = 1
    ns.CraftingWindow.Refresh()
    assert.are.equal("-500c", rows[1].arbitrageProfit.text)
  end)

  it("caches scrolling estimates and coalesces price and recipe refreshes", function()
    setfenv(1, environment)
    ns.CraftingWindow.Register()
    initialized(owner, rows[1], rows[1].node)
    assert.are.equal(1, captureCount)
    assert.are.equal(1, estimateCount)
    estimates.first.profit = 250
    frame.OnEvent(frame, "GET_ITEM_INFO_RECEIVED", 100, false)
    assert.are.equal(0, #timers)
    frame.OnEvent(frame, "GET_ITEM_INFO_RECEIVED", 100, true)
    frame.OnEvent(frame, "TRADE_SKILL_LIST_UPDATE")
    frame.OnEvent(frame, "MERCHANT_UPDATE")
    assert.are.equal(1, #timers)
    FlushTimers()
    assert.are.equal("+250c", rows[1].arbitrageProfit.text)
    assert.are.equal(2, captureCount)
    assert.is_true(frame.events.TRADE_SKILL_DATA_SOURCE_CHANGED)
    assert.is_true(frame.events.MERCHANT_SHOW)
  end)

  it("attaches when Blizzard loads later and refreshes when the list is reopened", function()
    setfenv(1, environment)
    local professionsFrame = ProfessionsFrame
    ProfessionsFrame = nil
    ns.CraftingWindow.Register()
    assert.is_nil(initialized)
    ProfessionsFrame = professionsFrame
    frame.OnEvent(frame, "ADDON_LOADED", "Blizzard_Professions")
    FlushTimers()
    assert.is_function(initialized)
    scrollBox.visible = false
    ns.CraftingWindow.Refresh()
    assert.are.equal(2, captureCount)
    estimates.first.profit = 300
    scrollBox.visible = true
    scrollBox.OnShow()
    FlushTimers()
    assert.are.equal("+300c", rows[1].arbitrageProfit.text)
  end)

  it("leaves categories untouched and hides stale profits while the profession changes", function()
    setfenv(1, environment)
    rows[2] = { node = {
      GetData = function()
        return { categoryInfo = {} }
      end,
    } }
    ns.CraftingWindow.Register()
    dataSourceChanging = true
    initialized(owner, rows[1], rows[1].node)
    assert.is_false(rows[1].arbitrageProfit.shown)
    assert.are.equal(1, captureCount)
  end)
end)

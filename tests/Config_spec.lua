local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Config", function()
  local environment
  local registeredSettings
  local controls
  local sections
  local registeredCategory
  local openedCategoryID
  local craftingRefreshCount
  local opportunityRefreshCount
  local minimapRefreshCount
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    registeredSettings = {}
    controls = {}
    sections = {}
    registeredCategory = nil
    openedCategoryID = nil
    craftingRefreshCount = 0
    opportunityRefreshCount = 0
    minimapRefreshCount = 0

    local function NewInitializer(kind, setting, tooltip, options)
      return {
        kind = kind,
        setting = setting,
        tooltip = tooltip,
        options = options,
      }
    end

    Settings = {
      VarType = {
        Boolean = "boolean",
        String = "string",
        Number = "number",
      },
      RegisterVerticalLayoutCategory = function(name)
        local category = {
          name = name,
          GetID = function()
            return "arbitrage-category"
          end,
        }
        local layout = {
          AddInitializer = function(_, initializer)
            sections[#sections + 1] = initializer.name
          end,
        }
        return category, layout
      end,
      RegisterAddOnSetting = function(category, variable, key, config, variableType, label, default)
        assert(category.name == "Arbitrage", "registers settings in the addon category")
        local setting = {
          key = key,
          label = label,
          variable = variable,
          variableType = variableType,
          default = default,
          SetValue = function(self, value)
            config[self.key] = value
            if self.callback then
              self.callback(self, value)
            end
          end,
          SetValueChangedCallback = function(self, callback)
            self.callback = callback
          end,
        }
        registeredSettings[#registeredSettings + 1] = setting
        return setting
      end,
      CreateCheckbox = function(category, setting, tooltip)
        assert(category.name == "Arbitrage", "creates checkboxes in the addon category")
        local initializer = NewInitializer("checkbox", setting, tooltip)
        controls[setting.key] = initializer
        return initializer
      end,
      CreateDropdown = function(category, setting, options, tooltip)
        assert(category.name == "Arbitrage", "creates dropdowns in the addon category")
        local initializer = NewInitializer("dropdown", setting, tooltip, options())
        controls[setting.key] = initializer
        return initializer
      end,
      CreateControlTextContainer = function()
        local data = {}
        return {
          Add = function(_, value, label)
            data[#data + 1] = { value = value, label = label }
          end,
          GetData = function()
            return data
          end,
        }
      end,
      RegisterAddOnCategory = function(category)
        registeredCategory = category
      end,
      OpenToCategory = function(categoryID)
        openedCategoryID = categoryID
      end,
    }

    function CreateSettingsListSectionHeaderInitializer(name)
      return { name = name }
    end

    C_CurrencyInfo = {
      GetCoinTextureString = function(value, height)
        assert.are.equal(10, height)
        return value .. "c"
      end,
    }

    ARBITRAGE_CONFIG = "invalid"

    ns = {
      OpportunityPanel = {
        Refresh = function()
          opportunityRefreshCount = opportunityRefreshCount + 1
        end,
      },
      CraftingWindow = {
        Refresh = function()
          craftingRefreshCount = craftingRefreshCount + 1
        end,
      },
      MinimapButton = {
        Refresh = function()
          minimapRefreshCount = minimapRefreshCount + 1
        end,
      },
    }
    assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
    ns.Config.Init()
  end)

  it("resets an invalid persisted config root", function()
    setfenv(1, environment)
    assert(type(ARBITRAGE_CONFIG) == "table", "resets an invalid persisted root")
  end)

  it("replaces invalid persisted values and fills every missing default", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = {
      showMarketValue = "invalid",
      tooltipDetails = "invalid",
      minimumProfit = 1234,
      showTooltips = true,
      includeBestCaseOnly = false,
    }
    ns.Config.Init()

    assert(ARBITRAGE_CONFIG.showTooltips == nil, "removes the retired tooltip master setting")
    assert(ARBITRAGE_CONFIG.showMarketValue == true, "resets invalid persisted values")
    assert(ARBITRAGE_CONFIG.showCraftingCost == true, "adds missing crafting cost default")
    assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")
    assert(ARBITRAGE_CONFIG.showCraftProfit == false, "hides Craft Profit by default")
    assert(ARBITRAGE_CONFIG.tooltipDetails == "shift", "resets an invalid detail mode")
    assert(ARBITRAGE_CONFIG.showCraftingWindowProfits == true, "adds the crafting window profits default")
    assert.is_nil(ARBITRAGE_CONFIG.includeBestCaseOnly)
    assert(ARBITRAGE_CONFIG.showUncertainOpportunities == true, "adds the uncertain opportunity default")
    assert(ARBITRAGE_CONFIG.minimumProfit == 1, "falls back to the default profit threshold")
    assert(ARBITRAGE_CONFIG.craftingWindowMinimumProfit == 1, "adds the crafting-window profit threshold")
    assert(ARBITRAGE_CONFIG.opportunityProfession == "", "adds the any-profession default")
    assert(ARBITRAGE_CONFIG.opportunityCrafter == "", "adds the any-crafter default")
    assert(ARBITRAGE_CONFIG.opportunitySaleMethod == "", "adds the any-sale-method default")
    assert.are.same({}, ARBITRAGE_CONFIG.databaseFilters)
    assert.is_false(ARBITRAGE_CONFIG.showMinimapButton)
  end)

  it("keeps the minimap button's saved position in a table of its own, replacing anything but a table", function()
    setfenv(1, environment)
    local saved = { minimapPos = 140 }
    ARBITRAGE_CONFIG = { minimapButton = saved }
    ns.Config.Init()
    assert.are.equal(saved, ns.Config.Get("minimapButton"))

    ARBITRAGE_CONFIG = { minimapButton = 140 }
    ns.Config.Init()
    local first = ns.Config.Get("minimapButton")
    assert.are.same({}, first)

    ARBITRAGE_CONFIG = {}
    ns.Config.Init()
    assert.are_not.equal(first, ns.Config.Get("minimapButton"))
  end)

  it("keeps saved Database filters for the Database tab to check, replacing anything but a table", function()
    setfenv(1, environment)
    local saved = { freshness = 3, slots = { Head = true } }
    ARBITRAGE_CONFIG = { databaseFilters = saved }
    ns.Config.Init()
    assert.are.equal(saved, ns.Config.Get("databaseFilters"))

    ARBITRAGE_CONFIG = { databaseFilters = "Head" }
    ns.Config.Init()
    assert.are.same({}, ns.Config.Get("databaseFilters"))
  end)

  it("keeps saved opportunity filters but resets an unknown sale method", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = {
      opportunityProfession = "Alchemy",
      opportunityCrafter = ns.Config.CURRENT_CHARACTER,
      opportunitySaleMethod = "vendor",
    }
    ns.Config.Init()
    assert.are.equal("Alchemy", ns.Config.Get("opportunityProfession"))
    assert.are.equal(ns.Config.CURRENT_CHARACTER, ns.Config.Get("opportunityCrafter"))
    assert.are.equal("vendor", ns.Config.Get("opportunitySaleMethod"))

    ARBITRAGE_CONFIG = { opportunitySaleMethod = "trade" }
    ns.Config.Init()
    assert.are.equal("", ns.Config.Get("opportunitySaleMethod"))
  end)

  it("migrates disabled legacy tooltip master switch once", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = { showTooltips = false, showMarketValue = true }
    ns.Config.Init()

    assert.is_nil(ARBITRAGE_CONFIG.showTooltips)
    assert.is_false(ns.Config.Get("showMarketValue"))
    assert.is_false(ns.Config.Get("showBuyout"))
    assert.is_false(ns.Config.Get("showCraftingCost"))
    assert.is_false(ns.Config.Get("showMinimumCraftCost"))
  end)

  it("clears the retired vendor profit settings and keeps the crafting cost choices", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = {
      showCraftingCost = false,
      showMinimumCraftCost = true,
      showVendorProfit = true,
      showMinimumVendorProfit = false,
    }
    ns.Config.Init()

    assert.is_nil(ARBITRAGE_CONFIG.showVendorProfit)
    assert.is_nil(ARBITRAGE_CONFIG.showMinimumVendorProfit)
    assert.is_false(ns.Config.Get("showCraftingCost"))
    assert.is_true(ns.Config.Get("showMinimumCraftCost"))
    assert.is_false(ns.Config.Get("showCraftProfit"))
  end)

  it("copies the old profit threshold into the crafting window once, including Show all crafts", function()
    setfenv(1, environment)
    for _, minimumProfit in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
      ARBITRAGE_CONFIG = { minimumProfit = minimumProfit }
      ns.Config.Init()
      assert.are.equal(minimumProfit, ns.Config.Get("minimumProfit"))
      assert.are.equal(minimumProfit, ns.Config.Get("craftingWindowMinimumProfit"))

      ARBITRAGE_CONFIG.minimumProfit = minimumProfit == 0 and 1 or 0
      ns.Config.Init()
      assert.are.equal(minimumProfit, ns.Config.Get("craftingWindowMinimumProfit"))
    end
  end)

  it("keeps a saved scan work preset and resets any other value to 10 ms", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = { scanWorkBudget = 16 }
    ns.Config.Init()
    assert.are.equal(16, ns.Config.Get("scanWorkBudget"))

    for _, invalid in ipairs({ 7, 0, 100, "fast" }) do
      ARBITRAGE_CONFIG = { scanWorkBudget = invalid }
      ns.Config.Init()
      assert.are.equal(10, ns.Config.Get("scanWorkBudget"))
    end
  end)

  it("validates the two profit thresholds independently", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = { minimumProfit = 500, craftingWindowMinimumProfit = 1234 }
    ns.Config.Init()
    assert.are.equal(500, ns.Config.Get("minimumProfit"))
    assert.are.equal(1, ns.Config.Get("craftingWindowMinimumProfit"))

    ARBITRAGE_CONFIG = { minimumProfit = "invalid", craftingWindowMinimumProfit = 500 }
    ns.Config.Init()
    assert.are.equal(1, ns.Config.Get("minimumProfit"))
    assert.are.equal(500, ns.Config.Get("craftingWindowMinimumProfit"))
  end)

  describe("the options panel", function()
    before_each(function()
      setfenv(1, environment)
      ns.Config.RegisterOptionsPanel()
    end)

    it("registers grouped addon settings", function()
      setfenv(1, environment)
      assert(registeredCategory and registeredCategory.name == "Arbitrage", "registers a vertical addon category")
      assert(#registeredSettings == 11, "registers all supported settings")
      assert(registeredSettings[1].variable == "Arbitrage_showMarketValue", "uses an addon-prefixed setting variable")
      assert.are.same({ "Item Tooltips", "Crafting Window", "Opportunities", "Scans", "Minimap" }, sections)
    end)

    it("provides explanatory text for every control", function()
      setfenv(1, environment)
      for key, control in pairs(controls) do
        assert(type(control.tooltip) == "string" and control.tooltip ~= "", key .. " has explanatory text")
      end
    end)

    it("labels every setting in Title Case with the Craft Cost and Buyout Craft Cost names", function()
      setfenv(1, environment)
      local labels = {}
      for index, setting in ipairs(registeredSettings) do
        labels[index] = setting.label
      end
      assert.are.same({
        "Show Market Value",
        "Show Buyout",
        "Show Craft Cost",
        "Show Buyout Craft Cost",
        "Show Craft Profit",
        "Pricing Details",
        "Show Crafting Window Profits",
        "Minimum Profit",
        "Show Skill-Up Icons",
        "Scan Work Per Frame",
        "Show Minimap Button",
      }, labels)
      for key, control in pairs(controls) do
        assert.is_nil(control.tooltip:lower():find("best", 1, true), key .. " drops the best-case name")
        assert.is_nil(control.tooltip:find("Crafting Cost", 1, true), key .. " uses the Craft Cost name")
      end
    end)

    it("offers an unchecked Show Craft Profit checkbox instead of the vendor profit ones", function()
      setfenv(1, environment)
      local craftProfit = controls.showCraftProfit
      assert.are.equal("checkbox", craftProfit.kind)
      assert.are.equal("Show Craft Profit", craftProfit.setting.label)
      assert.is_false(craftProfit.setting.default)
      assert.are.equal("Shows Market Value after the 5% Auction House cut minus Craft Cost.", craftProfit.tooltip)
      assert.is_nil(controls.showVendorProfit)
      assert.is_nil(controls.showMinimumVendorProfit)
    end)

    it("offers all pricing detail modes with the persisted Shift default", function()
      setfenv(1, environment)
      local details = controls.tooltipDetails
      assert(details.kind == "dropdown", "uses a dropdown for pricing details")
      assert(
        details.setting.variableType == "string" and details.setting.default == "shift",
        "persists the detail mode"
      )
      assert(
        #details.options == 3
          and details.options[1].value == "compact"
          and details.options[1].label == "Never"
          and details.options[2].value == "shift"
          and details.options[2].label == "Hold Shift"
          and details.options[3].value == "always"
          and details.options[3].label == "Always",
        "offers all pricing detail modes"
      )
    end)

    it("shows crafting window profits by default and refreshes when changed", function()
      setfenv(1, environment)
      assert(controls.showCraftingWindowProfits.setting.default == true, "shows crafting window profits by default")
      controls.showCraftingWindowProfits.setting:SetValue(false)
      assert(craftingRefreshCount == 1, "refreshes the crafting window when its visibility setting changes")
    end)

    it("shows skill-up icons by default and saves changes while refreshing Opportunities", function()
      setfenv(1, environment)
      local control = controls.showOpportunitySkillUpIcons
      assert.are.equal("checkbox", control.kind)
      assert.is_true(control.setting.default)
      assert.is_true(ns.Config.Get("showOpportunitySkillUpIcons"))

      control.setting:SetValue(false)
      ns.Config.Init()
      assert.is_false(ns.Config.Get("showOpportunitySkillUpIcons"))
      assert.are.equal(1, opportunityRefreshCount)
    end)

    it("hides the minimap button by default and updates it when changed", function()
      setfenv(1, environment)
      local control = controls.showMinimapButton
      assert.are.equal("checkbox", control.kind)
      assert.is_false(control.setting.default)

      control.setting:SetValue(true)
      assert.is_true(ns.Config.Get("showMinimapButton"))
      assert.are.equal(1, minimapRefreshCount)
    end)

    it("offers every crafting-window minimum-profit preset", function()
      setfenv(1, environment)
      local minimumProfit = controls.craftingWindowMinimumProfit
      assert.are.equal("dropdown", minimumProfit.kind)
      assert.are.equal("number", minimumProfit.setting.variableType)
      assert.are.equal(1, minimumProfit.setting.default)
      local values = {}
      for index, option in ipairs(minimumProfit.options) do
        values[index] = option.value
      end
      assert.are.same(
        { 0, 1, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000 },
        values
      )
      assert.are.equal("Show all crafts", minimumProfit.options[1].label)
      assert.are.equal("Any profit", minimumProfit.options[2].label)
      assert.are.equal("200c", minimumProfit.options[3].label)
      assert.are.equal("1000000c", minimumProfit.options[#minimumProfit.options].label)
    end)

    it("offers scan work presets from smoothest to fastest with a 10 ms default", function()
      setfenv(1, environment)
      local scanWorkBudget = controls.scanWorkBudget
      assert.are.equal("dropdown", scanWorkBudget.kind)
      assert.are.equal("number", scanWorkBudget.setting.variableType)
      assert.are.equal(10, scanWorkBudget.setting.default)
      local values, labels = {}, {}
      for index, option in ipairs(scanWorkBudget.options) do
        values[index] = option.value
        labels[index] = option.label
      end
      assert.are.same({ 4, 6, 8, 10, 12, 16, 20 }, values)
      assert.are.same({
        "4 ms (smoothest)",
        "6 ms",
        "8 ms",
        "10 ms (default)",
        "12 ms",
        "16 ms",
        "20 ms (fastest)",
      }, labels)

      scanWorkBudget.setting:SetValue(16)
      assert.are.equal(16, ns.Config.Get("scanWorkBudget"))
    end)

    it("keeps the crafting-window threshold independent and refreshes the crafting window", function()
      setfenv(1, environment)
      local setting = controls.craftingWindowMinimumProfit.setting
      ns.Config.Set("minimumProfit", 500)
      assert.are.equal(1, ns.Config.Get("craftingWindowMinimumProfit"))

      setting:SetValue(1000)
      assert.are.equal(500, ns.Config.Get("minimumProfit"))
      assert.are.equal(1000, ns.Config.Get("craftingWindowMinimumProfit"))
      assert.are.equal(1, craftingRefreshCount)

      setting:SetValue(0)
      assert.are.equal(500, ns.Config.Get("minimumProfit"))
      assert.are.equal(0, ns.Config.Get("craftingWindowMinimumProfit"))
      assert.are.equal(2, craftingRefreshCount)
    end)

    it("opens its registered category and exposes current config values", function()
      setfenv(1, environment)
      ns.Config.OpenOptionsPanel()
      assert(openedCategoryID == "arbitrage-category", "opens the registered addon settings category")
      assert(ns.Config.Get("showMarketValue") == true, "gets config values")
    end)
  end)
end)

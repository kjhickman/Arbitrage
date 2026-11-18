local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Config", function()
  local environment
  local registeredSettings
  local controls
  local sections
  local registeredCategory
  local openedCategoryID
  local craftingRefreshCount
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
      CraftingWindow = {
        Refresh = function()
          craftingRefreshCount = craftingRefreshCount + 1
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
    ARBITRAGE_CONFIG =
      { showMarketValue = "invalid", tooltipDetails = "invalid", minimumProfit = 1234, showTooltips = true }
    ns.Config.Init()

    assert(ARBITRAGE_CONFIG.showTooltips == nil, "removes the retired tooltip master setting")
    assert(ARBITRAGE_CONFIG.showMarketValue == true, "resets invalid persisted values")
    assert(ARBITRAGE_CONFIG.showCraftingCost == true, "adds missing crafting cost default")
    assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")
    assert(ARBITRAGE_CONFIG.showCraftProfit == false, "hides Craft Profit by default")
    assert(ARBITRAGE_CONFIG.tooltipDetails == "shift", "resets an invalid detail mode")
    assert(ARBITRAGE_CONFIG.showCraftingWindowProfits == true, "adds the crafting window profits default")
    assert(ARBITRAGE_CONFIG.includeBestCaseOnly == true, "adds the best-case-only default")
    assert(ARBITRAGE_CONFIG.showUncertainOpportunities == true, "adds the uncertain opportunity default")
    assert(ARBITRAGE_CONFIG.minimumProfit == 1, "falls back to the default profit threshold")
    assert(ARBITRAGE_CONFIG.craftingWindowMinimumProfit == 1, "adds the crafting-window profit threshold")
    assert(ARBITRAGE_CONFIG.opportunityProfession == "", "adds the any-profession default")
    assert(ARBITRAGE_CONFIG.opportunityCrafter == "", "adds the any-crafter default")
    assert(ARBITRAGE_CONFIG.opportunitySaleMethod == "", "adds the any-sale-method default")
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
      assert(#registeredSettings == 7, "registers all supported settings")
      assert(registeredSettings[1].variable == "Arbitrage_showMarketValue", "uses an addon-prefixed setting variable")
      assert(sections[1] == "Item Tooltips" and sections[2] == "Crafting Window", "groups related settings")
    end)

    it("provides explanatory text for every control", function()
      setfenv(1, environment)
      for key, control in pairs(controls) do
        assert(type(control.tooltip) == "string" and control.tooltip ~= "", key .. " has explanatory text")
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
          and details.options[1].label == "Compact"
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

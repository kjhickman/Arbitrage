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
        SetParentInitializer = function(self, parent, modifyPredicate)
          self.parentInitializer = parent
          self.modifyPredicates = { modifyPredicate }
        end,
      }
    end

    Settings = {
      VarType = {
        Boolean = "boolean",
        String = "string",
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
    assert(ARBITRAGE_CONFIG.tooltipDetails == "shift", "resets an invalid detail mode")
    assert(ARBITRAGE_CONFIG.showCraftingWindowProfits == true, "adds the crafting window profits default")
    assert(ARBITRAGE_CONFIG.includeBestCaseOnly == true, "adds the best-case-only default")
    assert(ARBITRAGE_CONFIG.showUncertainOpportunities == true, "adds the uncertain opportunity default")
    assert(ARBITRAGE_CONFIG.minimumProfit == 1, "falls back to the default profit threshold")
  end)

  it("migrates disabled legacy tooltip master switch once and updates opportunity filters", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = { showTooltips = false, showMarketValue = true }
    ns.Config.Init()

    assert.is_nil(ARBITRAGE_CONFIG.showTooltips)
    assert.is_false(ns.Config.Get("showMarketValue"))
    assert.is_false(ns.Config.Get("showCraftingCost"))
    assert.is_false(ns.Config.Get("showMinimumCraftCost"))

    ns.Config.Set("minimumProfit", 500)
    ns.Config.Set("includeBestCaseOnly", false)
    assert.are.equal(500, ns.Config.Get("minimumProfit"))
    assert.is_false(ns.Config.Get("includeBestCaseOnly"))
  end)

  describe("the options panel", function()
    before_each(function()
      setfenv(1, environment)
      ns.Config.RegisterOptionsPanel()
    end)

    it("registers grouped addon settings without modifying Blizzard's control hierarchy", function()
      setfenv(1, environment)
      assert(registeredCategory and registeredCategory.name == "Arbitrage", "registers a vertical addon category")
      assert(#registeredSettings == 5, "registers all supported settings")
      assert(registeredSettings[1].variable == "Arbitrage_showMarketValue", "uses an addon-prefixed setting variable")
      assert(sections[1] == "Item Tooltips" and sections[2] == "Crafting Window", "groups related settings")

      for key, control in pairs(controls) do
        assert(control.parentInitializer == nil, key .. " leaves Blizzard's search hierarchy untainted")
        assert(control.modifyPredicates == nil, key .. " avoids addon predicates in shared settings controls")
      end
    end)

    it("provides explanatory text for every control", function()
      setfenv(1, environment)
      for key, control in pairs(controls) do
        assert(type(control.tooltip) == "string" and control.tooltip ~= "", key .. " has explanatory text")
      end
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

    it("opens its registered category and exposes current config values", function()
      setfenv(1, environment)
      ns.Config.OpenOptionsPanel()
      assert(openedCategoryID == "arbitrage-category", "opens the registered addon settings category")
      assert(ns.Config.Get("showMarketValue") == true, "gets config values")
    end)
  end)
end)

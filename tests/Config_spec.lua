local NewEnvironment = dofile("tests/support/Environment.lua")

describe("Config", function()
  local environment
  local registeredSettings
  local controls
  local sections
  local registeredCategory
  local openedCategoryID
  local refreshCount
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
    refreshCount = 0
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
        Number = "number",
      },
      CreateSliderOptions = function(minValue, maxValue, step)
        return {
          minValue = minValue,
          maxValue = maxValue,
          step = step,
          SetLabelFormatter = function(self, labelType, formatter)
            self.labelType = labelType
            self.formatter = formatter
          end,
        }
      end,
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

    MinimalSliderWithSteppersMixin = { Label = { Right = "right" } }

    C_CurrencyInfo = {
      GetCoinTextureString = function(value)
        return tostring(value) .. "c"
      end,
    }

    function CreateSettingsCheckboxSliderInitializer(
      cbSetting,
      cbLabel,
      cbTooltip,
      sliderSetting,
      sliderOptions,
      sliderLabel,
      sliderTooltip
    )
      local initializer = NewInitializer("checkboxSlider", cbSetting, cbTooltip, sliderOptions)
      initializer.checkboxLabel = cbLabel
      initializer.sliderSetting = sliderSetting
      initializer.sliderLabel = sliderLabel
      initializer.sliderTooltip = sliderTooltip
      controls[cbSetting.key] = initializer
      controls[sliderSetting.key] = initializer
      return initializer
    end

    ARBITRAGE_CONFIG = "invalid"

    ns = {
      AuctionHouse = {
        Refresh = function()
          refreshCount = refreshCount + 1
        end,
      },
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
    ARBITRAGE_CONFIG = { showTooltips = "invalid", tooltipDetails = "invalid" }
    ns.Config.Init()

    assert(ARBITRAGE_CONFIG.showTooltips == true, "resets invalid persisted values")
    assert(ARBITRAGE_CONFIG.showMarketValue == true, "adds the market value default")
    assert(ARBITRAGE_CONFIG.showCraftingCost == true, "adds missing crafting cost default")
    assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")
    assert(ARBITRAGE_CONFIG.tooltipDetails == "shift", "resets an invalid detail mode")
    assert(ARBITRAGE_CONFIG.includeBestCaseOnly == true, "adds the best-case-only default")
    assert(ARBITRAGE_CONFIG.showUncertainOpportunities == true, "adds the uncertain opportunity default")
  end)

  describe("the options panel", function()
    before_each(function()
      setfenv(1, environment)
      ns.Config.RegisterOptionsPanel()
    end)

    it("registers grouped addon settings without modifying Blizzard's control hierarchy", function()
      setfenv(1, environment)
      assert(registeredCategory and registeredCategory.name == "Arbitrage", "registers a vertical addon category")
      assert(#registeredSettings == 9, "registers all supported settings")
      assert(registeredSettings[1].variable == "Arbitrage_showTooltips", "uses an addon-prefixed setting variable")
      assert(sections[1] == "Item Tooltips" and sections[2] == "Opportunity List", "groups related settings")

      local master = controls.showTooltips
      assert(master and master.kind == "checkbox", "creates the tooltip master checkbox")
      for key, control in pairs(controls) do
        assert(control.parentInitializer == nil, key .. " leaves Blizzard's search hierarchy untainted")
        assert(control.modifyPredicates == nil, key .. " avoids addon predicates in shared settings controls")
      end
    end)

    it("pairs the minimum profit slider with the profitable-only checkbox", function()
      setfenv(1, environment)
      local filter = controls.onlyProfitableCrafts
      assert(filter and filter.kind == "checkboxSlider", "creates one paired control for the profit filter")
      assert(filter.sliderSetting.key == "minimumProfit", "nests the minimum profit slider in the pair")
      assert(controls.minimumProfit == filter, "keeps the threshold inside the paired control")
      assert(
        filter.options.minValue == 0 and filter.options.maxValue == 500000 and filter.options.step == 1000,
        "steps the threshold in ten-silver increments up to fifty gold"
      )
      assert(filter.options.formatter(1000) == "1000c", "labels the threshold as money")
    end)

    it("refreshes the panel and the profession window when a profit filter changes", function()
      setfenv(1, environment)
      controls.onlyProfitableCrafts.setting:SetValue(false)
      assert(refreshCount == 1 and craftingRefreshCount == 1, "refreshes both views for the profitable-only switch")

      controls.minimumProfit.sliderSetting:SetValue(50000)
      assert(refreshCount == 2 and craftingRefreshCount == 2, "refreshes both views for the threshold")
      assert(ns.Config.Get("minimumProfit") == 50000, "stores the threshold in copper")
    end)

    it("preserves tooltip suboptions when the master switch is disabled and reenabled", function()
      setfenv(1, environment)
      local master = controls.showTooltips
      master.setting:SetValue(false)
      assert(ns.Config.Get("showTooltips") == false, "persists the tooltip master switch")
      controls.showMarketValue.setting:SetValue(false)
      controls.tooltipDetails.setting:SetValue("always")
      master.setting:SetValue(true)
      assert(ns.Config.Get("showMarketValue") == false, "preserves suboptions configured while tooltips are disabled")
      assert(ns.Config.Get("tooltipDetails") == "always", "preserves the detail mode when tooltips are reenabled")
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

    it("includes best-case and uncertain opportunities by default and refreshes when they change", function()
      setfenv(1, environment)
      assert(controls.includeBestCaseOnly.setting.default == true, "preserves best-case-only opportunities by default")
      assert(
        controls.showUncertainOpportunities.setting.default == true,
        "preserves uncertain opportunities by default"
      )
      controls.includeBestCaseOnly.setting:SetValue(false)
      controls.showUncertainOpportunities.setting:SetValue(false)
      assert(refreshCount == 2, "refreshes opportunities when their visibility settings change")
    end)

    it("opens its registered category and exposes current config values", function()
      setfenv(1, environment)
      ns.Config.OpenOptionsPanel()
      assert(openedCategoryID == "arbitrage-category", "opens the registered addon settings category")
      assert(ns.Config.Get("showTooltips") == true, "gets config values")
    end)
  end)
end)

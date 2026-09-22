local registeredSettings = {}
local controls = {}
local sections = {}
local registeredCategory
local openedCategoryID
local refreshCount = 0

local function NewInitializer(kind, setting, tooltip, options)
  return {
    kind = kind,
    setting = setting,
    tooltip = tooltip,
    options = options,
    SetParentInitializer = function(self, parent, modifyPredicate)
      self.parent = parent
      self.modifyPredicate = modifyPredicate
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

local ns = {
  AuctionHouse = {
    Refresh = function()
      refreshCount = refreshCount + 1
    end,
  },
}
assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
ns.Config.Init()

assert(type(ARBITRAGE_CONFIG) == "table", "resets an invalid persisted root")

ARBITRAGE_CONFIG = { showTooltips = "invalid", tooltipDetails = "invalid" }
ns.Config.Init()

assert(ARBITRAGE_CONFIG.showTooltips == true, "resets invalid persisted values")
assert(ARBITRAGE_CONFIG.showMarketValue == true, "adds the market value default")
assert(ARBITRAGE_CONFIG.showCraftingCost == true, "adds missing crafting cost default")
assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")
assert(ARBITRAGE_CONFIG.tooltipDetails == "shift", "resets an invalid detail mode")
assert(ARBITRAGE_CONFIG.includeBestCaseOnly == true, "adds the best-case-only default")
assert(ARBITRAGE_CONFIG.showUncertainOpportunities == true, "adds the uncertain opportunity default")

ns.Config.RegisterOptionsPanel()
assert(registeredCategory and registeredCategory.name == "Arbitrage", "registers a vertical addon category")
assert(#registeredSettings == 7, "registers all supported settings")
assert(registeredSettings[1].variable == "Arbitrage_showTooltips", "uses an addon-prefixed setting variable")
assert(sections[1] == "Item Tooltips" and sections[2] == "Opportunity List", "groups related settings")

local master = controls.showTooltips
assert(master and master.kind == "checkbox", "creates the tooltip master checkbox")
assert(controls.showMarketValue.parent == master, "makes Market Value depend on item tooltips")
assert(controls.showCraftingCost.parent == master, "makes Crafting Cost depend on item tooltips")
assert(controls.showMinimumCraftCost.parent == master, "makes Best-case Crafting Cost depend on item tooltips")
assert(controls.tooltipDetails.parent == master, "makes pricing details depend on item tooltips")

master.setting:SetValue(false)
assert(not controls.showMarketValue.modifyPredicate(), "disables Market Value with item tooltips")
assert(not controls.showCraftingCost.modifyPredicate(), "disables Crafting Cost with item tooltips")
assert(not controls.showMinimumCraftCost.modifyPredicate(), "disables Best-case Crafting Cost with item tooltips")
assert(not controls.tooltipDetails.modifyPredicate(), "disables pricing details with item tooltips")
master.setting:SetValue(true)

for key, control in pairs(controls) do
  assert(type(control.tooltip) == "string" and control.tooltip ~= "", key .. " has explanatory text")
end

local details = controls.tooltipDetails
assert(details.kind == "dropdown", "uses a dropdown for pricing details")
assert(details.setting.variableType == "string" and details.setting.default == "shift", "persists the detail mode")
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
assert(controls.includeBestCaseOnly.setting.default == true, "preserves best-case-only opportunities by default")
assert(controls.showUncertainOpportunities.setting.default == true, "preserves uncertain opportunities by default")
controls.includeBestCaseOnly.setting:SetValue(false)
controls.showUncertainOpportunities.setting:SetValue(false)
assert(refreshCount == 2, "refreshes opportunities when their visibility settings change")

ns.Config.OpenOptionsPanel()
assert(openedCategoryID == "arbitrage-category", "opens the registered addon settings category")
assert(ns.Config.Get("showTooltips") == true, "gets config values")

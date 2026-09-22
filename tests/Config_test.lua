local registeredSettings = {}
local checkboxes = {}
local registeredCategory
local openedCategoryID

Settings = {
  VarType = {
    Boolean = "boolean",
  },
  RegisterVerticalLayoutCategory = function(name)
    return {
      name = name,
      GetID = function()
        return "arbitrage-category"
      end,
    }
  end,
  RegisterAddOnSetting = function(category, variable, key, config, variableType, label, default)
    assert(category.name == "Arbitrage", "registers settings in the addon category")
    assert(variableType == "boolean", "registers Boolean settings")
    assert(default == true, "registers the configured default")
    local setting = {
      key = key,
      label = label,
      variable = variable,
      SetValue = function(self, value)
        config[self.key] = value
      end,
    }
    registeredSettings[#registeredSettings + 1] = setting
    return setting
  end,
  CreateCheckbox = function(category, setting)
    assert(category.name == "Arbitrage", "creates checkboxes in the addon category")
    checkboxes[#checkboxes + 1] = setting
  end,
  RegisterAddOnCategory = function(category)
    registeredCategory = category
  end,
  OpenToCategory = function(categoryID)
    openedCategoryID = categoryID
  end,
}

ARBITRAGE_CONFIG = "invalid"

local ns = {}
assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
ns.Config.Init()

assert(type(ARBITRAGE_CONFIG) == "table", "resets an invalid persisted root")

ARBITRAGE_CONFIG = { showTooltips = "invalid", useAuctionatorScans = true }
ns.Config.Init()

assert(ARBITRAGE_CONFIG.showTooltips == true, "resets invalid persisted values")
assert(ARBITRAGE_CONFIG.showCraftingCost == true, "adds missing crafting cost default")
assert(ARBITRAGE_CONFIG.showMinimumCraftCost == true, "adds missing defaults")
assert(ARBITRAGE_CONFIG.useAuctionatorScans == nil, "removes the obsolete Auctionator setting")

ns.Config.RegisterOptionsPanel()
assert(registeredCategory and registeredCategory.name == "Arbitrage", "registers a vertical addon category")
assert(#registeredSettings == 3 and #checkboxes == 3, "registers the three supported settings")
assert(registeredSettings[1].variable == "Arbitrage_showTooltips", "uses an addon-prefixed setting variable")

ns.Config.OpenOptionsPanel()
assert(openedCategoryID == "arbitrage-category", "opens the registered addon settings category")
assert(ns.Config.Get("showTooltips") == true, "gets config values")

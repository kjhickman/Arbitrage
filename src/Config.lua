local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showTooltips boolean
---@field showCraftingCost boolean
---@field showMinimumCraftCost boolean

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showTooltips = true,
  showCraftingCost = true,
  showMinimumCraftCost = true,
}

local category
local settings = {}

local OPTIONS = {
  { "showTooltips", "Show market and crafting values in item tooltips" },
  { "showCraftingCost", "Show crafting cost in item tooltips" },
  { "showMinimumCraftCost", "Show minimum craft cost in item tooltips" },
}

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  for key, value in pairs(defaults) do
    if type(ARBITRAGE_CONFIG[key]) ~= type(value) then
      ARBITRAGE_CONFIG[key] = value
    end
  end
  ARBITRAGE_CONFIG.useAuctionatorScans = nil

  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean
function ns.Config.Get(key)
  return config[key]
end

function ns.Config.ToggleTooltips()
  local enabled = not ns.Config.Get("showTooltips")
  if settings.showTooltips then
    settings.showTooltips:SetValue(enabled)
  else
    config.showTooltips = enabled
  end
  return enabled
end

function ns.Config.RegisterOptionsPanel()
  if category then
    return
  end

  category = Settings.RegisterVerticalLayoutCategory("Arbitrage")
  for _, option in ipairs(OPTIONS) do
    local key = option[1]
    local label = option[2]
    local setting = Settings.RegisterAddOnSetting(
      category,
      "Arbitrage_" .. key,
      key,
      config,
      Settings.VarType.Boolean,
      label,
      defaults[key]
    )
    Settings.CreateCheckbox(category, setting)
    settings[key] = setting
  end
  Settings.RegisterAddOnCategory(category)
end

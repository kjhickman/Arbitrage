local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showMarketValue boolean
---@field showCraftingCost boolean
---@field showMinimumCraftCost boolean
---@field showVendorProfit boolean
---@field showMinimumVendorProfit boolean
---@field tooltipDetails "compact"|"shift"|"always"
---@field showCraftingWindowProfits boolean
---@field craftingWindowMinimumProfit number copper; zero shows all known profits, including losses
---@field includeBestCaseOnly boolean
---@field showUncertainOpportunities boolean
---@field minimumProfit number copper; Auction House threshold; zero lists every known craft

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showMarketValue = true,
  showCraftingCost = true,
  showMinimumCraftCost = true,
  showVendorProfit = true,
  showMinimumVendorProfit = true,
  tooltipDetails = "shift",
  showCraftingWindowProfits = true,
  craftingWindowMinimumProfit = 1,
  includeBestCaseOnly = true,
  showUncertainOpportunities = true,
  minimumProfit = 1,
}

local optionsCategory

local DETAIL_MODES = {
  compact = true,
  shift = true,
  always = true,
}

-- Copper, on a 1-2-5 scale from two silver to a hundred gold, below which zero lists every
-- craft and one asks only that it turns a profit. Presets rather than a slider because a linear
-- slider cannot offer silver-sized thresholds and a useful ceiling at once.
ns.Config.MINIMUM_PROFIT_CHOICES =
  { 0, 1, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000 }
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }

local MINIMUM_PROFIT_VALUES = {}
for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
  MINIMUM_PROFIT_VALUES[copper] = true
end

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  -- Vendor profits previously followed the corresponding crafting-cost setting.
  if ARBITRAGE_CONFIG.showVendorProfit == nil then
    ARBITRAGE_CONFIG.showVendorProfit = ARBITRAGE_CONFIG.showCraftingCost
  end
  if ARBITRAGE_CONFIG.showMinimumVendorProfit == nil then
    ARBITRAGE_CONFIG.showMinimumVendorProfit = ARBITRAGE_CONFIG.showMinimumCraftCost
  end
  -- Both windows used the same minimum-profit threshold before they were split.
  if ARBITRAGE_CONFIG.craftingWindowMinimumProfit == nil then
    ARBITRAGE_CONFIG.craftingWindowMinimumProfit = ARBITRAGE_CONFIG.minimumProfit
  end

  for key, value in pairs(defaults) do
    if
      type(ARBITRAGE_CONFIG[key]) ~= type(value)
      or (key == "tooltipDetails" and not DETAIL_MODES[ARBITRAGE_CONFIG[key]])
      or (
        (key == "minimumProfit" or key == "craftingWindowMinimumProfit")
        and not MINIMUM_PROFIT_VALUES[ARBITRAGE_CONFIG[key]]
      )
    then
      ARBITRAGE_CONFIG[key] = value
    end
  end
  if ARBITRAGE_CONFIG.showTooltips == false then
    ARBITRAGE_CONFIG.showMarketValue = false
    ARBITRAGE_CONFIG.showCraftingCost = false
    ARBITRAGE_CONFIG.showMinimumCraftCost = false
    ARBITRAGE_CONFIG.showVendorProfit = false
    ARBITRAGE_CONFIG.showMinimumVendorProfit = false
  end
  ARBITRAGE_CONFIG.showTooltips = nil
  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean|string|number
function ns.Config.Get(key)
  return config[key]
end

---@param key "minimumProfit"|"includeBestCaseOnly"|"showUncertainOpportunities"
---@param value boolean|number
function ns.Config.Set(key, value)
  config[key] = value
end

local function RegisterSetting(category, key, variableType, label)
  return Settings.RegisterAddOnSetting(category, "Arbitrage_" .. key, key, config, variableType, label, defaults[key])
end

local function CreateMinimumProfitOptions()
  local container = Settings.CreateControlTextContainer()
  for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
    container:Add(copper, MINIMUM_PROFIT_LABELS[copper] or C_CurrencyInfo.GetCoinTextureString(copper, 10))
  end
  return container:GetData()
end

local function CreateDetailsOptions()
  local container = Settings.CreateControlTextContainer()
  container:Add("compact", "Compact")
  container:Add("shift", "Hold Shift")
  container:Add("always", "Always")
  return container:GetData()
end

function ns.Config.RegisterOptionsPanel()
  local category, layout = Settings.RegisterVerticalLayoutCategory("Arbitrage")
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Item Tooltips"))

  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMarketValue", Settings.VarType.Boolean, "Show Market Value"),
    "Shows the rolling Auction House Market Value for auctionable items."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showCraftingCost", Settings.VarType.Boolean, "Show Crafting Cost"),
    "Shows the cheapest estimated crafting route using rolling prices, vendors, and intermediate crafts."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMinimumCraftCost", Settings.VarType.Boolean, "Show Best-case Crafting Cost"),
    "Shows the same crafting calculation using the cheapest per-unit buyouts from the latest full scan."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showVendorProfit", Settings.VarType.Boolean, "Show Vendor Profit"),
    "Shows vendor sell value minus the rolling crafting cost, independently of the Crafting Cost line."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMinimumVendorProfit", Settings.VarType.Boolean, "Show Best-case Vendor Profit"),
    "Shows vendor sell value minus the latest scan's best-case crafting cost, independently of the Best-case Crafting Cost line."
  )
  Settings.CreateDropdown(
    category,
    RegisterSetting(category, "tooltipDetails", Settings.VarType.String, "Pricing details"),
    CreateDetailsOptions,
    "Controls when scan confidence and the materials to buy are shown."
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Crafting Window"))
  local showCraftingWindowProfits =
    RegisterSetting(category, "showCraftingWindowProfits", Settings.VarType.Boolean, "Show crafting window profits")
  showCraftingWindowProfits:SetValueChangedCallback(ns.CraftingWindow.Refresh)
  Settings.CreateCheckbox(
    category,
    showCraftingWindowProfits,
    "Shows estimated profit per craft and cost tooltips beside learned recipes in the crafting window."
  )
  local minimumProfit =
    RegisterSetting(category, "craftingWindowMinimumProfit", Settings.VarType.Number, "Minimum profit")
  minimumProfit:SetValueChangedCallback(ns.CraftingWindow.Refresh)
  Settings.CreateDropdown(
    category,
    minimumProfit,
    CreateMinimumProfitOptions,
    "Hides crafting-window profits below this per-craft amount, using the displayed estimated profit rather than the best case. Independent of Auction House filters; Show all crafts includes losses."
  )

  Settings.RegisterAddOnCategory(category)
  optionsCategory = category
end

function ns.Config.OpenOptionsPanel()
  Settings.OpenToCategory(optionsCategory:GetID())
end

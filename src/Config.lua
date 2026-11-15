local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showTooltips boolean
---@field showMarketValue boolean
---@field showCraftingCost boolean
---@field showMinimumCraftCost boolean
---@field tooltipDetails "compact"|"shift"|"always"
---@field includeBestCaseOnly boolean
---@field showUncertainOpportunities boolean
---@field onlyProfitableCrafts boolean
---@field minimumProfit number copper

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showTooltips = true,
  showMarketValue = true,
  showCraftingCost = true,
  showMinimumCraftCost = true,
  tooltipDetails = "shift",
  includeBestCaseOnly = true,
  showUncertainOpportunities = true,
  onlyProfitableCrafts = true,
  minimumProfit = 0,
}

local optionsCategory

local DETAIL_MODES = {
  compact = true,
  shift = true,
  always = true,
}

-- Copper, on a 1-2-5 scale from two silver to a hundred gold. Presets rather than a slider
-- because a linear slider cannot offer silver-sized thresholds and a useful ceiling at once.
local MINIMUM_PROFIT_CHOICES = { 0, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000 }

local MINIMUM_PROFIT_VALUES = {}
for _, copper in ipairs(MINIMUM_PROFIT_CHOICES) do
  MINIMUM_PROFIT_VALUES[copper] = true
end

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  for key, value in pairs(defaults) do
    if
      type(ARBITRAGE_CONFIG[key]) ~= type(value)
      or (key == "tooltipDetails" and not DETAIL_MODES[ARBITRAGE_CONFIG[key]])
      or (key == "minimumProfit" and not MINIMUM_PROFIT_VALUES[ARBITRAGE_CONFIG[key]])
    then
      ARBITRAGE_CONFIG[key] = value
    end
  end
  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean|string|number
function ns.Config.Get(key)
  return config[key]
end

local function RegisterSetting(category, key, variableType, label)
  return Settings.RegisterAddOnSetting(category, "Arbitrage_" .. key, key, config, variableType, label, defaults[key])
end

-- Both filter settings hide crafts in the profession window as well as the panel.
local function RefreshOpportunities()
  ns.AuctionHouse.Refresh()
  ns.CraftingWindow.Refresh()
end

local function CreateMinimumProfitOptions()
  local container = Settings.CreateControlTextContainer()
  for _, copper in ipairs(MINIMUM_PROFIT_CHOICES) do
    container:Add(copper, copper == 0 and "Any profit" or C_CurrencyInfo.GetCoinTextureString(copper, 10))
  end
  return container:GetData()
end

local function CreateProfitFilter(category)
  local onlyProfitable =
    RegisterSetting(category, "onlyProfitableCrafts", Settings.VarType.Boolean, "Only show profitable crafts")
  onlyProfitable:SetValueChangedCallback(RefreshOpportunities)
  Settings.CreateCheckbox(
    category,
    onlyProfitable,
    "Hides crafts that do not clear the minimum profit. Turn this off to list every known craft."
  )

  local minimumProfit = RegisterSetting(category, "minimumProfit", Settings.VarType.Number, "Minimum profit")
  minimumProfit:SetValueChangedCallback(RefreshOpportunities)
  Settings.CreateDropdown(
    category,
    minimumProfit,
    CreateMinimumProfitOptions,
    "Hides crafts earning less than this per craft."
  )
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
    RegisterSetting(category, "showTooltips", Settings.VarType.Boolean, "Enable Arbitrage item tooltips"),
    "Adds Arbitrage pricing information to item tooltips."
  )
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
  Settings.CreateDropdown(
    category,
    RegisterSetting(category, "tooltipDetails", Settings.VarType.String, "Pricing details"),
    CreateDetailsOptions,
    "Controls when scan confidence and the materials to buy are shown."
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Opportunity List"))
  CreateProfitFilter(category)
  local includeBestCaseOnly =
    RegisterSetting(category, "includeBestCaseOnly", Settings.VarType.Boolean, "Include best-case-only opportunities")
  includeBestCaseOnly:SetValueChangedCallback(RefreshOpportunities)
  Settings.CreateCheckbox(
    category,
    includeBestCaseOnly,
    "Includes crafts that are profitable only when materials can be bought at Best Cost."
  )
  local showUncertain =
    RegisterSetting(category, "showUncertainOpportunities", Settings.VarType.Boolean, "Show uncertain opportunities")
  showUncertain:SetValueChangedCallback(ns.AuctionHouse.Refresh)
  Settings.CreateCheckbox(
    category,
    showUncertain,
    "Includes opportunities based on limited, stale, volatile, or fallback market data."
  )

  Settings.RegisterAddOnCategory(category)
  optionsCategory = category
end

function ns.Config.OpenOptionsPanel()
  Settings.OpenToCategory(optionsCategory:GetID())
end

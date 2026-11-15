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

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 100 * COPPER_PER_SILVER
-- Ten silver a step keeps small thresholds reachable; the ceiling is what holds the stepper
-- count close to Blizzard's own densest slider.
local MINIMUM_PROFIT_STEP = 10 * COPPER_PER_SILVER
local MINIMUM_PROFIT_CEILING = 50 * COPPER_PER_GOLD

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  for key, value in pairs(defaults) do
    if
      type(ARBITRAGE_CONFIG[key]) ~= type(value)
      or (key == "tooltipDetails" and not DETAIL_MODES[ARBITRAGE_CONFIG[key]])
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

---@param copper number
---@return string
local function FormatMoney(copper)
  return C_CurrencyInfo.GetCoinTextureString(copper, 10)
end

-- Blizzard's paired control greys out the slider while the checkbox is off, so the threshold
-- never looks like it applies when the list is unfiltered.
local function CreateProfitFilter(category, layout)
  local onlyProfitable =
    RegisterSetting(category, "onlyProfitableCrafts", Settings.VarType.Boolean, "Only show profitable crafts")
  onlyProfitable:SetValueChangedCallback(RefreshOpportunities)

  local minimumProfit = RegisterSetting(category, "minimumProfit", Settings.VarType.Number, "Minimum profit")
  minimumProfit:SetValueChangedCallback(RefreshOpportunities)

  local sliderOptions = Settings.CreateSliderOptions(0, MINIMUM_PROFIT_CEILING, MINIMUM_PROFIT_STEP)
  sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatMoney)

  layout:AddInitializer(
    CreateSettingsCheckboxSliderInitializer(
      onlyProfitable,
      "Only show profitable crafts",
      "Hides crafts that do not clear the minimum profit. Turn this off to list every known craft.",
      minimumProfit,
      sliderOptions,
      "Minimum profit",
      "Hides crafts earning less than this per craft."
    )
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
  CreateProfitFilter(category, layout)
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

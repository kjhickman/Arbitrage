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
}

local optionsCategory

local DETAIL_MODES = {
  compact = true,
  shift = true,
  always = true,
}

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
---@return boolean|string
function ns.Config.Get(key)
  return config[key]
end

local function RegisterSetting(category, key, variableType, label)
  return Settings.RegisterAddOnSetting(category, "Arbitrage_" .. key, key, config, variableType, label, defaults[key])
end

local function CreateDetailsOptions()
  local container = Settings.CreateControlTextContainer()
  container:Add("compact", "Compact")
  container:Add("shift", "Hold Shift")
  container:Add("always", "Always")
  return container:GetData()
end

local function AreTooltipsEnabled()
  return config.showTooltips
end

function ns.Config.RegisterOptionsPanel()
  local category, layout = Settings.RegisterVerticalLayoutCategory("Arbitrage")
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Item Tooltips"))

  local tooltips = Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showTooltips", Settings.VarType.Boolean, "Enable Arbitrage item tooltips"),
    "Adds Arbitrage pricing information to item tooltips."
  )
  local marketValue = Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMarketValue", Settings.VarType.Boolean, "Show Market Value"),
    "Shows the rolling Auction House Market Value for auctionable items."
  )
  local craftingCost = Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showCraftingCost", Settings.VarType.Boolean, "Show Crafting Cost"),
    "Shows the cheapest estimated crafting route using rolling prices, vendors, and intermediate crafts."
  )
  local bestCost = Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMinimumCraftCost", Settings.VarType.Boolean, "Show Best-case Crafting Cost"),
    "Shows the same crafting calculation using the cheapest per-unit buyouts from the latest full scan."
  )
  local details = Settings.CreateDropdown(
    category,
    RegisterSetting(category, "tooltipDetails", Settings.VarType.String, "Pricing details"),
    CreateDetailsOptions,
    "Controls when scan confidence and the materials to buy are shown."
  )

  marketValue:SetParentInitializer(tooltips, AreTooltipsEnabled)
  craftingCost:SetParentInitializer(tooltips, AreTooltipsEnabled)
  bestCost:SetParentInitializer(tooltips, AreTooltipsEnabled)
  details:SetParentInitializer(tooltips, AreTooltipsEnabled)

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Opportunity List"))
  local includeBestCaseOnly =
    RegisterSetting(category, "includeBestCaseOnly", Settings.VarType.Boolean, "Include best-case-only opportunities")
  includeBestCaseOnly:SetValueChangedCallback(ns.AuctionHouse.Refresh)
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

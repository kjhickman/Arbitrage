local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showTooltips boolean
---@field showMinimumCraftCost boolean

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showTooltips = true,
  showMinimumCraftCost = true,
}

local panel
local checkbox
local checkboxLabel
local minimumCraftCheckbox
local category

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  for key, value in pairs(defaults) do
    if type(ARBITRAGE_CONFIG[key]) ~= type(value) then
      ARBITRAGE_CONFIG[key] = value
    end
  end

  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean
function ns.Config.Get(key)
  return config[key]
end

---@param key keyof ArbitrageConfig
---@param value boolean
function ns.Config.Set(key, value)
  config[key] = value
end

function ns.Config.ToggleTooltips()
  local enabled = not ns.Config.Get("showTooltips")
  ns.Config.Set("showTooltips", enabled)

  if checkbox then
    checkbox:SetChecked(enabled)
  end

  return enabled
end

function ns.Config.RegisterOptionsPanel()
  if panel then
    return
  end

  panel = CreateFrame("Frame", "ArbitrageOptionsPanel")
  panel.name = "Arbitrage"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Arbitrage")

  checkbox = CreateFrame("CheckButton", "ArbitrageTooltipCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
  checkbox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
  checkbox:SetChecked(ns.Config.Get("showTooltips"))
  checkbox:SetScript("OnClick", function(self)
    ns.Config.Set("showTooltips", self:GetChecked())
  end)

  checkboxLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  checkboxLabel:SetPoint("LEFT", checkbox, "RIGHT", 0, 1)
  checkboxLabel:SetText("Show market and crafting values in item tooltips")

  minimumCraftCheckbox = CreateFrame("CheckButton", "ArbitrageMinimumCraftCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
  minimumCraftCheckbox:SetPoint("TOPLEFT", checkbox, "BOTTOMLEFT", 0, -8)
  minimumCraftCheckbox:SetChecked(ns.Config.Get("showMinimumCraftCost"))
  minimumCraftCheckbox:SetScript("OnClick", function(self)
    ns.Config.Set("showMinimumCraftCost", self:GetChecked())
  end)

  local minimumCraftLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  minimumCraftLabel:SetPoint("LEFT", minimumCraftCheckbox, "RIGHT", 0, 1)
  minimumCraftLabel:SetText("Show minimum craft cost in item tooltips")

  panel:SetScript("OnShow", function()
    checkbox:SetChecked(ns.Config.Get("showTooltips"))
    minimumCraftCheckbox:SetChecked(ns.Config.Get("showMinimumCraftCost"))
  end)

  category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
end

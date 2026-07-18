local _, ns = ...

ns.Config = {}

local config

local defaults = {
  showTooltips = true,
}

local panel
local checkbox
local checkboxLabel
local category

function ns.Config.Init()
  ARBITRAGE_CONFIG = ARBITRAGE_CONFIG or {}

  for key, value in pairs(defaults) do
    if ARBITRAGE_CONFIG[key] == nil then
      ARBITRAGE_CONFIG[key] = value
    end
  end

  config = ARBITRAGE_CONFIG
end

function ns.Config.Get(key)
  return config[key]
end

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
  checkboxLabel:SetText("Show market value in item tooltips")

  panel:SetScript("OnShow", function()
    checkbox:SetChecked(ns.Config.Get("showTooltips"))
  end)

  category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
end

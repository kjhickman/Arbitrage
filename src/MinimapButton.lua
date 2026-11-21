local addonName, ns = ...

ns.MinimapButton = {}

local ICON_TEXTURE = "Interface\\AddOns\\Arbitrage\\media\\icon"

local LibDBIcon = LibStub("LibDBIcon-1.0")

local function OnClick(_, button)
  if button == "RightButton" then
    ns.Config.OpenOptionsPanel()
  else
    ns.Window.Toggle()
  end
end

local function OnTooltipShow(tooltip)
  tooltip:AddLine(addonName, 1, 1, 1)
  tooltip:AddLine("Left-click: Toggle the Arbitrage window", NORMAL_FONT_COLOR:GetRGB())
  tooltip:AddLine("Right-click: Open settings", NORMAL_FONT_COLOR:GetRGB())
end

-- LibDBIcon shows or hides the button from its saved table's hide field, at login and on Refresh.
local function SaveVisibility()
  local saved = ns.Config.Get("minimapButton")
  ---@cast saved table
  saved.hide = not ns.Config.Get("showMinimapButton")
  return saved
end

function ns.MinimapButton.Register()
  local launcher = LibStub("LibDataBroker-1.1"):NewDataObject(addonName, {
    type = "launcher",
    icon = ICON_TEXTURE,
    OnClick = OnClick,
    OnTooltipShow = OnTooltipShow,
  })
  LibDBIcon:Register(addonName, launcher, SaveVisibility())
end

function ns.MinimapButton.Refresh()
  SaveVisibility()
  LibDBIcon:Refresh(addonName)
end

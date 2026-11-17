local addonName, ns = ...

ns.Window = {}

---@class ArbitrageWindowFrame : Frame, PortraitFrameMixin
---@field CloseButton Button

local ICON_TEXTURE = "Interface\\AddOns\\Arbitrage\\media\\icon"
local WINDOW_WIDTH = 800
local WINDOW_HEIGHT = 512

---@type ArbitrageWindowFrame?
local window

function ns.Window.Toggle()
  if not window then
    local windowName = addonName .. "Window"
    local frame = CreateFrame("Frame", windowName, UIParent, "PortraitFrameTemplate")
    ---@cast frame ArbitrageWindowFrame
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetTitle(addonName)
    frame:SetPortraitToAsset(ICON_TEXTURE)
    frame.CloseButton:SetScript("OnClick", function()
      frame:Hide()
    end)
    frame:Hide()
    UISpecialFrames[#UISpecialFrames + 1] = windowName

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -69)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 6)
    content:Hide()
    ns.OpportunityPanel.Create(content, frame)

    frame:SetScript("OnShow", function()
      content:Show()
    end)
    frame:SetScript("OnHide", function()
      content:Hide()
    end)

    window = frame
  end

  if window:IsShown() then
    window:Hide()
  else
    window:Show()
  end
end

function Arbitrage_OnAddonCompartmentClick()
  ns.Window.Toggle()
end

local addonName, ns = ...

ns.Window = {}

---@class ArbitrageWindowFrame : Frame, PortraitFrameMixin
---@field CloseButton Button
---@field Tabs Button[]

local ICON_TEXTURE = "Interface\\AddOns\\Arbitrage\\media\\icon"
local WINDOW_WIDTH = 800
local WINDOW_HEIGHT = 512
local TABS = {
  { label = "Opportunities", create = "OpportunityPanel" },
  { label = "Database", create = "DatabasePanel" },
  { label = "Shopping List", create = "ShoppingPanel" },
}

---@type ArbitrageWindowFrame?
local window
---@type Frame[]
local contents = {}
local selectedTab = 1

local function ShowSelectedContent()
  for index, content in ipairs(contents) do
    content:SetShown(index == selectedTab)
  end
end

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

    for index, tabInfo in ipairs(TABS) do
      local content = CreateFrame("Frame", nil, frame)
      content:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -69)
      content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 6)
      content:Hide()
      ns[tabInfo.create].Create(content, frame)
      contents[index] = content

      -- PanelTabButtonTemplate adds each tab to frame.Tabs; the name is the fallback lookup.
      local tab = CreateFrame("Button", windowName .. "Tab" .. index, frame, "PanelTabButtonTemplate")
      tab:SetID(index)
      tab:SetText(tabInfo.label)
      tab:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        selectedTab = self:GetID()
        PanelTemplates_SetTab(frame, selectedTab)
        ShowSelectedContent()
      end)
      if index == 1 then
        tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 5, 2)
      end
    end
    PanelTemplates_SetNumTabs(frame, #TABS)
    PanelTemplates_SetTab(frame, selectedTab)

    frame:SetScript("OnShow", ShowSelectedContent)
    frame:SetScript("OnHide", function()
      for _, content in ipairs(contents) do
        content:Hide()
      end
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

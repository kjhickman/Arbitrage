local _, ns = ...

ns.PriceChart = {}

---@class ArbitragePriceChart
---@field frame Frame
---@field SetData fun(days: ArbitrageDailyValue[], marketValue: number?)

local DAY = 24 * 60 * 60
-- Market Value's window: the day fourteen days ago through today.
local WINDOW_DAYS = 14
local WIDTH = 262
local AXIS_WIDTH = 40
local PLOT_WIDTH = WIDTH - AXIS_WIDTH
local PLOT_HEIGHT = 88
-- Room below the plot for the day labels and the legend's two rows.
local HEIGHT = PLOT_HEIGHT + 48
local LEGEND_ROWS = { -26, -40 }
-- Keeps the markers on the first and last day and at the lowest and highest price inside the plot.
local INSET = 6
local TARGET_INTERVALS = 4
local DASH_LENGTH = 4
local DASH_GAP = 3
local DAILY_COLOR = { 1, 0.82, 0 }
local MARKET_VALUE_COLOR = { 0.85, 0.85, 0.85 }
local BUYOUT_COLOR = { 0.35, 0.75, 1 }
-- Units listed draw as faint bars on a scale of their own, no taller than this share of the plot,
-- so they stay behind the prices.
local UNITS_COLOR = { 1, 1, 1, 0.14 }
local BAR_WIDTH = 7
local BAR_SHARE = 0.35
local MARKER_SIZE = 5
local EMPTY_MESSAGE = "No scans in the last 14 days."
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:10:10:1:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:10:10:1:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:10:10:1:0|t"
local FormatQuantity = ns.ItemTable.FormatQuantity

-- Steps of 1, 2, or 5 times a power of ten, so the gridlines fall on round prices.
---@param rough number
---@return number
local function RoundStep(rough)
  if rough <= 1 then
    return 1
  end
  local magnitude = 10 ^ math.floor(math.log10(rough))
  local fraction = rough / magnitude
  if fraction <= 1 then
    return magnitude
  elseif fraction <= 2 then
    return 2 * magnitude
  elseif fraction <= 5 then
    return 5 * magnitude
  end
  return 10 * magnitude
end

-- The price range the plot spans, widened to whole steps. A single price sits mid-plot.
---@param low number
---@param high number
---@return number axisLow, number axisHigh, number step
local function GetAxis(low, high)
  if high <= low then
    local margin = math.max(1, math.floor(low * 0.1))
    low, high = low - margin, high + margin
  end
  local step = RoundStep((high - low) / TARGET_INTERVALS)
  return math.max(0, math.floor(low / step) * step), math.ceil(high / step) * step, step
end

-- Gridline prices in their largest coin, such as 2.5g or 75s, since they fall on round steps.
---@param copper number
---@return string
local function FormatAxisMoney(copper)
  if copper >= 10000 then
    return FormatQuantity(copper / 10000) .. GOLD_ICON
  elseif copper >= 100 then
    return FormatQuantity(copper / 100) .. SILVER_ICON
  end
  return FormatQuantity(copper) .. COPPER_ICON
end

---@param count number
---@param noun string
---@return string
local function Count(count, noun)
  return count .. " " .. noun .. (count == 1 and "" or "s")
end

-- Days are UTC, like the scans they group, so they're named in UTC too.
---@param day number
---@param today number
---@return string
local function FormatDay(day, today)
  local timestamp = day * DAY
  local name = date("!%b ", timestamp) .. tonumber(date("!%d", timestamp))
  if day == today then
    return name .. " (today)"
  end
  return name .. " (" .. Count(today - day, "day") .. " ago)"
end

-- Pools hide what they create and what they take back.
---@param region Region
local function HideRegion(_, region)
  region:Hide()
end

---@param parent Frame
---@return ArbitragePriceChart
function ns.PriceChart.Create(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(WIDTH, HEIGHT)

  local plot = CreateFrame("Frame", nil, frame)
  plot:SetPoint("TOPLEFT", frame, "TOPLEFT", AXIS_WIDTH, 0)
  plot:SetSize(PLOT_WIDTH, PLOT_HEIGHT)
  plot:EnableMouse(true)

  local background = plot:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0, 0, 0, 0.3)

  local emptyText = plot:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  emptyText:SetPoint("CENTER")
  emptyText:SetText(EMPTY_MESSAGE)

  for _, label in ipairs({
    { "TOPLEFT", "BOTTOMLEFT", Count(WINDOW_DAYS, "day") .. " ago" },
    { "TOP", "BOTTOM", Count(WINDOW_DAYS / 2, "day") .. " ago" },
    { "TOPRIGHT", "BOTTOMRIGHT", "Today" },
  }) do
    local dayLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    dayLabel:SetPoint(label[1], plot, label[2], 0, -4)
    dayLabel:SetText(label[3])
  end

  -- The legend draws a swatch the way each series is drawn, then names it.
  ---@param anchor (Region|number) the previous entry's name, or the row's offset below the plot
  ---@param text string
  ---@param drawSwatch fun(swatch: Frame)
  ---@return FontString
  local function AddLegendEntry(anchor, text, drawSwatch)
    local swatch = CreateFrame("Frame", nil, frame)
    swatch:SetSize(10, 10)
    if type(anchor) == "number" then
      swatch:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, anchor)
    else
      swatch:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
    end
    drawSwatch(swatch)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
    label:SetText(text)
    return label
  end

  ---@param color number[]
  ---@return fun(swatch: Frame)
  local function MarkerSwatch(color)
    return function(swatch)
      local outline = swatch:CreateTexture(nil, "ARTWORK")
      outline:SetSize(MARKER_SIZE + 2, MARKER_SIZE + 2)
      outline:SetPoint("CENTER")
      outline:SetColorTexture(0, 0, 0, 0.85)
      local fill = swatch:CreateTexture(nil, "OVERLAY")
      fill:SetSize(MARKER_SIZE, MARKER_SIZE)
      fill:SetPoint("CENTER")
      fill:SetColorTexture(color[1], color[2], color[3], 1)
    end
  end

  local dailyLabel = AddLegendEntry(LEGEND_ROWS[1], "Daily value", MarkerSwatch(DAILY_COLOR))
  local buyoutLabel = AddLegendEntry(LEGEND_ROWS[2], "Buyout", MarkerSwatch(BUYOUT_COLOR))
  AddLegendEntry(buyoutLabel, "Units listed", function(swatch)
    local bar = swatch:CreateTexture(nil, "ARTWORK")
    bar:SetSize(BAR_WIDTH, 10)
    bar:SetPoint("CENTER")
    bar:SetColorTexture(UNITS_COLOR[1], UNITS_COLOR[2], UNITS_COLOR[3], UNITS_COLOR[4] * 2)
  end)
  AddLegendEntry(dailyLabel, "Market Value", function(swatch)
    for _, x in ipairs({ 0, 6 }) do
      local dash = swatch:CreateTexture(nil, "ARTWORK")
      dash:SetSize(DASH_LENGTH, 1)
      dash:SetPoint("LEFT", swatch, "LEFT", x, 0)
      dash:SetColorTexture(MARKET_VALUE_COLOR[1], MARKET_VALUE_COLOR[2], MARKET_VALUE_COLOR[3], 1)
    end
  end)

  local gridlines = CreateObjectPool(function()
    local line = plot:CreateLine(nil, "BORDER")
    line:SetThickness(1)
    line:SetColorTexture(1, 1, 1, 0.1)
    return line
  end, HideRegion)
  local priceLabels = CreateObjectPool(function()
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    label:SetJustifyH("RIGHT")
    return label
  end, HideRegion)
  local seriesLines = CreateObjectPool(function()
    return plot:CreateLine(nil, "ARTWORK")
  end, HideRegion)
  -- Each marker is a dark square under a colored one, so it stands out from the lines.
  local markerOutlines = CreateObjectPool(function()
    return plot:CreateTexture(nil, "OVERLAY")
  end, HideRegion)
  local markers = CreateObjectPool(function()
    return plot:CreateTexture(nil, "OVERLAY", nil, 1)
  end, HideRegion)
  -- Above the plot's background, below its gridlines and prices.
  local bars = CreateObjectPool(function()
    return plot:CreateTexture(nil, "BACKGROUND", nil, 1)
  end, HideRegion)

  local hoverLine = plot:CreateLine(nil, "BORDER")
  hoverLine:SetThickness(1)
  hoverLine:SetColorTexture(1, 1, 1, 0.35)
  hoverLine:Hide()

  local today = 0
  local axisLow, axisHigh = 0, 1
  -- The plotted days by day number, for the hover tooltip.
  ---@type table<number, ArbitrageDailyValue>
  local shownDays = {}
  ---@type number?
  local hoveredDay

  ---@param day number
  ---@return number
  local function X(day)
    return INSET + (day - (today - WINDOW_DAYS)) / WINDOW_DAYS * (PLOT_WIDTH - 2 * INSET)
  end

  ---@param value number
  ---@return number
  local function Y(value)
    return INSET + (value - axisLow) / (axisHigh - axisLow) * (PLOT_HEIGHT - 2 * INSET)
  end

  ---@param x1 number
  ---@param y1 number
  ---@param x2 number
  ---@param y2 number
  ---@param color number[]
  ---@param thickness number
  local function DrawLine(x1, y1, x2, y2, color, thickness)
    local line = seriesLines:Acquire()
    line:Show()
    line:SetThickness(thickness)
    line:SetColorTexture(color[1], color[2], color[3], 1)
    line:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
    line:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
  end

  ---@param day number
  ---@param value number
  ---@param color number[]
  local function DrawMarker(day, value, color)
    local x, y = X(day), Y(value)
    local outline = markerOutlines:Acquire()
    outline:Show()
    outline:SetSize(MARKER_SIZE + 2, MARKER_SIZE + 2)
    outline:SetColorTexture(0, 0, 0, 0.85)
    outline:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
    local marker = markers:Acquire()
    marker:Show()
    marker:SetSize(MARKER_SIZE, MARKER_SIZE)
    marker:SetColorTexture(color[1], color[2], color[3], 1)
    marker:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
  end

  -- Joins one series' days, then marks each, so the markers sit over the lines.
  ---@param days ArbitrageDailyValue[]
  ---@param field "value"|"buyout"
  ---@param color number[]
  local function DrawSeries(days, field, color)
    local previous
    for _, point in ipairs(days) do
      local value = point[field]
      if value then
        if previous then
          DrawLine(X(previous.day), Y(previous[field]), X(point.day), Y(value), color, 2)
        end
        previous = point
      end
    end
    for _, point in ipairs(days) do
      if point[field] then
        DrawMarker(point.day, point[field], color)
      end
    end
  end

  local function HideHover()
    hoveredDay = nil
    hoverLine:Hide()
    if GameTooltip:IsOwned(plot) then
      GameTooltip:Hide()
    end
  end

  ---@param day number
  local function ShowHover(day)
    hoveredDay = day
    hoverLine:SetStartPoint("BOTTOMLEFT", plot, X(day), 0)
    hoverLine:SetEndPoint("BOTTOMLEFT", plot, X(day), PLOT_HEIGHT)
    hoverLine:Show()

    local shown = shownDays[day]
    GameTooltip:SetOwner(plot, "ANCHOR_TOP")
    GameTooltip:AddLine(FormatDay(day, today), 1, 1, 1)
    local function AddValue(label, value)
      GameTooltip:AddDoubleLine(label, value, nil, nil, nil, 1, 1, 1)
    end
    if shown.value then
      AddValue("Daily value (" .. Count(shown.count, "scan") .. ")", ns.ItemTable.FormatMoney(shown.value))
    end
    if shown.buyout then
      AddValue("Buyout (" .. Count(shown.buyoutCount, "scan") .. ")", ns.ItemTable.FormatMoney(shown.buyout))
    end
    if shown.quantity then
      AddValue("Units listed", ns.ItemTable.FormatCount(shown.quantity))
    end
    if shown.auctions then
      AddValue("Auctions", ns.ItemTable.FormatCount(shown.auctions))
    end
    GameTooltip:Show()
  end

  -- Follows the cursor to the nearest plotted day, redrawing the tooltip only when that changes.
  ---@param self Frame
  local function FollowCursor(self)
    local left = self:GetLeft()
    if not left then
      return
    end
    local cursorX = GetCursorPosition() / self:GetEffectiveScale()
    local cursorDay = today - WINDOW_DAYS + (cursorX - left - INSET) / (PLOT_WIDTH - 2 * INSET) * WINDOW_DAYS
    local nearest
    for day in pairs(shownDays) do
      if nearest == nil or math.abs(day - cursorDay) < math.abs(nearest - cursorDay) then
        nearest = day
      end
    end
    if nearest == nil then
      HideHover()
    elseif nearest ~= hoveredDay then
      ShowHover(nearest)
    end
  end

  plot:SetScript("OnEnter", function(self)
    self:SetScript("OnUpdate", FollowCursor)
  end)
  plot:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    HideHover()
  end)

  return {
    frame = frame,
    -- Plots each day's average price and Buyout, bars for its units listed, and a dashed line at
    -- Market Value.
    SetData = function(days, marketValue)
      HideHover()
      gridlines:ReleaseAll()
      priceLabels:ReleaseAll()
      seriesLines:ReleaseAll()
      markerOutlines:ReleaseAll()
      markers:ReleaseAll()
      bars:ReleaseAll()
      today = math.floor(time() / DAY)
      shownDays = {}

      emptyText:SetShown(#days == 0)
      if #days == 0 then
        return
      end
      local low, high = marketValue or math.huge, marketValue or -math.huge
      local mostUnits = 0
      for _, point in ipairs(days) do
        shownDays[point.day] = point
        if point.value then
          low, high = math.min(low, point.value), math.max(high, point.value)
        end
        if point.buyout then
          low, high = math.min(low, point.buyout), math.max(high, point.buyout)
        end
        mostUnits = math.max(mostUnits, point.quantity or 0)
      end

      for _, point in ipairs(days) do
        if point.quantity then
          local bar = bars:Acquire()
          bar:Show()
          bar:SetSize(BAR_WIDTH, math.max(1, point.quantity / mostUnits * PLOT_HEIGHT * BAR_SHARE))
          bar:SetColorTexture(UNITS_COLOR[1], UNITS_COLOR[2], UNITS_COLOR[3], UNITS_COLOR[4])
          bar:SetPoint("BOTTOM", plot, "BOTTOMLEFT", X(point.day), 0)
        end
      end
      if low > high then
        return
      end

      local step
      axisLow, axisHigh, step = GetAxis(low, high)
      for price = axisLow, axisHigh + step / 2, step do
        local y = Y(price)
        local gridline = gridlines:Acquire()
        gridline:Show()
        gridline:SetStartPoint("BOTTOMLEFT", plot, 0, y)
        gridline:SetEndPoint("BOTTOMLEFT", plot, PLOT_WIDTH, y)
        local label = priceLabels:Acquire()
        label:Show()
        label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -5, y)
        label:SetText(FormatAxisMoney(price))
      end

      if marketValue then
        local y = Y(marketValue)
        for x = 0, PLOT_WIDTH - 1, DASH_LENGTH + DASH_GAP do
          DrawLine(x, y, math.min(x + DASH_LENGTH, PLOT_WIDTH), y, MARKET_VALUE_COLOR, 1)
        end
      end
      DrawSeries(days, "buyout", BUYOUT_COLOR)
      -- Market Value's days go over the Buyouts they usually sit near.
      DrawSeries(days, "value", DAILY_COLOR)
    end,
  }
end

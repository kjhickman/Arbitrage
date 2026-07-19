local addonName, ns = ...

local frame = CreateFrame("Frame")
local listener = {}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function AddAuction(groups, itemLink, auctionInfo)
  local quantity = auctionInfo and auctionInfo[3]
  local buyout = auctionInfo and auctionInfo[10]

  if itemLink == nil or quantity == nil or buyout == nil or quantity <= 0 or buyout <= 0 then
    return
  end

  local unitPrice = math.ceil(buyout / quantity)

  -- ponytail: callback is synchronous on the legacy AH, revisit if targeting modern AH
  Auctionator.Utilities.DBKeyFromLink(itemLink, function(dbKeys)
    for _, dbKey in ipairs(dbKeys) do
      groups[dbKey] = groups[dbKey] or {}
      groups[dbKey][#groups[dbKey] + 1] = {
        price = unitPrice,
        quantity = quantity,
      }
    end
  end)
end

local function ProcessFullScan(rawFullScan)
  if type(rawFullScan) ~= "table" then
    Print("Full scan had no raw data")
    return
  end

  local groups = {}

  for _, entry in ipairs(rawFullScan) do
    AddAuction(groups, entry.itemLink, entry.auctionInfo)
  end

  local results = ns.MarketValue.CalculateAll(groups)
  local count = ns.Database.SaveScan(results, time())

  Print("Stored market prices for " .. count .. " items")
end

function listener:ReceiveEvent(eventName, rawFullScan)
  if eventName == Auctionator.FullScan.Events.ScanComplete then
    ProcessFullScan(rawFullScan)
  end
end

local function RegisterAuctionatorListener()
  if not (Auctionator and Auctionator.EventBus and Auctionator.FullScan and Auctionator.FullScan.Events) then
    Print("Auctionator full scan events are unavailable")
    return
  end

  Auctionator.EventBus:Register(listener, {
    Auctionator.FullScan.Events.ScanComplete,
  })
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"
  SLASH_ARBITRAGE2 = "/arbitrage"

  SlashCmdList.ARBITRAGE = function(message)
    local command, argument = strtrim(message or ""):match("^(%S*)%s*(.*)$")
    command = strlower(command or "")

    if command == "count" then
      Print("Stored items: " .. ns.Database.Count())
    elseif command == "status" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Tooltips: " .. (ns.Config.Get("showTooltips") and "enabled" or "disabled"))
      local latestScan = status.latestScan and date("%Y-%m-%d %H:%M", status.latestScan) or "unknown"
      Print("Latest scan: " .. latestScan)
      Print("Scans in last 14 days: " .. status.recentScanCount)
    elseif command == "tooltip" then
      local enabled = ns.Config.ToggleTooltips()
      Print("Tooltips: " .. (enabled and "enabled" or "disabled"))
    elseif command == "recipes" then
      local status = ns.RecipeBook.GetStatus()
      Print("Known recipes: " .. status.recipeCount .. " across " .. status.characterCount .. " characters")
    elseif command == "item" and argument and argument ~= "" then
      local result = ns.Database.GetRollingMarketValue({ argument })
      if result then
        local suffix = result.isUncertain and " ?" or ""
        Print(
          argument
            .. ": "
            .. result.value
            .. suffix
            .. " ("
            .. result.dayCount
            .. " days, "
            .. result.scanCount
            .. " scans)"
        )
      else
        Print(argument .. ": no market price stored")
      end
    else
      Print("Commands: /arb status, /arb count, /arb item <dbKey>, /arb recipes, /arb tooltip")
    end
  end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, eventName, loadedAddonName)
  if eventName ~= "ADDON_LOADED" or loadedAddonName ~= addonName then
    return
  end

  ns.Config.Init()
  ns.Database.Init()
  ns.RecipeBook.Init()
  ns.Config.RegisterOptionsPanel()
  RegisterAuctionatorListener()
  ns.RecipeBook.Register()
  if not ns.Tooltip.Register() then
    Print("Auctionator tooltips are unavailable")
  end
  RegisterSlashCommands()
  frame:UnregisterEvent("ADDON_LOADED")
end)

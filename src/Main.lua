local addonName, ns = ...

local frame = CreateFrame("Frame")

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Noop() end

---@alias ArbitragePricingCheckpoint fun(completed: number?, total: number?)

local function RefreshPrices()
  ns.OpportunityPanel.Refresh()
  ns.CraftingWindow.Refresh()
  ns.TrainerWindow.Refresh()
  ns.DatabaseIndex.Invalidate()
end

-- Groups auctions as the scan reads them, so grouping uses the reading frames' spare budget
-- rather than frames of its own, then prices the groups once reading ends.
---@return ArbitrageFullScanPricing
local function StartFullScan()
  ---@type table<string, ArbitrageMarketListings>
  local groups = {}
  -- The keys of auctions without a link, worked out once per item.
  ---@type table<number, string[]>
  local itemKeys = {}

  return {
    Add = function(itemID, itemLink, quantity, buyout)
      local unitPrice = math.ceil(buyout / quantity)
      local dbKeys = itemLink and ns.Keys.FromLink(itemLink) or itemKeys[itemID]
      if not dbKeys then
        dbKeys = ns.Keys.FromItemID(itemID)
        itemKeys[itemID] = dbKeys
      end

      for _, dbKey in ipairs(dbKeys) do
        ns.MarketValue.AddListing(groups, dbKey, unitPrice, quantity)
      end
    end,
    Finish = function(rawEntryCount, checkpoint)
      checkpoint = checkpoint or Noop
      if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
        return "Full scan contained no usable auctions; previous data kept"
      end

      local columns = ns.MarketValue.CalculateAll(groups, function(completed, total)
        checkpoint(completed and total and total > 0 and completed / total * 99 or nil)
      end)
      -- Hold at 99% while committing the scan and refreshing the results.
      checkpoint(99)
      ns.Profile.Stage("Full Scan", "Saving")
      local count = ns.Database.SaveScan(columns, time(), checkpoint)
      -- Refreshing waits for the next frame if saving used this one up.
      checkpoint()

      ns.Profile.Stage("Full Scan", "Refreshing")
      RefreshPrices()
      return "Full scan done: stored Market Values for " .. count .. " items"
    end,
  }
end

---@param buyouts table<string, number>
---@param quantities table<string, number>
---@param observedAt number
---@param checkpoint fun()?
---@return boolean saved
local function ProcessQuickScan(buyouts, quantities, observedAt, checkpoint)
  checkpoint = checkpoint or Noop
  ns.Profile.Stage("Quick Scan", "Saving")
  if not ns.Database.SaveQuickScan(buyouts, quantities, observedAt, checkpoint) then
    return false
  end
  -- Refreshing waits for the next frame if saving used this one up.
  checkpoint()
  ns.Profile.Stage("Quick Scan", "Refreshing")
  RefreshPrices()
  return true
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"

  local function PrintHelp()
    Print("/arb - Toggle the Arbitrage window")
    Print("/arb help - Show all commands")
    Print("/arb status - Show stored data and recent scans")
    Print("/arb settings - Open Arbitrage settings")
    Print("/arb forget <character> - Remove stored recipes for a character")
  end

  local function FormatKnownCharacters()
    local names = ns.RecipeBook.GetCharacterNames()
    if #names == 0 then
      return "no stored characters on this realm"
    end
    return "known: " .. table.concat(names, ", ")
  end

  SlashCmdList.ARBITRAGE = function(message)
    local trimmed = strtrim(message or "")
    local verb, rest = trimmed:match("^(%S+)%s*(.-)$")
    local command = strlower(verb or "")
    local argument = strtrim(rest or "")

    if command == "" then
      ns.Window.Toggle()
    elseif command == "status" and argument == "" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known vendor prices: " .. ns.Database.CountVendorPrices())
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Last full scan: " .. (status.latestScan and ns.Time.Since(status.latestScan) or "never"))
      Print("Last quick scan: " .. (status.latestQuickScan and ns.Time.Since(status.latestQuickScan) or "never"))
      Print("Scans in last 14 days: " .. status.recentScanCount)
    elseif command == "settings" and argument == "" then
      ns.Config.OpenOptionsPanel()
    elseif command == "forget" then
      if argument == "" then
        Print("Usage: /arb forget <character> (" .. FormatKnownCharacters() .. ")")
        return
      end
      local removed = ns.RecipeBook.ForgetCharacter(argument)
      if removed then
        ns.OpportunityPanel.Refresh()
        ns.CraftingWindow.Refresh()
        ns.DatabaseIndex.Invalidate()
        Print("Removed stored recipes for " .. removed)
      else
        Print("No stored recipes for " .. argument .. " (" .. FormatKnownCharacters() .. ")")
      end
    elseif command == "profile" then
      -- A developer command, left out of the help.
      ns.Profile.HandleCommand(strlower(argument))
    else
      PrintHelp()
    end
  end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, eventName, loadedAddonName)
  if eventName ~= "ADDON_LOADED" or loadedAddonName ~= addonName then
    return
  end

  ns.Profile.Init()
  ns.Profile.Start("Login", "Settings")
  ns.Config.Init()
  ns.Profile.Stage("Login", "Database")
  ns.Database.Init()
  ns.Profile.Stage("Login", "Recipes")
  ns.RecipeBook.Init()
  ns.Profile.Stage("Login", "Setup")
  ns.Scan.Init(StartFullScan, ProcessQuickScan)
  ns.OpportunityPanel.Register()
  ns.Vendor.Register()
  ns.RecipeCapture.Register()
  ns.CraftingWindow.Register()
  ns.TrainerWindow.Register()
  ns.Tooltip.Register()
  ns.MinimapButton.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  ns.Profile.Finish("Login")
  frame:UnregisterEvent("ADDON_LOADED")
end)

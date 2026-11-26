local NewEnvironment = dofile("tests/support/Environment.lua")

describe("TrainerWindow", function()
  local ns, eventFrame, rows, services, tooltip, initialized, timers, schematics, prices, scrollBox, tradeTrainer

  local function AddRow(index, requirementsWidth)
    local row = {
      node = {
        GetData = function()
          return { skillIndex = index }
        end,
      },
      subText = {
        GetLeft = function()
          return 48
        end,
        GetUnboundedStringWidth = function()
          return requirementsWidth or 0
        end,
      },
      GetRight = function()
        return 298
      end,
      HookScript = function(self, name, callback)
        self[name] = callback
      end,
      CreateFontString = function()
        return {
          SetPoint = function() end,
          SetText = function(self, text)
            self.text = text
          end,
          SetTextColor = function() end,
          GetStringWidth = function(self)
            return #self.text * 6
          end,
          Show = function(self)
            self.visible = true
          end,
          Hide = function(self)
            self.visible = false
          end,
        }
      end,
    }
    rows[#rows + 1] = row
    initialized(nil, row, row.node)
    return row
  end

  before_each(function()
    setfenv(1, NewEnvironment())
    rows, timers, prices = {}, {}, { [99] = 65 }
    tradeTrainer = true
    services = { { status = "available", data = { type = 1, id = 10 } } }
    schematics = {
      [10] = {
        recipeID = 10,
        recipeType = 1,
        outputItemID = 99,
        quantityMin = 3,
        quantityMax = 3,
        reagentSlotSchematics = {
          {
            required = true,
            quantityRequired = 2,
            reagents = { { itemID = 80 } },
            variableQuantities = {},
          },
        },
      },
    }
    eventFrame = {
      RegisterEvent = function() end,
      SetScript = function(self, name, callback)
        self[name] = callback
      end,
    }
    scrollBox = {
      IsVisible = function()
        return true
      end,
      ForEachFrame = function(_, callback)
        for _, row in ipairs(rows) do
          callback(row, row.node)
        end
      end,
      HookScript = function() end,
    }
    function CreateFrame()
      return eventFrame
    end
    function IsTradeskillTrainer()
      return tradeTrainer
    end
    function GetTrainerServiceInfo(index)
      return "Trainer recipe", services[index].status
    end
    function GetTrainerServiceCost(index)
      return 1000, services[index].isProfession
    end
    Enum = { TooltipDataType = { Spell = 1 }, TradeskillRecipeType = { Item = 1 } }
    C_TooltipInfo = {
      GetTrainerService = function(index)
        return services[index].data
      end,
    }
    C_TradeSkillUI = {
      GetRecipeInfo = function() end,
      GetRecipeSchematic = function(recipeID)
        return schematics[recipeID]
      end,
      GetRecipeOutputItemData = function() end,
      GetRecipeQualityItemIDs = function() end,
    }
    C_Item = { GetItemInfo = function() end }
    C_CurrencyInfo = {
      GetCoinTextureString = function(amount)
        return amount .. "c"
      end,
    }
    C_Timer = {
      After = function(_, callback)
        timers[#timers + 1] = callback
      end,
    }
    ScrollUtil = {
      AddInitializedFrameCallback = function(_, callback)
        initialized = callback
      end,
    }
    tooltip = {
      lines = {},
      IsOwned = function(self, row)
        return self.owner == row
      end,
      AddDoubleLine = function(self, label, value)
        self.lines[#self.lines + 1] = { label, value }
      end,
      Show = function() end,
    }
    GameTooltip = tooltip
    ns = {
      Opportunities = {
        GetForRecipe = function(recipe)
          local price = prices[recipe.outputItemID]
          if price == nil then
            return nil
          end
          assert.are.same({ { itemID = 80, quantity = 2 } }, recipe.reagents)
          return {
            saleMethod = "auction",
            profit = 999, -- The trainer must use the per-craft total, not this per-item value.
            perCraft = { craftCost = 220, profit = price * recipe.outputQuantity - 220 },
          }
        end,
      },
    }
    assert(loadfile("src/Terminology.lua"))("Arbitrage", ns)
    assert(loadfile("src/RecipeParser.lua"))("Arbitrage", ns)
    assert(loadfile("src/TrainerWindow.lua"))("Arbitrage", ns)
    ns.TrainerWindow.Register()
    ClassTrainerFrame = { ScrollBox = scrollBox }
    eventFrame:OnEvent("ADDON_LOADED", "Blizzard_TrainerUI")
  end)

  it("prices an unlearned recipe from its schematic and leaves normal capture alone", function()
    assert.is_nil(ns.RecipeParser.Capture(10))
    local row = AddRow(1)
    assert.is_true(row.arbitrageTrainerProfit.visible)
    assert.are.equal("-25c", row.arbitrageTrainerProfit.text)
    tooltip.owner = row
    row:OnEnter()
    assert.are.same({
      { "Typical Profit per craft (AH)", "-25c" },
      { "Materials per craft", "220c" },
    }, tooltip.lines)
  end)

  it("leaves requirements intact and still prices locked recipes on hover", function()
    services[1].status = "unavailable"
    local row = AddRow(1, 240)
    assert.is_not_true(row.arbitrageTrainerProfit.visible)
    tooltip.owner = row
    row:OnEnter()
    assert.are.equal("-25c", tooltip.lines[1][2])
  end)

  it("clears recycled rows and ignores learned recipes, profession ranks, and class trainers", function()
    local row = AddRow(1)
    initialized(nil, row, {
      GetData = function()
        return { categoryInfo = {} }
      end,
    })
    assert.is_false(row.arbitrageTrainerProfit.visible)
    tooltip.owner = row
    row:OnEnter()
    assert.are.same({}, tooltip.lines)
    services[1].status = "used"
    assert.is_nil(AddRow(1).arbitrageTrainerProfit)
    services[1].status, services[1].isProfession = "available", true
    assert.is_nil(AddRow(1).arbitrageTrainerProfit)
    services[1].isProfession, tradeTrainer = false, false
    assert.is_nil(AddRow(1).arbitrageTrainerProfit)
  end)

  it("leaves unknown prices blank and refreshes after trainer data changes", function()
    prices[99] = nil
    local row = AddRow(1)
    assert.is_nil(row.arbitrageTrainerProfit)
    prices[99] = 100
    eventFrame:OnEvent("TRAINER_UPDATE")
    eventFrame:OnEvent("ITEM_DATA_LOAD_RESULT", 99, true)
    assert.are.equal(1, #timers)
    timers[1]()
    assert.are.equal("+80c", row.arbitrageTrainerProfit.text)
  end)

  it("does not guess at missing spell IDs or mismatched schematics", function()
    services[1].data.type = 2
    assert.is_nil(AddRow(1).arbitrageTrainerProfit)
    services[1].data.type = 1
    schematics[10].recipeID = 11
    assert.is_nil(AddRow(1).arbitrageTrainerProfit)
  end)
end)

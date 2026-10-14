local NewEnvironment = dofile("tests/support/Environment.lua")

describe("RecipeCapture", function()
  local environment
  local ns, onEvent, events, messages
  local allRecipeIDCalls, recipeInfoCalls, dataSourceChanging, npcCrafting, runeforging
  local allRecipeIDs, recipeInfos, schematics, outputItems

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    events = {}
    messages = {}
    allRecipeIDCalls = 0
    recipeInfoCalls = {}
    dataSourceChanging = false
    npcCrafting = false
    runeforging = false

    function print(message)
      messages[#messages + 1] = message
    end

    function CreateFrame()
      return {
        RegisterEvent = function(_, eventName)
          events[eventName] = true
        end,
        SetScript = function(_, _, callback)
          onEvent = callback
        end,
      }
    end

    function geterrorhandler()
      return function(message)
        return message
      end
    end

    function GetRealmName()
      return "Test Realm"
    end

    function UnitName()
      return "Test Character"
    end

    function time()
      return 100
    end

    ARBITRAGE_RECIPES = nil
    Enum = {
      TradeskillRecipeType = {
        Item = 1,
        Enchant = 3,
      },
    }

    allRecipeIDs = { 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1999, 1000 }

    recipeInfos = {
      [1000] = { learned = true },
      [1001] = { learned = true },
      [1002] = { learned = true },
      [1003] = { learned = true },
      [1004] = { learned = true, isEnchantingRecipe = true },
      [1005] = { learned = true, qualityItemIDs = { 105, 106 } },
      [1006] = { learned = true },
      [1999] = { learned = false },
    }

    schematics = {
      [1000] = {
        outputItemID = 100,
        quantityMin = 2,
        quantityMax = 4,
        reagentSlotSchematics = {
          {
            required = true,
            reagents = { { itemID = 200 } },
            variableQuantities = {},
            quantityRequired = 3,
          },
          {
            required = false,
            reagents = { { itemID = 999 } },
            variableQuantities = {},
            quantityRequired = 1,
          },
        },
      },
      [1001] = {
        outputItemID = 101,
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {
          {
            required = true,
            reagents = { { itemID = 201 }, { itemID = 202 } },
            variableQuantities = {
              { reagent = { itemID = 202 }, quantity = 4 },
            },
            quantityRequired = 2,
          },
          {
            required = true,
            reagents = { { itemID = 201 } },
            variableQuantities = {},
            quantityRequired = 1,
          },
        },
      },
      [1002] = {
        outputItemID = 102,
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {
          {
            required = false,
            reagents = { { itemID = 203 } },
            variableQuantities = {},
            quantityRequired = 1,
          },
        },
      },
      [1003] = {
        outputItemID = 103,
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {
          {
            required = true,
            reagents = { { currencyID = 10 } },
            variableQuantities = {},
            quantityRequired = 1,
          },
        },
      },
      [1004] = {
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {},
      },
      [1005] = {
        outputItemID = 105,
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {
          {
            required = true,
            reagents = { { itemID = 205 } },
            variableQuantities = {},
            quantityRequired = 1,
          },
        },
      },
      [1006] = {
        recipeType = Enum.TradeskillRecipeType.Enchant,
        quantityMin = 1,
        quantityMax = 1,
        reagentSlotSchematics = {},
      },
    }

    outputItems = {
      [1000] = { itemID = 100 },
      [1001] = { itemID = 101 },
      [1002] = { itemID = 102 },
      [1003] = { itemID = 103 },
      [1004] = {},
      [1005] = { itemID = 105 },
      [1006] = {},
    }

    C_Item = {
      GetItemInfo = function(itemID)
        return "Item " .. itemID
      end,
    }

    C_TradeSkillUI = {
      GetBaseProfessionInfo = function()
        return { professionID = 171, professionName = "Alchemy" }
      end,
      GetAllRecipeIDs = function()
        allRecipeIDCalls = allRecipeIDCalls + 1
        return allRecipeIDs
      end,
      GetRecipeInfo = function(recipeID)
        recipeInfoCalls[recipeID] = (recipeInfoCalls[recipeID] or 0) + 1
        return recipeInfos[recipeID]
      end,
      GetRecipeSchematic = function(recipeID, isRecraft)
        assert(isRecraft == false, "requests normal recipe schematics")
        return schematics[recipeID]
      end,
      GetRecipeOutputItemData = function(recipeID)
        return outputItems[recipeID]
      end,
      GetRecipeQualityItemIDs = function(recipeID)
        return recipeInfos[recipeID] and recipeInfos[recipeID].qualityItemIDs
      end,
      IsDataSourceChanging = function()
        return dataSourceChanging
      end,
      IsNPCCrafting = function()
        return npcCrafting
      end,
      IsRuneforging = function()
        return runeforging
      end,
    }

    ns = {}
    assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeParser.lua"), "loads RecipeParser.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeCapture.lua"), "loads RecipeCapture.lua")("Arbitrage", ns)
    ns.RecipeBook.Init()
    ns.RecipeCapture.Register()
  end)

  it("registers modern profession events instead of legacy events", function()
    setfenv(1, environment)
    assert(events.TRADE_SKILL_SHOW and events.TRADE_SKILL_LIST_UPDATE, "registers modern profession events")
    assert(not events.TRADE_SKILL_UPDATE and not events.CRAFT_SHOW, "does not register legacy profession events")
  end)

  it("waits for stable data before enumerating and deduplicating unfiltered recipes", function()
    setfenv(1, environment)
    dataSourceChanging = true
    onEvent()
    assert(allRecipeIDCalls == 0, "does not capture while Blizzard is rebuilding the profession data source")
    dataSourceChanging = false
    onEvent()

    assert(allRecipeIDCalls == 1, "enumerates the open profession with the unfiltered recipe API")
    assert(recipeInfoCalls[1000] == 1, "deduplicates recipe IDs")
    assert(recipeInfoCalls[1999] == 1, "checks unlearned recipes returned by the unfiltered API")
  end)

  it("captures minimum output quantities and required reagents with stable keys", function()
    setfenv(1, environment)
    onEvent()
    local basicRecipes = ns.RecipeBook.GetRecipes(100)
    assert(#basicRecipes == 1, "captures a deterministic item recipe")
    assert(basicRecipes[1].outputQuantity == 2, "uses the conservative minimum output quantity")
    assert(#basicRecipes[1].reagents == 1, "ignores optional reagent slots")
    assert(basicRecipes[1].reagents[1].itemID == 200 and basicRecipes[1].reagents[1].quantity == 3, "captures reagents")
    assert(basicRecipes[1].recipeKey == "recipe:1000:100:200x3", "uses a stable recipe key")
  end)

  it("expands reagent choices with aggregated and variable quantities", function()
    setfenv(1, environment)
    onEvent()
    local choiceRecipes = ns.RecipeBook.GetRecipes(101)
    assert(#choiceRecipes == 2, "expands required reagent choices into recipe variants")
    local choicesByKey = {}
    for _, recipe in ipairs(choiceRecipes) do
      choicesByKey[recipe.recipeKey] = recipe
    end
    local combinedChoice = assert(choicesByKey["recipe:1001:101:201x3"], "aggregates duplicate choice reagents")
    assert(#combinedChoice.reagents == 1 and combinedChoice.reagents[1].quantity == 3, "stores the aggregated quantity")
    local variableChoice = assert(choicesByKey["recipe:1001:101:201x1:202x4"], "uses variable candidate quantities")
    assert(#variableChoice.reagents == 2, "stores every required choice reagent")
  end)

  it("skips unsupported recipes and reports their count", function()
    setfenv(1, environment)
    onEvent()
    assert(#ns.RecipeBook.GetRecipes(102) == 0, "skips recipes with only optional reagents")
    assert(#ns.RecipeBook.GetRecipes(103) == 0, "skips currency-only recipes")
    assert(
      #ns.RecipeBook.GetRecipes(105) == 0 and #ns.RecipeBook.GetRecipes(106) == 0,
      "skips ambiguous quality outputs"
    )
    assert(messages[1]:find("skipped 5 unsupported recipes", 1, true), "reports unsupported recipes once")
  end)

  it("keeps the previous snapshot when recipe data is incomplete and warns once", function()
    setfenv(1, environment)
    onEvent()
    recipeInfos[1000] = nil
    onEvent()
    local basicRecipes = ns.RecipeBook.GetRecipes(100)
    assert(#basicRecipes == 1 and basicRecipes[1].outputQuantity == 2, "keeps the previous incomplete snapshot")
    assert(messages[#messages]:find("recipe data was incomplete", 1, true), "reports incomplete data")
    local messageCount = #messages
    onEvent()
    assert(#messages == messageCount, "reports incomplete data only once")
  end)

  it("keeps a recovered snapshot when the recipe list becomes transiently empty", function()
    setfenv(1, environment)
    onEvent()
    recipeInfos[1000] = nil
    onEvent()
    recipeInfos[1000] = { learned = true }
    onEvent()
    allRecipeIDs = {}
    onEvent()
    assert(#ns.RecipeBook.GetRecipes(100) == 1, "does not replace a profession snapshot with an empty transient list")
  end)

  it("does not capture NPC crafting data", function()
    setfenv(1, environment)
    npcCrafting = true
    onEvent()
    assert(allRecipeIDCalls == 0, "does not capture NPC crafting data")
  end)

  it("does not capture runeforging data", function()
    setfenv(1, environment)
    runeforging = true
    onEvent()
    assert(allRecipeIDCalls == 0, "does not capture runeforging data")
  end)
end)

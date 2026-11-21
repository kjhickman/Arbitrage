local NewEnvironment = dofile("tests/support/Environment.lua")

describe("RecipeCapture", function()
  local environment
  local ns, onEvent, events, messages
  local dataSourceChanging, npcCrafting, runeforging
  local linkedCrafting, guildCrafting, auctionHouseRefreshes, craftingWindowRefreshes, databaseInvalidations
  local professionSlots, professionInfos, skillLineInfos
  local allRecipeIDs, recipeInfos, schematics, outputItems

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    onEvent = nil
    events = {}
    messages = {}
    dataSourceChanging = false
    npcCrafting = false
    runeforging = false
    linkedCrafting = false
    guildCrafting = false
    auctionHouseRefreshes = 0
    craftingWindowRefreshes = 0
    databaseInvalidations = 0
    professionSlots = { [1] = 1, [4] = 2 }
    professionInfos = {
      [1] = { name = "Alchemy", skillLine = 171 },
      [2] = { name = "Cooking", skillLine = 185 },
    }
    skillLineInfos = {
      [171] = { professionID = 171, professionName = "Alchemy" },
      [185] = { professionID = 185, professionName = "Cooking" },
    }

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

    function RegionalUniqueNamesEnabled()
      return false
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
      TradeskillRelativeDifficulty = {
        Optimal = 0,
        Medium = 1,
        Easy = 2,
        Trivial = 3,
      },
    }

    allRecipeIDs = { 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1999, 1000, 1002 }

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
        return allRecipeIDs
      end,
      GetRecipeInfo = function(recipeID)
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
      IsTradeSkillLinked = function()
        return linkedCrafting
      end,
      IsTradeSkillGuild = function()
        return guildCrafting
      end,
      GetProfessionInfoBySkillLineID = function(skillLineID)
        return skillLineInfos[skillLineID]
      end,
    }

    function GetProfessions()
      return professionSlots[1],
        professionSlots[2],
        professionSlots[3],
        professionSlots[4],
        professionSlots[5],
        professionSlots[6],
        professionSlots[7]
    end

    function GetProfessionInfo(slotIndex)
      local info = professionInfos[slotIndex]
      if not info then
        return nil
      end
      return info.name, nil, nil, nil, nil, nil, info.skillLine
    end

    strlower = string.lower

    ns = {
      OpportunityPanel = {
        Refresh = function()
          auctionHouseRefreshes = auctionHouseRefreshes + 1
        end,
      },
      CraftingWindow = {
        Refresh = function()
          craftingWindowRefreshes = craftingWindowRefreshes + 1
        end,
      },
      DatabaseIndex = {
        Invalidate = function()
          databaseInvalidations = databaseInvalidations + 1
        end,
      },
    }
    assert(loadfile("src/Realm.lua"), "loads Realm.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeParser.lua"), "loads RecipeParser.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeCapture.lua"), "loads RecipeCapture.lua")("Arbitrage", ns)
    ns.RecipeBook.Init()
    ns.RecipeCapture.Register()
  end)

  local function Printed(...)
    local lines = {}
    for index, message in ipairs({ ... }) do
      lines[index] = "|cff00ccffArbitrage:|r " .. message
    end
    return lines
  end

  local function LearnRecipe(recipeID, name)
    local outputItemID = recipeID + 1000
    allRecipeIDs[#allRecipeIDs + 1] = recipeID
    recipeInfos[recipeID] = { learned = true, name = name }
    outputItems[recipeID] = { itemID = outputItemID }
    schematics[recipeID] = {
      outputItemID = outputItemID,
      quantityMin = 1,
      quantityMax = 1,
      reagentSlotSchematics = {
        {
          required = true,
          reagents = { { itemID = 201 }, { itemID = 202 } },
          variableQuantities = {},
          quantityRequired = 1,
        },
      },
    }
  end

  it("registers modern profession events", function()
    setfenv(1, environment)
    assert(events.TRADE_SKILL_SHOW and events.TRADE_SKILL_LIST_UPDATE, "registers modern profession events")
  end)

  it("waits for stable profession data before capturing", function()
    setfenv(1, environment)
    dataSourceChanging = true
    onEvent()
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
    assert.are.equal(0, #messages)

    dataSourceChanging = false
    onEvent()
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(100))
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

  it("records and refreshes skill-up chances separately for each crafter", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000 }
    local info = recipeInfos[1000]
    local difficulty = Enum.TradeskillRelativeDifficulty
    info.canSkillUp, info.numSkillUps, info.relativeDifficulty = true, 2, difficulty.Optimal
    onEvent(nil, "TRADE_SKILL_SHOW")

    local character = UnitName
    function UnitName()
      return "Alt"
    end
    info.numSkillUps, info.relativeDifficulty = 1, difficulty.Easy
    onEvent(nil, "TRADE_SKILL_SHOW")

    local function GetSources()
      return ns.RecipeBook.GetCraftableOutputs()[1].sources
    end
    local sources = GetSources()
    assert.are.equal("Alt", sources[1].characterName)
    assert.are.equal(sources[1].recipeKey, sources[2].recipeKey)
    assert.are.same({ points = 1, difficulty = "easy" }, sources[1].skillUp)
    assert.are.same({ points = 2, difficulty = "optimal" }, sources[2].skillUp)

    UnitName = character
    info.canSkillUp, info.relativeDifficulty = false, difficulty.Trivial
    onEvent(nil, "TRADE_SKILL_LIST_UPDATE")
    assert.is_nil(GetSources()[2].skillUp)
    assert.are.same({ points = 1, difficulty = "easy" }, GetSources()[1].skillUp)
    assert.are.equal(3, auctionHouseRefreshes)
  end)

  it("skips gray, unranked, and disabled recipes that still report a skill-up", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000 }
    local info = recipeInfos[1000]
    local difficulty = Enum.TradeskillRelativeDifficulty
    local function CapturedSkillUp()
      onEvent(nil, "TRADE_SKILL_LIST_UPDATE")
      return ns.RecipeBook.GetCraftableOutputs()[1].sources[1].skillUp
    end

    -- Gray recipes report canSkillUp true and one point on Forever.
    info.canSkillUp, info.numSkillUps, info.relativeDifficulty = true, 1, difficulty.Trivial
    assert.is_nil(CapturedSkillUp())
    info.relativeDifficulty = nil
    assert.is_nil(CapturedSkillUp())
    info.relativeDifficulty, info.disabled = difficulty.Medium, true
    assert.is_nil(CapturedSkillUp())
    info.disabled = false
    assert.are.same({ points = 1, difficulty = "medium" }, CapturedSkillUp())
  end)

  it("ignores skill-ups saved before difficulties were recorded", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000 }
    onEvent(nil, "TRADE_SKILL_SHOW")
    for _, realm in pairs(ARBITRAGE_RECIPES) do
      for _, character in pairs(type(realm) == "table" and realm.characters or {}) do
        for _, profession in pairs(character.professions) do
          for _, recipe in pairs(profession.recipes) do
            recipe.skillUp = { points = 1, guaranteed = false }
          end
        end
      end
    end
    ns.RecipeBook.Init()
    assert.is_nil(ns.RecipeBook.GetCraftableOutputs()[1].sources[1].skillUp)
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

  it("skips unsupported recipes and reports each once in their count", function()
    setfenv(1, environment)
    onEvent()
    assert(#ns.RecipeBook.GetRecipes(102) == 0, "skips recipes with only optional reagents")
    assert(#ns.RecipeBook.GetRecipes(103) == 0, "skips currency-only recipes")
    assert(
      #ns.RecipeBook.GetRecipes(105) == 0 and #ns.RecipeBook.GetRecipes(106) == 0,
      "skips ambiguous quality outputs"
    )
    assert.are.same(
      Printed("Recorded 2 Alchemy recipes for Test Character", "Alchemy skipped 3 unsupported recipes"),
      messages
    )
  end)

  it("keeps unlearned recipes by the item they make without adding them to the recipe book", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000, 1998, 1999 }
    recipeInfos[1998] = { learned = false }
    schematics[1998] = {
      recipeID = 1998,
      recipeType = Enum.TradeskillRecipeType.Item,
      outputItemID = 198,
      quantityMin = 1,
      quantityMax = 1,
      reagentSlotSchematics = {
        { required = true, reagents = { { itemID = 200 } }, variableQuantities = {}, quantityRequired = 2 },
      },
    }
    onEvent()
    assert.are.same({ 1998 }, ns.RecipeBook.GetRecipeIDs(198))
    assert.are.same({}, ns.RecipeBook.GetRecipes(198))
    assert.are.same({ 1000 }, ns.RecipeBook.GetRecipeIDs(100))
    -- An unlearned recipe without a usable schematic is left out rather than holding up the snapshot.
    assert.are.same(Printed("Recorded 1 Alchemy recipe for Test Character"), messages)

    assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
    ns.RecipeBook.Init()
    assert.are.same({ 1998 }, ns.RecipeBook.GetRecipeIDs(198), "keeps unlearned recipes between sessions")
  end)

  it("does not count recipes that intentionally make no item as unsupported", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000, 1004, 1006 }
    onEvent()
    assert.are.same(Printed("Recorded 1 Alchemy recipe for Test Character"), messages)
  end)

  it("warns about unsupported recipes again only when there are more of them", function()
    setfenv(1, environment)
    onEvent()
    messages = {}

    -- A new session starts with fresh addon state but the same saved recipes.
    assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
    assert(loadfile("src/RecipeCapture.lua"), "loads RecipeCapture.lua")("Arbitrage", ns)
    ns.RecipeBook.Init()
    ns.RecipeCapture.Register()
    onEvent()
    assert.are.same({}, messages)

    recipeInfos[1007] = { learned = true, qualityItemIDs = { 107, 108 } }
    schematics[1007] = schematics[1005]
    outputItems[1007] = { itemID = 107 }
    allRecipeIDs[#allRecipeIDs + 1] = 1007
    onEvent()
    onEvent()
    assert.are.same(Printed("Alchemy skipped 4 unsupported recipes"), messages)
  end)

  it("reports how many recipes a profession recorded the first time, counting reagent choices once", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000, 1001 }
    onEvent()
    assert.are.same(Printed("Recorded 2 Alchemy recipes for Test Character"), messages)

    onEvent()
    assert.are.same(Printed("Recorded 2 Alchemy recipes for Test Character"), messages)
  end)

  it("names a newly learned recipe once", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000, 1001 }
    onEvent()
    messages = {}

    LearnRecipe(1100, "Elixir of Giants")
    onEvent()
    onEvent()
    assert.are.same(Printed("Test Character learned Elixir of Giants"), messages)
  end)

  it("lists several newly learned recipes alphabetically and summarises the rest", function()
    setfenv(1, environment)
    allRecipeIDs = { 1000 }
    onEvent()
    messages = {}

    LearnRecipe(1101, "Greater Healing Potion")
    LearnRecipe(1102, "Elixir of Agility")
    LearnRecipe(1103, "Fire Oil")
    onEvent()
    assert.are.same(
      Printed("Test Character learned 3 Alchemy recipes: Elixir of Agility, Fire Oil, Greater Healing Potion"),
      messages
    )

    messages = {}
    for recipeID = 1104, 1110 do
      LearnRecipe(recipeID, "Potion " .. recipeID)
    end
    onEvent()
    assert.are.same(
      Printed(
        "Test Character learned 7 Alchemy recipes: Potion 1104, Potion 1105, Potion 1106, Potion 1107, Potion 1108 and 2 more"
      ),
      messages
    )
  end)

  it("treats recipes already saved before this session as known", function()
    setfenv(1, environment)
    ARBITRAGE_RECIPES = {
      __version = 1,
      ["Test Realm"] = {
        characters = {
          ["Test Character"] = {
            professions = {
              Alchemy = {
                updatedAt = 1,
                recipes = {
                  ["recipe:1000:100:200x3"] = {
                    recipeKey = "recipe:1000:100:200x3",
                    outputItemID = 100,
                    outputQuantity = 2,
                    reagents = { { itemID = 200, quantity = 3 } },
                  },
                  ["recipe:1001:101:201x3"] = {
                    recipeKey = "recipe:1001:101:201x3",
                    outputItemID = 101,
                    outputQuantity = 1,
                    reagents = { { itemID = 201, quantity = 3 } },
                  },
                },
              },
            },
          },
        },
      },
    }
    ns.RecipeBook.Init()
    allRecipeIDs = { 1000, 1001 }
    onEvent()
    assert.are.same({}, messages)
    assert.are.equal(2, #ns.RecipeBook.GetRecipes(101))
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
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
  end)

  it("does not capture runeforging data", function()
    setfenv(1, environment)
    runeforging = true
    onEvent()
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
  end)

  it("does not capture linked or guild profession windows", function()
    setfenv(1, environment)
    linkedCrafting = true
    onEvent()
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))

    linkedCrafting = false
    guildCrafting = true
    onEvent()
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
  end)

  it("prunes unlearned professions after entering the world and refreshes UI views", function()
    setfenv(1, environment)
    onEvent()
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(100))
    assert.are.equal(1, auctionHouseRefreshes)
    assert.are.equal(1, craftingWindowRefreshes)
    assert.are.equal(1, databaseInvalidations)

    -- SKILL_LINES_CHANGED before PLAYER_ENTERING_WORLD must not prune.
    professionSlots = { [4] = 2 }
    onEvent(nil, "SKILL_LINES_CHANGED")
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(100))

    -- Entering the world reconciles across nil primary holes and removes unlearned Alchemy.
    onEvent(nil, "PLAYER_ENTERING_WORLD")
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
    assert.are.equal(2, auctionHouseRefreshes)
    assert.are.equal(2, craftingWindowRefreshes)
    assert.are.equal(2, databaseInvalidations)

    -- Re-capturing Alchemy and then dropping it mid-session prunes on SKILL_LINES_CHANGED.
    professionSlots = { [1] = 1, [4] = 2 }
    onEvent()
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(100))

    -- An occupied slot with unresolved info aborts pruning instead of wiping data.
    professionInfos[1] = { name = "", skillLine = 171 }
    onEvent(nil, "SKILL_LINES_CHANGED")
    assert.are.equal(1, #ns.RecipeBook.GetRecipes(100))

    -- Unlearning Alchemy removes it cleanly.
    professionSlots = { [4] = 2 }
    onEvent(nil, "SKILL_LINES_CHANGED")
    assert.are.equal(0, #ns.RecipeBook.GetRecipes(100))
  end)
end)

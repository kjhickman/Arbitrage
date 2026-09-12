local onEvent
local tradeHeaderExpanded = false
local craftHeaderExpanded = false
local onlyMakeable = true
local onlySkillUps = true
local itemNameFilter = "saved"
local minimumItemLevel = 10
local maximumItemLevel = 20
local tradeOutputQuantity = 2
local messages = {}

function print(message)
  messages[#messages + 1] = message
end

function CreateFrame()
  return {
    RegisterEvent = function() end,
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

UNKNOWN = "Unknown"
ARBITRAGE_RECIPES = nil

function IsTradeSkillLinked()
  return false
end

function GetNumTradeSkills()
  return 2
end

function GetTradeSkillInfo(index)
  if index == 1 then
    return "Header", "header", nil, tradeHeaderExpanded
  end
  return "Recipe", "optimal"
end

function ExpandTradeSkillSubClass()
  tradeHeaderExpanded = true
end

function CollapseTradeSkillSubClass()
  tradeHeaderExpanded = false
end

function GetTradeSkillSubClasses()
  return "Armor"
end

function GetTradeSkillSubClassFilter(index)
  return index == 1 and 1 or 0
end

function SetTradeSkillSubClassFilter() end

function GetTradeSkillInvSlots()
  return "Chest"
end

function GetTradeSkillInvSlotFilter(index)
  return index == 1 and 1 or 0
end

function SetTradeSkillInvSlotFilter() end

function GetOnlyShowMakeable()
  return onlyMakeable
end

function GetOnlyShowSkillUps()
  return onlySkillUps
end

function GetTradeSkillItemNameFilter()
  return itemNameFilter
end

function GetTradeSkillItemLevelFilter()
  return minimumItemLevel, maximumItemLevel
end

function TradeSkillOnlyShowMakeable(value)
  onlyMakeable = value
end

function TradeSkillOnlyShowSkillUps(value)
  onlySkillUps = value
end

function SetTradeSkillItemNameFilter(value)
  itemNameFilter = value
end

function SetTradeSkillItemLevelFilter(minimum, maximum)
  minimumItemLevel = minimum
  maximumItemLevel = maximum
end

function GetTradeSkillItemLink()
  return "item:100"
end

function GetTradeSkillNumMade()
  return tradeOutputQuantity
end

function GetTradeSkillNumReagents()
  return 1
end

function GetTradeSkillReagentInfo()
  return "Trade Reagent", nil, 3
end

function GetTradeSkillReagentItemLink()
  return "item:200"
end

function GetTradeSkillRecipeLink()
  return "|cffffd000|Henchant:1000|h[Alchemy: Trade Recipe]|h|r"
end

function GetTradeSkillLine()
  return "Alchemy"
end

function GetNumCrafts()
  return 2
end

function GetCraftInfo(index)
  if index == 1 then
    return "Header", nil, "header", nil, craftHeaderExpanded
  end
  return "Recipe", nil, "optimal"
end

function ExpandCraftSkillLine()
  craftHeaderExpanded = true
end

function CollapseCraftSkillLine()
  craftHeaderExpanded = false
end

function GetCraftItemLink()
  return "item:300"
end

function GetCraftNumMade()
  return 3
end

function GetCraftNumReagents()
  return 1
end

function GetCraftReagentInfo()
  return "Craft Reagent", nil, 2
end

function GetCraftReagentItemLink()
  return "item:400"
end

function GetCraftRecipeLink()
  return "|cffffd000|Henchant:2000|h[Cooking: Craft Recipe]|h|r"
end

function GetCraftName()
  return "Cooking"
end

local ns = {}
assert(loadfile("src/RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
assert(loadfile("src/RecipeCapture.lua"), "loads RecipeCapture.lua")("Arbitrage", ns)
ns.RecipeBook.Init()
ns.RecipeCapture.Register()

onEvent(nil, "TRADE_SKILL_SHOW")
local tradeRecipes = ns.RecipeBook.GetRecipes(100)
assert(#tradeRecipes == 1 and tradeRecipes[1].outputQuantity == 2, "captures trade-skill recipes")
assert(tradeRecipes[1].recipeKey == "recipe:1000", "uses the Classic trade-skill recipe ID")
assert(not tradeHeaderExpanded, "restores trade-skill headers")
assert(onlyMakeable and onlySkillUps, "restores trade-skill boolean filters")
assert(itemNameFilter == "saved" and minimumItemLevel == 10 and maximumItemLevel == 20, "restores filters")

tradeOutputQuantity = nil
onEvent(nil, "TRADE_SKILL_UPDATE")
tradeRecipes = ns.RecipeBook.GetRecipes(100)
assert(#tradeRecipes == 1 and tradeRecipes[1].outputQuantity == 2, "keeps the previous incomplete snapshot")
assert(#messages == 1, "reports incomplete recipe data once")

onEvent(nil, "CRAFT_SHOW")
local craftRecipes = ns.RecipeBook.GetRecipes(300)
assert(#craftRecipes == 1 and craftRecipes[1].outputQuantity == 3, "captures legacy craft recipes")
assert(craftRecipes[1].recipeKey == "recipe:2000", "uses the Classic craft recipe ID")
assert(not craftHeaderExpanded, "restores craft headers")

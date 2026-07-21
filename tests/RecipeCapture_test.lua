local onEvent
local errors = {}
local tradeExpansionFailure = true
local tradeCollapseFailure = true
local filterRestoreFailure = true
local craftFailure = true
local tradeHeaderExpanded = false
local craftHeaderExpanded = false
local tradeHeaderCollapses = 0
local craftHeaderCollapses = 0
local onlyMakeable = true
local onlySkillUps = true
local itemNameFilter = "saved"
local minimumItemLevel = 10
local maximumItemLevel = 20
local subclassFilterCalls = {}
local invSlotFilterCalls = {}
local messages = {}
local tradeOutputQuantity = 2

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
    errors[#errors + 1] = tostring(message)
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
  if tradeExpansionFailure then
    error("trade expansion failed")
  end
end

function CollapseTradeSkillSubClass()
  tradeHeaderExpanded = false
  tradeHeaderCollapses = tradeHeaderCollapses + 1
  if tradeCollapseFailure then
    error("trade collapse failed")
  end
end

function GetTradeSkillSubClasses()
  return "Armor"
end

function GetTradeSkillSubClassFilter(index)
  return index == 1 and 1 or 0
end

function SetTradeSkillSubClassFilter(index, enabled, exclusive)
  subclassFilterCalls[#subclassFilterCalls + 1] = { index, enabled, exclusive }
end

function GetTradeSkillInvSlots()
  return "Chest"
end

function GetTradeSkillInvSlotFilter(index)
  return index == 1 and 1 or 0
end

function SetTradeSkillInvSlotFilter(index, enabled, exclusive)
  invSlotFilterCalls[#invSlotFilterCalls + 1] = { index, enabled, exclusive }
end

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
  if filterRestoreFailure and value == "saved" then
    error("filter restoration failed")
  end
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
  return "|Hspell:1000|h"
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
  craftHeaderCollapses = craftHeaderCollapses + 1
end

function GetCraftItemLink()
  if craftFailure then
    error("craft capture failed")
  end
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
  return "|Hspell:2000|h"
end

function GetCraftName()
  return "Cooking"
end

local ns = {}
assert(loadfile("RecipeBook.lua"), "loads RecipeBook.lua")("Arbitrage", ns)
assert(loadfile("RecipeCapture.lua"), "loads RecipeCapture.lua")("Arbitrage", ns)
ns.RecipeBook.Init()
ns.RecipeCapture.Register()

onEvent(nil, "TRADE_SKILL_SHOW")
assert(#errors == 3, "reports trade-skill capture and cleanup errors")
assert(not tradeHeaderExpanded and tradeHeaderCollapses == 1, "restores trade-skill headers after errors")
assert(onlyMakeable and onlySkillUps, "restores trade-skill boolean filters after errors")
assert(
  itemNameFilter == "saved" and minimumItemLevel == 10 and maximumItemLevel == 20,
  "restores trade-skill filters after errors"
)
local subclassRestore = subclassFilterCalls[#subclassFilterCalls]
local invSlotRestore = invSlotFilterCalls[#invSlotFilterCalls]
assert(
  subclassRestore[1] == 1 and subclassRestore[2] == 1 and subclassRestore[3] == 0,
  "restores subclass filters after errors"
)
assert(
  invSlotRestore[1] == 1 and invSlotRestore[2] == 1 and invSlotRestore[3] == 0,
  "restores inventory-slot filters after errors"
)

tradeExpansionFailure = false
tradeCollapseFailure = false
filterRestoreFailure = false
onEvent(nil, "TRADE_SKILL_UPDATE")
local tradeRecipes = ns.RecipeBook.GetRecipes(100)
assert(#tradeRecipes == 1 and tradeRecipes[1].outputQuantity == 2, "retries trade-skill capture after errors")

tradeOutputQuantity = nil
onEvent(nil, "TRADE_SKILL_UPDATE")
tradeRecipes = ns.RecipeBook.GetRecipes(100)
assert(#tradeRecipes == 1 and tradeRecipes[1].outputQuantity == 2, "keeps the previous snapshot after incomplete data")
assert(#messages == 1, "reports incomplete recipe data once")

onEvent(nil, "CRAFT_SHOW")
assert(#errors == 4, "reports craft capture errors")
assert(not craftHeaderExpanded and craftHeaderCollapses == 1, "restores craft headers after errors")

craftFailure = false
onEvent(nil, "CRAFT_UPDATE")
local craftRecipes = ns.RecipeBook.GetRecipes(300)
assert(#craftRecipes == 1 and craftRecipes[1].outputQuantity == 3, "uses the legacy craft output quantity")

local _, ns = ...

ns.Realm = {}

---@param rule number?
---@return boolean
local function IsRuleActive(rule)
  return rule ~= nil and C_GameRules.IsGameRuleActive(rule)
end

---@return string
function ns.Realm.GetName()
  if not RegionalUniqueNamesEnabled() then
    return GetRealmName()
  end

  local gameRule = Enum.GameRule
  if IsRuleActive(gameRule.HardcoreRuleset) then
    return "Hardcore"
  end

  local isRP = IsRuleActive(gameRule.RPRuleset)
  local isPvP = IsRuleActive(gameRule.PvPRuleset)
  if isRP and isPvP then
    return "Roleplay PvP"
  end
  if isRP then
    return "Roleplay"
  end
  if isPvP then
    return "PvP"
  end
  return "Normal"
end

---@return string?
function ns.Realm.GetCharacterName()
  if not RegionalUniqueNamesEnabled() then
    return (UnitName("player"))
  end

  local name, surname = UnitNameUnmodified("player")
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if type(surname) == "string" and surname ~= "" then
    return name .. " " .. surname
  end
  return name
end

std = "lua51"
max_line_length = false

include_files = { "src/**/*.lua" }

read_globals = {
  "ARBITRAGE_CONFIG",
  "ARBITRAGE_DATABASE",
  "ARBITRAGE_IMPORT",
  "ARBITRAGE_RECIPES",
  "AuctionHouseFrame",
  "C_AuctionHouse",
  "C_CurrencyInfo",
  "C_Item",
  "C_Map",
  "C_MerchantFrame",
  "C_Timer",
  "C_TradeSkillUI",
  "CreateDataProvider",
  "CreateFrame",
  "CreateScrollBoxListLinearView",
  "CreateSettingsListSectionHeaderInitializer",
  "Enum",
  "GameTooltip",
  "GetCurrentRegion",
  "GetMerchantItemID",
  "GetMerchantNumItems",
  "GetRealmName",
  "IsShiftKeyDown",
  "Item",
  "LIGHTBLUE_FONT_COLOR",
  "LibStub",
  "NORMAL_FONT_COLOR",
  "ScrollBoxConstants",
  "ScrollBoxListMixin",
  "ScrollUtil",
  "Settings",
  "SlashCmdList",
  "TooltipDataProcessor",
  "TooltipUtil",
  "UNKNOWN",
  "UnitFactionGroup",
  "UnitName",
  "WHITE_FONT_COLOR",
  "date",
  "debugprofilestop",
  "geterrorhandler",
  "hooksecurefunc",
  "strlower",
  "strtrim",
  "time",
}

files["src/Config.lua"].globals = { "ARBITRAGE_CONFIG" }
files["src/Database.lua"].globals = { "ARBITRAGE_DATABASE" }
files["src/Main.lua"].globals = { "SLASH_ARBITRAGE1", "SlashCmdList.ARBITRAGE" }
files["src/RecipeBook.lua"].globals = { "ARBITRAGE_RECIPES" }

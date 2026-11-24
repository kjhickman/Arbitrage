-- A fake game client for the benchmark: enough of WoW's API for Arbitrage's own files to log in,
-- scan, and show their tables as they do in game. Frames run one after another on a fake clock,
-- timers fire on that clock, and an item's data loads the frame after something asks for it.
-- Item traits are made up from the item ID, the same every run.
local Client = {}

local FRAME_SECONDS = 1 / 60
-- Rows a scroll list draws, about as many as the Database tab shows.
local VISIBLE_ROWS = 22
local EQUIP_LOCS = {
  "INVTYPE_HEAD",
  "INVTYPE_SHOULDER",
  "INVTYPE_CHEST",
  "INVTYPE_ROBE",
  "INVTYPE_WAIST",
  "INVTYPE_LEGS",
  "INVTYPE_FEET",
  "INVTYPE_WRIST",
  "INVTYPE_HAND",
  "INVTYPE_FINGER",
  "INVTYPE_CLOAK",
  "INVTYPE_WEAPON",
  "INVTYPE_2HWEAPON",
  "INVTYPE_SHIELD",
  "INVTYPE_RANGED",
}
local OTHER_CLASSES = { 0, 7, 7, 7, 5, 3, 9, 15 }
local STATS = {
  "ITEM_MOD_STRENGTH_SHORT",
  "ITEM_MOD_AGILITY_SHORT",
  "ITEM_MOD_STAMINA_SHORT",
  "ITEM_MOD_INTELLECT_SHORT",
  "ITEM_MOD_SPIRIT_SHORT",
  "ITEM_MOD_ATTACK_POWER_SHORT",
  "ITEM_MOD_CRIT_RATING_SHORT",
  "ITEM_MOD_HIT_RATING_SHORT",
  "RESISTANCE0_NAME",
  "RESISTANCE2_NAME",
  "ITEM_MOD_DAMAGE_PER_SECOND_SHORT",
}
local SUFFIXES = { "the Bear", "the Eagle", "the Owl", "the Monkey", "the Tiger", "the Wolf", "the Whale", "Healing" }
local VARIANT_FIELDS = "^item:%-?%d+::::::::1:1485:::1:(%-?%d+)"

local function Noop() end

-- A number in [0, 1) that is always the same for the same input.
---@param value number
---@return number
function Client.Hash(value)
  return ((value * 2654435761) % 4294967296) / 4294967296
end
local Hash = Client.Hash

-- Widgets ----------------------------------------------------------------------------------------

local Widget = {}
local WidgetMeta = { __call = Noop }

-- Anything a template would provide that the benchmark doesn't model, a child or a method, is a
-- stand-in that does nothing.
local function NewStandIn()
  return setmetatable({ scripts = {} }, WidgetMeta)
end

WidgetMeta.__index = function(self, key)
  local method = Widget[key]
  if method ~= nil then
    return method
  end
  if type(key) == "string" and key:find("^%u") then
    local standIn = NewStandIn()
    rawset(self, key, standIn)
    return standIn
  end
end

for _, name in ipairs({
  "SetPoint",
  "SetAllPoints",
  "ClearAllPoints",
  "SetSize",
  "SetWidth",
  "SetHeight",
  "SetTextColor",
  "SetJustifyH",
  "SetWordWrap",
  "SetMaxLines",
  "SetTexture",
  "SetAtlas",
  "SetColorTexture",
  "SetTexCoord",
  "SetBlendMode",
  "SetFrameLevel",
  "EnableMouse",
  "EnableMouseWheel",
  "SetMovable",
  "SetClampedToScreen",
  "RegisterForDrag",
  "SetToplevel",
  "SetTitle",
  "SetPortraitToAsset",
  "SetHighlightAtlas",
  "SetNormalAtlas",
  "SetThickness",
  "SetStartPoint",
  "SetEndPoint",
  "SetVertexColor",
  "SetMotionScriptsWhileDisabled",
  "SetEnabled",
  "SetScrollChild",
  "SetVerticalScroll",
  "SetAutoFocus",
  "SetupMenu",
  "SetIsDefaultCallback",
  "SetDefaultCallback",
  "ValidateResetState",
  "SetHideIfUnscrollable",
  "SetFillPercent",
  "RegisterCallback",
  "SetMaxLetters",
}) do
  Widget[name] = Noop
end

---@type table
local client

local function NewWidget(parent)
  return setmetatable({ parent = parent, shown = true, scripts = {} }, WidgetMeta)
end

function Widget:Show()
  if not self.shown then
    self.shown = true
    if self.scripts.OnShow then
      self.scripts.OnShow(self)
    end
  end
end

function Widget:Hide()
  if self.shown then
    self.shown = false
    if self.scripts.OnHide then
      self.scripts.OnHide(self)
    end
  end
end

function Widget:SetShown(shown)
  if shown then
    self:Show()
  else
    self:Hide()
  end
end

function Widget:IsShown()
  return self.shown == true
end

function Widget:IsVisible()
  local region = self
  while region do
    if region.shown == false then
      return false
    end
    region = rawget(region, "parent")
  end
  return true
end

function Widget:SetScript(name, callback)
  self.scripts[name] = callback
  if name == "OnUpdate" then
    client.updating[self] = callback
  end
end

function Widget:GetScript(name)
  return self.scripts[name]
end

function Widget:HookScript(name, callback)
  local original = self.scripts[name]
  self:SetScript(name, function(...)
    if original then
      original(...)
    end
    callback(...)
  end)
end

function Widget:RegisterEvent(event)
  local frames = client.handlers[event]
  if not frames then
    frames = {}
    client.handlers[event] = frames
  end
  for _, frame in ipairs(frames) do
    if frame == self then
      return
    end
  end
  frames[#frames + 1] = self
end

function Widget:UnregisterEvent(event)
  local frames = client.handlers[event] or {}
  for index = #frames, 1, -1 do
    if frames[index] == self then
      table.remove(frames, index)
    end
  end
end

-- Like the game, setting an edit box's text tells its scripts.
function Widget:SetText(text)
  self.text = text
  if self.isEditBox and self.scripts.OnTextChanged then
    self.scripts.OnTextChanged(self, false)
  end
end

function Widget:GetText()
  return self.text or (self.isEditBox and "" or nil)
end

function Widget:SetID(id)
  self.id = id
end

function Widget:GetID()
  return self.id
end

function Widget:GetParent()
  return rawget(self, "parent")
end

function Widget:GetFrameLevel()
  return 1
end

function Widget:GetWidth()
  return 200
end

function Widget:GetStringWidth()
  return 60
end

function Widget:IsObjectType()
  return true
end

function Widget:CreateFontString()
  return NewWidget(self)
end
Widget.CreateTexture = Widget.CreateFontString
Widget.CreateLine = Widget.CreateFontString

-- A scroll list draws its first rows, as the game draws the rows in view.
function Widget:SetDataProvider(provider)
  self.rows = self.rows or {}
  local shown = math.min(VISIBLE_ROWS, provider.size)
  for index = 1, shown do
    local row = self.rows[index]
    if not row then
      row = client.CreateFrame("Button", nil, self)
      self.rows[index] = row
    end
    row.shown = true
    self.view.initializer(row, index)
  end
  for index = shown + 1, #self.rows do
    self.rows[index].shown = false
  end
end

function Widget:ForEachFrame(callback)
  for index, row in ipairs(self.rows or {}) do
    if row.shown then
      callback(row, index)
    end
  end
end

-- Items ------------------------------------------------------------------------------------------

---@param item number|string an item ID or a link
---@return number? itemID, number? variant the random enchant a link names
local function ParseItem(item)
  if type(item) == "number" then
    return item
  end
  if type(item) == "string" then
    local link = item:match("item:[^|]+")
    if link then
      return tonumber(link:match("^item:(%-?%d+)")), tonumber(link:match(VARIANT_FIELDS))
    end
    return tonumber(item)
  end
end

-- Install ----------------------------------------------------------------------------------------

-- Sets the game's globals and returns the client that drives them.
---@param options { now: number, realm: string, faction: string, region: number, character: string, cachedFraction: number, gearItems: table<number, true>, greyItems: table<number, true> }
function Client.Install(options)
  local startSeconds = 1000
  client = {
    frames = 0,
    seconds = startSeconds,
    handlers = {},
    updating = {},
    created = {},
    messages = {},
    timers = {},
    cached = {},
    pending = {},
    pendingSet = {},
    auctionHouseOpen = false,
  }
  local cached, gearItems, greyItems = client.cached, options.gearItems, options.greyItems

  local function IsGear(itemID)
    return gearItems[itemID] == true or Hash(itemID * 7 + 1) < 0.12
  end

  local function Quality(itemID)
    if greyItems[itemID] then
      return 0
    end
    if IsGear(itemID) then
      return 2 + math.floor(Hash(itemID + 17) * 3)
    end
    return 1 + math.floor(Hash(itemID + 19) * 3)
  end

  ---@return number classID, number subClassID, string equipLoc
  local function Class(itemID)
    if IsGear(itemID) then
      local classID = Hash(itemID + 3) < 0.3 and 2 or 4
      return classID, math.floor(Hash(itemID + 11) * 8), EQUIP_LOCS[1 + math.floor(Hash(itemID + 13) * #EQUIP_LOCS)]
    end
    return OTHER_CLASSES[1 + math.floor(Hash(itemID + 5) * #OTHER_CLASSES)], math.floor(Hash(itemID + 11) * 4), ""
  end

  local function RequestLoad(itemID)
    if not cached[itemID] and not client.pendingSet[itemID] then
      client.pendingSet[itemID] = true
      client.pending[#client.pending + 1] = itemID
    end
  end

  for _, id in ipairs(options.knownItems or {}) do
    if Hash(id + 29) < options.cachedFraction then
      cached[id] = true
    end
  end

  function client.CreateFrame(frameType, name, parent, template)
    local frame = NewWidget(parent)
    frame.frameType, frame.name, frame.template = frameType, name, template
    frame.isEditBox = frameType == "EditBox"
    client.created[#client.created + 1] = frame
    if type(name) == "string" and name ~= "" then
      _G[name] = frame
    end
    return frame
  end

  function client.FireEvent(event, ...)
    local frames = client.handlers[event]
    if not frames then
      return
    end
    for _, frame in ipairs({ unpack(frames) }) do
      if frame.scripts.OnEvent then
        frame.scripts.OnEvent(frame, event, ...)
      end
    end
  end

  -- One frame: items asked for last frame load, due timers run, then every OnUpdate script.
  function client.RunFrame()
    client.frames = client.frames + 1
    client.seconds = client.seconds + FRAME_SECONDS

    local loading = client.pending
    client.pending, client.pendingSet = {}, {}
    for _, itemID in ipairs(loading) do
      cached[itemID] = true
      client.FireEvent("ITEM_DATA_LOAD_RESULT", itemID, true)
      client.FireEvent("GET_ITEM_INFO_RECEIVED", itemID, true)
    end

    local timers = client.timers
    client.timers = {}
    for _, timer in ipairs(timers) do
      if timer.at <= client.seconds then
        timer.callback()
      else
        client.timers[#client.timers + 1] = timer
      end
    end

    for frame, callback in pairs(client.updating) do
      if frame:IsVisible() then
        callback(frame, FRAME_SECONDS)
      end
    end
  end

  ---@param done fun(): boolean
  ---@param limit number
  ---@return number frames
  function client.RunUntil(done, limit)
    local frames = 0
    while not done() do
      if frames >= limit then
        error("gave up after " .. limit .. " frames", 2)
      end
      client.RunFrame()
      frames = frames + 1
    end
    return frames
  end

  function client.RunFrames(count)
    for _ = 1, count do
      client.RunFrame()
    end
  end

  -- Runs frames until no item is loading and no timer is waiting.
  function client.Settle()
    return client.RunUntil(function()
      return #client.pending == 0 and #client.timers == 0
    end, 20000)
  end

  function client.Advance(seconds)
    client.seconds = client.seconds + seconds
  end

  ---@param ancestor table
  ---@param test fun(frame: table): boolean
  ---@return table[]
  function client.FindFrames(ancestor, test)
    local found = {}
    for _, frame in ipairs(client.created) do
      local region = rawget(frame, "parent")
      while region and region ~= ancestor do
        region = rawget(region, "parent")
      end
      if region == ancestor and test(frame) then
        found[#found + 1] = frame
      end
    end
    return found
  end

  -- The replicate list a full scan reads, as { count, Get(index) }, or nil.
  function client.SetReplicate(replicate)
    client.replicate = replicate
  end

  function client.SetBrowseResults(results)
    client.browseResults = results
  end

  function client.SetAuctionHouseOpen(open)
    client.auctionHouseOpen = open
  end

  -- Globals --------------------------------------------------------------------------------------

  local function Color(r, g, b)
    return {
      GetRGB = function()
        return r, g, b
      end,
      WrapTextInColorCode = function(_, text)
        return text
      end,
    }
  end

  CreateFrame = client.CreateFrame
  UIParent = NewStandIn()
  GameTooltip = NewStandIn()
  Settings = NewStandIn()
  TooltipDataProcessor = NewStandIn()
  TooltipUtil = NewStandIn()
  C_TooltipInfo = NewStandIn()
  C_TradeSkillUI = NewStandIn()
  C_MerchantFrame = NewStandIn()
  C_GameRules = NewStandIn()
  C_AddOns = NewStandIn()
  Professions = NewStandIn()
  SOUNDKIT = NewStandIn()
  UISpecialFrames = {}
  SlashCmdList = {}
  UNKNOWN = "Unknown"
  MenuResponse = { Refresh = 2 }
  NORMAL_FONT_COLOR = Color(1, 0.82, 0)
  WHITE_FONT_COLOR = Color(1, 1, 1)
  LIGHTBLUE_FONT_COLOR = Color(0.5, 0.7, 1)
  ScrollBoxConstants = { RetainScrollPosition = true, DiscardScrollPosition = false }
  ScrollBoxListMixin = { Event = { OnScroll = "OnScroll" } }
  for index, equipLoc in ipairs(EQUIP_LOCS) do
    _G[equipLoc] = "Slot " .. index
  end
  for quality = 0, 7 do
    _G["ITEM_QUALITY" .. quality .. "_DESC"] = "Quality " .. quality
  end
  for _, stat in ipairs(STATS) do
    _G[stat] = stat:lower()
  end

  Enum = {
    ItemClass = {
      Consumable = 0,
      Weapon = 2,
      Gem = 3,
      Armor = 4,
      Reagent = 5,
      Tradegoods = 7,
      Recipe = 9,
      Battlepet = 17,
    },
    ItemQuality = { Poor = 0, Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Artifact = 6 },
    ItemWeaponSubclass = {
      Axe1H = 0,
      Axe2H = 1,
      Bows = 2,
      Guns = 3,
      Mace1H = 4,
      Mace2H = 5,
      Polearm = 6,
      Sword1H = 7,
      Sword2H = 8,
      Warglaive = 9,
      Staff = 10,
      Unarmed = 13,
      Generic = 14,
      Dagger = 15,
      Thrown = 16,
      Crossbow = 18,
      Wand = 19,
      Fishingpole = 20,
    },
    ItemArmorSubclass = {
      Generic = 0,
      Cloth = 1,
      Leather = 2,
      Mail = 3,
      Plate = 4,
      Libram = 7,
      Idol = 8,
      Totem = 9,
      Sigil = 10,
      Relic = 11,
    },
    AuctionHouseFilter = {
      CommonQuality = 7,
      UncommonQuality = 8,
      RareQuality = 9,
      EpicQuality = 10,
      LegendaryQuality = 11,
      ArtifactQuality = 12,
    },
    ItemBind = { None = 0, OnAcquire = 1, OnEquip = 2, OnUse = 3 },
    TooltipDataType = { Item = 0, Spell = 1 },
    TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 },
    TradeskillRecipeType = { Item = 1 },
    GameRule = {},
  }

  function debugprofilestop()
    return os.clock() * 1000
  end

  function GetTime()
    return client.seconds
  end

  function time()
    return math.floor(options.now + client.seconds - startSeconds)
  end

  date = os.date
  strlower = string.lower
  strmatch = string.match
  function strtrim(value)
    return (value:match("^%s*(.-)%s*$"))
  end

  function print(message)
    client.messages[#client.messages + 1] = message
  end

  function geterrorhandler()
    return function(message)
      io.stderr:write(tostring(message), "\n")
    end
  end

  function hooksecurefunc(target, name, hook)
    local original = target[name]
    target[name] = function(...)
      local results = { original(...) }
      hook(...)
      return unpack(results)
    end
  end

  function LibStub()
    return NewStandIn()
  end

  PlaySound = Noop
  PanelTemplates_SetNumTabs = Noop
  PanelTemplates_SetTab = Noop
  PanelTemplates_TabResize = Noop
  HandleModifiedItemClick = Noop
  CreateSettingsListSectionHeaderInitializer = Noop
  function IsModifierKeyDown()
    return false
  end
  IsShiftKeyDown = IsModifierKeyDown
  IsTradeskillTrainer = IsModifierKeyDown
  function GetCursorPosition()
    return 0, 0
  end
  function GetMerchantNumItems()
    return 0
  end
  GetProfessions = Noop

  function RegionalUniqueNamesEnabled()
    return false
  end
  function GetRealmName()
    return options.realm
  end
  function UnitName()
    return options.character
  end
  function UnitNameUnmodified()
    return options.character
  end
  function UnitFactionGroup()
    return options.faction
  end
  function GetCurrentRegion()
    return options.region
  end

  C_Timer = {
    After = function(seconds, callback)
      client.timers[#client.timers + 1] = { at = client.seconds + seconds, callback = callback }
    end,
  }

  C_Map = {
    GetBestMapForUnit = function()
      return 1453
    end,
  }

  C_CurrencyInfo = {
    GetCoinTextureString = function(copper)
      return tostring(copper)
    end,
  }

  function CreateIndexRangeDataProvider(size)
    return { size = size }
  end

  function CreateScrollBoxListLinearView()
    return {
      SetElementExtent = Noop,
      SetElementInitializer = function(view, _, initializer)
        view.initializer = initializer
      end,
    }
  end

  ScrollUtil = {
    InitScrollBoxListWithScrollBar = function(scrollBox, _, view)
      scrollBox.view = view
    end,
    RegisterAlternateRowBehavior = Noop,
    InitScrollFrameWithScrollBar = Noop,
    AddInitializedFrameCallback = Noop,
  }

  function CreateObjectPool(create, reset)
    local active, inactive = {}, {}
    local pool = {}
    function pool:Acquire()
      local object = table.remove(inactive)
      if not object then
        object = create(self)
        reset(self, object)
      end
      active[#active + 1] = object
      return object
    end
    function pool:ReleaseAll()
      for _, object in ipairs(active) do
        reset(self, object)
        inactive[#inactive + 1] = object
      end
      active = {}
    end
    return pool
  end

  AuctionHouseFrame = NewWidget()
  function AuctionHouseFrame:IsShown()
    return client.auctionHouseOpen
  end

  C_Item = {
    DoesItemExistByID = function()
      return true
    end,
    IsItemDataCachedByID = function(itemID)
      return cached[itemID] == true
    end,
    RequestLoadItemDataByID = RequestLoad,
    GetItemInfoInstant = function(item)
      local itemID = ParseItem(item)
      if not itemID then
        return nil
      end
      local classID, subClassID, equipLoc = Class(itemID)
      return itemID, "Type", "Subtype", equipLoc, itemID, classID, subClassID
    end,
    -- Like the game, asking about an item that hasn't loaded starts loading it.
    GetItemInfo = function(item)
      local itemID, variant = ParseItem(item)
      if not itemID then
        return nil
      end
      if not cached[itemID] then
        RequestLoad(itemID)
        return nil
      end
      local name = "Item " .. itemID
      if variant then
        name = name .. " of " .. SUFFIXES[1 + variant % #SUFFIXES]
      end
      local classID, subClassID, equipLoc = Class(itemID)
      local itemLevel = 5 + itemID % 60
      local sellPrice = itemID % 7 == 0 and 0 or (itemID % 997) * 10 + 1
      return name,
        "|Hitem:" .. itemID .. "|h[" .. name .. "]|h",
        Quality(itemID),
        itemLevel,
        math.min(60, itemLevel),
        "Type",
        "Subtype",
        20,
        equipLoc,
        itemID,
        sellPrice,
        classID,
        subClassID,
        IsGear(itemID) and 2 or 0
    end,
    GetItemStats = function(link)
      local itemID, variant = ParseItem(link)
      if not itemID or not cached[itemID] then
        return nil
      end
      local stats = {}
      if IsGear(itemID) then
        local seed = itemID * 31 + (variant or 0)
        for index = 1, 2 + math.floor(Hash(seed) * 3) do
          stats[STATS[1 + math.floor(Hash(seed + index) * #STATS)]] = 1 + index
        end
      end
      return stats
    end,
    GetItemQualityColor = function(quality)
      return 1, 1, 1, quality == 0 and "ff9d9d9d" or "ffffffff"
    end,
    GetItemIconByID = function(itemID)
      return itemID
    end,
    GetItemClassInfo = function(classID)
      return "Class " .. classID
    end,
    GetItemSubClassInfo = function(classID, subClassID)
      return "Subclass " .. classID .. ":" .. subClassID
    end,
  }

  -- Auctions of items that haven't loaded come without quality or link, as the game sends them.
  C_AuctionHouse = {
    IsThrottledMessageSystemReady = function()
      return true
    end,
    ReplicateItems = Noop,
    SendBrowseQuery = Noop,
    SendSearchQuery = Noop,
    SendSellSearchQuery = Noop,
    SearchForFavorites = Noop,
    RequestMoreBrowseResults = Noop,
    HasFullBrowseResults = function()
      return true
    end,
    GetBrowseResults = function()
      return client.browseResults
    end,
    GetItemKeyInfo = function(itemKey)
      return cached[itemKey.itemID] and { quality = Quality(itemKey.itemID) } or nil
    end,
    GetNumReplicateItems = function()
      return client.replicate.count
    end,
    GetReplicateItemInfo = function(index)
      local itemID, _, quantity, buyout = client.replicate.Get(index)
      local loaded = cached[itemID] == true
      return loaded and "Item" or nil,
        itemID,
        quantity,
        loaded and Quality(itemID) or -1,
        true,
        1,
        nil,
        0,
        0,
        buyout,
        0,
        false,
        nil,
        nil,
        nil,
        0,
        itemID,
        loaded
    end,
    GetReplicateItemLink = function(index)
      local itemID, variant = client.replicate.Get(index)
      if not cached[itemID] then
        return nil
      end
      if variant then
        return ("|cff1eff00|Hitem:%d::::::::1:1485:::1:%d|h[Item]|h|r"):format(itemID, variant)
      end
      return "|cff1eff00|Hitem:" .. itemID .. "|h[Item]|h|r"
    end,
  }

  return client
end

return Client

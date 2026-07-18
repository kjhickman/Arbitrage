local _, ns = ...

ns.Database = {}

local VERSION = 1

local function GetRealm()
  return Auctionator.State and Auctionator.State.CurrentRealm or GetRealmName()
end

function ns.Database.Init()
  AUCTIONATOR_MARKET_PRICE_DATABASE = AUCTIONATOR_MARKET_PRICE_DATABASE or {}
  AUCTIONATOR_MARKET_PRICE_DATABASE.__version = VERSION

  local realm = GetRealm()
  AUCTIONATOR_MARKET_PRICE_DATABASE[realm] = AUCTIONATOR_MARKET_PRICE_DATABASE[realm] or {}

  ns.db = AUCTIONATOR_MARKET_PRICE_DATABASE[realm]
end

function ns.Database.SaveScan(results, timestamp)
  ns.Database.Init()

  local count = 0
  for dbKey, marketValue in pairs(results) do
    local item = ns.db[dbKey]
    if item == nil then
      item = { scans = {} }
      ns.db[dbKey] = item
    end

    item.marketValue = marketValue
    item.timestamp = timestamp
    item.scans[timestamp] = marketValue
    count = count + 1
  end

  return count
end

function ns.Database.Count()
  ns.Database.Init()

  local count = 0
  for key in pairs(ns.db) do
    if key ~= "__version" then
      count = count + 1
    end
  end

  return count
end

function ns.Database.Get(dbKey)
  ns.Database.Init()
  return ns.db[tostring(dbKey)]
end

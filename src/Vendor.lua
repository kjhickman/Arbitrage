local _, ns = ...

ns.Vendor = {}

local frame = CreateFrame("Frame")

function ns.Vendor.CacheMerchantPrices()
  for index = 1, GetMerchantNumItems() do
    local itemID = GetMerchantItemID(index)
    local info = C_MerchantFrame.GetItemInfo(index)

    if type(info) == "table" then
      local price = info.price
      local stackCount = info.stackCount
      if
        type(price) == "number"
        and price > 0
        and price < math.huge
        and type(stackCount) == "number"
        and stackCount > 0
        and stackCount < math.huge
        and info.numAvailable == -1
        and info.isPurchasable
        and not info.hasExtendedCost
      then
        ns.Database.RecordVendorPrice(itemID, price / stackCount)
      end
    end
  end
end

function ns.Vendor.Register()
  frame:RegisterEvent("MERCHANT_SHOW")
  frame:RegisterEvent("MERCHANT_UPDATE")
  frame:SetScript("OnEvent", ns.Vendor.CacheMerchantPrices)
end

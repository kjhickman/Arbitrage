local originalLoadfile = loadfile
local assert = require("luassert")

return function()
  local environment = setmetatable({}, { __index = _G })
  environment._G = environment
  environment.assert = assert
  environment.C_Item = {
    IsItemDataCachedByID = function()
      return false
    end,
  }
  -- Profiling reads the clock wherever work starts and stops; specs that time work replace it.
  environment.debugprofilestop = function()
    return 0
  end

  function environment.loadfile(path)
    local chunk, message = originalLoadfile(path)
    if chunk then
      setfenv(chunk, environment)
    end
    return chunk, message
  end

  return environment
end

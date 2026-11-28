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

  -- Makes CreateFrame give frames that only hear events, for a file that keeps one for that, and
  -- returns Fire, which sends the file an event it registered for.
  function environment.FakeEventFrames()
    local registered, onEvent = {}, nil
    function environment.CreateFrame()
      return {
        RegisterEvent = function(_, eventName)
          registered[eventName] = true
        end,
        SetScript = function(_, _, callback)
          onEvent = callback
        end,
      }
    end
    return function(eventName, ...)
      assert(registered[eventName], "listens for " .. eventName)
      onEvent(nil, eventName, ...)
    end
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

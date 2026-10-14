local NewEnvironment = dofile("tests/support/Environment.lua")

describe("test environments", function()
  it("isolates mocks without replacing runner globals", function()
    local originalPrint = _G.print
    local first = NewEnvironment()
    local second = NewEnvironment()
    first.print = function() end
    first.SlashCmdList = {}

    assert.are.equal(first, first._G)
    assert.are.equal(second, second._G)
    assert.are.equal(originalPrint, second.print)
    assert.are.equal(originalPrint, _G.print)
    assert.are_not.equal(first.SlashCmdList, second.SlashCmdList)
  end)

  it("binds loaded chunks to the mock environment", function()
    local environment = NewEnvironment()
    local chunk = assert(environment.loadfile("src/Keys.lua"))

    assert.are.equal(environment, getfenv(chunk))
  end)

  it("isolates libraries registered through _G", function()
    local originalLibStub = _G.LibStub
    local first = NewEnvironment()
    local second = NewEnvironment()

    assert(first.loadfile("libs/LibAHTab/LibStub/LibStub.lua"))()
    assert(second.loadfile("libs/LibAHTab/LibStub/LibStub.lua"))()

    assert.is_table(first.LibStub)
    assert.is_table(second.LibStub)
    assert.are_not.equal(first.LibStub, second.LibStub)
    assert.are.equal(originalLibStub, _G.LibStub)
  end)

  it("returns load errors unchanged", function()
    local environment = NewEnvironment()
    local chunk, message = environment.loadfile("tests/support/Missing.lua")

    assert.is_nil(chunk)
    assert.is_string(message)
  end)
end)

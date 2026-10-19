--[[
    ImageLib Loader
    Loads ImageLib once. Running this again does nothing and just returns
    the library that is already loaded.

    Usage:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/YetYoursTruly/Lucide/main/Loader.lua"))()

        local icon = FetchImage("minimize-2")
]]

local MAIN_URL = "https://raw.githubusercontent.com/YetYoursTruly/Lucide/main/ImageLib.lua"

local env = _G

if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)

    if ok and type(result) == "table" then
        env = result
    end
end

-- Already loaded: nothing to do.
if env.ImageLibLoaded and env.ImageLib then
    return env.ImageLib
end

-- Another script is loading it right now: wait for it.
if env.ImageLibLoading then
    local waited = 0

    while env.ImageLibLoading and waited < 15 do
        task.wait(0.1)
        waited = waited + 0.1
    end

    return env.ImageLib
end

env.ImageLibLoading = true

local ok, result = pcall(function()
    local source = game:HttpGet(MAIN_URL)
    local chunk, compileError = loadstring(source)

    assert(chunk, compileError)

    return chunk()
end)

env.ImageLibLoading = nil

if not ok then
    warn("[ImageLib Loader] Failed to load: " .. tostring(result))
    return nil
end

env.ImageLibLoaded = true

return env.ImageLib
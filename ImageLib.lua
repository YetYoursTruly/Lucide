--[[
    ImageLib
    Image library loader for the Lucide repo.

    Functions (also exposed globally):
      FetchImage(name)            -> rbxasset:// string you can put in any Image property
      DownloadImage(name)         -> local file path (downloads once, cached on disk)
      ImportImage(name, location) -> ImageLabel created inside `location`
                                     (if `location` is already an ImageLabel/ImageButton,
                                      its Image is set instead)

    Extras:
      ImageLib.Search(query, limit) -> list of matching image paths
      ImageLib.List()               -> list of every image path in the repo
      ImageLib.Refresh()            -> re-reads the repo file list

    `name` can be a bare name ("minimize-2"), a filename ("minimize-2.png"),
    or a sub-path ("arrows/arrow-up.png"). Matching is case-insensitive and
    searches every folder inside the repo's Images folder.

    All functions yield while downloading. Each returns nil, errorMessage on failure.
]]

local HttpService = game:GetService("HttpService")

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
    Owner = "YetYoursTruly",
    Repo = "Lucide",
    Branch = "main",
    Folder = "Images",

    CacheFolder = "ImageLib",
    IndexTTL = 6 * 60 * 60, -- seconds before the repo file list is re-fetched

    Extensions = { png = true, jpg = true, jpeg = true },
}

--==================================================
-- EXECUTOR ENVIRONMENT
--==================================================

local env = _G

if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)

    if ok and type(result) == "table" then
        env = result
    end
end

local requestFn = env.request
    or env.http_request
    or (type(env.syn) == "table" and env.syn.request)
    or nil

local isfile = env.isfile
local readfile = env.readfile
local writefile = env.writefile
local makefolder = env.makefolder
local isfolder = env.isfolder
local getAsset = env.getcustomasset or env.getsynasset

local CACHE = CONFIG.CacheFolder
local INDEX_FILE = CACHE .. "/index.json"

local ImageLib = { Version = "1.0" }

local function log(fmt, ...)
    warn("[ImageLib] " .. string.format(fmt, ...))
end

--==================================================
-- HELPERS
--==================================================

local function httpGet(url, headers)
    if type(requestFn) ~= "function" then
        return nil, "executor has no request function"
    end

    local ok, response = pcall(requestFn, {
        Url = url,
        Method = "GET",
        Headers = headers,
    })

    if not ok then
        return nil, tostring(response)
    end

    if type(response) ~= "table" then
        return nil, "no response"
    end

    if response.StatusCode ~= 200 then
        return nil, "HTTP " .. tostring(response.StatusCode)
    end

    local body = response.Body or response.body

    if type(body) ~= "string" or #body == 0 then
        return nil, "empty body"
    end

    return body
end

local function encodePath(path)
    return (string.gsub(path, "[^%w%-_%.~/]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function rawUrl(rel)
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s/%s",
        CONFIG.Owner,
        CONFIG.Repo,
        CONFIG.Branch,
        CONFIG.Folder,
        encodePath(rel)
    )
end

local function localPathFor(rel)
    -- Flat file names avoid nested-folder problems on mobile executors.
    return CACHE .. "/" .. (string.gsub(rel, "/", "__"))
end

local function ensureFolder()
    if type(makefolder) ~= "function" then
        return
    end

    local exists = false

    if type(isfolder) == "function" then
        local ok, value = pcall(isfolder, CACHE)
        exists = ok and value == true
    end

    if not exists then
        pcall(makefolder, CACHE)
    end
end

--==================================================
-- INDEX (every image under Images/, all subfolders)
--==================================================

local index = nil
local indexLoading = false

local function buildIndex(paths)
    local result = {
        paths = {},
        byPath = {},
        byName = {},
    }

    for _, path in ipairs(paths) do
        local lower = string.lower(path)
        local ext = string.match(lower, "%.(%w+)$")

        if ext and CONFIG.Extensions[ext] then
            local noext = string.sub(lower, 1, #lower - #ext - 1)
            local base = string.match(noext, "([^/]+)$")

            table.insert(result.paths, path)

            result.byPath[lower] = path
            result.byPath[noext] = result.byPath[noext] or path
            result.byName[base] = result.byName[base] or path
        end
    end

    return result
end

local function readDiskIndex()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        return nil
    end

    local ok, raw = pcall(function()
        if isfile(INDEX_FILE) then
            return readfile(INDEX_FILE)
        end
    end)

    if not ok or type(raw) ~= "string" then
        return nil
    end

    local decoded, data = pcall(function()
        return HttpService:JSONDecode(raw)
    end)

    if decoded
        and type(data) == "table"
        and type(data.time) == "number"
        and type(data.paths) == "table" then
        return data
    end

    return nil
end

local function writeDiskIndex(paths)
    if type(writefile) ~= "function" then
        return
    end

    pcall(function()
        ensureFolder()
        writefile(INDEX_FILE, HttpService:JSONEncode({
            time = os.time(),
            paths = paths,
        }))
    end)
end

local function fetchRemoteIndex()
    local url = string.format(
        "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
        CONFIG.Owner,
        CONFIG.Repo,
        CONFIG.Branch
    )

    local body, err = httpGet(url, {
        ["User-Agent"] = "ImageLib",
        ["Accept"] = "application/vnd.github+json",
    })

    if not body then
        return nil, err
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(body)
    end)

    if not ok or type(data) ~= "table" or type(data.tree) ~= "table" then
        return nil, "bad response from GitHub API"
    end

    if data.truncated then
        log("Repo is very large, GitHub truncated the file list")
    end

    local prefix = CONFIG.Folder .. "/"
    local paths = {}

    for _, item in ipairs(data.tree) do
        if item.type == "blob"
            and type(item.path) == "string"
            and string.sub(item.path, 1, #prefix) == prefix then
            table.insert(paths, string.sub(item.path, #prefix + 1))
        end
    end

    return paths
end

local function getIndex(force)
    if index and not force then
        return index
    end

    while indexLoading do
        task.wait()
    end

    if index and not force then
        return index
    end

    indexLoading = true

    local ok, result = pcall(function()
        local disk = readDiskIndex()

        if disk and not force and os.time() - disk.time < CONFIG.IndexTTL then
            return buildIndex(disk.paths)
        end

        local paths, err = fetchRemoteIndex()

        if paths then
            writeDiskIndex(paths)
            return buildIndex(paths)
        end

        if disk then
            log("Could not refresh image list (%s), using saved copy", tostring(err))
            return buildIndex(disk.paths)
        end

        error(tostring(err), 0)
    end)

    indexLoading = false

    if ok then
        index = result
        return index
    end

    log("Could not load image list: %s", tostring(result))
    return nil
end

--==================================================
-- NAME RESOLVING
--==================================================

local function resolve(name)
    if type(name) ~= "string" or name == "" then
        return nil, "invalid image name"
    end

    local key = string.lower(name)
    key = string.gsub(key, "\\", "/")
    key = string.gsub(key, "^/+", "")

    local folderPrefix = string.lower(CONFIG.Folder) .. "/"

    if string.sub(key, 1, #folderPrefix) == folderPrefix then
        key = string.sub(key, #folderPrefix + 1)
    end

    local noext = key
    local ext = string.match(key, "%.(%w+)$")

    if ext and CONFIG.Extensions[ext] then
        noext = string.sub(key, 1, #key - #ext - 1)
    end

    local idx = getIndex()

    if idx then
        local rel = idx.byPath[key] or idx.byPath[noext] or idx.byName[noext]

        if rel then
            return rel
        end

        return nil, string.format('image "%s" not found', name)
    end

    -- No index available: guess the direct path.
    local guess = string.gsub(name, "\\", "/")
    guess = string.gsub(guess, "^/+", "")

    local guessExt = string.match(string.lower(guess), "%.(%w+)$")

    if not (guessExt and CONFIG.Extensions[guessExt]) then
        guess = guess .. ".png"
    end

    return guess
end

--==================================================
-- DOWNLOAD / FETCH / IMPORT
--==================================================

local inflight = {}
local validFiles = {}
local assets = {}

function ImageLib.DownloadImage(name)
    if type(isfile) ~= "function"
        or type(readfile) ~= "function"
        or type(writefile) ~= "function" then
        return nil, "executor is missing file functions"
    end

    local rel, err = resolve(name)

    if not rel then
        log("%s", tostring(err))
        return nil, err
    end

    local path = localPathFor(rel)

    while inflight[rel] do
        task.wait()
    end

    if validFiles[rel] then
        return path, rel
    end

    local okCache, cached = pcall(function()
        return isfile(path) and #readfile(path) > 0
    end)

    if okCache and cached then
        validFiles[rel] = true
        return path, rel
    end

    inflight[rel] = true

    local ok, result = pcall(function()
        ensureFolder()

        local body, httpErr = httpGet(rawUrl(rel))

        if not body then
            error(tostring(httpErr), 0)
        end

        writefile(path, body)
    end)

    inflight[rel] = nil

    if not ok then
        log("Download failed for %s: %s", rel, tostring(result))
        return nil, tostring(result)
    end

    validFiles[rel] = true
    return path, rel
end

function ImageLib.FetchImage(name)
    if type(getAsset) ~= "function" then
        return nil, "executor has no getcustomasset"
    end

    local path, second = ImageLib.DownloadImage(name)

    if not path then
        return nil, second
    end

    local rel = second

    if assets[rel] then
        return assets[rel]
    end

    local ok, asset = pcall(getAsset, path)

    if not ok or not asset then
        log("getcustomasset failed for %s: %s", rel, tostring(asset))
        return nil, tostring(asset)
    end

    assets[rel] = asset
    return asset
end

function ImageLib.ImportImage(name, location)
    if typeof(location) ~= "Instance" then
        return nil, "ImportImage needs an Instance as the location"
    end

    local asset, err = ImageLib.FetchImage(name)

    if not asset then
        return nil, err
    end

    if location:IsA("ImageLabel") or location:IsA("ImageButton") then
        location.Image = asset
        return location
    end

    local image = Instance.new("ImageLabel")
    image.Name = tostring(name)
    image.BackgroundTransparency = 1
    image.BorderSizePixel = 0
    image.Size = UDim2.fromScale(1, 1)
    image.ScaleType = Enum.ScaleType.Fit
    image.Image = asset
    image.Parent = location

    return image
end

--==================================================
-- EXTRAS
--==================================================

function ImageLib.List()
    local idx = getIndex()

    if not idx then
        return {}
    end

    return table.clone(idx.paths)
end

function ImageLib.Search(query, limit)
    local results = {}
    local idx = getIndex()

    if not idx or type(query) ~= "string" then
        return results
    end

    query = string.lower(query)
    limit = limit or 25

    for _, path in ipairs(idx.paths) do
        if string.find(string.lower(path), query, 1, true) then
            table.insert(results, path)

            if #results >= limit then
                break
            end
        end
    end

    return results
end

function ImageLib.Refresh()
    return getIndex(true) ~= nil
end

--==================================================
-- EXPORT
--==================================================

if type(requestFn) ~= "function" then
    log("This executor has no request function, downloads will fail")
end

env.ImageLib = ImageLib
env.FetchImage = ImageLib.FetchImage
env.DownloadImage = ImageLib.DownloadImage
env.ImportImage = ImageLib.ImportImage

-- Load the file list in the background so the first FetchImage is fast.
task.spawn(getIndex)

return ImageLib
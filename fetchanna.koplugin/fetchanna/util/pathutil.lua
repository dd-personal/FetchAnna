local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local PathUtil = {}

local DATA_DIR = DataStorage:getDataDir()
local PLUGIN_NAME = "fetchanna.koplugin"
-- Plugins can live in several places (koreader/plugins, <data dir>/plugins, extra_plugin_paths), so the plugin root
-- comes from where this file was loaded, e.g. "@plugins/fetchanna.koplugin/fetchanna/util/pathutil.lua". The modules
-- are all in fetchanna/ so they don't clash in package.loaded with another plugin's of the same name, such as
-- KindleFetch's.
local LOADED_PLUGIN_PATH = debug.getinfo(1, "S").source:match("^@(.+)/fetchanna/util/pathutil%.lua$")

function PathUtil.getPluginPath()
    return LOADED_PLUGIN_PATH or DATA_DIR .. "/plugins/" .. PLUGIN_NAME
end

-- Scratch folder for downloads. Removed after a plugin update, so it must only hold our own files.
function PathUtil.getTmpPath()
    local cachePath = DATA_DIR .. "/cache"
    local tmpPath = cachePath .. "/fetchanna"
    lfs.mkdir(cachePath)
    lfs.mkdir(tmpPath)

    return tmpPath
end

return PathUtil

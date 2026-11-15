local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Device = require("device")
local FileUtil = require("fetchanna.util.fileutil")
local StringUtil = require("fetchanna.util.stringutil")
local LogUtil = require("fetchanna.util.logutil")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local FetchAnnaSettings = {}

local DEFAULTS = {
    show_book_covers = true,
    check_for_updates = true,
    -- DNS over HTTPS (see CurlUtil.applyEncryptedDns), for networks whose own DNS blocks the sites.
    encrypted_dns = false,
    search_cache_expiry_days = 14,
    download_dir = nil,
    -- The file types are set below.
    preferred_languages = { "en" },
    -- Whether the key and its sessions are kept when KOReader restarts, in a file of their own (see KeyStore). Off
    -- unless asked for, as anyone with the device could read it.
    remember_key = false,
}

local AVAILABLE_LANGUAGES = {
    {
        text = "English",
        code = "en",
    },
    {
        text = "Spanish",
        code = "es",
    },
    {
        text = "French",
        code = "fr",
    },
    {
        text = "German",
        code = "de",
    },
    {
        text = "Italian",
        code = "it",
    },
    {
        text = "Portuguese",
        code = "pt",
    },
    {
        text = "Russian",
        code = "ru",
    },
    {
        text = "Chinese",
        code = "zh",
    },
    {
        text = "Japanese",
        code = "ja",
    },
    {
        text = "Dutch",
        code = "nl",
    },
    {
        text = "Bulgarian",
        code = "bg",
    },
    {
        text = "Polish",
        code = "pl",
    },
    {
        text = "Arabic",
        code = "ar",
    },
    {
        text = "Latin",
        code = "la",
    },
    {
        text = "Hebrew",
        code = "he",
    },
    {
        text = "Traditional Chinese",
        code = "zh-Hant",
    },
    {
        text = "Turkish",
        code = "tr",
    },
    {
        text = "Hungarian",
        code = "hu",
    },
    {
        text = "Czech",
        code = "cs",
    },
    {
        text = "Swedish",
        code = "sv",
    },
    {
        text = "Danish",
        code = "da",
    },
    {
        text = "Korean",
        code = "ko",
    },
    {
        text = "Ukrainian",
        code = "uk",
    },
    {
        text = "Indonesian",
        code = "id",
    },
    {
        text = "Greek",
        code = "el",
    },
    {
        text = "Romanian",
        code = "ro",
    },
    {
        text = "Lithuanian",
        code = "lt",
    },
    {
        text = "Bangla",
        code = "bn",
    },
    {
        text = "Catalan",
        code = "ca",
    },
    {
        text = "Norwegian",
        code = "no",
    },
    {
        text = "Afrikaans",
        code = "af",
    },
    {
        text = "Finnish",
        code = "fi",
    },
    {
        text = "Croatian",
        code = "hr",
    },
    {
        text = "Serbian",
        code = "sr",
    },
    {
        text = "Thai",
        code = "th",
    },
    {
        text = "Hindi",
        code = "hi",
    },
    {
        text = "Irish",
        code = "ga",
    },
    {
        text = "Latvian",
        code = "lv",
    },
    {
        text = "Persian",
        code = "fa",
    },
    {
        text = "Vietnamese",
        code = "vi",
    },
    {
        text = "Slovak",
        code = "sk",
    },
    {
        text = "Kannada",
        code = "kn",
    },
    {
        text = "Tibetan",
        code = "bo",
    },
    {
        text = "Welsh",
        code = "cy",
    },
    {
        text = "Javanese",
        code = "jv",
    },
    {
        text = "Urdu",
        code = "ur",
    },
    {
        text = "Yiddish",
        code = "yi",
    },
    {
        text = "Armenian",
        code = "hy",
    },
    {
        text = "Belarusian",
        code = "be",
    },
    {
        text = "Kinyarwanda",
        code = "rw",
    },
    {
        text = "Tamil",
        code = "ta",
    },
    {
        text = "Kazakh",
        code = "kk",
    },
    {
        text = "Slovenian",
        code = "sl",
    },
    {
        text = "Malayalam",
        code = "ml",
    },
    {
        text = "Shan",
        code = "shn",
    },
    {
        text = "Mongolian",
        code = "mn",
    },
    {
        text = "Georgian",
        code = "ka",
    },
    {
        text = "Marathi",
        code = "mr",
    },
    {
        text = "Esperanto",
        code = "eo",
    },
    {
        text = "Estonian",
        code = "et",
    },
    {
        text = "Telugu",
        code = "te",
    },
    {
        text = "Filipino",
        code = "fil",
    },
    {
        text = "Gujarati",
        code = "gu",
    },
    {
        text = "Galician",
        code = "gl",
    },
    {
        text = "Kyrgyz",
        code = "ky",
    },
    {
        text = "Malay",
        code = "ms",
    },
    {
        text = "Azerbaijani",
        code = "az",
    },
    {
        text = "Swahili",
        code = "sw",
    },
    {
        text = "Quechua",
        code = "qu",
    },
    {
        text = "Punjabi",
        code = "pa",
    },
    {
        text = "Bashkir",
        code = "ba",
    },
    {
        text = "Albanian",
        code = "sq",
    },
    {
        text = "Uzbek",
        code = "uz",
    },
    {
        text = "Bosnian",
        code = "bs",
    },
    {
        text = "Basque",
        code = "eu",
    },
    {
        text = "Burmese",
        code = "my",
    },
    {
        text = "Amharic",
        code = "am",
    },
    {
        text = "Kurdish",
        code = "ku",
    },
    {
        text = "Western Frisian",
        code = "fy",
    },
    {
        text = "Zulu",
        code = "zu",
    },
    {
        text = "Pashto",
        code = "ps",
    },
    {
        text = "Nepali",
        code = "ne",
    },
    {
        text = "Somali",
        code = "so",
    },
    {
        text = "Uyghur",
        code = "ug",
    },
    {
        text = "Oromo",
        code = "om",
    },
    {
        text = "Macedonian",
        code = "mk",
    },
    {
        text = "Haitian Creole",
        code = "ht",
    },
    {
        text = "Lao",
        code = "lo",
    },
    {
        text = "Tatar",
        code = "tt",
    },
    {
        text = "Sinhala",
        code = "si",
    },
    {
        text = "Central Kurdish",
        code = "ckb",
    },
    {
        text = "Tajik",
        code = "tg",
    },
    {
        text = "Shona",
        code = "sn",
    },
    {
        text = "Sundanese",
        code = "su",
    },
    {
        text = "Norwegian Bokmål",
        code = "nb",
    },
    {
        text = "Malagasy",
        code = "mg",
    },
    {
        text = "Xhosa",
        code = "xh",
    },
    {
        text = "Hausa",
        code = "ha",
    },
    {
        text = "Sindhi",
        code = "sd",
    },
    {
        text = "Nyanja",
        code = "ny",
    },
}
-- The only file types searched for and downloaded: those KOReader's document providers open
-- (frontend/document/*document.lua, November 2026). Others Anna's Archive has, such as azw3, lit and lrf, are never
-- offered. Nor are any of these the installed KOReader can't open (see isOpenableFileType).
local EBOOK_FILE_TYPES = { "epub", "mobi", "azw", "fb2", "prc" }
local COMIC_FILE_TYPES = { "cbr", "cbz" }
local DOCUMENT_FILE_TYPES = { "pdf", "txt", "rtf", "doc", "docx", "odt", "djvu" }
local IMAGE_FILE_TYPES = { "jpg", "tif", "pdb" }
local WEB_FILE_TYPES = { "chm", "htm", "html", "htmlz" }
local AVAILABLE_FILE_TYPES = {}
for __, file_types in ipairs({
    EBOOK_FILE_TYPES,
    COMIC_FILE_TYPES,
    DOCUMENT_FILE_TYPES,
    IMAGE_FILE_TYPES,
    WEB_FILE_TYPES,
}) do
    for __, file_type in ipairs(file_types) do
        table.insert(AVAILABLE_FILE_TYPES, file_type)
    end
end
-- The default: epub only, which KOReader reads best.
DEFAULTS.preferred_file_types = { "epub" }
-- KindleFetch's default was every file type, saved when the settings were first filled in (see load). Found saved,
-- it's taken as that default rather than a choice, once (see FILE_TYPES_DEFAULT).
local OLD_DEFAULT_FILE_TYPES = AVAILABLE_FILE_TYPES
-- Saved once the old default has been looked for, so that choosing every file type afterwards is kept.
local FILE_TYPES_DEFAULT = 2

-- How long searches can be cached for.
local AVAILABLE_CACHE_EXPIRY_DAYS = { 1, 3, 7, 14, 30 }

local function settingsPath()
    return DataStorage:getSettingsDir() .. "/fetchanna_settings.lua"
end

-- Opened once and kept, as reading the file for every setting is slow.
local cached_file
local function getSettingsFile()
    if not cached_file then
        cached_file = LuaSettings:open(settingsPath())
    end
    return cached_file
end

local function sameSetting(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    if #a ~= #b then
        return false
    end
    for i, value in ipairs(a) do
        if value ~= b[i] then
            return false
        end
    end
    return true
end

-- Whether two lists hold the same things, in any order.
local function sameSet(a, b)
    if #a ~= #b then
        return false
    end
    local in_b = {}
    for __, value in ipairs(b) do
        in_b[value] = true
    end
    for __, value in ipairs(a) do
        if not in_b[value] then
            return false
        end
    end
    return true
end

-- Fills in the settings that aren't saved. Runs whenever the file manager or a book opens, so it only writes when
-- something changed.
function FetchAnnaSettings:load()
    local settings_file = getSettingsFile()
    local changed = false
    local function fill(name, value)
        if not sameSetting(settings_file:readSetting(name), value) then
            settings_file:saveSetting(name, value)
            changed = true
        end
    end

    -- A missing folder is kept, as it may be back, e.g. on an SD card.
    if not StringUtil.assertValidString(settings_file:readSetting("download_dir")) then
        local download_dir = self:getDownloadDir()
        if FileUtil.isValidDirectory(download_dir) then
            fill("download_dir", download_dir)
        end
    end
    fill("show_book_covers", self:getShowBookCovers())
    fill("check_for_updates", self:getCheckForUpdates())
    fill("search_cache_expiry_days", self:getSearchCacheExpiryDays())
    fill("preferred_languages", self:getPreferredLanguages())
    -- KindleFetch's saved default, every file type, goes back to epub only, once.
    if settings_file:readSetting("file_types_default") ~= FILE_TYPES_DEFAULT then
        local saved = settings_file:readSetting("preferred_file_types")
        if type(saved) == "table" and sameSet(saved, OLD_DEFAULT_FILE_TYPES) then
            LogUtil.info("choosing epub only, in place of every file type, the default before")
            settings_file:delSetting("preferred_file_types")
        end
        settings_file:saveSetting("file_types_default", FILE_TYPES_DEFAULT)
        changed = true
    end
    fill("preferred_file_types", self:getPreferredFileTypes())

    if changed then
        settings_file:flush()
        LogUtil.debug("saved the settings that were missing or out of date")
    end
end

-- The types of the settings that have no default.
local TYPES = {
    last_version = "string",
    last_update_check = "number",
    skipped_version = "string",
    recent_searches = "table",
}

-- Returns only the strings in a list.
local function strings(list)
    local kept = {}
    for __, value in ipairs(list) do
        if type(value) == "string" then
            table.insert(kept, value)
        end
    end
    return kept
end

-- Returns a setting, or its default when it isn't saved or has the wrong type (e.g. edited by hand), which could
-- fail as KOReader starts and leave the plugin out of the menu.
function FetchAnnaSettings:getSetting(name)
    local settings_file = getSettingsFile()
    local value = settings_file:readSetting(name)

    if value == nil then
        return DEFAULTS[name]
    end

    local expected = DEFAULTS[name] ~= nil and type(DEFAULTS[name]) or TYPES[name]
    if expected and type(value) ~= expected then
        LogUtil.warn("ignoring", name, "as it's saved as a", type(value), "rather than a", expected)
        return DEFAULTS[name]
    end
    -- The lists of languages, file types, book types and searches.
    if expected == "table" then
        return strings(value)
    end

    return value
end
-- Writes the settings. Returns true, or nil and why not. LuaSettings doesn't say when a write failed (e.g. full or
-- read-only storage), so the file is read back to tell.
local function flush(settings_file, name, data)
    settings_file:flush()
    if not sameSetting(LuaSettings:open(settingsPath()):readSetting(name), data) then
        LogUtil.warn("could not save", name, "in", settingsPath())
        return nil, _("FetchAnna's settings couldn't be saved")
    end
    return true
end

function FetchAnnaSettings:setSetting(name, data)
    local settings_file = getSettingsFile()
    settings_file:saveSetting(name, data)
    local ok, err = flush(settings_file, name, data)
    if not ok then
        return nil, err
    end

    if type(data) ~= "table" then
        LogUtil.debug("updated", name, "to", data)
    else
        LogUtil.debug("updated", name, "to", table.concat(data, ", "))
    end

    return true
end

function FetchAnnaSettings:getShowBookCovers()
    return FetchAnnaSettings:getSetting("show_book_covers")
end
function FetchAnnaSettings:setShowBookCovers(bool)
    return FetchAnnaSettings:setSetting("show_book_covers", bool)
end

function FetchAnnaSettings:getEncryptedDns()
    return FetchAnnaSettings:getSetting("encrypted_dns")
end
function FetchAnnaSettings:setEncryptedDns(bool)
    return FetchAnnaSettings:setSetting("encrypted_dns", bool)
end

-- check_for_updates: automatically, once per session.
function FetchAnnaSettings:getCheckForUpdates()
    return FetchAnnaSettings:getSetting("check_for_updates")
end
function FetchAnnaSettings:setCheckForUpdates(bool)
    return FetchAnnaSettings:setSetting("check_for_updates", bool)
end

function FetchAnnaSettings:getSearchCacheExpiryDays()
    return FetchAnnaSettings:getSetting("search_cache_expiry_days")
end
function FetchAnnaSettings:setSearchCacheExpiryDays(days)
    return FetchAnnaSettings:setSetting("search_cache_expiry_days", days)
end
function FetchAnnaSettings:getAvailableCacheExpiryDays()
    return AVAILABLE_CACHE_EXPIRY_DAYS
end

-- last_version: the plugin version when KOReader last started.
function FetchAnnaSettings:getLastVersion()
    return FetchAnnaSettings:getSetting("last_version")
end
function FetchAnnaSettings:setLastVersion(version)
    return FetchAnnaSettings:setSetting("last_version", version)
end

-- last_update_check: when the latest release was last looked up, in seconds.
function FetchAnnaSettings:getLastUpdateCheck()
    return FetchAnnaSettings:getSetting("last_update_check")
end
function FetchAnnaSettings:setLastUpdateCheck(time)
    return FetchAnnaSettings:setSetting("last_update_check", time)
end

-- skipped_version: the update that was turned down, so it isn't offered again automatically.
function FetchAnnaSettings:getSkippedVersion()
    return FetchAnnaSettings:getSetting("skipped_version")
end
function FetchAnnaSettings:setSkippedVersion(version)
    return FetchAnnaSettings:setSetting("skipped_version", version)
end

-- curl_update_declined: the curl version whose update was turned down, so it isn't offered again until there's a
-- newer one. Older versions saved true.
function FetchAnnaSettings:getCurlUpdateDeclined()
    local declined = getSettingsFile():readSetting("curl_update_declined")
    if declined == true or type(declined) == "string" then
        return declined
    end
end
-- nil once curl has been updated.
function FetchAnnaSettings:setCurlUpdateDeclined(version)
    return FetchAnnaSettings:setSetting("curl_update_declined", version or nil)
end

-- recent_searches: most recent first.
local MAX_RECENT_SEARCHES = 10
function FetchAnnaSettings:getRecentSearches()
    return FetchAnnaSettings:getSetting("recent_searches") or {}
end
-- Once each, whatever its capitals, as Library Genesis finds the same books either way.
function FetchAnnaSettings:addRecentSearch(query)
    local searches = { query }
    for __, search in ipairs(self:getRecentSearches()) do
        if search:lower() ~= query:lower() and #searches < MAX_RECENT_SEARCHES then
            table.insert(searches, search)
        end
    end
    return FetchAnnaSettings:setSetting("recent_searches", searches)
end
function FetchAnnaSettings:clearRecentSearches()
    return FetchAnnaSettings:setSetting("recent_searches", {})
end

-- remember_key (see KeyStore).
function FetchAnnaSettings:getRememberKey()
    return FetchAnnaSettings:getSetting("remember_key")
end
function FetchAnnaSettings:setRememberKey(bool)
    return FetchAnnaSettings:setSetting("remember_key", bool)
end

-- mirror_trust: when each site was approved to be sent the key, or revoked, by origin (see AnnasMirrors). Anything
-- else, e.g. edited by hand, is left out rather than taken to approve anything.
function FetchAnnaSettings:getMirrorTrust()
    local saved = FetchAnnaSettings:getSetting("mirror_trust")
    local trust = {}
    if type(saved) ~= "table" then
        return trust
    end
    for origin, decision in pairs(saved) do
        if type(origin) == "string" and type(decision) == "table" then
            local approved_at, revoked_at = decision.approved_at, decision.revoked_at
            if type(revoked_at) == "number" then
                trust[origin] = { revoked_at = revoked_at }
            elseif type(approved_at) == "number" then
                trust[origin] = { approved_at = approved_at }
            end
        end
    end
    return trust
end
-- An empty table forgets every decision.
function FetchAnnaSettings:setMirrorTrust(trust)
    return FetchAnnaSettings:setSetting("mirror_trust", trust)
end

-- download_dir, or the default while the saved folder can't be found. The saved one is kept, as it may be back.
function FetchAnnaSettings:getDownloadDir()
    local settings_file = getSettingsFile()
    local download_dir = settings_file:readSetting("download_dir")
    if StringUtil.assertValidString(download_dir) and not FileUtil.isValidDirectory(download_dir) then
        LogUtil.warn("the download folder", download_dir, "can't be found, so downloading to the default for now")
        download_dir = nil
    end

    if not StringUtil.assertValidString(download_dir) then
        download_dir = G_reader_settings:readSetting("home_dir") or ""

        if download_dir == "" then
            download_dir = "/mnt/us/documents"
            LogUtil.warn("settings home directory not found, defaulting to", download_dir)
        end

        if not FileUtil.isValidDirectory(download_dir) then
            -- home_dir is nil on some devices, so fall back to the koreader dir.
            download_dir = Device.home_dir or lfs.currentdir()
            LogUtil.warn("documents directory does not exist, defaulting to device home directory", download_dir)
        end
    end

    return download_dir
end
-- Returns true, or nil and why books can't be saved there (see FileUtil.checkWritableDir).
function FetchAnnaSettings:setDownloadDir(path)
    local ok, err = FileUtil.checkWritableDir(path)
    if not ok then
        LogUtil.warn("not downloading to", path, "as", err)
        return nil, err
    end

    local settings_file = getSettingsFile()
    settings_file:saveSetting("download_dir", path)
    local saved, save_err = flush(settings_file, "download_dir", path)
    if not saved then
        return nil, save_err
    end
    LogUtil.debug("download directory set to", path)
    return true
end

function FetchAnnaSettings:getPreferredLanguages()
    return FetchAnnaSettings:getSetting("preferred_languages")
end
function FetchAnnaSettings:setPreferredLanguages(languages)
    return FetchAnnaSettings:setSetting("preferred_languages", languages)
end
function FetchAnnaSettings:getAvailableLanguages()
    return AVAILABLE_LANGUAGES
end

-- Whether a file type (e.g. "epub") is offered (see EBOOK_FILE_TYPES) and the installed KOReader's document
-- registry can open it. Where that can't be asked, the list is taken as it is. Only these are ever searched for or
-- downloaded.
local openable = {}
function FetchAnnaSettings:isOpenableFileType(file_type)
    if type(file_type) ~= "string" then
        return false
    end
    file_type = file_type:lower()
    if openable[file_type] == nil then
        local offered = false
        for __, available in ipairs(AVAILABLE_FILE_TYPES) do
            if available == file_type then
                offered = true
            end
        end
        local loaded, DocumentRegistry = pcall(require, "document/documentregistry")
        if offered and loaded and type(DocumentRegistry) == "table" and DocumentRegistry.hasProvider then
            local asked, has_provider = pcall(DocumentRegistry.hasProvider, DocumentRegistry, "book." .. file_type)
            offered = not asked or has_provider == true
        end
        openable[file_type] = offered
    end
    return openable[file_type]
end

-- Returns the file types that are offered and KOReader can open (see isOpenableFileType), in a new list.
local function openableOnly(file_types)
    local kept = {}
    for __, file_type in ipairs(file_types) do
        if FetchAnnaSettings:isOpenableFileType(file_type) then
            table.insert(kept, file_type)
        end
    end
    return kept
end

-- preferred_file_types: only those still offered, e.g. without azw3.
function FetchAnnaSettings:getPreferredFileTypes()
    local saved = FetchAnnaSettings:getSetting("preferred_file_types")
    local file_types = openableOnly(saved)

    -- None of those chosen are offered any more, which isn't the same as all being turned off.
    if #file_types == 0 and #saved > 0 then
        return openableOnly(DEFAULTS.preferred_file_types)
    end
    return file_types
end
function FetchAnnaSettings:setPreferredFileTypes(file_types)
    return FetchAnnaSettings:setSetting("preferred_file_types", openableOnly(file_types))
end
function FetchAnnaSettings:getEbookFileTypes()
    return openableOnly(EBOOK_FILE_TYPES)
end
function FetchAnnaSettings:getComicFileTypes()
    return openableOnly(COMIC_FILE_TYPES)
end
function FetchAnnaSettings:getDocumentFileTypes()
    return openableOnly(DOCUMENT_FILE_TYPES)
end
function FetchAnnaSettings:getImageFileTypes()
    return openableOnly(IMAGE_FILE_TYPES)
end
function FetchAnnaSettings:getWebFileTypes()
    return openableOnly(WEB_FILE_TYPES)
end

return FetchAnnaSettings

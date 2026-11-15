local md5 = require("ffi/sha2").md5
local LogUtil = require("fetchanna.util.logutil")

-- Tells a book or cover from what a site can send in its place, such as a web page saying it's busy, by how the file
-- starts. Also works out a file's md5.
local FileCheck = {}

-- Bytes read from a file's start: enough for a PDF's header, which can come after other bytes.
local HEAD_SIZE = 1024
-- Bytes read at a time while working out an md5 (see Md5:step).
local MD5_CHUNK_SIZE = 1024 * 1024

-- How files of each type can start. Types that can start any way are only checked for not being a web page.
local ZIP = "PK\3\4"
local STARTS = {
    epub = { ZIP },
    cbz = { ZIP },
    docx = { ZIP },
    odt = { ZIP },
    htmlz = { ZIP },
    -- Or zipped.
    fb2 = { "<?xml", "<FictionBook", ZIP },
    djvu = { "AT&TFORM" },
    -- Many are zipped, or 7-Zip archives, whatever they're named.
    cbr = { "Rar!", ZIP, "7z\188\175\39\28" },
    rtf = { "{\\rtf" },
    chm = { "ITSF" },
    jpg = { "\255\216\255" },
    tif = { "II*\0", "MM\0*" },
}
-- Palm databases of Mobipocket and PalmDOC books, which say so after their names.
local PALM_TYPES = { mobi = true, azw = true, azw3 = true, prc = true }
-- How a web page starts, as opposed to e.g. an FB2 book, which is XML too.
local WEB_PAGE_STARTS = { "<!doctype html", "<html", "<head", "<body", "<script", "<meta", "<title" }

-- Returns the first bytes of the file at path, or nil if it can't be read.
function FileCheck.head(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local head = f:read(HEAD_SIZE)
    f:close()
    return head or ""
end

-- Returns head without a UTF-8 byte order mark or leading whitespace.
local function text(head)
    return (head:gsub("^\239\187\191", ""):gsub("^%s+", ""))
end

local function startsWith(s, start)
    return s:sub(1, #start) == start
end

-- Whether a file starting with head is a web page or JSON, which sites send in place of a file, e.g. when busy or a
-- link has expired.
function FileCheck.isWebPage(head)
    local start = text(head)
    local lower = start:lower()
    for __, page_start in ipairs(WEB_PAGE_STARTS) do
        if startsWith(lower, page_start) then
            return true
        end
    end
    -- A web page written as XML.
    if startsWith(lower, "<?xml") and (lower:find("<!doctype html", 1, true) or lower:find("<html", 1, true)) then
        return true
    end
    -- A JSON object or list, not e.g. a text book that starts with [Illustration].
    return start:find('^{%s*["}]') ~= nil or start:find('^%[%s*[{"%]]') ~= nil
end

-- Whether a file starting with head is of file_type, or nil when that type can start any way.
function FileCheck.isFileType(head, file_type)
    if file_type == "pdf" then
        -- Some have other bytes before it.
        return head:find("%PDF-", 1, true) ~= nil
    end
    if PALM_TYPES[file_type] then
        local palm_type = head:sub(61, 68)
        return palm_type == "BOOKMOBI" or palm_type == "TEXtREAd"
    end
    local starts = STARTS[file_type]
    if not starts then
        return nil
    end
    local start = text(head)
    for __, file_start in ipairs(starts) do
        if startsWith(head, file_start) or startsWith(start, file_start) then
            return true
        end
    end
    return false
end

-- Whether a file starting with head is an image, as covers are: JPEG, PNG, GIF or WebP.
function FileCheck.isImage(head)
    return startsWith(head, "\255\216\255")
        or startsWith(head, "\137PNG\r\n\26\n")
        or startsWith(head, "GIF8")
        or startsWith(head, "RIFF") and head:sub(9, 12) == "WEBP"
end

-- Returns the title of a web page starting with head, or nil if it has none.
function FileCheck.pageTitle(head)
    local title = head:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>([^<]*)")
    title = title and title:gsub("%s+", " "):match("^ ?(.-) ?$")
    return title ~= "" and title or nil
end

-- Returns what's wrong with the book downloaded to path: "web page" or "file type", then what it starts with, for the
-- log. Returns nil when nothing is.
function FileCheck.problem(path, file_type)
    local head = FileCheck.head(path)
    if not head then
        -- A file that can't be read isn't this check's to report.
        return nil
    end
    local function shown()
        return FileCheck.pageTitle(head) or head:sub(1, 80):gsub("[^%w%p ]", "?")
    end
    -- Unless a web page is what was asked for.
    if file_type ~= "htm" and file_type ~= "html" and FileCheck.isWebPage(head) then
        return "web page", shown()
    end
    if FileCheck.isFileType(head, file_type) == false then
        return "file type", shown()
    end
end

-- Works out a file's md5 a piece at a time, as a large book takes a while.
local Md5 = {}
Md5.__index = Md5

-- Reads the next piece. Returns the md5 (lower case) once the whole file is read, nil before that, or false and why if
-- it can't be read.
function Md5:step()
    local chunk, err = self.file:read(MD5_CHUNK_SIZE)
    if chunk then
        self.append(chunk)
        return nil
    end
    self:close()
    if err then
        return false, err
    end
    return self.append():lower()
end

-- Stops reading the file, e.g. when called off.
function Md5:close()
    if io.type(self.file) == "file" then
        self.file:close()
    end
end

-- Returns an Md5 for the file at path (see Md5:step), or nil and why not if it can't be read.
function FileCheck.md5(path)
    local file, err = io.open(path, "rb")
    if not file then
        LogUtil.warn("could not read", path, "to check it:", err)
        return nil, err
    end
    return setmetatable({ file = file, append = md5() }, Md5)
end

return FileCheck

-- Stand-ins for the web and the files that arrive from it.

local fixtures = {}

-- Serves pages from web.pages so specs contact no site, unless web.live is set. A page is html, or a function of the
-- request's options (see HttpUtil.getBody) returning html and the status or error. web.fetched keeps each URL asked
-- for, web.requests each request's form and cookies too.
function fixtures.fakeWeb(helper)
    local web = {
        pages = {},
        fetched = {},
        requests = {},
    }
    helper.useLiveHttp()
    local HttpUtil = require("fetchanna.util.httputil")
    local fetchLive = HttpUtil.getBody
    HttpUtil.getBody = function(url, opts)
        table.insert(web.fetched, url)
        table.insert(web.requests, { url = url, form = opts and opts.form, cookies = opts and opts.cookies })
        if web.live then
            return fetchLive(url, opts)
        end
        local page, err, status = web.pages[url], nil, nil
        if type(page) == "function" then
            page, err, status = page(opts or {})
        end
        if page or err then
            return page, err, status
        end
        return nil, "failed to connect to server"
    end
    return web
end

-- A stand-in cover, starting as a JPEG does (see FileCheck).
fixtures.JPEG = "\255\216\255\224jpeg"

-- How a few file types start (see FileCheck).
local BOOK_STARTS = {
    epub = "PK\3\4",
    pdf = "%PDF-1.7\n",
    mobi = string.rep("\0", 60) .. "BOOKMOBI",
}

-- Returns a stand-in book of file_type, bytes long.
function fixtures.bookFile(file_type, bytes)
    local start = BOOK_STARTS[file_type] or ""
    return (start .. string.rep("x", bytes)):sub(1, bytes)
end

-- Adds a downloaded cover for book id to the cover cache.
function fixtures.cacheCover(helper, id)
    local CurlUtil = require("fetchanna.util.curlutil")
    local download = CurlUtil.download
    CurlUtil.download = function(_, path)
        helper.writeFile(path, fixtures.JPEG)
        return true
    end
    require("fetchanna.cache.covercache"):download(id, "https://covers.example/" .. id .. ".jpg")
    CurlUtil.download = download
end

fixtures.DUNE = {
    md5 = "24778aacb1d0844950bf463c145b3d21",
    cover = "/fictioncovers/2509000/24778aacb1d0844950bf463c145b3d21_small.jpg",
    image_url = "https://covers.example/fictioncovers/24778aacb1d0844950bf463c145b3d21_small.jpg",
    series = "Dune Chronicles",
    title = "Dune (Dune Chronicles, Book 1)",
    authors = "Frank Herbert, ",
    year = "1990",
    language = "English",
    file_type = "epub",
    file_size = "1 MB",
}

-- Returns a site's page for the book with md5, linking to its file with a download key, as Library Genesis' did (see
-- downloader_spec).
function fixtures.adsPage(md5)
    return [[<html><body><table id="main"><tr><td><a href="get.php?md5=]]
        .. md5
        .. [[&key=ABC123"><h2>GET</h2></a></td></tr></table></body></html>]]
end

return fixtures

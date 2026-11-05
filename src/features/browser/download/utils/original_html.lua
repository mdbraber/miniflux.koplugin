local http = require('socket.http')
local ltn12 = require('ltn12')
local socket = require('socket')
local socketutil = require('socketutil')
local util = require('util')
local logger = require('logger')

-- **OriginalHtml** - Downloads the original page of an entry instead of the
-- content stored in Miniflux.
--
-- Miniflux sanitizes entry content and strips inline styles. That is fine for
-- articles, but email newsletters rely on inline styles and <style> blocks for
-- their layout. When a feed marks its entries with the `web-view` tag (as
-- Newsbridge does), the entry URL points at a page that shows the newsletter
-- exactly as it was sent. For those entries we download that page and keep its
-- styles, so KOReader can render it close to the original (best with
-- Render Mode "web" and Embedded Style on).
local OriginalHtml = {}

-- Entries carrying this Miniflux tag are downloaded from their original URL
OriginalHtml.TAG = 'web-view'

-- Refuse pages larger than this (bytes), to protect memory on e-readers
local MAX_BYTES = 5 * 1024 * 1024

---Check whether an entry should be downloaded from its original URL
---@param entry_data table Miniflux entry
---@param settings table Plugin settings
---@return boolean
function OriginalHtml.shouldUse(entry_data, settings)
    if not settings or settings.use_original_html == false then
        return false
    end
    if not entry_data or type(entry_data.url) ~= 'string' then
        return false
    end
    if not entry_data.url:match('^https?://') then
        return false
    end
    if type(entry_data.tags) ~= 'table' then
        return false
    end
    for _, tag in ipairs(entry_data.tags) do
        if tag == OriginalHtml.TAG then
            return true
        end
    end
    return false
end

---Download a page
---@param url string Page URL
---@return string|nil body, string|nil error
function OriginalHtml.fetch(url)
    local body = {}
    local size = 0
    local sink = function(chunk, err)
        if chunk then
            size = size + #chunk
            if size > MAX_BYTES then
                return nil, 'page too large'
            end
            table.insert(body, chunk)
        end
        return 1, err
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(
        1,
        http.request({
            url = url,
            method = 'GET',
            headers = { ['User-Agent'] = 'KOReader/1.0' },
            sink = sink,
        })
    )
    socketutil:reset_timeout()

    if headers == nil then
        return nil, 'network error: ' .. tostring(code or status)
    end
    if code ~= 200 then
        return nil, 'HTTP ' .. tostring(code)
    end
    local html = table.concat(body)
    if html == '' then
        return nil, 'empty page'
    end
    return html, nil
end

---Get the original page for an entry, or nil when it should not or could not be used
---@param entry_data table Miniflux entry
---@param settings table Plugin settings
---@return string|nil html
function OriginalHtml.resolve(entry_data, settings)
    if not OriginalHtml.shouldUse(entry_data, settings) then
        return nil
    end
    local html, err = OriginalHtml.fetch(entry_data.url)
    if not html then
        logger.warn(
            '[Miniflux:OriginalHtml] Falling back to Miniflux content for',
            entry_data.id,
            entry_data.url,
            err
        )
        return nil
    end
    logger.info('[Miniflux:OriginalHtml] Using original page for', entry_data.id, entry_data.url)
    return html
end

-- Fixed widths at or above this (CSS px) are layout containers (newsletters are
-- usually 600–700 px wide); they become full width. Smaller ones (buttons,
-- icons, columns) are left alone.
local FLUID_MIN_PX = 400

local function fluidCss(css)
    -- width / max-width: Npx -> 100% ; min-width: Npx -> 0
    css = css:gsub('([%w%-]*width)(%s*:%s*)(%d+%.?%d*)px', function(prop, sep, n)
        if tonumber(n) < FLUID_MIN_PX then
            return nil
        end
        local p = prop:lower()
        if p == 'min-width' then
            return prop .. sep .. '0'
        elseif p == 'width' or p == 'max-width' then
            return prop .. sep .. '100%'
        end
        return nil
    end)
    return css
end

local function fluidTag(tag)
    local name = (tag:match('^<%s*([%w]+)') or ''):lower()
    local big = false
    -- width="600", width='600', width=600 (plain numbers are pixels)
    tag = tag:gsub('(%s[Ww][Ii][Dd][Tt][Hh]%s*=%s*)(["\']?)(%d+)(["\']?)', function(pre, q1, n, q2)
        if tonumber(n) < FLUID_MIN_PX then
            return nil
        end
        big = true
        return pre .. '"100%"'
    end)
    tag = tag:gsub('(%s[Ss][Tt][Yy][Ll][Ee]%s*=%s*")([^"]*)(")', function(pre, css, post)
        return pre .. fluidCss(css) .. post
    end)
    tag = tag:gsub("(%s[Ss][Tt][Yy][Ll][Ee]%s*=%s*')([^']*)(')", function(pre, css, post)
        return pre .. fluidCss(css) .. post
    end)
    -- A wide image's fixed height would distort it once its width follows the screen
    if big and name == 'img' then
        tag = tag:gsub('%s[Hh][Ee][Ii][Gg][Hh][Tt]%s*=%s*["\']?%d+["\']?', '')
    end
    return tag
end

---Make a fixed-width page (e.g. a 600 px newsletter) use the full screen width:
---wide width attributes and CSS widths become 100%, wide images scale down.
---@param html string
---@return string
function OriginalHtml.makeFluid(html)
    html = html:gsub('<%s*[%a][^>]*>', fluidTag)
    html = html:gsub('(<[Ss][Tt][Yy][Ll][Ee][^>]*>)(.-)(</[Ss][Tt][Yy][Ll][Ee]>)', function(open, css, close)
        return open .. fluidCss(css) .. close
    end)
    return html
end

local FLUID_CSS = '<style>img { max-width: 100% !important; height: auto !important; }'
    .. ' table { max-width: 100% !important; }</style>'

---Turn a downloaded page into a standalone document for KOReader.
---Keeps the page's own <html>/<head>/<style>; makes sure there is a charset and title.
---@param html string Page HTML (already cleaned and with local image paths)
---@param entry_data table Miniflux entry
---@return string document
function OriginalHtml.finalizeDocument(html, entry_data)
    local has_html_tag = html:find('<[Hh][Tt][Mm][Ll][%s>]') ~= nil
    if not has_html_tag then
        html = '<!DOCTYPE html>\n<html>\n<head></head>\n<body>\n' .. html .. '\n</body>\n</html>'
    end

    local head_start, head_end = html:find('<[Hh][Ee][Aa][Dd][^>]*>')
    if not head_start then
        -- Insert a <head> right after <html ...>
        local _, html_end = html:find('<[Hh][Tt][Mm][Ll][^>]*>')
        html = html:sub(1, html_end) .. '\n<head></head>' .. html:sub(html_end + 1)
        head_start, head_end = html:find('<[Hh][Ee][Aa][Dd][^>]*>')
    end

    html = OriginalHtml.makeFluid(html)
    head_start, head_end = html:find('<[Hh][Ee][Aa][Dd][^>]*>')

    local additions = {}
    if not html:find('<[Mm][Ee][Tt][Aa][^>]-[Cc][Hh][Aa][Rr][Ss][Ee][Tt]') then
        table.insert(additions, '<meta charset="UTF-8">')
    end
    if not html:find('<[Tt][Ii][Tt][Ll][Ee][%s>]') then
        local title = util.htmlEscape(entry_data.title or '')
        table.insert(additions, '<title>' .. title .. '</title>')
    end
    -- Our rules go last in <head> so they win over the page's own styles
    local head_close = html:find('</[Hh][Ee][Aa][Dd]>')
    if head_close then
        html = html:sub(1, head_close - 1) .. FLUID_CSS .. html:sub(head_close)
        head_start, head_end = html:find('<[Hh][Ee][Aa][Dd][^>]*>')
    else
        table.insert(additions, FLUID_CSS)
    end
    if #additions > 0 then
        html = html:sub(1, head_end)
            .. '\n'
            .. table.concat(additions, '\n')
            .. html:sub(head_end + 1)
    end
    return html
end

return OriginalHtml

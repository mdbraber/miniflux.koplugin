local _ = require('gettext')
local util = require('util') -- Use KOReader's built-in utilities
local T = require('ffi/util').template

-- [Third party](https://github.com/koreader/koreader-base/tree/master/thirdparty) tool
-- https://github.com/msva/lua-htmlparser
local htmlparser = require('htmlparser')

-- Import dependencies for entry content processing
local Images = require('features/browser/download/utils/images')
local YouTubeUtils = require('features/browser/download/utils/youtube_utils')
local Error = require('shared/error')

-- **HtmlUtils** - HTML utilities for Miniflux Browser
--
-- This utility module handles HTML document creation and processing for offline
-- viewing of RSS entries in KOReader.
local HtmlUtils = {}

-- Escape string for use in Lua pattern matching
local function escapePattern(str)
    -- Escape special pattern characters: ( ) . % + - * ? [ ] ^ $
    return str:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
end

-- =============================================================================
-- ENTRY CONTENT PROCESSING
-- =============================================================================

-- TODO: Think of a better name for this function
-- Current candidates: processEntryContent, transformEntryHtml, processHtmlContent
---Process and transform entry content HTML
---@param raw_content string Raw HTML content
---@param options table {entry_data, seen_images, base_url, include_images, original_document?}
---@return string|nil processed_html, Error|nil error
function HtmlUtils.processEntryContent(raw_content, options)
    local entry_data = options.entry_data
    local seen_images = options.seen_images
    local base_url = options.base_url
    local include_images = options.include_images
    local original_document = options.original_document

    if not entry_data or not raw_content then
        return nil, Error.new('Invalid parameters for HTML processing')
    end

    -- Process and clean content
    local processed_content = Images.processHtmlImages(raw_content, {
        seen_images = seen_images,
        include_images = include_images,
        base_url = base_url,
        preserve_attributes = original_document,
    })
    processed_content =
        HtmlUtils.cleanHtmlContent(processed_content, { keep_styles = original_document })

    -- Original pages (e.g. newsletters) are complete documents with their own styles:
    -- keep them as they are instead of wrapping them in our template
    if original_document then
        local OriginalHtml = require('features/browser/download/utils/original_html')
        return OriginalHtml.finalizeDocument(processed_content, entry_data), nil
    end

    -- Create HTML document
    local html_content = HtmlUtils.createHtmlDocument(entry_data, processed_content)

    if not html_content then
        return nil, Error.new('Failed to process HTML content')
    end

    return html_content, nil
end

-- =============================================================================
-- HTML DOCUMENT CREATION
-- =============================================================================

-- Built into every entry page (needs KOReader's Embedded Style on). KOReader's
-- book stylesheet indents and justifies every paragraph without spacing; web
-- articles read better as left-aligned blocks with space between them.
local ENTRY_CSS = [[
body { margin: 0; }
.entry-meta { margin: 0 0 1.2em 0; padding: 0 0 0.6em 0; border-bottom: 1px solid #888888; }
.entry-meta .entry-title { font-size: 1.5em; line-height: 1.2; margin: 0 0 0.3em 0; text-align: left; text-indent: 0; }
.entry-meta .entry-byline { font-size: 0.85em; margin: 0; text-align: left; text-indent: 0; }
.entry-content p, .entry-content li, .entry-content dd, .entry-content div, .entry-content td,
.entry-content blockquote, .entry-content figcaption {
    text-align: left; text-indent: 0;
}
.entry-content p { margin: 0 0 0.8em 0; }
.entry-content h1, .entry-content h2, .entry-content h3, .entry-content h4, .entry-content h5, .entry-content h6 {
    margin: 1.2em 0 0.4em 0; line-height: 1.25; text-align: left; text-indent: 0;
}
.entry-content ul, .entry-content ol { margin: 0 0 0.8em 0; padding-left: 1.4em; }
.entry-content li { margin: 0 0 0.3em 0; }
.entry-content img { max-width: 100% !important; height: auto !important; display: block; margin: 0.6em auto; }
.entry-content figure { margin: 0 0 1em 0; }
.entry-content figcaption { font-size: 0.85em; font-style: italic; }
.entry-content blockquote { margin: 0 0 0.8em 0; padding: 0 0 0 0.8em; border-left: 3px solid #888888; }
.entry-content pre { white-space: pre-wrap; font-size: 0.85em; margin: 0 0 0.8em 0; }
.entry-content hr { border: 0; border-top: 1px solid #888888; margin: 1em 0; }
.entry-source { margin: 1.5em 0 0 0; padding: 0.6em 0 0 0; border-top: 1px solid #888888; font-size: 0.85em; text-align: left; text-indent: 0; }
]]

---Create a complete HTML document for an entry
---@param entry MinifluxEntry Entry data
---@param content string Processed HTML content
---@return string Complete HTML document
function HtmlUtils.createHtmlDocument(entry, content)
    local DateFormat = require('shared/date_format')
    local escaped_title = util.htmlEscape(entry.title or _('Untitled Entry'))

    -- One byline under the title: "Feed · 4 November 2026, 11:03" (local time)
    local byline_parts = {}
    if entry.feed and entry.feed.title and entry.feed.title ~= '' then
        table.insert(byline_parts, (util.htmlEscape(entry.feed.title)))
    end
    local published = entry.published_at and DateFormat.formatIso8601(entry.published_at)
    if published then
        table.insert(byline_parts, (util.htmlEscape(published)))
    end
    local byline = #byline_parts > 0
            and ('\n        <p class="entry-byline">' .. table.concat(byline_parts, ' · ') .. '</p>')
        or ''

    -- Link to the original at the end, where it is useful when an article was cut short
    local source = ''
    if entry.url and entry.url ~= '' then
        local host = entry.url:match('^https?://([^/?#]+)') or entry.url
        host = host:gsub('^www%.', '')
        source = string.format(
            '\n    <p class="entry-source"><a href="%s">%s</a></p>',
            (entry.url:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub('<', '&lt;'):gsub('>', '&gt;')),
            (util.htmlEscape(T(_('Read on %1'), host)))
        )
    end

    return string.format(
        [[<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>%s</title>
    <style>
%s    </style>
</head>
<body>
    <div class="entry-meta">
        <h1 class="entry-title">%s</h1>%s
    </div>
    <div class="entry-content">
        %s
    </div>%s
</body>
</html>]],
        escaped_title,
        ENTRY_CSS,
        escaped_title,
        byline,
        content,
        source
    )
end

---Process YouTube iframes and replace them with thumbnails using regex
---@param content string HTML content containing iframes
---@return string Content with YouTube iframes replaced by thumbnails
function HtmlUtils.processYouTubeIframes(content)
    if not content or content == '' then
        return content
    end

    -- Pattern to match complete iframe elements with YouTube URLs
    local youtube_iframe_pattern = '<iframe[^>]*src="[^"]*youtu[^"]*"[^>]*>.-</iframe>'

    -- Replace all YouTube iframes using YouTubeUtils
    local processed_content = content:gsub(youtube_iframe_pattern, YouTubeUtils.replaceIframeHtml)
    return processed_content
end

---Clean and normalize HTML content for offline viewing using DOM parser
---@param content string Raw HTML content
---@param opts? {keep_styles?: boolean} Keep <style> blocks (for original pages)
---@return string Cleaned HTML content
function HtmlUtils.cleanHtmlContent(content, opts)
    opts = opts or {}
    if not content or content == '' then
        return ''
    end

    -- First, process YouTube iframes and replace them with thumbnails (fast, no HTTP calls)
    content = HtmlUtils.processYouTubeIframes(content)

    -- Elements that won't work offline - remove using CSS selectors
    local unwanted_selectors = {
        'script', -- Scripts (security and functionality)
        'iframe', -- Iframes (won't work offline)
        'video', -- Videos (won't work offline)
        'object', -- Objects and embeds (multimedia)
        'embed', -- Flash/multimedia embeds
        'form', -- Forms (won't work offline)
    }
    if not opts.keep_styles then
        table.insert(unwanted_selectors, 'style') -- Style blocks (can cause display issues)
    end

    -- Use HTML parser approach (reliable)
    local root = htmlparser.parse(content, 5000)

    -- Track elements that get removed or replaced for efficient string replacement
    local element_replacements = {} -- {original_text = replacement_text}
    local total_processed = 0

    -- Remove each type of unwanted element
    for _, selector in ipairs(unwanted_selectors) do
        local elements = root:select(selector)
        if elements then
            for _, element in ipairs(elements) do
                -- Get the original element text BEFORE removal
                local element_text = element:gettext()
                if element_text and element_text ~= '' then
                    element_replacements[element_text] = ''
                    total_processed = total_processed + 1
                end
            end
        end
    end

    -- Use efficient string replacement instead of DOM reconstruction
    if total_processed > 0 then
        local cleaned_content = content
        for element_text, replacement in pairs(element_replacements) do
            local escaped_pattern = escapePattern(element_text)
            cleaned_content = cleaned_content:gsub(escaped_pattern, replacement)
        end
        return cleaned_content
    else
        return content
    end
end

return HtmlUtils

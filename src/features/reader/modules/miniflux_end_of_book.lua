--[[--
**Miniflux End of Book Module**

This module handles the end-of-book/end-of-entry dialog functionality that appears
when users reach the end of a Miniflux RSS entry. It provides navigation options,
status management, and local entry operations.

This module integrates with KOReader's event system by extending Widget and
overriding the ReaderStatus onEndOfBook behavior specifically for Miniflux entries.
--]]

local EventListener = require('ui/widget/eventlistener')
local UIManager = require('ui/uimanager')
local ButtonDialog = require('ui/widget/buttondialog')
local Notification = require('shared/widgets/notification')
local Device = require('device')
local util = require('util')
local _ = require('gettext')

local EntryPaths = require('domains/utils/entry_paths')
local EntryValidation = require('domains/utils/entry_validation')
local EntryMetadata = require('domains/utils/entry_metadata')

---@class MinifluxEndOfBook : EventListener
---@field miniflux Miniflux The main Miniflux plugin instance
---@field wrapped_method table The wrapped method object
local MinifluxEndOfBook = EventListener:extend({
    name = 'miniflux_end_of_book',
    wrapped_method = nil,
    miniflux = nil,
})

---Initialize the module and wrap the onEndOfBook method
function MinifluxEndOfBook:init()
    if self.miniflux and self.miniflux.ui and self.miniflux.ui.status then
        local reader_status = self.miniflux.ui.status

        self.wrapped_method = util.wrapMethod(reader_status, 'onEndOfBook', function(...)
            if self:shouldShowCustomDialog() then
                return self:showCustomEndOfBookDialog()
            else
                return self.wrapped_method:raw_method_call(...)
            end
        end)
    end
end

---Check if we should show custom dialog for miniflux entries
---@return boolean
function MinifluxEndOfBook:shouldShowCustomDialog()
    if
        not self.miniflux.ui
        or not self.miniflux.ui.document
        or not self.miniflux.ui.document.file
    then
        return false
    end

    local file_path = self.miniflux.ui.document.file
    -- Check if this is a miniflux HTML entry
    return file_path:match('/miniflux/') and file_path:match('%.html$')
end

---Show custom end of book dialog for miniflux entries
---@return boolean
function MinifluxEndOfBook:showCustomEndOfBookDialog()
    local file_path = self.miniflux.ui.document.file

    -- Extract entry ID from path and convert to number
    local entry_id_str = file_path:match('/miniflux/(%d+)/')
    local entry_id = entry_id_str and tonumber(entry_id_str)

    if entry_id then
        -- Show the end of entry dialog with entry info as parameter
        local entry_info = {
            file_path = file_path,
            entry_id = entry_id,
        }

        self:showDialog(entry_info)
        return true -- Handled by custom dialog
    end

    return false -- Should not happen if shouldShowCustomDialog works correctly
end

---Show end of entry dialog with navigation options
---@param entry_info table Entry information with file_path and entry_id
---@param opts? {title?: string} Dialog title (defaults to the end-of-entry text)
---@return table|nil Dialog reference for caller management or nil if failed
function MinifluxEndOfBook:showDialog(entry_info, opts)
    opts = opts or {}
    if not entry_info or not entry_info.file_path or not entry_info.entry_id then
        return nil
    end

    if not self.miniflux or not self.miniflux.reader_entry_service then
        return nil
    end

    -- Get ReaderUI's DocSettings to read current status (includes optimistic updates)
    local doc_settings = self.miniflux.ui and self.miniflux.ui.doc_settings

    -- Load current metadata from doc_settings cache (not SDR) to see optimistic updates
    local metadata = doc_settings and doc_settings:readSetting('miniflux_entry')

    -- Use status for business logic (fallback to SDR if doc_settings unavailable)
    local entry_status
    if metadata and metadata.status then
        entry_status = metadata.status
    else
        -- Fallback to SDR if doc_settings not available
        local sdr_metadata = EntryMetadata.loadMetadata(entry_info.entry_id)
        entry_status = sdr_metadata and sdr_metadata.status or 'unread'
    end

    -- Helper function to navigate to entry with consistent parameters
    local function navigateToEntry(direction)
        local Navigation = require('features/reader/services/navigation_service')
        Navigation.navigateToEntry(entry_info, self.miniflux, { direction = direction })
    end

    -- Use utility functions for button text and callback
    local mark_button_text = EntryValidation.getStatusButtonText(entry_status)
    local mark_callback
    if EntryValidation.isEntryRead(entry_status) then
        mark_callback = function()
            self.miniflux.reader_entry_service:changeEntryStatus(
                entry_info.entry_id,
                'unread',
                doc_settings
            )
        end
    else
        mark_callback = function()
            self.miniflux.reader_entry_service:changeEntryStatus(
                entry_info.entry_id,
                'read',
                doc_settings
            )
        end
    end

    local is_starred = self.miniflux.reader_entry_service:isEntryStarred(entry_info.entry_id, doc_settings)

    -- Declare dialog variable first for proper scoping in callbacks
    ---@type ButtonDialog
    local dialog
    local buttons = {
        {
            {
                text = _('← Previous'),
                callback = function()
                    UIManager:close(dialog)
                    navigateToEntry('previous')
                end,
            },
            {
                text = _('Next →'),
                callback = function()
                    UIManager:close(dialog)
                    navigateToEntry('next')
                end,
            },
        },
        {
            {
                text = is_starred and _('★ Unstar') or _('☆ Star'),
                callback = function()
                    UIManager:close(dialog)
                    self.miniflux.reader_entry_service:toggleEntryStar(entry_info.entry_id, doc_settings)
                end,
            },
            {
                text = mark_button_text,
                callback = function()
                    UIManager:close(dialog)
                    mark_callback()
                end,
            },
        },
        {
            {
                text = _('⚠ Delete local entry'),
                callback = function()
                    UIManager:close(dialog)
                    -- Inline deletion with validation
                    if not EntryValidation.isValidId(entry_info.entry_id) then
                        Notification:warning(_('Cannot delete: invalid entry ID'))
                        return
                    end

                    local success = EntryPaths.deleteLocalEntry(entry_info.entry_id)
                    if success then
                        local ReaderUI = require('apps/reader/readerui')
                        if ReaderUI.instance then
                            ReaderUI.instance:onClose()
                        end
                        -- Return to the browser view where the user was before opening this entry
                        self:returnToBrowser()
                    end
                end,
            },
            {
                text = _('⌂ Return to Miniflux'),
                callback = function()
                    UIManager:close(dialog)
                    local ReaderUI = require('apps/reader/readerui')
                    if ReaderUI.instance then
                        ReaderUI.instance:onClose()
                    end
                    self:returnToBrowser()
                end,
            },
        },
        {
            {
                text = _('Cancel'),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        },
    }

    -- Create dialog and assign to the pre-declared variable
    dialog = ButtonDialog:new({
        name = 'miniflux_end_of_entry',
        title = opts.title or _("You've reached the end of the entry.\nWhat would you like to do?"),
        title_align = 'center',
        buttons = buttons,
    })

    -- Enhance dialog with physical key handlers for navigation (inline)
    if Device:hasKeys() then
        -- Add key event handlers to the dialog
        ---@diagnostic disable: inject-field
        dialog.key_events = dialog.key_events or {}

        -- Navigate to previous entry (logical "back" direction)
        dialog.key_events.NavigatePrevious = {
            { Device.input.group.PgBack }, -- Page back buttons
            event = 'NavigateTo',
            args = 'previous',
        }

        -- Navigate to next entry (logical "forward" direction)
        dialog.key_events.NavigateNext = {
            { Device.input.group.PgFwd }, -- Page forward buttons
            event = 'NavigateTo',
            args = 'next',
        }
    end

    ---@param direction 'previous'|'next' # Direction of where to navigate
    -- selene: allow(shadowing)
    ---@diagnostic disable: inject-field
    function dialog:onNavigateTo(direction)
        UIManager:close(dialog)
        navigateToEntry(direction)
        return true
    end

    -- Show dialog and return reference for caller management
    UIManager:show(dialog)
    return dialog
end

-- =============================================================================
-- ACTIONS WHILE READING (menu and gestures)
-- =============================================================================

---Entry info for the open document, or nil when it is not a Miniflux entry
---@return {file_path: string, entry_id: number}|nil
function MinifluxEndOfBook:getCurrentEntryInfo()
    if not self:shouldShowCustomDialog() then
        return nil
    end
    local file_path = self.miniflux.ui.document.file
    local entry_id = tonumber(file_path:match('/miniflux/(%d+)/'))
    if not entry_id then
        return nil
    end
    return { file_path = file_path, entry_id = entry_id }
end

---Show the entry menu (previous/next, star, mark read, return) at any point
---@return boolean handled
function MinifluxEndOfBook:showEntryActions()
    local entry_info = self:getCurrentEntryInfo()
    if not entry_info then
        return false
    end
    self:showDialog(entry_info, { title = _('Miniflux entry') })
    return true
end

---@param direction 'previous'|'next'
---@return boolean handled
function MinifluxEndOfBook:navigateFromCurrent(direction)
    local entry_info = self:getCurrentEntryInfo()
    if not entry_info then
        return false
    end
    local Navigation = require('features/reader/services/navigation_service')
    Navigation.navigateToEntry(entry_info, self.miniflux, { direction = direction })
    return true
end

---Close the entry and go back to the list it was opened from
---@return boolean handled
function MinifluxEndOfBook:returnToListFromCurrent()
    if not self:getCurrentEntryInfo() then
        return false
    end
    local ReaderUI = require('apps/reader/readerui')
    if ReaderUI.instance then
        ReaderUI.instance:onClose()
    end
    self:returnToBrowser()
    return true
end

---@return boolean handled
function MinifluxEndOfBook:toggleStarFromCurrent()
    local entry_info = self:getCurrentEntryInfo()
    if not entry_info then
        return false
    end
    local doc_settings = self.miniflux.ui and self.miniflux.ui.doc_settings
    self.miniflux.reader_entry_service:toggleEntryStar(entry_info.entry_id, doc_settings)
    return true
end

-- Gesture actions (registered in main.lua); they do nothing outside Miniflux entries
function MinifluxEndOfBook:onMinifluxEntryActions()
    return self:showEntryActions()
end
function MinifluxEndOfBook:onMinifluxNextEntry()
    return self:navigateFromCurrent('next')
end
function MinifluxEndOfBook:onMinifluxPreviousEntry()
    return self:navigateFromCurrent('previous')
end
function MinifluxEndOfBook:onMinifluxReturnToList()
    return self:returnToListFromCurrent()
end
function MinifluxEndOfBook:onMinifluxToggleStar()
    return self:toggleStarFromCurrent()
end

---Return to the browser view where the user was before opening this entry.
---Routing and back-stack seeding live in MinifluxBrowser:openContext so the
---back button works as expected after the user lands on the saved view.
---@return nil
function MinifluxEndOfBook:returnToBrowser()
    if not self.miniflux or not self.miniflux.browser then
        return
    end

    self.miniflux.browser:openContext(self.miniflux:getBrowserContext())
end

---Cleanup method - revert the wrapped method
function MinifluxEndOfBook:onCloseWidget()
    if self.wrapped_method then
        self.wrapped_method:revert()
        self.wrapped_method = nil
    end
end

return MinifluxEndOfBook

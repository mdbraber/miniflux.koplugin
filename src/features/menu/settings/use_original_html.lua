local UIManager = require('ui/uimanager')
local Notification = require('shared/widgets/notification')
local _ = require('gettext')

-- **Use Original HTML Settings** - ON/OFF toggle for downloading the original
-- page (with its own styles) for entries tagged "web-view", such as email
-- newsletters published by Newsbridge.
local UseOriginalHtml = {}

---Get the menu item for the original page setting
---@param settings MinifluxSettings Settings instance
---@return table Menu item configuration
function UseOriginalHtml.getMenuItem(settings)
    return {
        text_func = function()
            return settings.use_original_html and _('Original page for web-view entries - ON')
                or _('Original page for web-view entries - OFF')
        end,
        help_text = _(
            'Entries tagged "web-view" (e.g. newsletters) are downloaded from their original page, keeping its layout. Best with Render Mode "web" and Embedded Style on. Already downloaded entries are not changed.'
        ),
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _('ON') .. (settings.use_original_html and ' ✓' or ''),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UseOriginalHtml.updateSetting({
                            settings = settings,
                            new_value = true,
                            touchmenu_instance = touchmenu_instance,
                            message = _('web-view entries will use their original page'),
                        })
                    end,
                },
                {
                    text = _('OFF') .. (not settings.use_original_html and ' ✓' or ''),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UseOriginalHtml.updateSetting({
                            settings = settings,
                            new_value = false,
                            touchmenu_instance = touchmenu_instance,
                            message = _('All entries will use the Miniflux content'),
                        })
                    end,
                },
            }
        end,
    }
end

---Update the setting
---@param options {settings: MinifluxSettings, new_value: boolean, touchmenu_instance: table, message: string}
function UseOriginalHtml.updateSetting(options)
    options.settings.use_original_html = options.new_value

    local notification = Notification:success(options.message, { timeout = 2 })

    UIManager:scheduleIn(0.5, function()
        notification:close()
        options.touchmenu_instance:backToUpperMenu()
    end)
end

return UseOriginalHtml

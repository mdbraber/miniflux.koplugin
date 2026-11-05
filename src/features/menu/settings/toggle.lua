local _ = require('gettext')

-- **Toggle** - A checkbox menu item for a boolean plugin setting.
local Toggle = {}

---@param opts {settings: MinifluxSettings, key: string, text: string, help_text?: string, on_change?: fun(value: boolean)}
---@return table Menu item
function Toggle.getMenuItem(opts)
    return {
        text = opts.text,
        help_text = opts.help_text,
        checked_func = function()
            return opts.settings[opts.key] == true
        end,
        callback = function()
            local value = not (opts.settings[opts.key] == true)
            opts.settings[opts.key] = value
            if opts.on_change then
                opts.on_change(value)
            end
        end,
    }
end

return Toggle

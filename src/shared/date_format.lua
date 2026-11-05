-- **DateFormat** - Human-readable dates for entry pages.
local DateFormat = {}

local MONTHS = {
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
}

---Convert an ISO-8601 timestamp (Z, ±hh:mm, ±hhmm or no offset = UTC) to a Unix time
---@param iso string e.g. "2026-11-04T10:03:00Z" or "2026-11-04T11:03:00+01:00"
---@return number|nil
function DateFormat.parseIso8601(iso)
    if type(iso) ~= 'string' then
        return nil
    end
    local y, mo, d, h, mi, s, rest = iso:match('^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*)(.*)$')
    -- Feeds without a date come through as 0001-01-01: treat anything before 1971 as unknown
    if not y or tonumber(y) < 1971 then
        return nil
    end
    local fields = {
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(mi),
        sec = tonumber(s) or 0,
        isdst = false,
    }
    -- os.time() reads the table as local time; measure the local offset at that moment
    -- and undo it, so we get the time as if the fields were UTC.
    local as_local = os.time(fields)
    if not as_local then
        return nil
    end
    local utc_fields = os.date('!*t', as_local)
    utc_fields.isdst = false
    local local_offset = os.difftime(as_local, os.time(utc_fields))
    local utc = as_local + local_offset

    -- The timestamp's own offset (fractional seconds are ignored)
    rest = rest:gsub('^%.%d+', '')
    local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)')
    if sign then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        utc = sign == '+' and utc - offset or utc + offset
    end
    return utc
end

---Format a Unix time in local time as "4 November 2026, 11:03"
---@param unix number
---@return string
function DateFormat.formatLocal(unix)
    local t = os.date('*t', unix)
    return string.format('%d %s %d, %02d:%02d', t.day, MONTHS[t.month], t.year, t.hour, t.min)
end

---Format an ISO-8601 timestamp for display, or nil when it cannot be parsed
---@param iso string
---@return string|nil
function DateFormat.formatIso8601(iso)
    local unix = DateFormat.parseIso8601(iso)
    return unix and DateFormat.formatLocal(unix) or nil
end

return DateFormat

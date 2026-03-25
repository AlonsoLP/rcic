-- TNS|RCIC Config|TNE
-- =========================================================================
-- rcic_cfg.lua — RC Info Center (Configuration Tool)
--
-- Version:      4.0
-- Date:         2026-03-26
-- Author:       Alonso Lara (github.com/AlonsoLP)
-- Install path: /SCRIPTS/TOOLS/rcic_cfg.lua
--
-- Description:
--   EdgeTX Tools script providing a full-screen configuration UI for
--   rcic.lua. Renders a scrollable menu with real-time editing for all
--   runtime parameters: battery alerts, tab visibility, GPS options,
--   arm-switch detection, and display preferences. Settings are written
--   immediately to /SCRIPTS/TELEMETRY/rcic.cfg in CSV format so that
--   rcic.lua picks them up on the next wake-up without a radio restart.
--
-- Compatibility: EdgeTX 2.9+ | Lua 5.3
-- License:       MIT — see full text below
--
-- -------------------------------------------------------------------------
--
-- Copyright (c) 2026 Alonso Lara
--
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.
-- =========================================================================

-- ------------------------------------------------------------
-- 1. EXTERNAL FUNCTION LOCALIZATION
-- ------------------------------------------------------------

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local string_fmt = string.format

-- ------------------------------------------------------------
-- 2. CONFIGURATION DEFAULTS
-- These mirror the defaults in rcic.lua and are overwritten by
-- load_config() on startup. All edits are persisted to disk
-- immediately after every change (instant-save model).
-- ------------------------------------------------------------

local CFG_FILE = "/SCRIPTS/TELEMETRY/rcic.cfg"  -- shared config file path; read/written by both scripts

-- Telemetry update rate and battery alert behaviour
local UPDATE_RATE            = 100    -- centiseconds between background updates (100 = 1 s)
local BATTERY_ALERT_ENABLED  = true   -- enable per-cell low-voltage visual alert
local BATTERY_ALERT_AUDIO    = true   -- play audio tone on low-voltage alert
local BATTERY_ALERT_INTERVAL = 2000   -- minimum time between consecutive alerts (cs)
local BATTERY_ALERT_STEP     = 0.1    -- minimum voltage drop (V) required to re-trigger alert
local SAG_CURRENT_THRESHOLD  = 20     -- amperes; suppress alerts above this draw (sag suppression)
local TX_BAT_WARN            = 0      -- TX battery warning threshold (V); 0 = disabled
local TOAST_DURATION         = 100    -- on-screen toast display duration (cs)
local BAT_CAPACITY_MAH       = 1500   -- nominal battery capacity (mAh); used for flight time estimate

-- GPS settings
local MIN_SATS        = 4      -- minimum satellites required to accept a GPS fix
local GPX_LOG_ENABLED = false  -- write GPS track log to /LOGS/R_HHMMSS.gpx when armed

-- Interface and radio behaviour
local HAPTIC   = false  -- enable vibration pulses on supported radios
local AUTO_TAB = true   -- auto-switch to GPS/LOC tab on telemetry loss

-- Arm switch detection
local ARM_SWITCH = ""  -- arm switch name (e.g. "SF"); "" = disabled
local ARM_VALUE  = 0   -- switch position value captured during arm-listen

-- Tab visibility flags — each enables or disables a dashboard tab in rcic.lua
local TAB_BAT_EN, TAB_GPS_EN, TAB_TOT_EN, TAB_LOC_EN = true, true, true, true
local TAB_PWR_EN, TAB_LNK_EN, TAB_RAD_EN             = true, true, true

-- ------------------------------------------------------------
-- 3. INTERNAL CONSTANTS AND LOOKUP TABLES
-- ------------------------------------------------------------

-- Ordered list of supported arm switches; the 1-based index is stored in CSV field 13
local ARM_SW_LIST = { "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH" }

-- TX battery fallback threshold used when getGeneralSettings() returns no battWarn value.
-- Populated from the radio's General Settings in init(); used as the restore value when
-- the "TX Alert" toggle is switched ON after having been OFF.
local bat_warn_default = 6.6

-- ------------------------------------------------------------
-- 4. ENVIRONMENT AND DISPLAY VARIABLES
-- ------------------------------------------------------------

local SCREEN_W, SCREEN_H  -- screen dimensions in pixels; set in init()
local VISIBLE_ROWS         -- number of menu rows that fit between the title bar and bottom edge

-- Symbol aliases for switch position indicators shown in the "Arm SW" menu row
local SYM_UP   = CHAR_UP    -- ▲ displayed when the switch is in the high (+) position
local SYM_DOWN = CHAR_DOWN  -- ▼ displayed when the switch is in the low  (-) position

-- ------------------------------------------------------------
-- 5. MENU ENGINE STATE VARIABLES
-- ------------------------------------------------------------

-- Scrollable selection list state
local cfg_sel    = 1     -- 1-based index of the currently highlighted menu row
local cfg_len    = 0     -- total number of visible rows after the last refresh_cfg_vals() call
local cfg_scroll = 0     -- first visible row offset (0-based); drives the scrolling window

-- Edit-mode flags
local cfg_edit          = false  -- true while a numeric item is being edited via rot/+/-
local cfg_edit_snapshot = nil    -- value saved on edit-enter; restored on EVT_EXIT_BREAK (cancel)

-- Flat parallel arrays backing the rendered menu rows (rebuilt by refresh_cfg_vals)
local cfg_id    = {}  -- numeric item ID; maps row to its config variable via cfg_set_var()
local cfg_label = {}  -- display label shown left-aligned on each row
local cfg_val   = {}  -- pre-formatted value string shown right-aligned on each row

-- ------------------------------------------------------------
-- 6. ARM-SWITCH LISTEN STATE VARIABLES
-- ------------------------------------------------------------
-- Switch listen is a two-phase flow:
--   Phase 1 (listen) : snapshot all switch positions, then wait for any change.
--   Phase 2 (confirm): user presses ENTER to commit the detected switch and position.

local sw_listen      = false  -- true while the tool is waiting for a switch movement
local sw_snapshot    = {}     -- switch positions captured at listen-start (index = ARM_SW_LIST index)
local sw_pending     = ""     -- name of the first switch that moved since listen started
local sw_pending_val = 0      -- raw position value of sw_pending at the time of detection

-- ------------------------------------------------------------
-- 7. UTILITY FUNCTIONS
-- ------------------------------------------------------------

-- Wraps a 1-based index cyclically within [1..n], stepping by dir (+1 or -1).
-- Stepping past n returns 1; stepping before 1 returns n.
-- Used for menu row navigation in handle_cfg_events().
local function cycle(val, n, dir) return (val - 1 + dir + n) % n + 1 end

-- Returns the symbol character that represents a raw switch position value.
-- Positive → SYM_UP (▲), negative → SYM_DOWN (▼), zero → "-" (centre / off).
-- Used to format the "Arm SW" row value (e.g. "SF▲").
local function sw_pos(val)
    if     val > 0 then return SYM_UP
    elseif val < 0 then return SYM_DOWN
    else                return "-"
    end
end

-- ------------------------------------------------------------
-- 8. CONFIG FILE I/O
-- ------------------------------------------------------------

-- Reads and parses the persistent configuration from the SD card CSV file
-- (CFG_FILE). Fields are positionally mapped. Missing or extra fields are
-- silently ignored, preserving forward and backward compatibility.
local function load_config()
    local file = io.open(CFG_FILE, "r")
    if not file then return end
    local content = io.read(file, 512)
    io.close(file)
    if not content or #content == 0 then return end

    local c = {}
    for v in string.gmatch(content .. ",", "([^,]*),") do c[#c + 1] = tonumber(v) end

    if c[1] then
        UPDATE_RATE = c[1]; BATTERY_ALERT_ENABLED = c[2] == 1; BATTERY_ALERT_AUDIO = c[3] == 1
        BATTERY_ALERT_INTERVAL = c[4]; BATTERY_ALERT_STEP = c[5] / 100; SAG_CURRENT_THRESHOLD = c[6]
        TX_BAT_WARN = c[7] / 10; TOAST_DURATION = c[8]; BAT_CAPACITY_MAH = c[9]
        MIN_SATS = c[10]; HAPTIC = c[11] == 1; AUTO_TAB = c[12] == 1
        ARM_SWITCH = (c[13] > 0 and ARM_SW_LIST[c[13]]) or ""
        ARM_VALUE = c[14]; GPX_LOG_ENABLED = c[15] == 1; TAB_BAT_EN = c[16] == 1
        TAB_GPS_EN = c[17] == 1; TAB_TOT_EN = c[18] == 1; TAB_LOC_EN = c[19] == 1
        TAB_LNK_EN = c[20] == 1; TAB_PWR_EN = c[21] == 1; TAB_RAD_EN = c[22] == 1
    end
end

-- Serialises all config variables to the shared CSV file (CFG_FILE).
-- Field positions are fixed and must remain in sync with load_config() in
-- both scripts. Called immediately after every user edit (instant-save model)
-- so that rcic.lua always reads the latest values on the next wake-up.
local function save_config()
    local file = io.open(CFG_FILE, "w")
    local arm_idx = 0
    for i, sw in ipairs(ARM_SW_LIST) do if sw == ARM_SWITCH then arm_idx = i; break end end
    if file then
        io.write(file, string_fmt(
	    "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
            UPDATE_RATE,
            BATTERY_ALERT_ENABLED  and 1 or 0,
            BATTERY_ALERT_AUDIO    and 1 or 0,
            BATTERY_ALERT_INTERVAL,
            math_floor(BATTERY_ALERT_STEP * 100),
            SAG_CURRENT_THRESHOLD,
            math_floor(TX_BAT_WARN * 10),
            TOAST_DURATION,
            BAT_CAPACITY_MAH,
            MIN_SATS,
            HAPTIC          and 1 or 0,
            AUTO_TAB        and 1 or 0,
            arm_idx,
            ARM_VALUE,
            GPX_LOG_ENABLED and 1 or 0,
            TAB_BAT_EN      and 1 or 0,
            TAB_GPS_EN      and 1 or 0,
            TAB_TOT_EN      and 1 or 0,
            TAB_LOC_EN      and 1 or 0,
            TAB_LNK_EN      and 1 or 0,
            TAB_PWR_EN      and 1 or 0,
            TAB_RAD_EN      and 1 or 0))
        io.close(file)
    end
end

-- ------------------------------------------------------------
-- 9. MENU ENGINE
-- ------------------------------------------------------------

-- Internal row counter reset to 1 at the start of each refresh_cfg_vals() call.
local cfg_count = 1

-- Appends a single row to the menu arrays at position cfg_count.
--   id    : numeric key used by cfg_set_var() to route edits to the correct variable.
--   label : left-aligned display string; prefix with "  " for sub-items under a tab toggle.
--   val   : pre-formatted right-aligned value string (e.g. "ON", "1.0s", "20A").
local function add_cfg(id, label, val)
    cfg_id[cfg_count], cfg_label[cfg_count], cfg_val[cfg_count] = id, label, val
    cfg_count = cfg_count + 1
end

-- Rebuilds the entire menu row list from the current variable values.
-- Sub-items under a tab toggle are only added when that tab is enabled,
-- keeping the list compact and context-sensitive.
-- Must be called after any edit and after load_config() so that the rendered
-- menu always reflects the live state.
-- Sets cfg_len to the new row count and clamps cfg_sel within [1..cfg_len].
local function refresh_cfg_vals()
    cfg_count = 1

    add_cfg(1,  "Update Rate",     string_fmt("%.1fs", UPDATE_RATE / 100))

    add_cfg(15, "Tab BAT",         TAB_BAT_EN and "ON" or "OFF")
    if TAB_BAT_EN then
        add_cfg(2,  "  Battery Alert",  BATTERY_ALERT_ENABLED and "ON" or "OFF")
        add_cfg(3,  "  Audio Alert",    BATTERY_ALERT_AUDIO   and "ON" or "OFF")
        add_cfg(4,  "  Alert Interval", string_fmt("%.0fs",  BATTERY_ALERT_INTERVAL / 100))
        add_cfg(5,  "  Alert Step",     string_fmt("-%.2fV", BATTERY_ALERT_STEP))
        add_cfg(6,  "  Sag Limit",      string_fmt("%dA",    SAG_CURRENT_THRESHOLD))
        add_cfg(9,  "  Battery MAH",    string_fmt("%dmAh",  BAT_CAPACITY_MAH))
    end

    add_cfg(16, "Tab GPS",         TAB_GPS_EN and "ON" or "OFF")
    if TAB_GPS_EN then
        add_cfg(10, "  Min Sats",   string_fmt("%d", MIN_SATS))
        add_cfg(14, "  GPS Log",    GPX_LOG_ENABLED and "ON" or "OFF")
    end

    add_cfg(17, "Tab TOT",         TAB_TOT_EN and "ON" or "OFF")
    add_cfg(18, "Tab LOC",         TAB_LOC_EN and "ON" or "OFF")
    add_cfg(19, "Tab LNK",         TAB_LNK_EN and "ON" or "OFF")
    add_cfg(20, "Tab PWR",         TAB_PWR_EN and "ON" or "OFF")
    add_cfg(21, "Tab RAD",         TAB_RAD_EN and "ON" or "OFF")

    add_cfg(7,  "TX Alert",        TX_BAT_WARN > 0 and "ON" or "OFF")
    add_cfg(8,  "Toast Time",      string_fmt("%.1fs", TOAST_DURATION / 100))
    add_cfg(11, "Haptic",          HAPTIC   and "ON" or "OFF")
    if TAB_GPS_EN or TAB_LOC_EN then
        add_cfg(12, "Auto Tab",    AUTO_TAB and "ON" or "OFF")
    end

    -- "Arm SW" row: shows the live-detected switch during sw_listen, or the saved value otherwise
    local sw_val = "--"
    if sw_listen and sw_pending ~= "" then
        sw_val = sw_pending .. sw_pos(sw_pending_val)
    elseif ARM_SWITCH ~= "" then
        sw_val = ARM_SWITCH .. sw_pos(ARM_VALUE)
    end
    add_cfg(13, "Arm SW", sw_val)

    cfg_len = cfg_count - 1
    if cfg_sel > cfg_len then cfg_sel = math_max(1, cfg_len) end
end

-- Routes an edited value to the correct config variable using the item ID.
-- Numeric items receive the new clamped value from the rotary encoder handler.
-- Boolean items receive a pre-computed negation from the toggle handler.
local function cfg_set_var(id, val)
    if     id == 1  then UPDATE_RATE            = val
    elseif id == 2  then BATTERY_ALERT_ENABLED  = val
    elseif id == 3  then BATTERY_ALERT_AUDIO    = val
    elseif id == 4  then BATTERY_ALERT_INTERVAL = val
    elseif id == 5  then BATTERY_ALERT_STEP     = val
    elseif id == 6  then SAG_CURRENT_THRESHOLD  = val
    elseif id == 7  then TX_BAT_WARN            = val
    elseif id == 8  then TOAST_DURATION         = val
    elseif id == 9  then BAT_CAPACITY_MAH       = val
    elseif id == 10 then MIN_SATS               = val
    elseif id == 11 then HAPTIC                 = val
    elseif id == 12 then AUTO_TAB               = val
    elseif id == 14 then GPX_LOG_ENABLED        = val
    elseif id == 15 then TAB_BAT_EN             = val
    elseif id == 16 then TAB_GPS_EN             = val
    elseif id == 17 then TAB_TOT_EN             = val
    elseif id == 18 then TAB_LOC_EN             = val
    elseif id == 19 then TAB_LNK_EN             = val
    elseif id == 20 then TAB_PWR_EN             = val
    elseif id == 21 then TAB_RAD_EN             = val
    end
end

-- ------------------------------------------------------------
-- 10. ARM-SWITCH DETECTION
-- ------------------------------------------------------------

-- Commits the pending switch detection result to ARM_SWITCH / ARM_VALUE
-- and clears the listen state. Called when the user presses ENTER after
-- a switch movement has been detected during sw_listen mode.
local function confirm_sw_listen()
    if sw_pending ~= "" then
        ARM_SWITCH, ARM_VALUE = sw_pending, sw_pending_val
    end
    sw_listen, sw_pending = false, ""
end

-- Polls switch positions on every run() cycle while sw_listen is active.
--   Phase 1: scans all ARM_SW_LIST entries against sw_snapshot; on any
--            change, records the switch name/value in sw_pending/sw_pending_val.
--   Phase 2: once a candidate is captured (sw_pending ~= ""), only tracks
--            that switch to reflect real-time position changes in the menu row.
-- Calls refresh_cfg_vals() so the "Arm SW" row always shows the live state.
local function track_sw_listen()
    if sw_pending ~= "" then
        local v = getValue(sw_pending) or 0
        if v ~= sw_pending_val then sw_pending_val = v; refresh_cfg_vals() end
    else
        for i, sw in ipairs(ARM_SW_LIST) do
            local v = getValue(sw) or 0
            if v ~= sw_snapshot[i] then
                sw_pending, sw_pending_val = sw, v
                refresh_cfg_vals(); break
            end
        end
    end
end

-- ------------------------------------------------------------
-- 11. EVENT HANDLING
-- ------------------------------------------------------------

-- Processes all EdgeTX events for the configuration menu.
-- Operates in two modes:
--
--   Navigation mode (cfg_edit == false):
--     ROT / +/-  scroll the selection cursor.
--     ENTER      opens numeric edit, toggles booleans, or starts arm-listen.
--     EXIT       closes the tool (returns 2 to EdgeTX).
--
--   Edit mode (cfg_edit == true):
--     ROT / +/-  increment or decrement the active numeric value within its
--                clamped range; refreshes the menu label on every step.
--     ENTER      confirms the new value, saves immediately, and exits edit mode.
--     EXIT       cancels the edit, restores the snapshot captured on entry,
--                saves the restored value, and exits edit mode.
--
-- Boolean and tab-toggle items use instant-save on ENTER without entering
-- edit mode. The arm-switch item redirects ENTER to the sw_listen flow.
-- Returns 0 to continue rendering, or 2 to signal EdgeTX to close the tool.
local function handle_cfg_events(event)
    if event == EVT_EXIT_BREAK and not cfg_edit then
        return 2  -- close the Tools script; return to the radio menu
    end

    if not cfg_edit then
        -- Navigation mode
        if     event == EVT_ROT_RIGHT  or event == EVT_PLUS_FIRST  then cfg_sel = cycle(cfg_sel, cfg_len,  1)
        elseif event == EVT_ROT_LEFT   or event == EVT_MINUS_FIRST then cfg_sel = cycle(cfg_sel, cfg_len, -1)
        elseif event == EVT_ENTER_BREAK then
            local id = cfg_id[cfg_sel]

            if id == 13 then
                -- Arm-switch item: first ENTER starts listen mode, second ENTER commits
                if sw_listen then
                    confirm_sw_listen()
                    save_config()
                    refresh_cfg_vals()
                else
                    for i, sw in ipairs(ARM_SW_LIST) do sw_snapshot[i] = getValue(sw) or 0 end
                    sw_pending, sw_listen, cfg_edit = "", true, true
                    refresh_cfg_vals()
                end

            elseif id == 2 or id == 3 or id == 7 or id == 11 or id == 12
                or id == 14 or (id >= 15 and id <= 21) then
                -- Boolean toggle: compute new value and save immediately
                local nv
                if     id == 2  then nv = not BATTERY_ALERT_ENABLED
                elseif id == 3  then nv = not BATTERY_ALERT_AUDIO
                elseif id == 7  then nv = TX_BAT_WARN > 0 and 0 or bat_warn_default
                elseif id == 11 then nv = not HAPTIC
                elseif id == 12 then nv = not AUTO_TAB
                elseif id == 14 then nv = not GPX_LOG_ENABLED
                elseif id == 15 then nv = not TAB_BAT_EN
                elseif id == 16 then nv = not TAB_GPS_EN
                elseif id == 17 then nv = not TAB_TOT_EN
                elseif id == 18 then nv = not TAB_LOC_EN
                elseif id == 19 then nv = not TAB_LNK_EN
                elseif id == 20 then nv = not TAB_PWR_EN
                elseif id == 21 then nv = not TAB_RAD_EN
                end
                cfg_set_var(id, nv)
                save_config()
                refresh_cfg_vals()

            else
                -- Numeric item: snapshot current value and enter edit mode
                if     id == 1  then cfg_edit_snapshot = UPDATE_RATE
                elseif id == 4  then cfg_edit_snapshot = BATTERY_ALERT_INTERVAL
                elseif id == 5  then cfg_edit_snapshot = BATTERY_ALERT_STEP
                elseif id == 6  then cfg_edit_snapshot = SAG_CURRENT_THRESHOLD
                elseif id == 8  then cfg_edit_snapshot = TOAST_DURATION
                elseif id == 9  then cfg_edit_snapshot = BAT_CAPACITY_MAH
                elseif id == 10 then cfg_edit_snapshot = MIN_SATS
                end
                cfg_edit = true
            end
        end

    else
        -- Edit mode
        local id = cfg_id[cfg_sel]

        if event == EVT_ENTER_BREAK then
            if id == 13 and sw_listen then
                confirm_sw_listen()
                refresh_cfg_vals()
            end
            save_config()
            cfg_edit_snapshot, cfg_edit = nil, false

        elseif event == EVT_EXIT_BREAK then
            if id == 13 and sw_listen then
                sw_listen, sw_pending = false, ""
                refresh_cfg_vals()
            elseif cfg_edit_snapshot ~= nil then
                cfg_set_var(id, cfg_edit_snapshot)  -- cancel: restore the pre-edit value
                cfg_edit_snapshot = nil
                save_config()
                refresh_cfg_vals()
            end
            cfg_edit = false

        elseif event == EVT_ROT_RIGHT  or event == EVT_PLUS_FIRST
            or event == EVT_ROT_LEFT   or event == EVT_MINUS_FIRST then
            if id ~= 13 then
                local dir = (event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST) and 1 or -1
                local nv
                if     id == 1  then nv = math_max(10,   math_min(500,   UPDATE_RATE            + 10   * dir))
                elseif id == 4  then nv = math_max(0,    math_min(10000, BATTERY_ALERT_INTERVAL + 100  * dir))
                elseif id == 5  then nv = math_max(0.05, math_min(1.0,   BATTERY_ALERT_STEP     + 0.05 * dir))
                elseif id == 6  then nv = math_max(5,    math_min(100,   SAG_CURRENT_THRESHOLD  + 5    * dir))
                elseif id == 8  then nv = math_max(50,   math_min(500,   TOAST_DURATION         + 50   * dir))
                elseif id == 9  then nv = math_max(100,  math_min(20000, BAT_CAPACITY_MAH       + 100  * dir))
                elseif id == 10 then nv = math_max(3,    math_min(8,     MIN_SATS               + dir))
                end
                if nv ~= nil then cfg_set_var(id, nv) end
                refresh_cfg_vals()
            end
        end
    end

    -- Keep cfg_sel inside the visible window [cfg_scroll+1 .. cfg_scroll+VISIBLE_ROWS]
    if     cfg_sel > cfg_scroll + VISIBLE_ROWS then cfg_scroll = cfg_sel - VISIBLE_ROWS
    elseif cfg_sel <= cfg_scroll               then cfg_scroll = cfg_sel - 1
    end

    return 0
end

-- ------------------------------------------------------------
-- 12. DRAWING
-- ------------------------------------------------------------

-- Renders the configuration menu to the LCD.
-- Draws an inverted title bar at the top, then iterates over the visible
-- row window [cfg_scroll+1 .. cfg_scroll+VISIBLE_ROWS]. The selected row
-- is highlighted with INVERS on the label. In edit mode the value field
-- blinks at ~1 Hz: blink_on alternates each second to show active editing.
local function draw_cfg_page(blink_on)
    lcd.clear()
    lcd.drawFilledRectangle(0, 0, SCREEN_W, 10, SOLID)
    lcd.drawText(SCREEN_W / 2, 1, "RCIC Configuration", SMLSIZE + CENTER + INVERS)

    local txt_y   = 13
    local end_idx = math_min(cfg_scroll + VISIBLE_ROWS, cfg_len)

    for i = cfg_scroll + 1, end_idx do
        local flags_label = SMLSIZE
        local flags_val   = SMLSIZE + RIGHT

        if i == cfg_sel then
            flags_label = flags_label + INVERS
            if cfg_edit then
                if blink_on then flags_val = flags_val + INVERS end
            else
                flags_val = flags_val + INVERS
            end
        end

        lcd.drawText(4,            txt_y, cfg_label[i], flags_label)
        lcd.drawText(SCREEN_W - 2, txt_y, cfg_val[i],   flags_val)
        txt_y = txt_y + 9
    end
end

-- ------------------------------------------------------------
-- 13. TOOL LIFECYCLE
-- ------------------------------------------------------------

-- Initializes the configuration tool on first load.
-- Detects screen dimensions and computes VISIBLE_ROWS for the scroll engine.
-- Reads the TX battery warning threshold from the radio's General Settings
-- (used as the restore value when the "TX Alert" toggle is switched ON).
-- Loads the current config from the SD card and builds the initial menu list.
local function init()
    SCREEN_W, SCREEN_H = LCD_W or 128, LCD_H or 64
    VISIBLE_ROWS = math_floor((SCREEN_H - 14) / 9)

    local gs = getGeneralSettings() or {}
    bat_warn_default = gs.battWarn or 6.6

    load_config()
    refresh_cfg_vals()
end

-- Main loop called by EdgeTX on every frame (~30 Hz).
-- Polls the arm-switch listener when active, dispatches the current event to
-- the menu handler, and redraws the screen each frame.
-- Returns 2 to EdgeTX when the user exits via EVT_EXIT_BREAK in navigation mode.
local function run(event)
    if sw_listen then track_sw_listen() end

    local action = handle_cfg_events(event)
    if action == 2 then return 2 end  -- user exited; signal EdgeTX to close the tool

    local blink_on = (math_floor(getTime() / 100) % 2) == 0
    draw_cfg_page(blink_on)
    return 0
end

-- ------------------------------------------------------------

return { init = init, run = run }

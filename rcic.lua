-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version:     1.31
-- Date:        2026-02-21
-- Author:      Alonso Lara (github.com/AlonsoLP)
-- Description: Lightweight telemetry dashboard for EdgeTX 2.9+ with
--              battery alerts, valid GPS check & Plus Code generation.
--
-- License:     MIT License
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
-- 1. USER CONFIGURATION
-- ------------------------------------------------------------
local MIN_SATS               = 4    -- minimum satellites to trust position
local UPDATE_RATE            = 100  -- data update rate (100 = 1s)
local BATTERY_ALERT_ENABLED  = true -- enable/disable visual battery alerts
local BATTERY_ALERT_AUDIO    = true -- enable/disable voice/number readout
local BATTERY_ALERT_INTERVAL = 2000 -- minimum time between alerts (2000 = 20s)
local BATTERY_ALERT_STEP     = 0.1  -- voltage drop for new alert

-- ------------------------------------------------------------
-- 2. CONSTANTS AND INTERNAL CONFIGURATION
-- ------------------------------------------------------------
local CENTISECS_PER_SEC      = 100
local BAT_CONFIG             = {
    { text = "LiPo",  volt = 3.5, v_max = 4.2,  v_min = 3.2, v_range = 1.0 },
    { text = "LiHV",  volt = 3.6, v_max = 4.35, v_min = 3.2, v_range = 1.15 },
    { text = "LiIon", volt = 3.2, v_max = 4.2,  v_min = 2.8, v_range = 1.4 }
}

-- ------------------------------------------------------------
-- 2.1. FUNCTION LOCALIZATION
-- ------------------------------------------------------------
-- Standard Lua
local math_floor             = math.floor
local math_abs               = math.abs
local math_max               = math.max
local math_min               = math.min
local math_cos               = math.cos
local math_sqrt              = math.sqrt
local string_fmt             = string.format
local string_sub             = string.sub

-- EdgeTX API
local lcd_drawText           = lcd.drawText
local lcd_drawRect           = lcd.drawRectangle
local lcd_drawFilledRect     = lcd.drawFilledRectangle
local lcd_clear              = lcd.clear
local getTime                = getTime
local getValue               = getValue
local playNumber             = playNumber

-- ------------------------------------------------------------
-- 3. SCREEN AND FONT DETECTION
-- ------------------------------------------------------------
local SCREEN_W, SCREEN_H
local FONT_COORDS, FONT_INFO
local SCREEN_CENTER_X

-- ------------------------------------------------------------
-- 4. LAYOUT
-- ------------------------------------------------------------
local TAB_H, CONTENT_Y, CONTENT_H
local LAYOUT
local TABS, TABS_LAYOUT, TAB_W

-- ------------------------------------------------------------
-- 5. TRANSLATION SYSTEM
-- ------------------------------------------------------------
local function detect_language()
    local settings = getGeneralSettings()
    if settings and settings.language then
        return string_sub(string.lower(settings.language), 1, 2)
    end
    return "es"
end

local LANG
local BASE_TEXTS        = {
    waiting  = "WAITING GPS",
    sats     = "SAT",
    altitude = "ALT",
    cells    = "CELLS",
    vcell    = "VCELL",
    max_alt  = "MAX ALT",
    distance = "DIST",
    min_volt = "MIN V",
    max_spd  = "MAX SPD",
    max_cur  = "MAX AMP",
}

local LANG_OVERRIDES    = {
    es = {
        waiting  = "ESPERANDO GPS",
        cells    = "CELDAS",
        vcell    = "VCELDA",
        distance = "DIST",
        max_spd  = "VEL MAX",
    },
    fr = {
        waiting  = "ATTENTE GPS",
        cells    = "ELEMS",
        vcell    = "VELEM",
        distance = "DIST",
        max_spd  = "VIT MAX",
    },
    de = {
        waiting  = "WARTE GPS",
        altitude = "HOEHE",
        cells    = "ZELLEN",
        vcell    = "VZELL",
        max_alt  = "MAX HOEHE",
        distance = "DIST",
        max_spd  = "V MAX",
        max_cur  = "A MAX",
    },
    it = {
        waiting  = "ATTESA GPS",
        altitude = "ALTITUDINE",
        cells    = "CELLE",
        vcell    = "VCELLA",
        distance = "DIST",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
    },
    pt = {
        waiting  = "AGUARDANDO",
        cells    = "CELULAS",
        vcell    = "VCEL",
        distance = "DIST",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
    },
    ru = {
        waiting  = "OZHID GPS",
        sats     = "SPT",
        altitude = "VYSOTA",
        cells    = "BAN",
        vcell    = "VBAN",
        max_alt  = "MAX VYS",
        distance = "DIST",
        max_spd  = "MAX SKOR",
        max_cur  = "MAX TOK",
    },
    pl = {
        waiting  = "SZUKAM GPS",
        altitude = "WYS",
        cells    = "CELA",
        vcell    = "VCELA",
        max_alt  = "MAX WYS",
        distance = "DIST",
        max_spd  = "MAX PRED",
        max_cur  = "MAX PRAD",
    },
    cz = {
        waiting  = "CEKAM GPS",
        altitude = "VYSKA",
        cells    = "CLANKY",
        vcell    = "VCLAN",
        max_alt  = "MAX VYS",
        distance = "VZDAL",
        max_spd  = "RYCHL",
        max_cur  = "PROUD",
    },
    jp = {
        waiting  = "GPS TAIKI",
        sats     = "EIS",
        altitude = "KODO",
        cells    = "SERU",
        vcell    = "VSERU",
        max_alt  = "MAX KODO",
        distance = "KYORI",
        max_spd  = "SOKU",
        max_cur  = "DENRYU",
    },
}

-- ------------------------------------------------------------
-- 6. PERSISTENT VARIABLES
-- ------------------------------------------------------------

local current_page      = 1

local gps_state         = {
    lat           = 0,
    lon           = 0,
    alt           = 0,
    fix           = false,
    plus_code     = "",
    plus_code_url = "",
    lat_str       = "0.000000",
    lon_str       = "0.000000"
}

local last_update_time  = 0

local bat_state         = {
    cells      = 0,
    last_volt  = 0,
    alert_time = 0,
    alert_volt = 0,
    cfg_idx    = 1, -- Default: LiPo index = 1
    threshold  = BAT_CONFIG[1].volt,
    lbl_vmin   = string_fmt("%.2fV", BAT_CONFIG[1].v_min),
    lbl_vmax   = string_fmt("%.2fV", BAT_CONFIG[1].v_max),
    -- Cached strings for drawing
    rx_fmt     = "0.00V",
    cell_fmt   = "0.00V",
    cell_s     = "0S",
    pct_val    = 0,
    pct_str    = "0%"
}
local toast_msg         = nil
local toast_time        = 0
local toast_layout      = { x = 0, y = 0, w = 0, h = 11 }

local telemetry_live    = false
local sats              = 0
local rx_bt             = 0
local cell_voltage      = 0

-- Pre-allocate to save GC cycles
local str_minus_minus_V = "--V"
local str_minus_minus   = "--"

local function show_toast(msg)
    toast_msg = msg
    toast_time = getTime()

    local msg_w = #toast_msg * 6 + 10 -- Width estimation
    if msg_w < 60 then msg_w = 60 end

    toast_layout.w = msg_w
    toast_layout.x = math_floor((SCREEN_W - msg_w) / 2)
    -- toast_layout.y is static, pre-calculated in init()
end

local force_redraw = true

local stats = {
    max_alt     = 0,
    total_dist  = 0,
    min_voltage = 0,
    max_speed   = 0,
    max_current = 0,
}

local tot_strs = {
    l1_left  = "",
    l1_right = "",
    l2_left  = "",
    l2_right = "",
    l3_left  = ""
}

local gps_str_info = ""

local function reset_stats()
    stats.max_alt     = 0
    stats.total_dist  = 0
    stats.min_voltage = 0
    stats.max_speed   = 0
    stats.max_current = 0
end

-- ------------------------------------------------------------
-- 7. UTILITY FUNCTIONS
-- ------------------------------------------------------------

local function detect_cells(voltage)
    if voltage < 0.5 then return 0 end
    return math_floor(voltage / 4.3) + 1
end

local function is_valid_gps(lat, lon)
    return lat >= -90 and lat <= 90 and
        lon >= -180 and lon <= 180 and
        not (lat == 0 and lon == 0)
end

local lat_divisors = { 800000, 40000, 2000, 100, 5 }
local lon_divisors = { 640000, 32000, 1600, 80, 4 }
local alphabet = "23456789CFGHJMPQRVWX"

local function to_plus_code(lat, lon)
    lat = math_max(-90, math_min(89.9999, lat)) + 90
    while lon < -180 do lon = lon + 360 end
    while lon >= 180 do lon = lon - 360 end
    lon = lon + 180

    local code = ""
    local lat_val = math_floor(lat * 40000)
    local lon_val = math_floor(lon * 32000)

    for i = 1, 5 do
        local lat_digit = math_floor(lat_val / lat_divisors[i]) % 20
        local lon_digit = math_floor(lon_val / lon_divisors[i]) % 20
        code = code .. string_sub(alphabet, lat_digit + 1, lat_digit + 1)
        code = code .. string_sub(alphabet, lon_digit + 1, lon_digit + 1)
        if i == 4 then code = code .. "+" end
    end

    -- Calculate and append the 11th character (sub-grid pixel)
    local row = lat_val % 5
    local col = lon_val % 4
    local ndx = row * 4 + col
    code = code .. string_sub(alphabet, ndx + 1, ndx + 1)

    return code
end

-- Approximate Distance (Equirectangular)
local RAD = math.pi / 180
local R_EARTH = 6371000

local function fast_dist(lat1, lon1, lat2, lon2)
    local x = (lon2 - lon1) * RAD * math_cos((lat1 + lat2) / 2 * RAD)
    local y = (lat2 - lat1) * RAD
    return math_sqrt(x * x + y * y) * R_EARTH
end

-- Format distance (m or km)
local function format_dist(meters)
    return meters >= 1000 and string_fmt("%.2fkm", meters / 1000) or string_fmt("%.0fm", meters)
end

-- ------------------------------------------------------------
-- 8. INIT FUNCTION
-- ------------------------------------------------------------

local function init()
    SCREEN_W    = LCD_W or 128
    SCREEN_H    = LCD_H or 64

    FONT_COORDS = MIDSIZE
    FONT_INFO   = SMLSIZE
    if SCREEN_W >= 300 then
        FONT_COORDS = DBLSIZE
        FONT_INFO   = MIDSIZE
    end

    SCREEN_CENTER_X = SCREEN_W / 2
    TAB_H           = 9
    CONTENT_Y       = TAB_H + 1
    CONTENT_H       = SCREEN_H - CONTENT_Y

    LAYOUT          = {
        coord_lat_y = CONTENT_Y + math_floor(CONTENT_H * 0.10),
        coord_lon_y = CONTENT_Y + math_floor(CONTENT_H * 0.38),
        info_y      = CONTENT_Y + math_floor(CONTENT_H * 0.65),
        url_y       = CONTENT_Y + math_floor(CONTENT_H * 0.84),
        waiting_y   = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        sats_y      = CONTENT_Y + math_floor(CONTENT_H * 0.70),
        bat_label_y = CONTENT_Y + math_floor(CONTENT_H * 0.037),
        bat_value_y = CONTENT_Y + math_floor(CONTENT_H * 0.222),
        bat_cell_y  = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        bat_pct_y   = CONTENT_Y + math_floor(CONTENT_H * 0.63),
        bat_bar_y   = CONTENT_Y + math_floor(CONTENT_H * 0.815),
        bar_w       = SCREEN_W - 2,
        tot_line1_y = CONTENT_Y + math_floor(CONTENT_H * 0.037),
        tot_line2_y = CONTENT_Y + math_floor(CONTENT_H * 0.222),
        tot_line3_y = CONTENT_Y + math_floor(CONTENT_H * 0.407),
        gps_lost_h  = SCREEN_H - CONTENT_Y,
        -- tot_line4_y = CONTENT_Y + math_floor(CONTENT_H * 0.593),
        -- tot_line5_y = CONTENT_Y + math_floor(CONTENT_H * 0.778)
    }

    toast_layout.y  = math_floor(SCREEN_H / 2) - 5

    TABS            = { "BAT", "GPS", "TOT" }
    TAB_W           = math_floor(SCREEN_W / #TABS)
    TABS_LAYOUT     = {}
    for i = 1, #TABS do
        local x = (i - 1) * TAB_W
        local w = (i == #TABS) and (SCREEN_W - x) or TAB_W
        TABS_LAYOUT[i] = { name = TABS[i], x = x, w = w, centerText_x = x + math_floor(w / 2) }
    end

    LANG = detect_language()

    if LANG_OVERRIDES[LANG] then
        for k, v in pairs(LANG_OVERRIDES[LANG]) do BASE_TEXTS[k] = v end
    end
end

-- ------------------------------------------------------------
-- 9. DATA UPDATE (BACKGROUND) FUNCTION
-- ------------------------------------------------------------

local function background()
    local current_time = getTime()
    if current_time - last_update_time < UPDATE_RATE then
        return
    end
    last_update_time = current_time

    local gps_data = getValue("GPS")
    sats = getValue("Sats") or 0
    rx_bt = getValue("RxBt") or 0
    local rssi = getValue("RQly") or 0
    local alt = getValue("Alt") or getValue("GAlt") or 0
    local gspd = getValue("GSpd") or 0
    local curr = getValue("Curr") or 0

    telemetry_live = (rssi > 0)
    local cur_lat, cur_lon = 0, 0

    if type(gps_data) == "table" then
        cur_lat = gps_data["lat"] or gps_data[1] or 0
        cur_lon = gps_data["lon"] or gps_data[2] or 0
    end

    -- --- Update GPS position and stats ---
    if telemetry_live and sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
        if gps_state.lat ~= cur_lat or gps_state.lon ~= cur_lon then
            gps_state.plus_code = to_plus_code(cur_lat, cur_lon)
            gps_state.plus_code_url = "+CODE " .. gps_state.plus_code
            gps_state.lat_str = string_fmt("%.6f", cur_lat)
            gps_state.lon_str = string_fmt("%.6f", cur_lon)

            if gps_state.fix then
                local d = fast_dist(gps_state.lat, gps_state.lon, cur_lat, cur_lon)
                if d < 5000 then
                    stats.total_dist = stats.total_dist + d
                end
            end
        end

        gps_state.lat = cur_lat
        gps_state.lon = cur_lon
        gps_state.alt = alt
        gps_state.fix = true

        if alt > stats.max_alt then
            stats.max_alt = alt
        end

        if gspd > stats.max_speed then
            stats.max_speed = gspd
        end
    end

    if telemetry_live and curr > stats.max_current then
        stats.max_current = curr
    end

    -- --- Battery ---
    if math_abs(rx_bt - bat_state.last_volt) > 1.0 then
        bat_state.cells = detect_cells(rx_bt)
    end
    bat_state.last_volt = rx_bt

    cell_voltage = bat_state.cells > 0 and (rx_bt / bat_state.cells) or 0

    if bat_state.cells > 0 and cell_voltage > 0 then
        if stats.min_voltage == 0 or cell_voltage < stats.min_voltage then
            stats.min_voltage = cell_voltage
        end
    end

    -- Bat cache
    local bcfg = BAT_CONFIG[bat_state.cfg_idx]
    bat_state.rx_fmt = string_fmt("%.2fV", rx_bt)
    bat_state.cell_fmt = string_fmt("%.2fV", cell_voltage)
    bat_state.cell_s = bat_state.cells .. "S"
    bat_state.pct_val = bat_state.cells > 0 and math_max(0, math_min(1, (cell_voltage - bcfg.v_min) / bcfg.v_range)) or 0
    bat_state.pct_str = math_floor(bat_state.pct_val * 100) .. "%"

    -- GPS cache
    gps_str_info = BASE_TEXTS.sats .. ":" .. sats
    if gps_state.alt ~= 0 then
        gps_str_info = gps_str_info .. "  " .. BASE_TEXTS.altitude .. ":" .. math_floor(gps_state.alt) .. "m"
    end

    -- TOT cache
    tot_strs.l1_left  = string_fmt("%s:%.2fV", BASE_TEXTS.min_volt, stats.min_voltage)
    tot_strs.l1_right = string_fmt("%s: %.1fA", BASE_TEXTS.max_cur, stats.max_current)
    tot_strs.l2_left  = string_fmt("%s: %.0fm", BASE_TEXTS.max_alt, stats.max_alt)
    tot_strs.l2_right = string_fmt("%s: %s", BASE_TEXTS.distance, format_dist(stats.total_dist))
    tot_strs.l3_left  = string_fmt("%s: %.1fkmh", BASE_TEXTS.max_spd, stats.max_speed)

    force_redraw      = true
end

-- ------------------------------------------------------------
-- 10. DRAWING FUNCTIONS
-- ------------------------------------------------------------

local function draw_tabs()
    for i = 1, #TABS_LAYOUT do
        local tab = TABS_LAYOUT[i]
        if i == current_page then
            -- active tab: solid background, inverted text
            lcd_drawFilledRect(tab.x, 0, tab.w, TAB_H, SOLID)
            lcd_drawText(tab.centerText_x, 1, tab.name, SMLSIZE + CENTER + INVERS)
        else
            -- inactive tab: border only, normal text
            lcd_drawRect(tab.x, 0, tab.w, TAB_H, SOLID)
            lcd_drawText(tab.centerText_x, 1, tab.name, SMLSIZE + CENTER)
        end
    end
end

local function draw_bat_page(blink_on)
    local bcfg = BAT_CONFIG[bat_state.cfg_idx]
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_value_y,
        bat_state.rx_fmt, DBLSIZE + CENTER)
    lcd_drawText(0, LAYOUT.bat_label_y, BASE_TEXTS.vcell, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.bat_label_y, BASE_TEXTS.cells, SMLSIZE + RIGHT)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_label_y, bcfg.text, SMLSIZE + CENTER)

    local cell_voltage_alert = (BATTERY_ALERT_ENABLED and bat_state.cells > 0 and cell_voltage > 0 and cell_voltage < bat_state.threshold)

    if bat_state.cells > 0 then
        local volt_flags = SMLSIZE
        if cell_voltage_alert then
            volt_flags = volt_flags + INVERS
        end
        lcd_drawText(0, LAYOUT.bat_cell_y, bat_state.cell_fmt, volt_flags)
        lcd_drawText(SCREEN_W, LAYOUT.bat_cell_y, bat_state.cell_s, SMLSIZE + RIGHT)
    else
        lcd_drawText(0, LAYOUT.bat_cell_y, str_minus_minus_V, SMLSIZE)
        lcd_drawText(SCREEN_W, LAYOUT.bat_cell_y, str_minus_minus, SMLSIZE + RIGHT)
    end

    if (not cell_voltage_alert) or blink_on then
        lcd_drawText(0, LAYOUT.bat_pct_y,
            bat_state.lbl_vmin, SMLSIZE)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_pct_y,
            bat_state.pct_str, SMLSIZE + CENTER)
        lcd_drawText(SCREEN_W, LAYOUT.bat_pct_y,
            bat_state.lbl_vmax, SMLSIZE + RIGHT)
        lcd_drawRect(0, LAYOUT.bat_bar_y, LAYOUT.bar_w + 2, 7, SOLID)
        if bat_state.cells > 0 then
            local fill = math_floor(bat_state.pct_val * LAYOUT.bar_w)
            if fill > 0 then
                lcd_drawFilledRect(1, LAYOUT.bat_bar_y + 1, fill, 5, SOLID)
            end
        end
    end
end

local function draw_gps_page(blink_on)
    if gps_state.fix and not telemetry_live and blink_on then
        lcd_drawRect(0, CONTENT_Y, SCREEN_W, LAYOUT.gps_lost_h, SOLID)
    end

    if gps_state.fix then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.coord_lat_y,
            gps_state.lat_str, FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.coord_lon_y,
            gps_state.lon_str, FONT_COORDS + CENTER)

        lcd_drawText(SCREEN_CENTER_X, LAYOUT.info_y, gps_str_info, FONT_INFO + CENTER)

        lcd_drawText(SCREEN_CENTER_X, LAYOUT.url_y,
            gps_state.plus_code_url, FONT_INFO + CENTER)
    else
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, BASE_TEXTS.waiting, FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y,
            BASE_TEXTS.sats .. ": " .. sats, FONT_INFO + CENTER)
    end
end

local function draw_tot_page()
    lcd_drawText(0, LAYOUT.tot_line1_y, tot_strs.l1_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line1_y, tot_strs.l1_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line2_y, tot_strs.l2_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line2_y, tot_strs.l2_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line3_y, tot_strs.l3_left, SMLSIZE)
end

local last_blink_state = false

-- ------------------------------------------------------------
-- 11. MAIN FUNCTION
-- ------------------------------------------------------------
local function run(event)
    if event ~= 0 then
        force_redraw = true

        if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
            current_page = current_page % #TABS + 1
        elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
            current_page = (current_page - 2) % #TABS + 1
        elseif event == EVT_ENTER_FIRST then
            if current_page == 1 then
                bat_state.cfg_idx = (bat_state.cfg_idx % #BAT_CONFIG) + 1
                local bcfg = BAT_CONFIG[bat_state.cfg_idx]
                bat_state.threshold = bcfg.volt
                bat_state.lbl_vmin = string_fmt("%.2fV", bcfg.v_min)
                bat_state.lbl_vmax = string_fmt("%.2fV", bcfg.v_max)
                show_toast(string_fmt("** %s (%.1fv) **", bcfg.text, bat_state.threshold))
            elseif current_page == 2 then
                if type(screenshot) == "function" then
                    screenshot()
                end
                show_toast("** SCREENSHOT **")
            elseif current_page == 3 then
                reset_stats()
                show_toast("** RESET **")
            end
        end
    end

    -- --- Audio and alarms ---
    local current_time = getTime()
    if BATTERY_ALERT_ENABLED and bat_state.cells > 0 and cell_voltage > 0 then
        if cell_voltage < bat_state.threshold then
            if bat_state.alert_volt == 0 or
                (current_time - bat_state.alert_time >= BATTERY_ALERT_INTERVAL and bat_state.alert_volt - cell_voltage >= BATTERY_ALERT_STEP) then
                if BATTERY_ALERT_AUDIO then
                    playNumber(math_floor(cell_voltage * 10), 0, PREC1)
                end
                bat_state.alert_time = current_time
                bat_state.alert_volt = cell_voltage
            end
        else
            bat_state.alert_volt = 0
        end
    end

    local blink_on = (math_floor(current_time / CENTISECS_PER_SEC) % 2) == 0
    if blink_on ~= last_blink_state then
        last_blink_state = blink_on
        force_redraw = true
    end

    local show_toast_now = toast_msg and (current_time - toast_time) < 200
    if show_toast_now then
        force_redraw = true -- always redraw while toast is visible
    end

    if not force_redraw then return 0 end
    force_redraw = false

    lcd_clear()
    draw_tabs()

    if current_page == 1 then
        draw_bat_page(blink_on)
    elseif current_page == 2 then
        draw_gps_page(blink_on)
    elseif current_page == 3 then
        draw_tot_page()
    end

    -- Unified message system (Toast)
    if toast_msg and (current_time - toast_time) < 200 then
        lcd_drawFilledRect(toast_layout.x - 2, toast_layout.y - 1, toast_layout.w + 4, toast_layout.h, SOLID)
        lcd_drawText(SCREEN_CENTER_X, toast_layout.y, toast_msg, SMLSIZE + CENTER + INVERS)
    end

    return 0
end

return { init = init, background = background, run = run }

-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version:     1.02
-- Date:        2026-02-19
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
local BATTERY_ALERT_ENABLED  = true -- enable/disable battery alerts
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
local SCREEN_W               = LCD_W or 128
local SCREEN_H               = LCD_H or 64

local FONT_COORDS            = MIDSIZE
local FONT_INFO              = SMLSIZE
if SCREEN_W >= 300 then
    FONT_COORDS = DBLSIZE
    FONT_INFO   = MIDSIZE
end

local SCREEN_CENTER_X = SCREEN_W / 2

-- ------------------------------------------------------------
-- 4. LAYOUT
-- ------------------------------------------------------------
local TAB_H           = 9                    -- tab bar height
local CONTENT_Y       = TAB_H + 1            -- content start y (10px)
local CONTENT_H       = SCREEN_H - CONTENT_Y -- available height for content

-- Proportional positions within content area
local LAYOUT          = {
    -- GPS page
    coord_lat_y = CONTENT_Y + math_floor(CONTENT_H * 0.10),
    coord_lon_y = CONTENT_Y + math_floor(CONTENT_H * 0.38),
    info_y      = CONTENT_Y + math_floor(CONTENT_H * 0.65),
    url_y       = CONTENT_Y + math_floor(CONTENT_H * 0.84),
    waiting_y   = CONTENT_Y + math_floor(CONTENT_H * 0.25),
    sats_y      = CONTENT_Y + math_floor(CONTENT_H * 0.70),
    -- BAT page
    bat_label_y = CONTENT_Y + math_floor(CONTENT_H * 0.037),
    bat_value_y = CONTENT_Y + math_floor(CONTENT_H * 0.222),
    bat_cell_y  = CONTENT_Y + math_floor(CONTENT_H * 0.25),
    bat_pct_y   = CONTENT_Y + math_floor(CONTENT_H * 0.63),
    bat_bar_y   = CONTENT_Y + math_floor(CONTENT_H * 0.815),
    -- TOT page
    tot_line1_y = CONTENT_Y + math_floor(CONTENT_H * 0.037),
    tot_line2_y = CONTENT_Y + math_floor(CONTENT_H * 0.222),
    tot_line3_y = CONTENT_Y + math_floor(CONTENT_H * 0.407),
    tot_line4_y = CONTENT_Y + math_floor(CONTENT_H * 0.593),
    tot_line5_y = CONTENT_Y + math_floor(CONTENT_H * 0.778)
}

local TABS            = { "BAT", "GPS", "TOT" }
local TAB_W           = math_floor(SCREEN_W / #TABS)

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

local LANG = detect_language()

local BASE_TEXTS = {
    lost     = "!LOST!",
    waiting  = "WAITING GPS",
    sats     = "SAT",
    altitude = "ALT",
    battery  = "BATTERY",
    cells    = "CELLS",
    vcell    = "VCELL",
    max_alt  = "MAX ALT",
    distance = "DIST",
    min_volt = "MIN V",
    max_spd  = "MAX SPD",
    max_cur  = "MAX AMP",
}

local LANG_OVERRIDES = {
    es = {
        lost     = "!PERDIDO!",
        waiting  = "ESPERANDO GPS",
        battery  = "BATERIA",
        cells    = "CELDAS",
        vcell    = "VCELDA",
        distance = "DIST",
        max_spd  = "VEL MAX",
    },
    fr = {
        lost     = "!PERDU!",
        waiting  = "ATTENTE GPS",
        battery  = "BATTERIE",
        cells    = "ELEMS",
        vcell    = "VELEM",
        distance = "DIST",
        max_spd  = "VIT MAX",
    },
    de = {
        lost     = "!VERLOREN!",
        waiting  = "WARTE GPS",
        altitude = "HOEHE",
        battery  = "BATTERIE",
        cells    = "ZELLEN",
        vcell    = "VZELL",
        max_alt  = "MAX HOEHE",
        distance = "DIST",
        max_spd  = "V MAX",
        max_cur  = "A MAX",
    },
    it = {
        lost     = "!PERSO!",
        waiting  = "ATTESA GPS",
        altitude = "ALTITUDINE",
        battery  = "BATTERIA",
        cells    = "CELLE",
        vcell    = "VCELLA",
        distance = "DIST",
        flight_t = "TEMPO",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
    },
    pt = {
        lost     = "!PERDIDO!",
        waiting  = "AGUARDANDO",
        battery  = "BATERIA",
        cells    = "CELULAS",
        vcell    = "VCEL",
        distance = "DIST",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
    },
    ru = {
        lost     = "!POTEPAH!",
        waiting  = "OZHID GPS",
        sats     = "SPT",
        altitude = "VYSOTA",
        battery  = "BAT",
        cells    = "BAN",
        vcell    = "VBAN",
        max_alt  = "MAX VYS",
        distance = "DIST",
        max_spd  = "MAX SKOR",
        max_cur  = "MAX TOK",
    },
    pl = {
        lost     = "!ZGUBIONY!",
        waiting  = "SZUKAM GPS",
        altitude = "WYS",
        battery  = "BAT",
        cells    = "CELA",
        vcell    = "VCELA",
        max_alt  = "MAX WYS",
        distance = "DIST",
        max_spd  = "MAX PRED",
        max_cur  = "MAX PRAD",
    },
    cz = {
        lost     = "!ZTRACENO!",
        waiting  = "CEKAM GPS",
        altitude = "VYSKA",
        battery  = "BAT",
        cells    = "CLANKY",
        vcell    = "VCLAN",
        max_alt  = "MAX VYS",
        distance = "VZDAL",
        max_spd  = "RYCHL",
        max_cur  = "PROUD",
    },
    jp = {
        lost     = "!FUNSHITSU!",
        waiting  = "GPS TAIKI",
        sats     = "EIS",
        altitude = "KODO",
        battery  = "BAT",
        cells    = "SERU",
        vcell    = "VSERU",
        max_alt  = "MAX KODO",
        distance = "KYORI",
        max_spd  = "SOKU",
        max_cur  = "DENRYU",
    },
}

local TR = {}
for k, v in pairs(BASE_TEXTS) do
    TR[k] = v
end
if LANG_OVERRIDES[LANG] then
    for k, v in pairs(LANG_OVERRIDES[LANG]) do
        TR[k] = v
    end
end

-- ------------------------------------------------------------
-- 6. PERSISTENT VARIABLES
-- ------------------------------------------------------------

local current_page     = 1 -- 1=BAT, 2=GPS, 3=TOT

local gps_state        = {
    lat           = 0,
    lon           = 0,
    alt           = 0,
    fix           = false,
    plus_code     = "",
    plus_code_url = "",
    lat_str       = "0.000000",
    lon_str       = "0.000000"
}

local last_update_time = 0

local bat_state        = {
    cells      = 0,
    last_volt  = 0,
    alert_time = 0,
    alert_volt = 0,
    cfg_idx    = 1, -- Default: LiPo index = 1
    threshold  = BAT_CONFIG[1].volt,
    lbl_vmin   = string_fmt("%.2fV", BAT_CONFIG[1].v_min),
    lbl_vmax   = string_fmt("%.2fV", BAT_CONFIG[1].v_max)
}
local toast_msg        = nil
local toast_time       = 0
local toast_x          = 0
local toast_y          = 0
local toast_w          = 0

local function show_toast(msg)
    toast_msg   = msg
    toast_time  = getTime()

    local msg_w = #toast_msg * 6 + 10 -- Width estimation
    if msg_w < 60 then msg_w = 60 end

    toast_w = msg_w
    toast_x = math_floor((SCREEN_W - msg_w) / 2)
    toast_y = math_floor(SCREEN_H / 2) - 5
end

local stats = {
    max_alt     = 0,
    total_dist  = 0,
    min_voltage = 0,
    max_speed   = 0,
    max_current = 0,
}

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

-- Plus Code (Open Location Code) — precision ~14m (10 digits)


local function to_plus_code(lat, lon)
    local alphabet = "23456789CFGHJMPQRVWX"
    lat = math_max(-90, math_min(89.9999, lat)) + 90
    while lon < -180 do lon = lon + 360 end
    while lon >= 180 do lon = lon - 360 end
    lon = lon + 180

    -- Multipliers pre-calculated for the 5 loops (20^(5-i)*5 and 20^(5-i)*4) to avoid CPU-hungry power (^) ops
    local lat_divisors = { 800000, 40000, 2000, 100, 5 }
    local lon_divisors = { 640000, 32000, 1600, 80, 4 }

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
    if meters >= 1000 then
        return string_fmt("%.2fkm", meters / 1000)
    else
        return string_fmt("%.0fm", meters)
    end
end

-- ------------------------------------------------------------
-- 8. DRAWING FUNCTIONS
-- ------------------------------------------------------------

local function draw_tabs()
    for i = 1, #TABS do
        local name = TABS[i]
        local x = (i - 1) * TAB_W
        local w = (i == #TABS) and (SCREEN_W - x) or TAB_W -- last tab takes the rest
        if i == current_page then
            -- active tab: solid background, inverted text
            lcd_drawFilledRect(x, 0, w, TAB_H, SOLID)
            lcd_drawText(x + math_floor(w / 2), 1, name, SMLSIZE + CENTER + INVERS)
        else
            -- inactive tab: border only, normal text
            lcd_drawRect(x, 0, w, TAB_H, SOLID)
            lcd_drawText(x + math_floor(w / 2), 1, name, SMLSIZE + CENTER)
        end
    end
end

local function draw_bat_page(rx_bt, cell_voltage, cell_voltage_alert, blink_on)
    local bcfg = BAT_CONFIG[bat_state.cfg_idx]
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_value_y,
        string_fmt("%.2fV", rx_bt), DBLSIZE + CENTER)
    lcd_drawText(0, LAYOUT.bat_label_y, TR.vcell, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.bat_label_y, TR.cells, SMLSIZE + RIGHT)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_label_y, bcfg.text, SMLSIZE + CENTER)

    if bat_state.cells > 0 then
        local volt_flags = SMLSIZE
        if cell_voltage_alert then
            volt_flags = volt_flags + INVERS
        end
        lcd_drawText(0, LAYOUT.bat_cell_y,
            string_fmt("%.2fV", cell_voltage), volt_flags)
        lcd_drawText(SCREEN_W, LAYOUT.bat_cell_y,
            bat_state.cells .. "S", SMLSIZE + RIGHT)
    else
        lcd_drawText(0, LAYOUT.bat_cell_y, "--V", SMLSIZE)
        lcd_drawText(SCREEN_W, LAYOUT.bat_cell_y, "--", SMLSIZE + RIGHT)
    end

    local pct = 0
    if bat_state.cells > 0 then
        pct = math_max(0, math_min(1, (cell_voltage - bcfg.v_min) / bcfg.v_range))
    end

    local BAR_X = 0
    local BAR_Y = LAYOUT.bat_bar_y
    local BAR_W = SCREEN_W - 2
    local BAR_H = 7

    if (not cell_voltage_alert) or blink_on then
        lcd_drawText(0, LAYOUT.bat_pct_y,
            bat_state.lbl_vmin, SMLSIZE)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_pct_y,
            math_floor(pct * 100) .. "%", SMLSIZE + CENTER)
        lcd_drawText(SCREEN_W, LAYOUT.bat_pct_y,
            bat_state.lbl_vmax, SMLSIZE + RIGHT)
        lcd_drawRect(BAR_X, BAR_Y, BAR_W + 2, BAR_H, SOLID)
        if bat_state.cells > 0 then
            local fill = math_floor(pct * BAR_W)
            if fill > 0 then
                lcd_drawFilledRect(BAR_X + 1, BAR_Y + 1, fill, BAR_H - 2, SOLID)
            end
        end
    end
end

local function draw_gps_page(telemetry_live, sats, blink_on)
    if gps_state.fix and not telemetry_live and blink_on then
        lcd_drawRect(0, CONTENT_Y, SCREEN_W, SCREEN_H - CONTENT_Y, SOLID)
    end

    if gps_state.fix then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.coord_lat_y,
            gps_state.lat_str, FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.coord_lon_y,
            gps_state.lon_str, FONT_COORDS + CENTER)

        if gps_state.alt ~= 0 then
            local info_str = TR.sats .. ":" .. sats .. "  " .. TR.altitude .. ":" .. math_floor(gps_state.alt) .. "m"
            lcd_drawText(SCREEN_CENTER_X, LAYOUT.info_y, info_str, FONT_INFO + CENTER)
        else
            local info_str = TR.sats .. ":" .. sats
            lcd_drawText(SCREEN_CENTER_X, LAYOUT.info_y, info_str, FONT_INFO + CENTER)
        end

        lcd_drawText(SCREEN_CENTER_X, LAYOUT.url_y,
            gps_state.plus_code_url, FONT_INFO + CENTER)
    else
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, TR.waiting, FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y,
            TR.sats .. ": " .. sats, FONT_INFO + CENTER)
    end
end

local function draw_tot_page()
    lcd_drawText(0, LAYOUT.tot_line1_y,
        string_fmt("%s:%.2fV", TR.min_volt, stats.min_voltage), SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line1_y,
        string_fmt("%s: %.1fA", TR.max_cur, stats.max_current), SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line2_y,
        string_fmt("%s: %.0fm", TR.max_alt, stats.max_alt), SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line2_y,
        string_fmt("%s: %s", TR.distance, format_dist(stats.total_dist)), SMLSIZE + RIGHT)
    local spd_unit = "kmh"
    lcd_drawText(0, LAYOUT.tot_line3_y,
        string_fmt("%s: %.1f%s", TR.max_spd, stats.max_speed, spd_unit), SMLSIZE)
end

-- ------------------------------------------------------------
-- 9. MAIN FUNCTION
-- ------------------------------------------------------------
local function run(event)
    if event == EVT_ENTER_FIRST then
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

    if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
        current_page = current_page % #TABS + 1
    elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
        current_page = (current_page - 2) % #TABS + 1
    end

    -- --- Refresh rate control ---
    local current_time = getTime()
    if current_time - last_update_time < UPDATE_RATE then
        return 0
    end
    last_update_time       = current_time

    -- --- Read telemetry data ---
    local gps_data         = getValue("GPS")
    local sats             = getValue("Sats") or 0
    local rx_bt            = getValue("RxBt") or 0
    local rssi             = getValue("RQly") or 0
    local alt              = getValue("Alt") or getValue("GAlt") or 0
    local gspd             = getValue("GSpd") or 0
    local curr             = getValue("Curr") or 0

    local telemetry_live   = (rssi > 0)
    local cur_lat, cur_lon = 0, 0

    if type(gps_data) == "table" then
        cur_lat = gps_data["lat"] or gps_data[1] or 0
        cur_lon = gps_data["lon"] or gps_data[2] or 0
    end

    -- --- Update GPS position and stats ---
    if telemetry_live and sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
        -- Plus code only if coordinates change
        if gps_state.lat ~= cur_lat or gps_state.lon ~= cur_lon then
            gps_state.plus_code = to_plus_code(cur_lat, cur_lon)
            gps_state.plus_code_url = "+CODE " .. gps_state.plus_code
            gps_state.lat_str = string_fmt("%.6f", cur_lat)
            gps_state.lon_str = string_fmt("%.6f", cur_lon)

            -- Accumulated distance
            if gps_state.fix then
                local d = fast_dist(gps_state.lat, gps_state.lon, cur_lat, cur_lon)
                if d < 5000 then -- ignore jumps > 5km (erratic GPS)
                    stats.total_dist = stats.total_dist + d
                end
            end
        end

        gps_state.lat = cur_lat
        gps_state.lon = cur_lon
        gps_state.alt = alt
        gps_state.fix = true

        -- Max altitude
        if alt > stats.max_alt then
            stats.max_alt = alt
        end

        -- Max Speed
        if gspd > stats.max_speed then
            stats.max_speed = gspd
        end
    end

    -- Max Current (independent of GPS, but requires telemetry)
    if telemetry_live and curr > stats.max_current then
        stats.max_current = curr
    end

    -- --- Battery ---
    if math_abs(rx_bt - bat_state.last_volt) > 1.0 then
        bat_state.cells = detect_cells(rx_bt)
    end
    bat_state.last_volt = rx_bt

    local cell_voltage = bat_state.cells > 0 and (rx_bt / bat_state.cells) or 0

    -- Minimum voltage recorded
    if bat_state.cells > 0 and cell_voltage > 0 then
        if stats.min_voltage == 0 or cell_voltage < stats.min_voltage then
            stats.min_voltage = cell_voltage
        end
    end

    -- Battery alert system (audio) - USE battery_alert_threshold variable
    local cell_voltage_alert = false
    if BATTERY_ALERT_ENABLED and bat_state.cells > 0 and cell_voltage > 0 then
        local time_since_alert = current_time - bat_state.alert_time
        local voltage_drop     = bat_state.alert_volt - cell_voltage
        if cell_voltage < bat_state.threshold then -- DYNAMIC VARIABLE USE
            cell_voltage_alert = true
            if bat_state.alert_volt == 0 or
                (time_since_alert >= BATTERY_ALERT_INTERVAL and voltage_drop >= BATTERY_ALERT_STEP) then
                playNumber(math_floor(cell_voltage * 10), 0, PREC1)
                bat_state.alert_time = current_time
                bat_state.alert_volt = cell_voltage
            end
        else
            bat_state.alert_volt = 0
        end
    end

    local blink_on = (math_floor(current_time / CENTISECS_PER_SEC) % 2) == 0

    lcd_clear()
    draw_tabs()

    if current_page == 1 then
        draw_bat_page(rx_bt, cell_voltage, cell_voltage_alert, blink_on)
    elseif current_page == 2 then
        draw_gps_page(telemetry_live, sats, blink_on)
    elseif current_page == 3 then
        draw_tot_page()
    end

    -- Unified message system (Toast)
    -- Unified message system (Toast)
    if toast_msg and (current_time - toast_time) < 200 then
        -- Draw background and text (using pre-calculated values)
        lcd_drawFilledRect(toast_x - 2, toast_y - 1, toast_w + 4, 11, SOLID)
        lcd_drawText(SCREEN_CENTER_X, toast_y, toast_msg, SMLSIZE + CENTER + INVERS)
    end

    return 0
end

return { run = run }

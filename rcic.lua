-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version:     2.1
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
local UPDATE_RATE            = 100  -- data update rate (100 = 1s)
local BATTERY_ALERT_ENABLED  = true -- enable/disable visual battery alerts
local BATTERY_ALERT_AUDIO    = true -- enable/disable voice/number readout
local BATTERY_ALERT_INTERVAL = 2000 -- minimum time between alerts (2000 = 20s)
local BATTERY_ALERT_STEP     = 0.1  -- voltage drop for new alert

-- ------------------------------------------------------------
-- 2. CONSTANTS AND INTERNAL CONFIGURATION
-- ------------------------------------------------------------
local CENTISECS_PER_SEC      = 100
local MIN_SATS               = 4
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
    max_sats = "MAX SAT",
    mahdrain = "DRAIN",
}

local LANG_OVERRIDES    = {
    es = {
        waiting  = "ESPERANDO GPS",
        cells    = "CELDAS",
        vcell    = "VCELDA",
        distance = "DIST",
        max_spd  = "VEL MAX",
        mahdrain = "CONS",
    },
    fr = {
        waiting  = "ATTENTE GPS",
        cells    = "ELEMS",
        vcell    = "VELEM",
        distance = "DIST",
        max_spd  = "VIT MAX",
        mahdrain = "CONS",
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
        mahdrain = "VERB",
    },
    it = {
        waiting  = "ATTESA GPS",
        altitude = "ALTITUDINE",
        cells    = "CELLE",
        vcell    = "VCELLA",
        distance = "DIST",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
        mahdrain = "CONS",
    },
    pt = {
        waiting  = "AGUARDANDO",
        cells    = "CELULAS",
        vcell    = "VCEL",
        distance = "DIST",
        max_spd  = "VEL MAX",
        max_cur  = "COR MAX",
        mahdrain = "CONS",
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
        max_sats = "MAX SPT",
        mahdrain = "RASH",
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
        mahdrain = "ZUZY",
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
        mahdrain = "SPOTR",
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
        max_sats = "MAX EIS",
        mahdrain = "SHOHI",
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
    lon_str       = "0.000000",
    sats          = 0,
    qr_cache      = nil
}

local last_update_time  = 0

local bat_state         = {
    cells        = 0,
    last_volt    = 0,
    alert_time   = 0,
    alert_volt   = 0,
    cfg_idx      = 1, -- Default: LiPo index = 1
    threshold    = BAT_CONFIG[1].volt,
    lbl_vmin     = string_fmt("%.2fV", BAT_CONFIG[1].v_min),
    lbl_vmax     = string_fmt("%.2fV", BAT_CONFIG[1].v_max),
    rx_bt        = 0,
    cell_voltage = 0,
    -- Cached strings for drawing
    rx_fmt       = "0.00V",
    cell_fmt     = "0.00V",
    cell_s       = "0S",
    pct_val      = 0,
    pct_str      = "0%"
}
local toast_msg         = nil
local toast_time        = 0
local toast_layout      = { x = 0, y = 0, w = 0, h = 11 }
local show_cfg          = false

local telemetry_live    = false

local cfg_sel           = 1
local cfg_edit          = false
local cfg_changed       = false
local CFG_FILE          = "/SCRIPTS/TELEMETRY/rcic.cfg"

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
    max_sats    = 0,
    mahdrain    = 0,
}

local tot_strs = {
    l1_left  = "",
    l1_right = "",
    l2_left  = "",
    l2_right = "",
    l3_left  = "",
    l3_right = "",
    l4_left  = ""
}

local gps_str_info = ""

local function reset_stats()
    stats.max_alt     = 0
    stats.total_dist  = 0
    stats.min_voltage = 0
    stats.max_speed   = 0
    stats.max_current = 0
    stats.max_sats    = 0
    stats.mahdrain    = 0
end

-- ------------------------------------------------------------
-- 7. UTILITY FUNCTIONS
-- ------------------------------------------------------------

local function save_config()
    local file = io.open(CFG_FILE, "w")
    if file then
        local cfg_str = string_fmt("%d,%d,%d,%d,%.2f",
            UPDATE_RATE,
            BATTERY_ALERT_ENABLED and 1 or 0,
            BATTERY_ALERT_AUDIO and 1 or 0,
            BATTERY_ALERT_INTERVAL,
            BATTERY_ALERT_STEP
        )
        io.write(file, cfg_str)
        io.close(file)
    end
end

local function load_config()
    local file = io.open(CFG_FILE, "r")
    if file then
        local content = io.read(file, 200)
        io.close(file)
        if content and #content > 0 then
            -- Expected format: UPDATE_RATE, BAT_ALERT, AUDIO, ALERT_INT, ALERT_STEP
            -- Example: 50,1,1,500,0.1
            local comma1 = string.find(content, ",", 1, true)
            local comma2 = comma1 and string.find(content, ",", comma1 + 1, true)
            local comma3 = comma2 and string.find(content, ",", comma2 + 1, true)
            local comma4 = comma3 and string.find(content, ",", comma3 + 1, true)

            if comma1 and comma2 and comma3 and comma4 then
                local ur_str   = string.sub(content, 1, comma1 - 1)
                local ba_str   = string.sub(content, comma1 + 1, comma2 - 1)
                local au_str   = string.sub(content, comma2 + 1, comma3 - 1)
                local ai_str   = string.sub(content, comma3 + 1, comma4 - 1)
                local step_str = string.sub(content, comma4 + 1)

                local ur       = tonumber(ur_str)
                if ur then UPDATE_RATE = ur end

                local ba = tonumber(ba_str)
                if ba then BATTERY_ALERT_ENABLED = (ba == 1) end

                local au = tonumber(au_str)
                if au then BATTERY_ALERT_AUDIO = (au == 1) end

                local ai = tonumber(ai_str)
                if ai then BATTERY_ALERT_INTERVAL = ai end

                local st = tonumber(step_str)
                if st then BATTERY_ALERT_STEP = st end
            end
        end
    end
end

local function detect_cells(voltage)
    if voltage < 0.5 then return 0 end
    return math_floor(voltage / 4.3) + 1
end

local function is_valid_gps(lat, lon)
    return (lat ~= 0 or lon ~= 0) and
        lat >= -90 and lat <= 90 and
        lon >= -180 and lon <= 180
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

-- V2 L QR Code Generator (25x25)
local qr_e, qr_l = nil, nil
local qr_b = {}
local qr_m = {}
local qr_ec = {}
-- Pattern: {val, mask}
local qr_base = {
    { 0x1fc007f, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x174015d, 0x1fe01ff }, { 0x174005d, 0x1fe01ff },
    { 0x174005d, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x1fd557f, 0x1ffffff }, { 0x0000100, 0x1fe01ff },
    { 0x04601f7, 0x1fe01ff }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x01f0040, 0x01f0040 }, { 0x0110100, 0x01f01ff }, { 0x015017f, 0x01f01ff }, { 0x0110141, 0x01f01ff },
    { 0x01f015d, 0x01f01ff }, { 0x000005d, 0x00001ff }, { 0x000015d, 0x00001ff }, { 0x0000141, 0x00001ff },
    { 0x000017f, 0x00001ff }
}
local qr_gen = { 59, 13, 104, 189, 68, 209, 30, 8, 163, 65, 41, 229, 98, 50, 36, 59 }

local function generate_qrv2(lat, lon)
    if not bit32 then return nil end

    local t = string_fmt("geo:%.6f,%.6f", lat, lon)
    local bi = 0
    local function pb(v, c)
        for i = c - 1, 0, -1 do
            qr_b[bi] = bit32.band(bit32.rshift(v, i), 1)
            bi = bi + 1
        end
    end

    pb(4, 4)
    pb(#t, 8)
    for i = 1, #t do pb(string.byte(t, i), 8) end
    pb(0, 4)
    while bi % 8 ~= 0 do pb(0, 1) end
    local pad, pi = { 236, 17 }, 0
    while bi < 224 do
        pb(pad[pi % 2 + 1], 8)
        pi = pi + 1
    end

    for i = 0, 27 do
        local acc = 0
        for j = 0, 7 do acc = bit32.lshift(acc, 1) + qr_b[i * 8 + j] end
        qr_m[i + 1] = acc
    end

    for i = 1, 16 do qr_ec[i] = 0 end
    for i = 1, 28 do
        local f = bit32.bxor(qr_m[i], qr_ec[1])
        for j = 1, 15 do qr_ec[j] = qr_ec[j + 1] end
        qr_ec[16] = 0
        if f ~= 0 then
            local lf = qr_l[f]
            for j = 1, 16 do qr_ec[j] = bit32.bxor(qr_ec[j], qr_e[(lf + qr_l[qr_gen[j]]) % 255]) end
        end
    end

    for i = 1, 16 do
        for j = 7, 0, -1 do
            qr_b[bi] = bit32.band(bit32.rshift(qr_ec[i], j), 1)
            bi = bi + 1
        end
    end
    for i = 1, 7 do
        qr_b[bi] = 0
        bi = bi + 1
    end

    local res = {}
    for r = 0, 24 do res[r + 1] = qr_base[r + 1][1] end

    local cx, cy, dir, bd = 24, 24, -1, 0
    while cx >= 0 do
        if cx == 6 then cx = cx - 1 end
        for _ = 1, 25 do
            for col = 0, 1 do
                local nx = cx - col
                if bit32.band(qr_base[cy + 1][2], bit32.lshift(1, nx)) == 0 then
                    local bit = qr_b[bd]
                    bd = bd + 1
                    if (cy + nx) % 2 == 0 then bit = bit32.bxor(bit, 1) end
                    if bit == 1 then res[cy + 1] = bit32.bor(res[cy + 1], bit32.lshift(1, nx)) end
                end
            end
            cy = cy + dir
        end
        cy = cy - dir
        dir = -dir
        cx = cx - 2
    end
    return res
end

-- ------------------------------------------------------------
-- 8. INIT FUNCTION
-- ------------------------------------------------------------

local function init()
    if bit32 and not qr_e then
        qr_e, qr_l = {}, {}
        local x = 1
        for i = 0, 254 do
            qr_e[i] = x
            qr_l[x] = i
            x = x * 2
            if x > 255 then x = bit32.bxor(x, 285) end
        end
        qr_e[255] = qr_e[0]
    end

    load_config()

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
        tot_line4_y = CONTENT_Y + math_floor(CONTENT_H * 0.593),
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
    gps_state.sats = getValue("Sats") or 0
    bat_state.rx_bt = getValue("RxBt") or 0
    local rssi = getValue("RQly") or 0
    local alt = getValue("Alt") or getValue("GAlt") or 0
    local gspd = getValue("GSpd") or 0
    local curr = getValue("Curr") or 0
    local Capa = getValue("Capa") or 0

    telemetry_live = (rssi > 0)
    local cur_lat, cur_lon = 0, 0

    if type(gps_data) == "table" then
        cur_lat = gps_data["lat"] or gps_data[1] or 0
        cur_lon = gps_data["lon"] or gps_data[2] or 0
    end

    if gps_state.sats > stats.max_sats then
        stats.max_sats = gps_state.sats
    end

    -- --- Update GPS position and stats ---
    if telemetry_live and gps_state.sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
        if gps_state.lat ~= cur_lat or gps_state.lon ~= cur_lon then
            gps_state.plus_code = to_plus_code(cur_lat, cur_lon)
            gps_state.plus_code_url = "+CODE " .. gps_state.plus_code
            gps_state.lat_str = string_fmt("%.6f", cur_lat)
            gps_state.lon_str = string_fmt("%.6f", cur_lon)
            gps_state.qr_cache = generate_qrv2(cur_lat, cur_lon)

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

    if telemetry_live then
        if curr > stats.max_current then
            stats.max_current = curr
        end
        if Capa > stats.mahdrain then
            stats.mahdrain = Capa
        end
    end

    -- --- Battery ---
    if math_abs(bat_state.rx_bt - bat_state.last_volt) > 1.0 then
        bat_state.cells = detect_cells(bat_state.rx_bt)
    end
    bat_state.last_volt = bat_state.rx_bt

    bat_state.cell_voltage = bat_state.cells > 0 and (bat_state.rx_bt / bat_state.cells) or 0

    if bat_state.cells > 0 then
        if stats.min_voltage == 0 or bat_state.cell_voltage < stats.min_voltage then
            stats.min_voltage = bat_state.cell_voltage
        end
    end

    -- Bat cache
    local bcfg = BAT_CONFIG[bat_state.cfg_idx]
    bat_state.rx_fmt = string_fmt("%.2fV", bat_state.rx_bt)
    bat_state.cell_fmt = string_fmt("%.2fV", bat_state.cell_voltage)
    bat_state.cell_s = bat_state.cells .. "S"
    bat_state.pct_val = bat_state.cells > 0 and
        math_max(0, math_min(1, (bat_state.cell_voltage - bcfg.v_min) / bcfg.v_range)) or 0
    bat_state.pct_str = math_floor(bat_state.pct_val * 100) .. "%"

    -- GPS cache
    gps_str_info = BASE_TEXTS.sats .. ":" .. gps_state.sats
    if gps_state.alt ~= 0 then
        gps_str_info = gps_str_info .. "  " .. BASE_TEXTS.altitude .. ":" .. math_floor(gps_state.alt) .. "m"
    end

    -- TOT cache
    tot_strs.l1_left  = string_fmt("%s:%.2fV", BASE_TEXTS.min_volt, stats.min_voltage)
    tot_strs.l1_right = string_fmt("%s: %.1fA", BASE_TEXTS.max_cur, stats.max_current)
    tot_strs.l2_left  = string_fmt("%s: %.0fm", BASE_TEXTS.max_alt, stats.max_alt)
    tot_strs.l2_right = string_fmt("%s: %s", BASE_TEXTS.distance, format_dist(stats.total_dist))
    tot_strs.l3_left  = string_fmt("%s: %.1fkmh", BASE_TEXTS.max_spd, stats.max_speed)
    tot_strs.l3_right = string_fmt("%s: %d", BASE_TEXTS.max_sats, stats.max_sats)
    tot_strs.l4_left  = string_fmt("%s: %dmAh", BASE_TEXTS.mahdrain, stats.mahdrain)

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

    local cell_voltage_alert = (BATTERY_ALERT_ENABLED and bat_state.cells > 0 and bat_state.cell_voltage < bat_state.threshold)

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
        lcd_drawText(SCREEN_W - 9, LAYOUT.coord_lat_y,
            gps_state.lat_str, FONT_COORDS + RIGHT)
        lcd_drawText(SCREEN_W - 9, LAYOUT.coord_lon_y,
            gps_state.lon_str, FONT_COORDS + RIGHT)

        lcd_drawText(SCREEN_CENTER_X, LAYOUT.info_y, gps_str_info, FONT_INFO + CENTER)

        lcd_drawText(SCREEN_CENTER_X, LAYOUT.url_y,
            gps_state.plus_code_url, FONT_INFO + CENTER)

        if gps_state.qr_cache then
            -- Background: SOLID (is white on dark themes)
            lcd_drawFilledRect(7, LAYOUT.coord_lat_y - 2, 29, 29, SOLID)
            for r = 0, 24 do
                local row_bits = gps_state.qr_cache[r + 1]
                for c = 0, 24 do
                    if bit32.band(row_bits, bit32.lshift(1, c)) ~= 0 then
                        -- Dots: ERASE (is black on dark themes)
                        lcd_drawFilledRect(9 + c, LAYOUT.coord_lat_y + r, 1, 1, ERASE or 0)
                    end
                end
            end
        end
    else
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, BASE_TEXTS.waiting, FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y,
            BASE_TEXTS.sats .. ": " .. gps_state.sats, FONT_INFO + CENTER)
    end
end

local function draw_tot_page()
    lcd_drawText(0, LAYOUT.tot_line1_y, tot_strs.l1_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line1_y, tot_strs.l1_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line2_y, tot_strs.l2_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line2_y, tot_strs.l2_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line3_y, tot_strs.l3_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line3_y, tot_strs.l3_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line4_y, tot_strs.l4_left, SMLSIZE)
end

local function draw_cfg_page(blink_on)
    local cw = SCREEN_W - 10
    local ch = SCREEN_H - 10
    if cw > 180 then cw = 180 end
    if ch > 60 then ch = 60 end
    local cx = math_floor((SCREEN_W - cw) / 2)
    local cy = math_floor((SCREEN_H - ch) / 2)

    lcd_drawFilledRect(cx, cy, cw, ch, ERASE or 0)
    lcd_drawRect(cx, cy, cw, ch, SOLID)

    local txt_y = cy + 4
    local sh = 10

    local items = {
        { label = "UPDATE RATE", val = string_fmt("%.1fs", UPDATE_RATE / 100),            is_bool = false },
        { label = "BAT ALERT",   val = BATTERY_ALERT_ENABLED and "ON" or "OFF",           is_bool = true },
        { label = "AUDIO",       val = BATTERY_ALERT_AUDIO and "ON" or "OFF",             is_bool = true },
        { label = "ALERT INT.",  val = string_fmt("%.0fs", BATTERY_ALERT_INTERVAL / 100), is_bool = false },
        { label = "ALERT STEP",  val = string_fmt("-%.2fv", BATTERY_ALERT_STEP),          is_bool = false }
    }

    for i = 1, #items do
        local flags_label = SMLSIZE
        local flags_val = SMLSIZE + RIGHT

        if i == cfg_sel then
            if cfg_edit then
                if blink_on then flags_val = flags_val + INVERS end
            else
                flags_label = flags_label + INVERS
                flags_val = flags_val + INVERS
            end
        end

        lcd_drawText(cx + 4, txt_y, items[i].label, flags_label)
        lcd_drawText(cx + cw - 4, txt_y, items[i].val, flags_val)
        txt_y = txt_y + sh
    end
end

local last_blink_state = false

-- ------------------------------------------------------------
-- 11. MAIN FUNCTION
-- ------------------------------------------------------------
local function run(event)
    if event ~= 0 then
        force_redraw = true

        -- Telemetry button check (short press = 108 on this radio)
        if event == 108 then
            show_cfg = not show_cfg
            if not show_cfg then
                cfg_edit = false  -- auto-exit edit mode
                if cfg_changed then
                    save_config() -- save changes to SD card
                    cfg_changed = false
                end
            end
            return 0
        end

        -- Block all other events until toggled off, but allow navigation
        if show_cfg then
            if not cfg_edit then
                if event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST then
                    cfg_sel = cfg_sel % 5 + 1
                elseif event == EVT_ROT_LEFT or event == EVT_MINUS_FIRST then
                    cfg_sel = (cfg_sel - 2 + 5) % 5 + 1
                elseif event == EVT_ENTER_BREAK then
                    cfg_edit = true
                end
            else
                -- In edit mode
                if event == EVT_ENTER_BREAK or event == EVT_RTN_FIRST then
                    cfg_edit = false
                elseif event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST then
                    cfg_changed = true
                    if cfg_sel == 1 then
                        UPDATE_RATE = math_min(500, UPDATE_RATE + 10)
                    elseif cfg_sel == 2 then
                        BATTERY_ALERT_ENABLED = not BATTERY_ALERT_ENABLED
                    elseif cfg_sel == 3 then
                        BATTERY_ALERT_AUDIO = not BATTERY_ALERT_AUDIO
                    elseif cfg_sel == 4 then
                        BATTERY_ALERT_INTERVAL = math_min(10000, BATTERY_ALERT_INTERVAL + 100)
                    elseif cfg_sel == 5 then
                        BATTERY_ALERT_STEP = math_min(1.0, BATTERY_ALERT_STEP + 0.05)
                    end
                elseif event == EVT_ROT_LEFT or event == EVT_MINUS_FIRST then
                    cfg_changed = true
                    if cfg_sel == 1 then
                        UPDATE_RATE = math_max(10, UPDATE_RATE - 10)
                    elseif cfg_sel == 2 then
                        BATTERY_ALERT_ENABLED = not BATTERY_ALERT_ENABLED
                    elseif cfg_sel == 3 then
                        BATTERY_ALERT_AUDIO = not BATTERY_ALERT_AUDIO
                    elseif cfg_sel == 4 then
                        BATTERY_ALERT_INTERVAL = math_max(0, BATTERY_ALERT_INTERVAL - 100)
                    elseif cfg_sel == 5 then
                        BATTERY_ALERT_STEP = math_max(0.05, BATTERY_ALERT_STEP - 0.05)
                    end
                end
            end
            return 0
        end

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
    if BATTERY_ALERT_ENABLED and bat_state.cells > 0 then
        if bat_state.cell_voltage < bat_state.threshold then
            if bat_state.alert_volt == 0 or
                (current_time - bat_state.alert_time >= BATTERY_ALERT_INTERVAL and bat_state.alert_volt - bat_state.cell_voltage >= BATTERY_ALERT_STEP) then
                if BATTERY_ALERT_AUDIO then
                    playNumber(math_floor(bat_state.cell_voltage * 10), 0, PREC1)
                end
                bat_state.alert_time = current_time
                bat_state.alert_volt = bat_state.cell_voltage
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

    local toast_visible = toast_msg and (current_time - toast_time) < 200
    if toast_visible then
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

    if show_cfg then
        draw_cfg_page(blink_on)
    end

    -- Unified message system (Toast)
    if toast_visible then
        lcd_drawFilledRect(toast_layout.x - 2, toast_layout.y - 1, toast_layout.w + 4, toast_layout.h, SOLID)
        lcd_drawText(SCREEN_CENTER_X, toast_layout.y, toast_msg, SMLSIZE + CENTER + INVERS)
    end

    return 0
end

return { init = init, background = background, run = run }

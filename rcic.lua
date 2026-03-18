-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version: 3.1
-- Date:    2026-03-18
-- Author:  Alonso Lara (github.com/AlonsoLP)
--
-- Description:
--   Lightweight telemetry dashboard for EdgeTX 2.9+ radios.
--   Features: live battery monitoring with per-cell voltage and alerts,
--   GPS coordinates with Plus Code and QR code generation, flight stats
--   (max altitude, distance, speed, current, mAh drain), multi-language
--   support (es/en/fr/de/it/pt/ru/pl/cz/jp), persistent config via SD card,
--   and touch-screen tab navigation for compatible radios.
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
-- 1. RUNTIME CONFIGURATION DEFAULTS
-- ------------------------------------------------------------
local UPDATE_RATE            = 100    -- centiseconds (100 = 1 s)
local BATTERY_ALERT_ENABLED  = true   -- visual drone low-voltage warning
local BATTERY_ALERT_AUDIO    = true
local BATTERY_ALERT_INTERVAL = 2000   -- min time between alerts (cs)
local BATTERY_ALERT_STEP     = 0.1    -- V drop required for re-alert
local SAG_CURRENT_THRESHOLD  = 20     -- amperes; suppress alerts above this draw
local BAT_CAPACITY_MAH       = 1500   -- mAh; set to your typical battery capacity
local TX_BAT_WARN            = 0      -- visual TX low-voltage warning
local USE_IMPERIAL           = false
local TOAST_DURATION         = 100    -- centiseconds = 1.5 seconds
local MIN_SATS               = 4      -- minimum satellites required to accept a GPS fix
local HAPTIC                 = false  -- enables vibration pulses on supported radios

-- ------------------------------------------------------------
-- 2. CONSTANTS AND INTERNAL CONFIGURATION
-- ------------------------------------------------------------
local CENTISECS_PER_SEC = 100
local GPS_MAX_JUMP      = 5000  -- metres; filters impossible GPS teleport jumps
local LOC_BEEP_MAX_CS   = 200
local LOC_BEEP_MIN_CS   = 20

-- LOC signal segmentation boundaries (dBm, negative).
-- ELRS reports antenna RSSI in dBm; typical range is -15 (strong) to -115 (lost).
-- LOC_SEG_NEAR: at or above this value the bar reads 100%.
-- LOC_SEG_FAR : at or below this value the bar is clamped to 10% (never 0%,
--               to distinguish "weak signal" from "no signal").
local LOC_SEG_NEAR      = -15   -- & up: 100%
local LOC_SEG_FAR       = -70   -- & below: 10%

-- Each chemistry entry defines the per-cell voltage window used for
-- % estimation and alert threshold. v_range = v_max - v_min; stored
-- explicitly to avoid repeated subtraction in hot draw paths.
local BAT_CONFIG = {
    { text = "LiPo",  volt = 3.5, v_max = 4.2,  v_min = 3.2, v_range = 1.0  },
    { text = "LiHV",  volt = 3.6, v_max = 4.35, v_min = 3.2, v_range = 1.15 },
    { text = "LiIon", volt = 3.2, v_max = 4.2,  v_min = 2.8, v_range = 1.4  },
}

local SENSOR_MAP = {
    link = { "RQly", "RSSI"        },
    rxbt = { "RxBt", "VFAS", "A1"  },
    capa = { "Capa", "Fuel"        },
    sats = { "Sats"                },
    gps  = { "GPS"                 },
    alt  = { "Alt",  "GAlt"        },
    gspd = { "GSpd"                },
    curr = { "Curr"                },
    vspd = { "VSpd"                },
    loc  = { "1RSS", "2RSS", "RSSI"},
}

-- ------------------------------------------------------------
-- 2.1. FUNCTION LOCALIZATION
-- ------------------------------------------------------------
-- Standard Lua
local math_floor         = math.floor
local math_abs           = math.abs
local math_max           = math.max
local math_min           = math.min
local math_cos           = math.cos
local math_sqrt          = math.sqrt
local string_fmt         = string.format
local string_sub         = string.sub
local string_byte        = string.byte
local string_lower       = string.lower
local string_gmatch      = string.gmatch

-- EdgeTX API
local lcd_drawText       = lcd.drawText
local lcd_drawRect       = lcd.drawRectangle
local lcd_drawFilledRect = lcd.drawFilledRectangle
local lcd_clear          = lcd.clear
local getTime            = getTime
local getValue           = getValue
local playNumber         = playNumber
local EVT_TOUCH_FIRST    = EVT_TOUCH_FIRST   -- nil on non-touch radios

local ERASE_FLAG         = ERASE or 0  -- ERASE may be nil on monochrome radios; 0 = safe no-op fallback

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

local BASE_TEXTS        = {
    waiting   = "WAITING GPS",
    sats      = "SAT",
    altitude  = "ALT",
    vcell     = "VCELL",
    max_alt   = "MAX ALT",
    distance  = "DIST",
    min_volt  = "MIN V",
    max_spd   = "MAX SPD",
    max_cur   = "MAX AMP",
    max_sats  = "MAX SATS",
    mahdrain  = "DRAIN",
    shot      = "SCREENSHOT",
    resetted  = "RESET",
    tab_bat   = "BAT",
    tab_gps   = "GPS",
    tab_tot   = "TOT",
    tab_loc   = "LOC",
    cfg_rate  = "Update Rate",
    cfg_alert = "Battery Alert",
    cfg_audio = "Audio Alert",
    cfg_int   = "Alert Interval",
    cfg_step  = "Alert Step",
    cfg_on    = "ON",
    cfg_off   = "OFF",
    cfg_sag   = "Sag Limit",
    cfg_tx_warn = "TX Alert",
    cfg_toast = "Toast Time",
    cfg_capacity = "Battery MAH",
    cfg_minsats = "Min Sats",
    cfg_haptic = "Haptic",
    flt_time  = "FLT",
    min_lq    = "MIN LQ",
    loc_start = "ENTER: START",
    loc_dynpwr1 = "Best results obtained if",
    loc_dynpwr2 = "disable TX Dynamic Power",
    loc_nosig = "NO SIGNAL",
}

local LANG_OVERRIDES    = {
    es = {
        waiting   = "ESPERANDO GPS",
        vcell     = "VCELDA",
        distance  = "DIST",
        max_spd   = "VEL MAX",
        mahdrain  = "CONS",
        shot      = "CAPTURA",
        resetted  = "REINICIO",
        cfg_rate  = "Actualizar",
        cfg_alert = "Alerta Bat",
        cfg_int   = "Interv. Alerta",
        cfg_step  = "Salto Alerta",
        cfg_on    = "SI",
        cfg_off   = "NO",
	cfg_tx_warn = "Alerta TX",
	cfg_toast = "T. Aviso",
	cfg_haptic = "Haptico",
	flt_time  = "VUELO",
    },
    fr = {
        waiting   = "ATTENTE GPS",
        vcell     = "VELEM",
        distance  = "DIST",
        max_spd   = "VIT MAX",
        mahdrain  = "CONS",
        shot      = "CAPTURE",
        cfg_rate  = "Rafraichir",
        cfg_alert = "Alerte Bat",
        cfg_int   = "Interv. Alerte",
        cfg_step  = "Saut Alerte",
        cfg_on    = "OUI",
        cfg_off   = "NON",
	cfg_tx_warn = "Alerte TX",
	cfg_toast = "T. Notif",
	cfg_haptic = "Haptique",
	flt_time  = "VOL",
    },
    de = {
        waiting   = "WARTE GPS",
        altitude  = "HOEHE",
        vcell     = "VZELL",
        max_alt   = "MAX HOEHE",
        distance  = "DIST",
        max_spd   = "V MAX",
        max_cur   = "A MAX",
        mahdrain  = "VERB",
        shot      = "FOTO",
        tab_bat   = "AKK",
        tab_tot   = "GES",
        cfg_rate  = "Rate",
        cfg_alert = "Akku Alarm",
        cfg_int   = "Alarm Interv.",
        cfg_step  = "Alarm Step",
        cfg_on    = "EIN",
        cfg_off   = "AUS",
	cfg_sag   = "Sag Grenz",
	cfg_toast = "Meld Zeit",
	cfg_capacity = "Akk MAH",
	cfg_haptic = "Haptik",
	flt_time  = "FLUG",
    },
    it = {
        waiting   = "ATTESA GPS",
        altitude  = "ALTITUDINE",
        vcell     = "VCELLA",
        distance  = "DIST",
        max_spd   = "VEL MAX",
        max_cur   = "COR MAX",
        mahdrain  = "CONS",
        shot      = "CATTURA",
        cfg_rate  = "Aggiorna",
        cfg_alert = "Allarme Bat",
        cfg_int   = "Allarme Interv.",
        cfg_step  = "Allarme Step",
        cfg_on    = "SI",
        cfg_off   = "NO",
	cfg_tx_warn = "Allarme TX",
	cfg_toast = "T. Avviso",
	cfg_haptic = "Aptico",
	flt_time  = "VOLO",
    },
    pt = {
        waiting   = "AGUARDANDO",
        vcell     = "VCEL",
        distance  = "DIST",
        max_spd   = "VEL MAX",
        max_cur   = "COR MAX",
        mahdrain  = "CONS",
        shot      = "CAPTURA",
        cfg_rate  = "Taxa Atual.",
        cfg_alert = "Alerta Bat",
        cfg_int   = "Interv. Alerta",
        cfg_step  = "Passo Alerta",
        cfg_on    = "LIG",
        cfg_off   = "DES",
	cfg_tx_warn = "Alerta TX",
	cfg_toast = "T. Aviso",
	cfg_haptic = "Haptico",
	flt_time  = "VOO",
    },
    ru = {
        waiting   = "OZHID GPS",
        sats      = "SPT",
        altitude  = "VYSOTA",
        vcell     = "VBAN",
        max_alt   = "MAX VYS",
        distance  = "DIST",
        max_spd   = "MAX SKOR",
        max_cur   = "MAX TOK",
        max_sats  = "MAX SPT",
        mahdrain  = "RASH",
        shot      = "FOTO",
        resetted  = "SBROS",
        tab_bat   = "AKB",
        tab_tot   = "VSE",
        cfg_rate  = "Obnovlenie",
        cfg_alert = "Vtrev Bat",
        cfg_audio = "Zvuk",
        cfg_int   = "Interv. Trev",
        cfg_step  = "Shag Trev",
        cfg_on    = "VK",
        cfg_off   = "VY",
	cfg_sag   = "Sag Porog",
        cfg_tx_warn = "Trev TX",
	cfg_toast = "Vr Soob",
	cfg_capacity = "Akb MAH",
	cfg_minsats = "Min Spt",
	cfg_haptic = "Vibro",
	flt_time  = "POLET",
    },
    pl = {
        waiting   = "SZUKAM GPS",
        altitude  = "WYS",
        vcell     = "VCELA",
        max_alt   = "MAX WYS",
        distance  = "DIST",
        max_spd   = "MAX PRED",
        max_cur   = "MAX PRAD",
        mahdrain  = "ZUZY",
        shot      = "FOTO",
        tab_bat   = "AKU",
        tab_tot   = "SUM",
        cfg_rate  = "Odswiez",
        cfg_alert = "Alarm Bat",
        cfg_int   = "Interw. Alarm",
        cfg_step  = "Krok Alarm",
        cfg_on    = "WL",
        cfg_off   = "WYL",
	cfg_toast = "Czas Pow",
	cfg_capacity = "Aku MAH",
	cfg_haptic = "Wibracja",
        flt_time  = "LOT",
    },
    cz = {
        waiting   = "CEKAM GPS",
        altitude  = "VYSKA",
        vcell     = "VCLAN",
        max_alt   = "MAX VYS",
        distance  = "VZDAL",
        max_spd   = "RYCHL",
        max_cur   = "PROUD",
        mahdrain  = "SPOTR",
        shot      = "FOTKA",
        tab_tot   = "CEL",
        cfg_rate  = "Obnova",
        cfg_alert = "Alarm Bat",
        cfg_int   = "Interv. Alarm",
        cfg_step  = "Krok Alarm",
        cfg_on    = "ZAP",
        cfg_off   = "VYP",
	cfg_toast = "Cas Zpr",
	cfg_haptic = "Vibrace",
        flt_time  = "LET",
    },
    jp = {
        waiting   = "GPS TAIKI",
        sats      = "EIS",
        altitude  = "KODO",
        vcell     = "VSERU",
        max_alt   = "MAX KODO",
        distance  = "KYORI",
        max_spd   = "SOKU",
        max_cur   = "DENRYU",
        max_sats  = "MAX EIS",
        mahdrain  = "SHOHI",
        shot      = "SATSU",
        resetted  = "RISETTO",
        cfg_rate  = "Koshin",
        cfg_alert = "Keiho",
        cfg_audio = "Onsei",
        cfg_int   = "Kehio Kankaku",
        cfg_step  = "Keiho Step",
	cfg_sag   = "Sag Amp",
	cfg_tx_warn = "TX Keiho",
	cfg_toast = "Hyoji Ji",
	cfg_minsats = "Min Eis",
	cfg_haptic = "Shindo",
	flt_time  = "HIKO",
    },
}

-- ------------------------------------------------------------
-- 6. PERSISTENT VARIABLES
-- ------------------------------------------------------------

local current_page     = 1
local qr_scale         = 1   -- pixels per QR module
local last_update_time = 0

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
    qr_cache      = nil,
    vspd          = 0,     -- vertical speed m/s (+ascending / -descending)
    prev_alt      = 0,     -- altitude from previous cycle for delta calculation
}


local bat_state         = {
    cells        = 0,
    last_volt    = 0,
    alert_time   = 0,
    alert_volt   = 0,
    cfg_idx      = 1,        -- Default: LiPo index = 1
    threshold    = BAT_CONFIG[1].volt,
    lbl_vmin     = string_fmt("%.2fV", BAT_CONFIG[1].v_min),
    lbl_vmax     = string_fmt("%.2fV", BAT_CONFIG[1].v_max),
    rx_bt        = 0,
    cell_voltage = 0,
    curr         = 0,
    -- Cached strings for drawing
    rx_fmt       = "0.00V",
    cell_fmt     = "0.00V",
    cell_s       = "0S",
    pct_val      = 0,
    pct_str      = "0%",
    -- TX
    bat_tx       = 0,      -- TX battery raw voltage (V)
    bat_tx_fmt   = "--V",  -- cached display string
    chem_cell_str = "",    -- cached "LiPo[4S]" / "LiPo[-S]"
    last_cells   = -1,
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

-- Pre-allocated constants and buffers to reduce GC pressure
local str_minus_minus_V = "--V"       -- placeholder shown when cell count is unknown
local QR_PAD            = { 236, 17 } -- QR padding bytes 0xEC/0x11 per spec; fixed, never changes
local qr_res            = {}          -- 25-row QR result buffer; reused across every regeneration
local _alt_unit         = "m"
local _alt_factor       = 1.0
local _spd_unit         = "kmh"
local _spd_factor       = 1.0

-- Displays a centered toast notification for TOAST_DURATION centiseconds.
-- Recalculates width and position on every call to fit variable-length messages.
local function show_toast(msg)
    toast_msg = msg
    toast_time = getTime()

    local msg_w = math_max(#toast_msg * 6 + 10, 60)

    toast_layout.w = msg_w
    toast_layout.x = math_floor((SCREEN_W - msg_w) / 2)
    -- toast_layout.y is static, pre-calculated in init()
end

local force_redraw = true

local STATS_DEFAULTS = { max_alt = 0, total_dist = 0, min_voltage = 0, max_speed = 0, max_current = 0, max_sats = 0, mahdrain = 0, flight_time = 0, min_lq = 999 }
local stats = {}

local tot_strs = {
    l1_left  = "", l1_right = "",
    l2_left  = "", l2_right = "",
    l3_left  = "", l3_right = "",
    l4_left  = "", l4_right = "",
    l5_left  = "",
}

local gps_str_info = ""
local gps_sats_str = ""

local CFG_KEYS = {"cfg_rate","cfg_alert","cfg_audio","cfg_int","cfg_step","cfg_sag","cfg_tx_warn","cfg_toast","cfg_capacity","cfg_minsats","cfg_haptic"}
local cfg_items = {}

-- Resets all flight statistics to their default zero values.
-- Called on init and when the user triggers a manual reset from the TOT page.
local function reset_stats()
    for k, v in pairs(STATS_DEFAULTS) do stats[k] = v end
end
reset_stats()

-- sensor names
local _s = {}

-- true if Fuel (not Capa)
local _capa_is_pct = false

local cfg_scroll = 0

-- fallback TX warning threshold when getGeneralSettings() provides no battWarn value
local _bat_warn_default = 6.6

-- true when LOC sensor resolves to 1RSS/2RSS (ELRS); selects segmented dBm scaling
local _loc_is_elrs  = false

local loc_active    = false
local loc_next_play = 0

-- last raw signal value (dBm for ELRS, 0-100 for RSSI). nil = no sensor read.
local loc_sig = nil
-- TX power in mW from TPWR sensor; nil if sensor absent.
local loc_tpwr = nil
-- normalised 0-100 value driving bar fill, beep rate and haptic.
local loc_sig_pct = 0

-- ------------------------------------------------------------
-- 7. UTILITY FUNCTIONS
-- ------------------------------------------------------------

local function refresh_cfg_vals()
    cfg_items[1].val  = string_fmt("%.1fs", UPDATE_RATE / 100)
    cfg_items[2].val  = BATTERY_ALERT_ENABLED and BASE_TEXTS.cfg_on or BASE_TEXTS.cfg_off
    cfg_items[3].val  = BATTERY_ALERT_AUDIO and BASE_TEXTS.cfg_on or BASE_TEXTS.cfg_off
    cfg_items[4].val  = string_fmt("%.0fs", BATTERY_ALERT_INTERVAL / 100)
    cfg_items[5].val  = string_fmt("-%.2fV", BATTERY_ALERT_STEP)
    cfg_items[6].val  = string_fmt("%dA", SAG_CURRENT_THRESHOLD)
    cfg_items[7].val  = TX_BAT_WARN > 0 and BASE_TEXTS.cfg_on or BASE_TEXTS.cfg_off
    cfg_items[8].val  = string_fmt("%.1fs", TOAST_DURATION / 100)
    cfg_items[9].val  = string_fmt("%dmAh", BAT_CAPACITY_MAH)
    cfg_items[10].val = string_fmt("%d", MIN_SATS)
    cfg_items[11].val = HAPTIC and BASE_TEXTS.cfg_on or BASE_TEXTS.cfg_off
end

-- Serialises all user-configurable settings to a CSV file on the SD card.
-- Field order is fixed; see load_config() code for the mapping.
local function save_config()
    local file = io.open(CFG_FILE, "w")
    if file then
	io.write(file, string_fmt("%d,%d,%d,%d,%.2f,%d,%.1f,%d,%d,%d,%d",
	    UPDATE_RATE, BATTERY_ALERT_ENABLED and 1 or 0,
	    BATTERY_ALERT_AUDIO and 1 or 0,
	    BATTERY_ALERT_INTERVAL, BATTERY_ALERT_STEP,
	    SAG_CURRENT_THRESHOLD, TX_BAT_WARN,
	    TOAST_DURATION, BAT_CAPACITY_MAH, MIN_SATS,
	    HAPTIC and 1 or 0))
        io.close(file)
    end
end

-- Reads and parses the CSV config file from SD card, applying values to runtime vars.
-- Missing or extra fields are silently ignored, preserving forward compatibility.
local function load_config()
    local file = io.open(CFG_FILE, "r")
    if not file then return end
    local content = io.read(file, 200)
    io.close(file)
    if not content or #content == 0 then return end

    local fields = {}
    for v in string_gmatch(content .. ",", "([^,]*),") do
        fields[#fields + 1] = v
    end
    local function n(i) return tonumber(fields[i]) end

    if n(1) then UPDATE_RATE            = n(1)        end
    if n(2) then BATTERY_ALERT_ENABLED  = n(2) == 1   end
    if n(3) then BATTERY_ALERT_AUDIO    = n(3) == 1   end
    if n(4) then BATTERY_ALERT_INTERVAL = n(4)        end
    if n(5) then BATTERY_ALERT_STEP     = n(5)        end
    if n(6) then SAG_CURRENT_THRESHOLD  = n(6)        end
    if n(7) then TX_BAT_WARN            = n(7)        end
    if n(8)  then TOAST_DURATION        = n(8)        end
    if n(9)  then BAT_CAPACITY_MAH      = n(9)        end
    if n(10) then MIN_SATS              = n(10)       end
    if n(11) then HAPTIC                = n(11) == 1  end
end

-- Uses v_max + 0.05 V as the per-cell ceiling instead of v_max to avoid
-- misclassifying a freshly charged pack. Example: a 4S LiPo at 16.82 V
-- divided by 4.20 gives 4.004 → floor = 4 correct, but at exactly 16.80 V
-- divided by 4.20 gives exactly 4.000 → floor = 4 still correct.
-- Without the margin, floating-point drift could produce 3.999 → floor = 3.
local function detect_cells(voltage)
    if voltage < 0.5 then return 0 end
    -- +0.05 V margin per chemistry — LiPo: 4.25  LiHV: 4.40  LiIon: 4.25
    return math_floor(voltage / (BAT_CONFIG[bat_state.cfg_idx].v_max + 0.05)) + 1
end

-- EdgeTX GPS sensor returns {lat=0, lon=0} before acquiring a fix.
-- The (0,0) point is in the Gulf of Guinea; excluding it avoids
-- plotting the drone at sea during cold start.
local function is_valid_gps(lat, lon)
    return (lat ~= 0 or lon ~= 0) and
        lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180
end

local lat_divisors = { 800000, 40000, 2000, 100, 5 }
local lon_divisors = { 640000, 32000, 1600, 80, 4 }
local alphabet     = "23456789CFGHJMPQRVWX"

-- Encodes a WGS-84 coordinate pair as an Open Location Code (Plus Code).
-- Output: 11-character code, e.g. "8FRCGP22+WH"
local function to_plus_code(lat, lon)
    lat = math_max(-90, math_min(89.9999, lat)) + 90
    while lon < -180 do lon = lon + 360 end
    while lon >= 180 do lon = lon - 360 end
    lon = lon + 180

    local lat_val = math_floor(lat * 40000)
    local lon_val = math_floor(lon * 32000)
    local code = ""

    for i = 1, 5 do
        local ld = math_floor(lat_val / lat_divisors[i]) % 20
        local od = math_floor(lon_val / lon_divisors[i]) % 20
        code = code
            .. string_sub(alphabet, ld + 1, ld + 1)
            .. string_sub(alphabet, od + 1, od + 1)
        if i == 4 then code = code .. "+" end
    end

    local ndx = (lat_val % 5) * 4 + (lon_val % 4)
    return code .. string_sub(alphabet, ndx + 1, ndx + 1)
end

-- Equirectangular distance approximation; accurate to ~0.5% for distances < 100 km.
local RAD     = math.pi / 180
local R_EARTH = 6371000  -- metres

local function fast_dist(lat1, lon1, lat2, lon2)
    local x = (lon2 - lon1) * RAD * math_cos((lat1 + lat2) / 2 * RAD)
    local y = (lat2 - lat1) * RAD
    return math_sqrt(x * x + y * y) * R_EARTH
end

-- Returns a human-readable distance string: metres below 1 km, kilometres above.
local function format_dist(meters)
    if USE_IMPERIAL then
        local ft = meters * 3.28084
        return ft >= 5280
            and string_fmt("%.2fmi", ft / 5280)
            or  string_fmt("%.0fft", ft)
    end
    return meters >= 1000
        and string_fmt("%.2fkm", meters / 1000)
        or  string_fmt("%.0fm",  meters)
end

-- Wraps a 1-based index cyclically within [1..n], stepping by dir (+1 or -1).
local function cycle(val, n, dir) return (val - 1 + dir + n) % n + 1 end

-- QR Code v2-L generator producing a 25×25 module matrix.
-- Encodes a "geo:lat,lon" URI suitable for any QR scanner.
-- Uses Lua 5.3 native bitwise operators (EdgeTX 2.9+ / Lua 5.3 required).
-- Output is written into the pre-allocated module-level qr_res table.
--
-- qr_e / qr_l : GF(256) exp/log tables, built once in init()
-- qr_b        : working bitstream buffer (data + EC + remainder bits)
-- qr_m        : 28 data codewords as integers
-- qr_ec       : 16 Reed-Solomon error correction codewords
-- qr_base     : fixed module pattern (finder patterns, timing, format info)
-- qr_gen      : RS generator polynomial coefficients for v2-L (16 EC codewords)
local qr_e, qr_l = nil, nil
local qr_b = {}
local qr_m = {}
local qr_ec = {}

-- {base_value, write_mask}: 1-bits in write_mask mark reserved/fixed modules.
local qr_base = {
    { 0x1fc007f, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x174015d, 0x1fe01ff }, { 0x174005d, 0x1fe01ff },
    { 0x174005d, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x1fd557f, 0x1ffffff }, { 0x0000100, 0x1fe01ff },
    { 0x04601f7, 0x1fe01ff }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x01f0040, 0x01f0040 }, { 0x0110100, 0x01f01ff }, { 0x015017f, 0x01f01ff }, { 0x0110141, 0x01f01ff },
    { 0x01f015d, 0x01f01ff }, { 0x000005d, 0x00001ff }, { 0x000015d, 0x00001ff }, { 0x0000141, 0x00001ff },
    { 0x000017f, 0x00001ff }
}

-- Generator polynomial for QR v2-L (16 EC codewords, degree-16 over GF(256))
local qr_gen = { 59, 13, 104, 189, 68, 209, 30, 8, 163, 65, 41, 229, 98, 50, 36, 59 }

-- Encodes a "geo:lat,lon" URI as a QR Code version 2-L (25×25 modules,
-- ~7% error correction). Version 2-L was chosen because:
--   - "geo:±DD.DDDDDD,±DDD.DDDDDD" fits within the 28-byte data capacity.
--   - Low EC level maximises data capacity; outdoor use does not need high EC.
-- The matrix is written into the pre-allocated module-level qr_res[] table
-- to avoid heap allocation on every GPS position update.
-- GF(256) arithmetic uses the primitive polynomial x^8+x^4+x^3+x^2+1 (0x11D).
-- qr_e[i] = alpha^i mod p(x)  — antilog / exponent table
-- qr_l[v] = log_alpha(v)      — log table; undefined for v=0 (never accessed)
-- Together they convert multiply/divide in GF(256) to table lookups + mod 255.
-- Mask pattern 0: flip module when (row + col) % 2 == 0.
-- QR spec requires at least one mask to be evaluated; pattern 0 is hardcoded
-- here for simplicity since the payload has no periodic structure that would
-- cause a score penalty.
local function generate_qrv2(lat, lon)
    local t = string_fmt("geo:%.6f,%.6f", lat, lon)
    local bi = 0

    -- Pack `c` bits from integer `v` into qr_b[], most-significant bit first.
    local function pb(v, c)
        for i = c - 1, 0, -1 do
	    qr_b[bi] = (v >> i) & 1
            bi = bi + 1
        end
    end

    -- Encode payload: mode=byte(4), byte-count, UTF-8 data, terminator nibble
    pb(4, 4)
    pb(#t, 8)
    for i = 1, #t do pb(string_byte(t, i), 8) end
    pb(0, 4)
    while bi % 8 ~= 0 do pb(0, 1) end  -- byte-align the bitstream

    -- Pad with alternating 0xEC / 0x11 bytes to fill the 28-byte data capacity (v2-L)
    local pi = 0
    while bi < 224 do
        pb(QR_PAD[pi % 2 + 1], 8)
        pi = pi + 1
    end

    -- Pack 28 data bytes into qr_m[] as integers for Reed-Solomon processing
    for i = 0, 27 do
        local acc = 0
	for j = 0, 7 do acc = (acc << 1) + qr_b[i * 8 + j] end
        qr_m[i + 1] = acc
    end

    -- Reed-Solomon error correction over GF(256).
    -- Produces 16 EC codewords using the v2-L generator polynomial.
    for i = 1, 16 do qr_ec[i] = 0 end
    for i = 1, 28 do
	local f = qr_m[i] ~ qr_ec[1]
        for j = 1, 15 do qr_ec[j] = qr_ec[j + 1] end
        qr_ec[16] = 0
        if f ~= 0 then
            local lf = qr_l[f]
            for j = 1, 16 do qr_ec[j] = qr_ec[j] ~ qr_e[(lf + qr_l[qr_gen[j]]) % 255] end
        end
    end

    -- Append 16 EC codewords + 7 remainder bits to the bitstream
    for i = 1, 16 do
        for j = 7, 0, -1 do
	    qr_b[bi] = (qr_ec[i] >> j) & 1
            bi = bi + 1
        end
    end
    pb(0, 7)

    -- Initialise qr_res from the fixed base pattern (finder patterns, timing, format info)
    for r = 0, 24 do qr_res[r + 1] = qr_base[r + 1][1] end

    -- Place data bits using diagonal column scan (right-to-left column pairs, top/bottom sweep).
    -- Applies mask pattern 0: invert module when (row + col) % 2 == 0.
    local cx, cy, dir, bd = 24, 24, -1, 0
    while cx >= 0 do
        if cx == 6 then cx = cx - 1 end  -- skip the vertical timing column
        for _ = 1, 25 do
            for col = 0, 1 do
                local nx = cx - col
		if (qr_base[cy + 1][2] & (1 << nx)) == 0 then  -- skip reserved modules
                    local bit = qr_b[bd]
                    bd = bd + 1
		    if (cy + nx) % 2 == 0 then bit = bit ~ 1 end  -- mask pattern 0
		    if bit == 1 then qr_res[cy + 1] = qr_res[cy + 1] | (1 << nx) end
                end
            end
            cy = cy + dir
        end
        cy = cy - dir
        dir = -dir
        cx = cx - 2
    end
    return qr_res
end

-- Returns the raw signal value from the active LOC sensor, or nil if unavailable.
-- Returns nil also when the sensor reads exactly 0 (no-signal sentinel value).
local function loc_get_signal()
    if not _s.loc then return nil end
    local v = getValue(_s.loc)
    return v ~= 0 and v or nil
end

-- ------------------------------------------------------------
-- 8. INIT FUNCTION
-- ------------------------------------------------------------

local function init()
    -- Build GF(256) exp/log tables for Reed-Solomon ECC.
    -- Uses the irreducible polynomial x^8+x^4+x^3+x^2+1 = 0x11D (285 decimal),
    -- the same primitive used by both QR Code and AES.
    if not qr_e then
        qr_e, qr_l = {}, {}
        local x = 1
        for i = 0, 254 do
            qr_e[i] = x
            qr_l[x] = i
            x = x * 2
	    if x > 255 then x = x ~ 285 end  -- reduce modulo the GF(256) polynomial
        end
        qr_e[255] = qr_e[0]
    end

    local gs = getGeneralSettings() or {}

    -- Apply language overrides; falls back to English if the locale is not found.
    local LANG = (gs.language and string_sub(string_lower(gs.language), 1, 2)) or "en"

    if LANG_OVERRIDES[LANG] then
        for k, v in pairs(LANG_OVERRIDES[LANG]) do BASE_TEXTS[k] = v end
    end

    -- Populate config menu labels after language selection
    for i, key in ipairs(CFG_KEYS) do
	cfg_items[i] = { label = BASE_TEXTS[key], val = "" }
    end

    TX_BAT_WARN = gs.battWarn or _bat_warn_default
    _bat_warn_default = gs.battWarn or _bat_warn_default
    if gs.imperial ~= nil then USE_IMPERIAL = gs.imperial ~= 0 end
    if USE_IMPERIAL then
	_alt_unit   = "ft";  _alt_factor  = 3.28084
	_spd_unit   = "mph"; _spd_factor  = 0.621371
    end

    load_config()

    -- Detect screen dimensions and select font sizes accordingly
    SCREEN_W    = LCD_W or 128
    SCREEN_H    = LCD_H or 64
    FONT_COORDS = MIDSIZE
    FONT_INFO   = SMLSIZE
    if SCREEN_W >= 300 then  -- large-screen radios (TX16S, TX12 Mk2, Boxer, etc.)
        FONT_COORDS = DBLSIZE
        FONT_INFO   = MIDSIZE
    end

    -- 128px = 1, 320px = 3, 480px = 4
    qr_scale = math_min(4, math_floor(SCREEN_W / 100))

    -- Pre-compute all layout positions as absolute pixel coordinates to
    -- avoid repeated arithmetic inside the draw functions.
    SCREEN_CENTER_X = math_floor(SCREEN_W / 2)
    TAB_H           = 9
    CONTENT_Y       = TAB_H + 1
    CONTENT_H       = SCREEN_H - CONTENT_Y

    LAYOUT          = {
        coord_lat_y = CONTENT_Y + math_floor(CONTENT_H * 0.09),
        coord_lon_y = CONTENT_Y + math_floor(CONTENT_H * 0.37),
        info_y      = CONTENT_Y + math_floor(CONTENT_H * 0.65),
        url_y       = CONTENT_Y + math_floor(CONTENT_H * 0.84),
        waiting_y   = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        sats_y      = CONTENT_Y + math_floor(CONTENT_H * 0.70),
        bat_label_y = CONTENT_Y + math_floor(CONTENT_H * 0.038),
        bat_value_y = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        bat_cell_y  = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        bat_pct_y   = CONTENT_Y + math_floor(CONTENT_H * 0.65),
        bat_bar_y   = CONTENT_Y + math_floor(CONTENT_H * 0.815),
        bar_w       = SCREEN_W - 2,
        tot_line1_y = CONTENT_Y + math_floor(CONTENT_H * 0.03),
        tot_line2_y = CONTENT_Y + math_floor(CONTENT_H * 0.22),
        tot_line3_y = CONTENT_Y + math_floor(CONTENT_H * 0.40),
        tot_line4_y = CONTENT_Y + math_floor(CONTENT_H * 0.56),
        tot_line5_y = CONTENT_Y + math_floor(CONTENT_H * 0.78),
        gps_lost_h  = SCREEN_H - CONTENT_Y,
	cfg_item_h  = 8,
	qr_x        = 18,
	qr_y        = CONTENT_Y + math_floor(CONTENT_H * 0.15),
    }

    LAYOUT.cfg_visible = math_floor((math_min(SCREEN_H - 10, 60) - 4) / LAYOUT.cfg_item_h)
    local _cw = math_min(SCREEN_W - 10, 180)
    local _ch = math_min(SCREEN_H - 10, 60)
    LAYOUT.cfg_x  = math_floor((SCREEN_W - _cw) / 2)
    LAYOUT.cfg_y  = math_floor((SCREEN_H - _ch) / 2)
    LAYOUT.cfg_w  = _cw
    LAYOUT.cfg_h  = _ch

    local _lcw = math_max(4, math_floor(SCREEN_W / 20))
    LAYOUT.loc_cell_w = _lcw
    LAYOUT.loc_cell_h = math_floor(CONTENT_H * 0.40)
    LAYOUT.loc_cell_n = math_floor((SCREEN_W - 4) / _lcw)
    LAYOUT.loc_cell_y = SCREEN_H - LAYOUT.loc_cell_h - 1

    toast_layout.y  = math_floor(SCREEN_H / 2) - 5

    -- Pre-compute tab geometry used for drawing and touch hit-testing
    TABS        = { BASE_TEXTS.tab_bat, BASE_TEXTS.tab_gps, BASE_TEXTS.tab_tot, BASE_TEXTS.tab_loc }
    TAB_W       = math_floor(SCREEN_W / #TABS)
    TABS_LAYOUT = {}
    for i = 1, #TABS do
        local x = (i - 1) * TAB_W
        local w = (i == #TABS) and (SCREEN_W - x) or TAB_W
        TABS_LAYOUT[i] = { name = TABS[i], x = x, w = w, centerText_x = x + math_floor(w / 2) }
    end
end

-- Probes all sensor candidates in SENSOR_MAP and caches the first responding name.
-- Sets _loc_is_elrs true when the resolved LOC sensor is 1RSS/2RSS (ELRS link).
-- Runs once after telemetry becomes live; resets _s._done on link loss to re-detect.
local function detect_sensors()
    for key, candidates in pairs(SENSOR_MAP) do
        for _, name in ipairs(candidates) do
            if getValue(name) ~= nil then _s[key] = name; break end
        end
    end
    _capa_is_pct = (_s.capa == "Fuel")
    _loc_is_elrs = (_s.loc == "1RSS" or _s.loc == "2RSS")
    _s._done = true
end

-- ------------------------------------------------------------
-- 9. DATA UPDATE (BACKGROUND) FUNCTION
-- ------------------------------------------------------------

local function background()
    local current_time = getTime()

    -- Rate-limit data updates to UPDATE_RATE centiseconds (default 1 Hz)
    if current_time - last_update_time < UPDATE_RATE then
        return
    end
    last_update_time = current_time

    -- These sensors are available even without a full telemetry link.
    if not _s._done then detect_sensors() end
    bat_state.bat_tx = getValue("tx-voltage") or 0
    gps_state.sats   = _s.sats and getValue(_s.sats) or 0
    bat_state.rx_bt  = _s.rxbt and getValue(_s.rxbt) or 0

    -- Active link?
    local lq = _s.link and getValue(_s.link) or 0
    telemetry_live = lq > 0
    if not telemetry_live and _s._done then _s._done = nil end

    -- Skip remaining sensor reads when no active link
    if telemetry_live then
	stats.flight_time = stats.flight_time + UPDATE_RATE

	if lq < stats.min_lq then stats.min_lq = lq end

	local gps_data = _s.gps  and getValue(_s.gps)  or nil
	local alt      = _s.alt  and getValue(_s.alt)  or 0
	local gspd     = _s.gspd and getValue(_s.gspd) or 0
	local capa     = _s.capa and getValue(_s.capa) or 0
	local curr     = _s.curr and getValue(_s.curr) or 0

	bat_state.curr = curr

	if gps_state.sats > stats.max_sats then
    	    stats.max_sats = gps_state.sats
	end

	local cur_lat, cur_lon = 0, 0
	if type(gps_data) == "table" then
    	    cur_lat = gps_data["lat"] or gps_data[1] or 0
    	    cur_lon = gps_data["lon"] or gps_data[2] or 0
	end

	if gps_state.sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
	    if gps_state.lat ~= cur_lat or gps_state.lon ~= cur_lon then
		-- do_update gate: skip Plus Code and QR regeneration if the drone moved
		-- less than 2 m. GPS sensors quantise to ~1 m; this prevents redundant
		-- regeneration caused by LSB jitter on a stationary craft.
		local do_update = not gps_state.fix

		if gps_state.fix then
		    local d = fast_dist(gps_state.lat, gps_state.lon, cur_lat, cur_lon)

		    -- GPS_MAX_JUMP rejects teleport jumps (receiver glitch / reboot)
		    if d < GPS_MAX_JUMP then stats.total_dist = stats.total_dist + d end

		    do_update = d > 2.0
		end
		if do_update then
		    gps_state.lat_str       = string_fmt("%.6f", cur_lat)
		    gps_state.lon_str       = string_fmt("%.6f", cur_lon)
		    gps_state.plus_code     = to_plus_code(cur_lat, cur_lon)
		    gps_state.plus_code_url = "OLC:" .. gps_state.plus_code
		    gps_state.qr_cache      = generate_qrv2(cur_lat, cur_lon)
		end
	    end

    	    gps_state.lat = cur_lat
    	    gps_state.lon = cur_lon
    	    gps_state.alt = alt
    	    gps_state.fix = true

	    if alt  > stats.max_alt   then stats.max_alt   = alt  end
    	    if gspd > stats.max_speed then stats.max_speed = gspd end
	end

        if curr > stats.max_current then stats.max_current = curr end
        if capa > stats.mahdrain    then stats.mahdrain    = capa end

	-- Vario: prefer direct VSpd sensor (INAV/BF); fall back to altitude delta.
	-- Guard prev_alt ~= 0 avoids a spurious spike on the very first fix cycle.
	local raw_vspd = _s.vspd and getValue(_s.vspd) or 0
	if raw_vspd ~= 0 then
    	    gps_state.vspd = raw_vspd
	elseif gps_state.fix and gps_state.prev_alt ~= 0 then
    	    gps_state.vspd = (alt - gps_state.prev_alt) / (UPDATE_RATE / CENTISECS_PER_SEC)
	end
	gps_state.prev_alt = alt
    end

    -- Cell count is re-inferred whenever pack voltage jumps more than 1 V.
    -- This handles two cases:
    --   1. Cold start: RxBt climbs from 0 V when the drone powers on.
    --   2. Battery swap: pack voltage changes significantly mid-session.
    -- A 1 V hysteresis avoids false re-detection from normal sag under load.
    if math_abs(bat_state.rx_bt - bat_state.last_volt) > 1.0 then bat_state.cells = detect_cells(bat_state.rx_bt) end

    bat_state.last_volt    = bat_state.rx_bt
    bat_state.cell_voltage = bat_state.cells > 0 and (bat_state.rx_bt / bat_state.cells) or 0

    if bat_state.cells > 0 then
        if stats.min_voltage == 0 or bat_state.cell_voltage < stats.min_voltage then
            stats.min_voltage = bat_state.cell_voltage
        end
    end

    -- Bat cache: pre-format all display strings to avoid allocations inside draw functions
    local bcfg              = BAT_CONFIG[bat_state.cfg_idx]
    bat_state.rx_fmt        = string_fmt("%.2fV", bat_state.rx_bt)
    bat_state.cell_fmt      = string_fmt("%.2fV", bat_state.cell_voltage)
    bat_state.bat_tx_fmt    = string_fmt("%.1fV", bat_state.bat_tx)
    bat_state.pct_val       = bat_state.cells > 0 and
        math_max(0, math_min(1, (bat_state.cell_voltage - bcfg.v_min) / bcfg.v_range)) or 0
    if bat_state.cells ~= bat_state.last_cells then
	bat_state.last_cells    = bat_state.cells
	bat_state.cell_s        = string_fmt("%dS", bat_state.cells)
	bat_state.chem_cell_str = string_fmt("%s [%s]", bcfg.text,
    	    bat_state.cells > 0 and bat_state.cell_s or "-S")
    end

    local pct = math_floor(bat_state.pct_val * 100)
    if bat_state.cells > 0 and bat_state.curr > 0.5 then
	local mins = math_floor(BAT_CAPACITY_MAH * bat_state.pct_val / bat_state.curr * 60 / 1000)
	bat_state.pct_str = string_fmt("%d%% ~%dm", pct, mins)
    else
	bat_state.pct_str = string_fmt("%d%%", pct)
    end

    -- GPS cache: shared by the fixed-GPS info line and the waiting-for-fix screen
    if gps_state.alt ~= 0 then
	gps_str_info = string_fmt("%s:%d%s %+.1f", BASE_TEXTS.altitude, math_floor(gps_state.alt * _alt_factor), _alt_unit, gps_state.vspd)
    end
    gps_sats_str = string_fmt("%s:%d", BASE_TEXTS.sats, gps_state.sats)

    -- TOT cache: pre-format all stats strings
    tot_strs.l1_left  = string_fmt("%s:%.2fV", BASE_TEXTS.min_volt, stats.min_voltage)
    tot_strs.l1_right = string_fmt("%s: %.1fA", BASE_TEXTS.max_cur, stats.max_current)
    tot_strs.l2_left = string_fmt("%s: %.0f%s", BASE_TEXTS.max_alt,
	stats.max_alt * _alt_factor, _alt_unit)
    tot_strs.l2_right = string_fmt("%s: %s", BASE_TEXTS.distance, format_dist(stats.total_dist))
    tot_strs.l3_left = string_fmt("%s: %.1f%s", BASE_TEXTS.max_spd,
	stats.max_speed * _spd_factor, _spd_unit)
    tot_strs.l3_right = string_fmt("%s: %d", BASE_TEXTS.max_sats, stats.max_sats)
    tot_strs.l4_left = _capa_is_pct
	and string_fmt("%s: %d%%",  BASE_TEXTS.mahdrain, stats.mahdrain)
	or  string_fmt("%s: %dmAh", BASE_TEXTS.mahdrain, stats.mahdrain)
    tot_strs.l4_right = string_fmt("%s: %d:%02d", BASE_TEXTS.flt_time,
	math_floor(stats.flight_time / 6000),
	math_floor(stats.flight_time / 100) % 60)
    tot_strs.l5_left  = stats.min_lq == 999
	and string_fmt("%s: --",   BASE_TEXTS.min_lq)
	or  string_fmt("%s: %d%%", BASE_TEXTS.min_lq, stats.min_lq)

    force_redraw      = true
end

-- ------------------------------------------------------------
-- 10. DRAWING FUNCTIONS
-- ------------------------------------------------------------

-- Draws the tab headers at the top of the screen.
-- Active tab uses filled background + inverted text; inactive tabs use border 
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

-- Draws the BAT page
local function draw_bat_page(blink_on)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_value_y,
        bat_state.rx_fmt, DBLSIZE + CENTER)
    lcd_drawText(0, LAYOUT.bat_label_y, BASE_TEXTS.vcell, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.bat_label_y, "TX", SMLSIZE + RIGHT)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_label_y,
	bat_state.chem_cell_str, SMLSIZE + CENTER)

    local cell_voltage_alert = (BATTERY_ALERT_ENABLED and bat_state.cells > 0 and bat_state.cell_voltage < bat_state.threshold)

    if bat_state.cells > 0 then
	lcd_drawText(0, LAYOUT.bat_cell_y, bat_state.cell_fmt,
	    SMLSIZE + (cell_voltage_alert and INVERS or 0))
    else
        lcd_drawText(0, LAYOUT.bat_cell_y, str_minus_minus_V, SMLSIZE)
    end

    lcd_drawText(SCREEN_W, LAYOUT.bat_cell_y, bat_state.bat_tx_fmt,
	SMLSIZE + RIGHT + (TX_BAT_WARN > 0
	    and bat_state.bat_tx > 0
	    and bat_state.bat_tx < TX_BAT_WARN
	    and blink_on and INVERS or 0))

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

-- Draws the GPS page
local function draw_gps_page(blink_on)
    if gps_state.fix and not telemetry_live and blink_on then
        lcd_drawRect(0, CONTENT_Y, SCREEN_W, LAYOUT.gps_lost_h, SOLID)
    end

    if gps_state.fix then
        lcd_drawText(SCREEN_W - 4, LAYOUT.coord_lat_y, gps_state.lat_str, FONT_COORDS + RIGHT)
        lcd_drawText(SCREEN_W - 4, LAYOUT.coord_lon_y, gps_state.lon_str, FONT_COORDS + RIGHT)
	lcd_drawText(SCREEN_W - 4, LAYOUT.info_y,      gps_str_info,      FONT_INFO + RIGHT)
	lcd_drawText(4,            LAYOUT.url_y,       gps_sats_str,      FONT_INFO)
	lcd_drawText(SCREEN_W - 4, LAYOUT.url_y,       gps_state.plus_code_url, FONT_INFO + RIGHT)

	if gps_state.qr_cache then
	    local qr_size = 25 * qr_scale + 4
	    lcd_drawFilledRect(LAYOUT.qr_x, LAYOUT.qr_y, qr_size, qr_size, SOLID)
	    for r = 0, 24 do
    		local row_bits = gps_state.qr_cache[r + 1]
    		if row_bits ~= 0 then
        	    for c = 0, 24 do
            		if (row_bits & (1 << c)) ~= 0 then
                	    lcd_drawFilledRect(LAYOUT.qr_x + 2 + c * qr_scale, LAYOUT.qr_y + 2 + r * qr_scale, qr_scale, qr_scale, ERASE_FLAG)
            		end
        	    end
    		end
	    end
	end
    else
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, BASE_TEXTS.waiting, FONT_COORDS + CENTER)
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y, gps_sats_str, FONT_INFO + CENTER)
    end
end

-- Draws the TOT page
local function draw_tot_page()
    lcd_drawText(0, LAYOUT.tot_line1_y, tot_strs.l1_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line1_y, tot_strs.l1_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line2_y, tot_strs.l2_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line2_y, tot_strs.l2_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line3_y, tot_strs.l3_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line3_y, tot_strs.l3_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line4_y, tot_strs.l4_left, SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.tot_line4_y, tot_strs.l4_right, SMLSIZE + RIGHT)
    lcd_drawText(0, LAYOUT.tot_line5_y, tot_strs.l5_left,  SMLSIZE)
end

-- Draws the LOC page
local function draw_loc_page(blink_on)
    if not loc_active then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, BASE_TEXTS.loc_start, FONT_COORDS + CENTER)
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y - 6, BASE_TEXTS.loc_dynpwr1, FONT_INFO + CENTER)
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y + 2, BASE_TEXTS.loc_dynpwr2, FONT_INFO + CENTER)
        return
    end

    if not loc_sig then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y,
            BASE_TEXTS.loc_nosig, FONT_COORDS + CENTER + (blink_on and INVERS or 0))
        return
    end

    local dbl_y  = CONTENT_Y + 9
    local sml_y  = dbl_y + 6
    lcd_drawText(SCREEN_CENTER_X, dbl_y, string_fmt("%d dB", loc_sig), DBLSIZE + CENTER)
    lcd_drawText(2,               sml_y, loc_tpwr and string_fmt("%dmW", loc_tpwr) or "?mW", FONT_INFO)
    lcd_drawText(SCREEN_W - 2,    sml_y, string_fmt("%d%%", math_floor(loc_sig_pct)), FONT_INFO + RIGHT)

    local cells_filled = math_floor(loc_sig_pct * LAYOUT.loc_cell_n / 100)
    for i = 0, LAYOUT.loc_cell_n - 1 do
        local cx = 2 + i * LAYOUT.loc_cell_w
        lcd_drawRect(cx, LAYOUT.loc_cell_y,
            LAYOUT.loc_cell_w - 1, LAYOUT.loc_cell_h, SOLID)
        if i < cells_filled then
            lcd_drawFilledRect(cx + 1, LAYOUT.loc_cell_y + 1,
                LAYOUT.loc_cell_w - 3, LAYOUT.loc_cell_h - 2, SOLID)
        end
    end
end

-- Draws the CFG overlay
local function draw_cfg_page(blink_on)
    local cx, cy = LAYOUT.cfg_x, LAYOUT.cfg_y
    local cw, ch = LAYOUT.cfg_w, LAYOUT.cfg_h

    lcd_drawFilledRect(cx, cy, cw, ch, ERASE_FLAG)
    lcd_drawRect(cx, cy, cw, ch, SOLID)

    local txt_y = cy + 4

    cfg_scroll = math_max(0, math_min(cfg_scroll, #cfg_items - LAYOUT.cfg_visible))
    for i = cfg_scroll + 1, math_min(cfg_scroll + LAYOUT.cfg_visible, #cfg_items) do
        local flags_label = SMLSIZE
        local flags_val = SMLSIZE + RIGHT

        if i == cfg_sel then
            if cfg_edit then
                if blink_on then flags_val = flags_val + INVERS end
            else
                flags_val = flags_val + INVERS
            end
        end

        lcd_drawText(cx + 4,      txt_y, cfg_items[i].label, flags_label)
        lcd_drawText(cx + cw - 4, txt_y, cfg_items[i].val,   flags_val)
        txt_y = txt_y + LAYOUT.cfg_item_h
    end
end

local last_blink_state = false

-- ------------------------------------------------------------
-- 11. MAIN FUNCTION
-- ------------------------------------------------------------
local function run(event)
    if event ~= 0 then
        force_redraw = true

        -- Touch-screen tab navigation (TX16S, Boxer, and other touch-capable radios).
        -- EVT_TOUCH_FIRST is nil on button-only radios, so the outer guard is safe.
	if EVT_TOUCH_FIRST and event == EVT_TOUCH_FIRST and not show_cfg then
	    if getTouchState then
    		local touch = getTouchState()
    		if touch and touch.y <= TAB_H then
        	    local tapped = math_floor(touch.x / TAB_W) + 1
        	    if tapped >= 1 and tapped <= #TABS then current_page = tapped end
    		end
	    end
	    return 0
	end

        -- Toggle config overlay; auto-save on close if settings were modified
	if event == EVT_VIRTUAL_MENU_LONG then
            show_cfg = not show_cfg
	    if show_cfg then refresh_cfg_vals() end
            if not show_cfg then
                cfg_edit = false  -- always exit edit mode when closing
                if cfg_changed then
                    save_config() -- save changes to SD card
                    cfg_changed = false
                end
            end
            return 0
        end

        -- Block all other events until toggled off, but allow navigation
        if show_cfg then
	    if event == EVT_EXIT_BREAK and not cfg_edit then
    		show_cfg = false
    		if cfg_changed then
        	    save_config()
        	    cfg_changed = false
    		end
    		return 0
	    end
            if not cfg_edit then
		if event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST then
		    cfg_sel = cycle(cfg_sel, #cfg_items,  1)
		elseif event == EVT_ROT_LEFT or event == EVT_MINUS_FIRST then
		    cfg_sel = cycle(cfg_sel, #cfg_items, -1)
                elseif event == EVT_ENTER_BREAK then
                    cfg_edit = true
                end
            else
                -- In edit mode
                if event == EVT_ENTER_BREAK or event == EVT_EXIT_BREAK then
                    cfg_edit = false
		elseif event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST or
    			event == EVT_ROT_LEFT  or event == EVT_MINUS_FIRST then
		    cfg_changed = true
		    local dir = (event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST) and 1 or -1
		    if cfg_sel == 1 then
    			UPDATE_RATE = math_max(10, math_min(500, UPDATE_RATE + 10 * dir))
		    elseif cfg_sel == 2 then
    			BATTERY_ALERT_ENABLED = not BATTERY_ALERT_ENABLED
		    elseif cfg_sel == 3 then
    			BATTERY_ALERT_AUDIO = not BATTERY_ALERT_AUDIO
		    elseif cfg_sel == 4 then
    			BATTERY_ALERT_INTERVAL = math_max(0, math_min(10000, BATTERY_ALERT_INTERVAL + 100 * dir))
		    elseif cfg_sel == 5 then
    			BATTERY_ALERT_STEP = math_max(0.05, math_min(1.0, BATTERY_ALERT_STEP + 0.05 * dir))
		    elseif cfg_sel == 6 then
    			SAG_CURRENT_THRESHOLD = math_max(5, math_min(100, SAG_CURRENT_THRESHOLD + 5 * dir))
		    elseif cfg_sel == 7 then
			TX_BAT_WARN = TX_BAT_WARN > 0 and 0 or _bat_warn_default
		    elseif cfg_sel == 8 then
			TOAST_DURATION = math_max(50, math_min(500, TOAST_DURATION + 50 * dir))
		    elseif cfg_sel == 9 then
			BAT_CAPACITY_MAH = math_max(100, math_min(20000, BAT_CAPACITY_MAH + 100 * dir))
		    elseif cfg_sel == 10 then
			MIN_SATS = math_max(3, math_min(8, MIN_SATS + dir))
		    elseif cfg_sel == 11 then
			HAPTIC = not HAPTIC
		    end
		    refresh_cfg_vals()
                end
            end

	    if cfg_sel > cfg_scroll + LAYOUT.cfg_visible then
    		cfg_scroll = cfg_sel - LAYOUT.cfg_visible
	    elseif cfg_sel <= cfg_scroll then
    		cfg_scroll = cfg_sel - 1
	    end

            return 0
        end

	if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
	    current_page = cycle(current_page, #TABS,  1)
	elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
	    current_page = cycle(current_page, #TABS, -1)
	elseif event == EVT_ENTER_BREAK then
            if current_page == 1 then
                bat_state.cfg_idx = (bat_state.cfg_idx % #BAT_CONFIG) + 1
                local bcfg = BAT_CONFIG[bat_state.cfg_idx]
                bat_state.threshold = bcfg.volt
                bat_state.lbl_vmin = string_fmt("%.2fV", bcfg.v_min)
                bat_state.lbl_vmax = string_fmt("%.2fV", bcfg.v_max)
		bat_state.chem_cell_str = string_fmt("%s [%s]", bcfg.text,
		    bat_state.cells > 0 and bat_state.cell_s or "-S")
                show_toast(string_fmt("** %s (%.1fV) **", bcfg.text, bat_state.threshold))
            elseif current_page == 2 then
                if type(screenshot) == "function" then
                    screenshot()
                end
                show_toast(string_fmt("** %s **", BASE_TEXTS.shot))
            elseif current_page == 3 then
                reset_stats()
		show_toast(string_fmt("** %s **", BASE_TEXTS.resetted))
	    elseif current_page == 4 then
		loc_active = not loc_active
	        if not loc_active then loc_next_play = 0; loc_sig = nil end
            end
        end
    end

    -- Battery alert logic. Two-tier re-alert logic:
    --   Tier 1 (time): re-alert only after BATTERY_ALERT_INTERVAL centiseconds
    --                  have elapsed since the last alert.
    --   Tier 2 (step): re-alert only if voltage has dropped at least
    --                  BATTERY_ALERT_STEP volts since the last alert.
    -- Both conditions must be true simultaneously. This prevents spamming
    -- alerts when voltage fluctuates around the threshold under sag.
    -- SAG_CURRENT_THRESHOLD suppresses all alerts during high-current draws
    -- where temporary voltage sag is expected and non-critical.
    local current_time = getTime()
    if BATTERY_ALERT_ENABLED and bat_state.cells > 0 and bat_state.curr <= SAG_CURRENT_THRESHOLD then
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
	    if bat_state.alert_volt ~= 0 then
    		bat_state.alert_time = current_time
    		bat_state.alert_volt = 0
	    end
        end
    end

    -- blink_on toggles at 1 Hz by testing bit 0 of (time / 100cs).
    -- Redraws are forced on every state change to avoid stale frames.
    local blink_on = (math_floor(current_time / CENTISECS_PER_SEC) % 2) == 0
    if blink_on ~= last_blink_state then
        last_blink_state = blink_on
        force_redraw = true
    end

    -- Keep redrawing while a toast is visible (toast has its own duration timer)
    local toast_visible = toast_msg and (current_time - toast_time) < TOAST_DURATION
    if toast_visible then
        force_redraw = true -- always redraw while toast is visible
    end

    -- Locator
    if current_page == 4 and loc_active then
	-- Signal Cache
	local s = loc_get_signal()
	local tpwr_raw = getFieldInfo("TPWR") and getValue("TPWR") or nil

	-- ELRS uses segmented dBm scaling with two linear zones:
	--   Zone 1 (noise floor → FAR): maps -115..LOC_SEG_FAR  → 0..10%
	--   Zone 2 (FAR → near):        maps LOC_SEG_FAR..LOC_SEG_NEAR → 10..100%
	-- The two-zone model gives higher resolution in the useful mid-range
	-- while still showing movement at the extreme far end.
	-- Non-ELRS links report 0-100 directly; no remapping needed.
	if s then
	    if _loc_is_elrs then
		-- segmented: -115..LOC_SEG_FAR = 0..10% | LOC_SEG_FAR..LOC_SEG_NEAR = 10..100%
		if s >= LOC_SEG_NEAR then
    		    loc_sig_pct = 100
		elseif s <= LOC_SEG_FAR then
    		    loc_sig_pct = math_max(0, 10 * (s - (-115)) / (LOC_SEG_FAR - (-115)))
		else
    		    loc_sig_pct = 10 + 90 * (s - LOC_SEG_FAR) / (LOC_SEG_NEAR - LOC_SEG_FAR)
		end
	    else
    		loc_sig_pct = math_max(0, math_min(100, s))
	    end
	else
	    loc_sig_pct   = 0
	end

	-- Force redraw only when signal or TX power actually changes.
	if s ~= loc_sig or tpwr_raw ~= loc_tpwr then
    	    loc_sig   = s
    	    loc_tpwr  = tpwr_raw
    	    force_redraw = true
	end

	-- Beep
	local now = getTime()
	if now >= loc_next_play then
    	    if loc_sig then
        	playTone(math_floor(400 + loc_sig_pct * 6), 80, 0, PLAY_NOW)
        	if HAPTIC and playHaptic then playHaptic(7, 0, 1) end
    	    end
	    -- interval shrinks linearly from LOC_BEEP_MAX_CS (weak signal) to LOC_BEEP_MIN_CS (strong signal)
    	    loc_next_play = now + math_floor(LOC_BEEP_MAX_CS - (LOC_BEEP_MAX_CS - LOC_BEEP_MIN_CS) * loc_sig_pct / 100)
	end
    end

    if not force_redraw then return 0 end
    force_redraw = false

    lcd_clear()
    draw_tabs()

    if     current_page == 1 then draw_bat_page(blink_on)
    elseif current_page == 2 then draw_gps_page(blink_on)
    elseif current_page == 3 then draw_tot_page()
    elseif current_page == 4 then draw_loc_page(blink_on)
    end

    if show_cfg then draw_cfg_page(blink_on) end

    -- Unified toast notification system (centered, inverted text overlay)
    if toast_visible then
        lcd_drawFilledRect(toast_layout.x - 2, toast_layout.y - 1, toast_layout.w + 4, toast_layout.h, SOLID)
        lcd_drawText(SCREEN_CENTER_X, toast_layout.y, toast_msg, SMLSIZE + CENTER + INVERS)
    end

    return 0
end

return { init = init, background = background, run = run }

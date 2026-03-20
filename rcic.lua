-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version: 3.2
-- Date:    2026-03-20
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
local AUTO_TAB               = true   -- auto-switch to GPS/LOC tab on telemetry loss
local ARM_SWITCH             = ""     -- arm switch name ("" = disabled)
local ARM_VALUE              = 0      -- exact switch value captured during arm-listen

-- ------------------------------------------------------------
-- 2. CONSTANTS AND INTERNAL CONFIGURATION
-- ------------------------------------------------------------

local CENTISECS_PER_SEC = 100
local GPS_MAX_JUMP      = 5000  -- metres; filters impossible GPS teleport jumps

local LOC_BEEP_MAX_CS   = 200
local LOC_BEEP_MIN_CS   = 20
local LOC_BEEP_RANGE    = LOC_BEEP_MAX_CS - LOC_BEEP_MIN_CS  -- 180 cs

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
    fmode = { "FM",  "FMod"        },
    tpwr  = { "TPWR"               },
}

local ARM_SW_LIST = {"SA","SB","SC","SD","SE","SF","SG","SH"}

local SYM_UP   = CHAR_UP   -- ▲ (high)
local SYM_DOWN = CHAR_DOWN -- ▼ (low)

local FM_AREA_W   = 26
local FM_DISARMED = { ["OK"]=true, ["!ERR"]=true, ["WAIT"]=true, [""] = true }

-- Equirectangular distance approximation; accurate to ~0.5% for distances < 100 km.
local RAD     = math.pi / 180
local R_EARTH = 6371000  -- metres
local LAT_DIVISORS = { 800000, 40000, 2000, 100, 5 }
local LON_DIVISORS = { 640000, 32000, 1600, 80, 4 }
local ALPHABET     = "23456789CFGHJMPQRVWX"

local QR_PAD = { 236, 17 } -- QR padding bytes 0xEC/0x11 per spec; fixed, never changes
local QR_BASE = {          -- {base_value, write_mask}: 1-bits in write_mask mark reserved/fixed modules.
    { 0x1fc007f, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x174015d, 0x1fe01ff }, { 0x174005d, 0x1fe01ff },
    { 0x174005d, 0x1fe01ff }, { 0x1040041, 0x1fe01ff }, { 0x1fd557f, 0x1ffffff }, { 0x0000100, 0x1fe01ff },
    { 0x04601f7, 0x1fe01ff }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 }, { 0x0000040, 0x0000040 }, { 0x0000000, 0x0000040 },
    { 0x01f0040, 0x01f0040 }, { 0x0110100, 0x01f01ff }, { 0x015017f, 0x01f01ff }, { 0x0110141, 0x01f01ff },
    { 0x01f015d, 0x01f01ff }, { 0x000005d, 0x00001ff }, { 0x000015d, 0x00001ff }, { 0x0000141, 0x00001ff },
    { 0x000017f, 0x00001ff }
}
-- Generator polynomial for QR v2-L (16 EC codewords, degree-16 over GF(256))
local QR_GEN = { 59, 13, 104, 189, 68, 209, 30, 8, 163, 65, 41, 229, 98, 50, 36, 59 }

local CFG_FILE          = "/SCRIPTS/TELEMETRY/rcic.cfg"

local STATS_DEFAULTS = { max_alt = 0, total_dist = 0, min_voltage = 0, max_speed = 0, max_current = 0, max_sats = 0, mahdrain = 0, flight_time = 0, min_lq = 999 }

-- ------------------------------------------------------------
-- 3. EXTERNAL CONSTANTS/FUNCTION LOCALIZATION
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
-- 4. ENVIRONMENT AND LAYOUT VARIABLES
-- ------------------------------------------------------------

local SCREEN_W, SCREEN_H, SCREEN_CENTER_X
local FONT_COORDS, FONT_INFO
local TAB_H, CONTENT_Y, CONTENT_H
local LAYOUT
local TABS, TABS_LAYOUT, TAB_W

local qr_scale         = 1   -- pixels per QR module

local alt_unit        = "m"
local alt_factor      = 1.0
local spd_unit        = "kmh"
local spd_factor      = 1.0

-- fallback TX warning threshold when getGeneralSettings() provides no battWarn value
local bat_warn_default = 6.6

local CFG_KEYS = { "cfg_rate", "cfg_alert", "cfg_audio", "cfg_int",
		   "cfg_step", "cfg_sag", "cfg_tx_warn", "cfg_toast",
		   "cfg_capacity", "cfg_minsats", "cfg_haptic",
		   "cfg_autotab", "cfg_armswitch" }

local toast_shot     = ""   -- pre-built in init() after language setup
local toast_resetted = ""   -- pre-built in init() after language setup

-- ------------------------------------------------------------
-- 4.1. TRANSLATION SYSTEM VARIABLES
-- ------------------------------------------------------------

local BASE_TEXTS = {
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
    cfg_autotab = "Auto Tab",
    cfg_armswitch = "Arm SW",
    flt_time  = "FLT",
    min_lq    = "MIN LQ",
    loc_start = "ENTER: START",
    loc_dynpwr1 = "Best results obtained if",
    loc_dynpwr2 = "disable TX Dynamic Power",
    loc_nosig = "NO SIGNAL",
    efficiency = "EFF",
}

local LANG_OVERRIDES = {
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
-- 5. TELEMETRY ENGINE STATUS VARIABLES (Background)
-- ------------------------------------------------------------

local last_update_time = 0

local telemetry_live   = false
local prev_telem_live = false

local sensors = {}

local capa_is_pct = false
local loc_is_elrs = false

local gps_state = {
    lat           = 0,
    lon           = 0,
    alt           = 0,
    fix           = false,
    plus_code_url = "",
    lat_str       = "0.000000",
    lon_str       = "0.000000",
    sats          = 0,
    qr_cache      = nil,
    vspd          = 0,     -- vertical speed m/s (+ascending / -descending)
    prev_alt      = 0,     -- altitude from previous cycle for delta calculation
}

local bat_state = {
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

local stats = {}

local fm_str        = nil
local fm_armed      = false
local armed_display = false

-- ------------------------------------------------------------
-- 6. INTERFACE STATE AND EVENTS VARIABLES (run)
-- ------------------------------------------------------------

local current_page     = 1
local force_redraw     = true
local last_blink_state = false

local show_cfg          = false
local cfg_sel           = 1
local cfg_edit          = false
local cfg_edit_snapshot = nil
local cfg_changed       = false
local cfg_scroll        = 0
local cfg_items         = {}

local loc_active    = false
local loc_next_play = 0
local loc_sig       = nil       -- last raw signal value (dBm for ELRS, 0-100 for RSSI). nil = no sensor read.
local loc_tpwr      = nil       -- TX power in mW from TPWR sensor; nil if sensor absent.
local loc_sig_pct   = 0         -- normalised 0-100 value driving bar fill, beep rate and haptic.
local loc_peak_pct  = 0         -- normalised peak 0-100, drives bar marker

local toast_msg    = nil
local toast_time   = 0
local toast_layout = { x = 0, y = 0, w = 0, h = 11 }

local sw_listen      = false  -- true while scanning for switch input
local sw_snapshot    = {}     -- switch values at listen start
local sw_pending     = ""     -- switch detected during listen, pending confirmation
local sw_pending_val = 0

-- ------------------------------------------------------------
-- 7. RENDERING BUFFERS & GC CACHE VARIABLES
-- ------------------------------------------------------------

local tot_strs = {
    l1_left  = "", l1_right = "",
    l2_left  = "", l2_right = "",
    l3_left  = "", l3_right = "",
    l4_left  = "", l4_right = "",
    l5_left  = "", l5_right = "",
}

local gps_str_info = ""
local gps_sats_str = ""
local last_sats   = -1

local qr_e, qr_l = nil, nil  -- GF(256) exp/log tables, built once in init()
local qr_b       = {}        -- working bitstream buffer (data + EC + remainder bits)
local qr_m       = {}        -- 28 data codewords as integers
local qr_ec      = {}        -- 16 Reed-Solomon error correction codewords
local qr_res     = {}        -- 25-row QR result buffer; reused across every regeneration

local str_minus_minus_V = "--V"  -- placeholder shown when cell count is unknown

local loc_sig_fmt  = ""      -- "%d dB"
local loc_tpwr_fmt = "?mW"   -- "%dmW" o "?mW"
local loc_pct_fmt  = "0%"    -- "%d%%"

-- ------------------------------------------------------------
-- 8. UTILITY FUNCTIONS
-- ------------------------------------------------------------

-- Returns a single display character representing the physical position of
-- a switch based on its raw getValue() reading: SYM_UP (▲) when the value
-- is positive (high), SYM_DOWN (▼) when negative (low), or "-" when zero
-- (mid). Used to show the captured ARM_SWITCH position in the config
-- overlay (cfg_items[13]) and during the live arm-switch capture session.
local function sw_pos(val)
    if     val > 0 then return SYM_UP
    elseif val < 0 then return SYM_DOWN
    else               return "-"
    end
end

-- Rebuilds the display value string for every item in cfg_items[], reflecting
-- the current state of all runtime configuration variables. Called whenever
-- the config overlay opens, after any setting is changed in edit mode, and
-- during the arm-switch capture session to show the live switch position.
-- Item 13 (ARM_SWITCH) has three display states:
--   · Capture in progress + switch identified → "<SW><pos>"  (e.g. "SB^")
--   · Capture idle + switch configured        → "<SW><pos>"  (e.g. "SA-")
--   · No switch configured                    → "--"
-- All other items format their corresponding runtime variable directly into
-- a short string sized to fit the config overlay value column.
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
    cfg_items[12].val = AUTO_TAB and BASE_TEXTS.cfg_on or BASE_TEXTS.cfg_off
    if sw_listen and sw_pending ~= "" then
	cfg_items[13].val = sw_pending .. sw_pos(sw_pending_val)
    elseif ARM_SWITCH ~= "" then
	cfg_items[13].val = ARM_SWITCH .. sw_pos(ARM_VALUE)
    else
	cfg_items[13].val = "--"
    end
end

-- Assigns val directly to the runtime configuration variable mapped to sel
-- (1–12). Used by the rotary handler (via cfg_set_var) and by the edit-cancel
-- path (EVT_EXIT_BREAK) to restore a snapshot. Item 13 (ARM_SWITCH) is not
-- handled here: its capture lifecycle is managed separately by sw_listen /
-- confirm_sw_listen. Callers must invoke refresh_cfg_vals() after this call
-- to rebuild the cfg_items[].val display strings.
local function cfg_set_var(sel, val)
    if     sel == 1  then UPDATE_RATE             = val
    elseif sel == 2  then BATTERY_ALERT_ENABLED   = val
    elseif sel == 3  then BATTERY_ALERT_AUDIO     = val
    elseif sel == 4  then BATTERY_ALERT_INTERVAL  = val
    elseif sel == 5  then BATTERY_ALERT_STEP      = val
    elseif sel == 6  then SAG_CURRENT_THRESHOLD   = val
    elseif sel == 7  then TX_BAT_WARN             = val
    elseif sel == 8  then TOAST_DURATION          = val
    elseif sel == 9  then BAT_CAPACITY_MAH        = val
    elseif sel == 10 then MIN_SATS                = val
    elseif sel == 11 then HAPTIC                  = val
    elseif sel == 12 then AUTO_TAB                = val
    end
end

-- Wraps a 1-based index cyclically within [1..n], stepping by dir (+1 or -1).
-- Handles both forward and backward wrapping: stepping past n returns 1,
-- stepping before 1 returns n. Used for tab navigation in run() and for
-- scrolling through cfg_items[] in handle_cfg_events().
-- Example: cycle(4, 4, 1) → 1,  cycle(1, 4, -1) → 4
local function cycle(val, n, dir) return (val - 1 + dir + n) % n + 1 end

-- ------------------------------------------------------------
-- 9. INIT & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Resets all flight statistics to their zero/default values by copying
-- every field from STATS_DEFAULTS into the stats table. Covers max altitude,
-- total distance, min cell voltage, max speed, max current, max satellites,
-- mAh drain, flight time, and min link quality (min_lq resets to 999 so
-- the first real reading always becomes the new minimum).
-- Called once at startup and whenever the user triggers a manual reset
-- from the TOT page (EVT_ENTER_BREAK on current_page == 3).
local function reset_stats()
    for k, v in pairs(STATS_DEFAULTS) do stats[k] = v end
end

-- Builds the GF(256) exponent and log lookup tables used by the Reed-Solomon
-- ECC encoder inside generate_qrv2(). The field is constructed over the
-- irreducible primitive polynomial x^8+x^4+x^3+x^2+1 (0x11D = 285), the
-- same polynomial used by the QR Code specification and AES.
-- qr_e[i] = alpha^i mod p(x)  — antilog / exponent table (0..255)
-- qr_l[v] = log_alpha(v)      — log table (1..255; v=0 is undefined)
-- Together they reduce GF(256) multiply/divide to integer addition and a
-- mod-255 table lookup, avoiding per-symbol division in the hot RS loop.
-- Guarded by (not qr_e) so repeated calls to init() are safe with no cost.
local function init_gf_tables()
    if not qr_e then
        qr_e, qr_l = {}, {}
        local x = 1
        for i = 0, 254 do
            qr_e[i] = x
--	    if not qr_l[x] then qr_l[x] = i end
            qr_l[x] = i
            x = x * 2
            if x > 255 then x = x ~ 285 end
        end
        qr_e[255] = qr_e[0]
    end
end

-- Reads and parses the persistent configuration from the SD card CSV file
-- (CFG_FILE). Fields are positionally mapped in the same order used by
-- save_config(): update rate, alert flags, intervals, thresholds, imperial
-- units, capacity, ARM switch index and value. Missing or extra fields are
-- silently ignored, preserving forward and backward compatibility across
-- firmware versions. If the file is absent or empty, all runtime variables
-- retain their compiled-in defaults. The ARM switch is resolved from its
-- stored 1-based index back to a name in ARM_SW_LIST ("SA"…"SH"); index 0
-- means no switch configured (ARM_SWITCH = "").
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
    if n(5) then BATTERY_ALERT_STEP     = n(5) / 100  end
    if n(6) then SAG_CURRENT_THRESHOLD  = n(6)        end
    if n(7) then TX_BAT_WARN            = n(7) / 10   end
    if n(8)  then TOAST_DURATION        = n(8)        end
    if n(9)  then BAT_CAPACITY_MAH      = n(9)        end
    if n(10) then MIN_SATS              = n(10)       end
    if n(11) then HAPTIC                = n(11) == 1  end
    if n(12) then AUTO_TAB              = n(12) == 1  end
    if n(13) then ARM_SWITCH            = (n(13) > 0 and ARM_SW_LIST[n(13)]) or "" end
    if n(14) then ARM_VALUE             = n(14)       end
end

-- Applies language overrides from LANG_OVERRIDES to BASE_TEXTS, pre-builds
-- toast strings, populates cfg_items labels, and applies radio-level settings
-- (TX battery warning threshold, imperial units). Finishes by loading the
-- persistent config from SD card so all user settings are active before the
-- first draw cycle.
local function apply_language(gs)
    local LANG = (gs.language and string_sub(string_lower(gs.language), 1, 2)) or "en"
    if LANG_OVERRIDES[LANG] then
        for k, v in pairs(LANG_OVERRIDES[LANG]) do BASE_TEXTS[k] = v end
    end

    toast_shot     = "** " .. BASE_TEXTS.shot     .. " **"
    toast_resetted = "** " .. BASE_TEXTS.resetted .. " **"

    for i, key in ipairs(CFG_KEYS) do
        cfg_items[i] = { label = BASE_TEXTS[key], val = "" }
    end

    TX_BAT_WARN       = gs.battWarn or bat_warn_default
    bat_warn_default = gs.battWarn or bat_warn_default
    if gs.imperial ~= nil then USE_IMPERIAL = gs.imperial ~= 0 end
    if USE_IMPERIAL then
        alt_unit   = "ft";  alt_factor  = 3.28084
        spd_unit   = "mph"; spd_factor  = 0.621371
    end
end

-- Detects screen dimensions and selects font sizes accordingly.
-- Small screens (< 300 px): MIDSIZE coords, SMLSIZE info.
-- Large screens (TX16S, TX12 Mk2, Boxer, etc.): DBLSIZE coords, MIDSIZE info.
-- Also derives qr_scale (1–4 px/module) from screen width so the QR code
-- fills the available space without overflowing on any supported radio.
local function detect_screen()
    SCREEN_W    = LCD_W or 128
    SCREEN_H    = LCD_H or 64
    FONT_COORDS = MIDSIZE
    FONT_INFO   = SMLSIZE
    if SCREEN_W >= 300 then
        FONT_COORDS = DBLSIZE
        FONT_INFO   = MIDSIZE
    end
    qr_scale = math_min(4, math_floor(SCREEN_W / 100))
end

-- Pre-computes all layout positions as absolute pixel coordinates to avoid
-- repeated arithmetic inside draw functions. Covers GPS, BAT, TOT, LOC and
-- CFG overlay geometry, the toast Y position, and tab bar hit regions.
-- Must be called after detect_screen() so SCREEN_W/H are already set.
local function compute_layout()
    SCREEN_CENTER_X = math_floor(SCREEN_W / 2)
    TAB_H           = 9
    CONTENT_Y       = TAB_H + 1
    CONTENT_H       = SCREEN_H - CONTENT_Y

    LAYOUT = {
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

    LAYOUT.loc_cell_bw   = LAYOUT.loc_cell_w - 1   -- rect border width
    LAYOUT.loc_cell_iw   = LAYOUT.loc_cell_w - 3   -- filled inner width
    LAYOUT.loc_cell_ih   = LAYOUT.loc_cell_h - 2   -- filled inner height
    LAYOUT.loc_peak_off  = math_floor((LAYOUT.loc_cell_w - 1) / 2) - 1

    toast_layout.y  = math_floor(SCREEN_H / 2) - 5

    TABS        = { BASE_TEXTS.tab_bat, BASE_TEXTS.tab_gps, BASE_TEXTS.tab_tot, BASE_TEXTS.tab_loc }
    TAB_W       = math_floor((SCREEN_W - FM_AREA_W) / #TABS)
    TABS_LAYOUT = {}
    for i = 1, #TABS do
        local x = (i - 1) * TAB_W
	local w = (i == #TABS) and (SCREEN_W - FM_AREA_W - x) or TAB_W
        TABS_LAYOUT[i] = { name = TABS[i], x = x, w = w, centerText_x = x + math_floor(w / 2) }
    end
end

-- ------------------------------------------------------------

local function init()
    reset_stats()
    init_gf_tables()
    local gs = getGeneralSettings() or {}
    apply_language(gs)
    detect_screen()
    load_config()
    compute_layout()
end

-- ------------------------------------------------------------
-- 10. DATA UPDATE (BACKGROUND) & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Probes all sensor candidates in SENSOR_MAP and caches the first responding name.
-- Sets loc_is_elrs true when the resolved LOC sensor is 1RSS/2RSS (ELRS link).
-- Runs once after telemetry becomes live; resets sensors.done on link loss to re-detect.
local function detect_sensors()
    for key, candidates in pairs(SENSOR_MAP) do
        for _, name in ipairs(candidates) do
            if getValue(name) ~= nil then sensors[key] = name; break end
        end
    end
    capa_is_pct = (sensors.capa == "Fuel")
    loc_is_elrs = (sensors.loc == "1RSS" or sensors.loc == "2RSS")
    sensors.done = true
end

-- EdgeTX GPS sensor returns {lat=0, lon=0} before acquiring a fix.
-- The (0,0) point is in the Gulf of Guinea; excluding it avoids
-- plotting the drone at sea during cold start.
local function is_valid_gps(lat, lon)
    return (lat ~= 0 or lon ~= 0) and
        lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180
end

-- Approximates the great-circle distance between two WGS-84 coordinate pairs
-- using the equirectangular projection. Multiplies the longitude delta by
-- cos(mid-latitude) to correct for meridian convergence, then applies
-- Pythagoras in radians scaled by Earth's mean radius (6 371 000 m).
-- Accurate to ~0.5% for distances under 100 km — sufficient for drone telemetry.
-- Returns distance in metres as a float.
local function fast_dist(lat1, lon1, lat2, lon2)
    local x = (lon2 - lon1) * RAD * math_cos((lat1 + lat2) / 2 * RAD)
    local y = (lat2 - lat1) * RAD
    return math_sqrt(x * x + y * y) * R_EARTH
end

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
        local ld = math_floor(lat_val / LAT_DIVISORS[i]) % 20
        local od = math_floor(lon_val / LON_DIVISORS[i]) % 20
        code = code
            .. string_sub(ALPHABET, ld + 1, ld + 1)
            .. string_sub(ALPHABET, od + 1, od + 1)
        if i == 4 then code = code .. "+" end
    end

    local ndx = (lat_val % 5) * 4 + (lon_val % 4)
    return code .. string_sub(ALPHABET, ndx + 1, ndx + 1)
end

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
            for j = 1, 16 do qr_ec[j] = qr_ec[j] ~ qr_e[(lf + qr_l[QR_GEN[j]]) % 255] end
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
    for r = 0, 24 do qr_res[r + 1] = QR_BASE[r + 1][1] end

    -- Place data bits using diagonal column scan (right-to-left column pairs, top/bottom sweep).
    -- Applies mask pattern 0: invert module when (row + col) % 2 == 0.
    local cx, cy, dir, bd = 24, 24, -1, 0
    while cx >= 0 do
        if cx == 6 then cx = cx - 1 end  -- skip the vertical timing column
        for _ = 1, 25 do
            for col = 0, 1 do
                local nx = cx - col
		if (QR_BASE[cy + 1][2] & (1 << nx)) == 0 then  -- skip reserved modules
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

-- Processes a confirmed valid GPS reading: applies a 2-metre jitter gate to
-- avoid redundant Plus Code and QR regeneration on a stationary craft, accumulates
-- travel distance with a teleport-jump filter (GPS_MAX_JUMP), and updates the
-- cached coordinate strings, Plus Code URL, QR matrix, position, altitude,
-- fix flag, and max altitude / max speed stats.
local function update_gps_position(cur_lat, cur_lon, alt, gspd)
    if gps_state.lat ~= cur_lat or gps_state.lon ~= cur_lon then
        local do_update = not gps_state.fix

        if gps_state.fix then
            local d = fast_dist(gps_state.lat, gps_state.lon, cur_lat, cur_lon)
            if d < GPS_MAX_JUMP then stats.total_dist = stats.total_dist + d end
            do_update = d > 2.0
        end

        if do_update then
            gps_state.lat_str       = string_fmt("%.6f", cur_lat)
            gps_state.lon_str       = string_fmt("%.6f", cur_lon)
            gps_state.plus_code_url = "OLC:" .. to_plus_code(cur_lat, cur_lon)
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

-- Pre-formats all battery display strings into bat_state to avoid string
-- allocations inside draw functions. Updates rx_fmt, cell_fmt, bat_tx_fmt,
-- pct_val and pct_str every cycle. Rebuilds cell_s and chem_cell_str only
-- when the detected cell count changes.
local function update_bat_strings()
    local bcfg = BAT_CONFIG[bat_state.cfg_idx]
    bat_state.rx_fmt     = string_fmt("%.2fV", bat_state.rx_bt)
    bat_state.cell_fmt   = string_fmt("%.2fV", bat_state.cell_voltage)
    bat_state.bat_tx_fmt = string_fmt("%.1fV", bat_state.bat_tx)
    bat_state.pct_val    = bat_state.cells > 0 and
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
end

-- Converts a raw distance in metres to a human-readable string.
-- Below 1 000 m returns an integer metre value ("542m").
-- At or above 1 000 m returns a two-decimal kilometre value ("1.23km").
-- When USE_IMPERIAL is true, converts to feet below one mile ("1 247ft")
-- or decimal miles at or above ("0.77mi").
-- Output is pre-formatted for direct use in lcd_drawText — no further
-- allocation needed at the call site.
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

-- Pre-formats all ten TOT-page stat strings into tot_strs to avoid string
-- allocations inside draw_tot_page. Covers min voltage, max current, max
-- altitude, total distance, max speed, max satellites, mAh drain, flight
-- time, min link quality, and mAh/km efficiency. Called once per background
-- cycle so draw_tot_page renders with zero allocations.
local function update_tot_strings()
    tot_strs.l1_left  = string_fmt("%s:%.2fV",  BASE_TEXTS.min_volt, stats.min_voltage)
    tot_strs.l1_right = string_fmt("%s: %.1fA", BASE_TEXTS.max_cur,  stats.max_current)
    tot_strs.l2_left  = string_fmt("%s: %.0f%s", BASE_TEXTS.max_alt,
        stats.max_alt * alt_factor, alt_unit)
    tot_strs.l2_right = string_fmt("%s: %s",    BASE_TEXTS.distance, format_dist(stats.total_dist))
    tot_strs.l3_left  = string_fmt("%s: %.1f%s", BASE_TEXTS.max_spd,
        stats.max_speed * spd_factor, spd_unit)
    tot_strs.l3_right = string_fmt("%s: %d",    BASE_TEXTS.max_sats, stats.max_sats)
    tot_strs.l4_left  = capa_is_pct
        and string_fmt("%s: %d%%",  BASE_TEXTS.mahdrain, stats.mahdrain)
        or  string_fmt("%s: %dmAh", BASE_TEXTS.mahdrain, stats.mahdrain)
    tot_strs.l4_right = string_fmt("%s: %d:%02d", BASE_TEXTS.flt_time,
        math_floor(stats.flight_time / 6000),
        math_floor(stats.flight_time / 100) % 60)
    tot_strs.l5_left  = stats.min_lq == 999
        and string_fmt("%s: --",   BASE_TEXTS.min_lq)
        or  string_fmt("%s: %d%%", BASE_TEXTS.min_lq, stats.min_lq)

    local _km      = stats.total_dist / 1000
    local _eff_val = (_km > 0.5 and stats.mahdrain > 0)
        and (USE_IMPERIAL and (stats.mahdrain / (_km * 1.60934))
        or  (stats.mahdrain / _km)) or nil
    tot_strs.l5_right = _eff_val
        and string_fmt("%s:%.0f%s", BASE_TEXTS.efficiency, _eff_val,
            USE_IMPERIAL and "/mi" or "/km")
        or  string_fmt("%s:--", BASE_TEXTS.efficiency)
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

-- ------------------------------------------------------------

local function background()
    local current_time = getTime()

    -- Rate-limit data updates to UPDATE_RATE centiseconds (default 1 Hz)
    if current_time - last_update_time < UPDATE_RATE then
        return
    end
    last_update_time = current_time

    -- These sensors are available even without a full telemetry link.
    if not sensors.done then detect_sensors() end
    bat_state.bat_tx = getValue("tx-voltage") or 0
    gps_state.sats   = sensors.sats and getValue(sensors.sats) or 0
    bat_state.rx_bt  = sensors.rxbt and getValue(sensors.rxbt) or 0

    -- Active link?
    local lq = sensors.link and getValue(sensors.link) or 0
    telemetry_live = lq > 0

    if not telemetry_live then
	if sensors.done then sensors.done = nil end
	fm_str  = nil    -- clear stale flight mode on link loss
	fm_armed = false
    end

    -- Skip remaining sensor reads when no active link
    if telemetry_live then
	if lq < stats.min_lq then stats.min_lq = lq end

	local gps_data = sensors.gps  and getValue(sensors.gps)  or nil
	local alt      = sensors.alt  and getValue(sensors.alt)  or 0
	local gspd     = sensors.gspd and getValue(sensors.gspd) or 0
	local capa     = sensors.capa and getValue(sensors.capa) or 0
	local curr     = sensors.curr and getValue(sensors.curr) or 0
	bat_state.curr = curr

	-- Flight mode: read string sensor; update fm_armed state
	if sensors.fmode then
	    local fm = getValue(sensors.fmode)
	    fm_str   = (type(fm) == "string" and #fm > 0) and fm or nil
	    fm_armed = fm_str ~= nil and not FM_DISARMED[fm_str]
	end

	if gps_state.sats > stats.max_sats then
    	    stats.max_sats = gps_state.sats
	end

	local cur_lat, cur_lon = 0, 0
	if type(gps_data) == "table" then
    	    cur_lat = gps_data["lat"] or gps_data[1] or 0
    	    cur_lon = gps_data["lon"] or gps_data[2] or 0
	end

        if gps_state.sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
            update_gps_position(cur_lat, cur_lon, alt, gspd)
        end

        if curr > stats.max_current then stats.max_current = curr end
        if capa > stats.mahdrain    then stats.mahdrain    = capa end

	-- Vario: prefer direct VSpd sensor (INAV/BF); fall back to altitude delta.
	-- Guard prev_alt ~= 0 avoids a spurious spike on the very first fix cycle.
	local raw_vspd = sensors.vspd and getValue(sensors.vspd) or 0
	if raw_vspd ~= 0 then
    	    gps_state.vspd = raw_vspd
	elseif gps_state.fix and gps_state.prev_alt ~= 0 then
    	    gps_state.vspd = (alt - gps_state.prev_alt) / (UPDATE_RATE / CENTISECS_PER_SEC)
	end
	gps_state.prev_alt = alt
    end

    if ARM_SWITCH ~= "" then
	local sv = getValue(ARM_SWITCH)
	armed_display = sv ~= nil and sv == ARM_VALUE
    elseif telemetry_live and sensors.fmode then
	armed_display = fm_armed
    else
	armed_display = false
    end

    -- Flight time: count only when armed.
    -- When no arm detection is available (no fmode, no ARM_SWITCH), counts
    -- whenever the telemetry link is live — the only safe fallback.
    if telemetry_live then
	local no_arm_detect = not sensors.fmode and ARM_SWITCH == ""
	if no_arm_detect or armed_display then
    	    stats.flight_time = stats.flight_time + UPDATE_RATE
	end
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

    update_bat_strings()

    -- GPS cache: shared by the fixed-GPS info line and the waiting-for-fix screen
    if gps_state.alt ~= 0 then
	gps_str_info = string_fmt("%s:%d%s %+.1f", BASE_TEXTS.altitude, math_floor(gps_state.alt * alt_factor), alt_unit, gps_state.vspd)
    end
    if gps_state.sats ~= last_sats then
	last_sats   = gps_state.sats
	gps_sats_str = string_fmt("%s:%d", BASE_TEXTS.sats, gps_state.sats)
    end

    update_tot_strings()

    force_redraw      = true
end

-- ------------------------------------------------------------
-- 11. DRAWING FUNCTIONS
-- ------------------------------------------------------------

-- Draws the tab headers at the top of the screen.
-- Active tab uses filled background + inverted text; inactive tabs use border 
local function draw_tabs()
    for i = 1, #TABS_LAYOUT do
        local tab = TABS_LAYOUT[i]
        if i == current_page then
            lcd_drawFilledRect(tab.x, 0, tab.w, TAB_H, SOLID)
            lcd_drawText(tab.centerText_x, 1, tab.name, SMLSIZE + CENTER + INVERS)
        else
            lcd_drawRect(tab.x, 0, tab.w, TAB_H, SOLID)
            lcd_drawText(tab.centerText_x, 1, tab.name, SMLSIZE + CENTER)
        end
    end

    -- Flight mode indicator: right of last tab
    local fx = SCREEN_W - FM_AREA_W + math_floor(FM_AREA_W / 2)
    if fm_str then
	-- FM text: INVERS when armed, normal when disarmed
	lcd_drawText(fx, 1, fm_str, SMLSIZE + CENTER + (armed_display and INVERS or 0))
    elseif ARM_SWITCH ~= "" and armed_display then
	-- No FM: show "ARM" centered, always normal (no inversion)
	lcd_drawText(fx, 1, "ARM", SMLSIZE + CENTER)
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
    lcd_drawText(SCREEN_W, LAYOUT.tot_line5_y, tot_strs.l5_right, SMLSIZE + RIGHT)
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
    lcd_drawText(SCREEN_CENTER_X, dbl_y, loc_sig_fmt,  DBLSIZE + CENTER)
    lcd_drawText(2,               sml_y, loc_tpwr_fmt, FONT_INFO)
    lcd_drawText(SCREEN_W - 2,    sml_y, loc_pct_fmt,  FONT_INFO + RIGHT)

    local cells_filled = math_floor(loc_sig_pct * LAYOUT.loc_cell_n / 100)

    for i = 0, LAYOUT.loc_cell_n - 1 do
	local cx = 2 + i * LAYOUT.loc_cell_w
	lcd_drawRect(cx, LAYOUT.loc_cell_y, LAYOUT.loc_cell_bw, LAYOUT.loc_cell_h, SOLID)
	if i < cells_filled then
    	    lcd_drawFilledRect(cx + 1, LAYOUT.loc_cell_y + 1,
        	LAYOUT.loc_cell_iw, LAYOUT.loc_cell_ih, SOLID)
	end
    end

    -- Peak marker: thin filled mark at peak cell position (only if above current)
    if loc_peak_pct > loc_sig_pct then
	local pcx = 2 + math_floor(loc_peak_pct * (LAYOUT.loc_cell_n - 1) / 100) * LAYOUT.loc_cell_w
	lcd_drawFilledRect(pcx + LAYOUT.loc_peak_off,
    	    LAYOUT.loc_cell_y + 1, 2, LAYOUT.loc_cell_ih, SOLID)
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

-- Displays a centered notification banner for TOAST_DURATION centiseconds.
-- Recalculates the banner width and horizontal position on every call to
-- fit variable-length messages. The vertical position (toast_layout.y) is
-- pre-computed once in init() and never changes. The banner is rendered
-- by run() as an overlay on top of the active page, and dismissed
-- automatically once (getTime() - toast_time) >= TOAST_DURATION.
-- Calling show_toast() again before the previous toast expires replaces
-- it immediately and resets the timer.
local function show_toast(msg)
    toast_msg = msg
    toast_time = getTime()

    local msg_w = math_max(#toast_msg * 6 + 10, 60)
    toast_layout.w = msg_w
    toast_layout.x = math_floor((SCREEN_W - msg_w) / 2)
end

-- ------------------------------------------------------------
-- 12. EVENT & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Serialises all user-configurable runtime variables to a fixed-format CSV
-- file on the SD card (CFG_FILE). Field order is fixed and must stay in sync
-- with load_config(). The ARM_SWITCH name is stored as a 1-based index into
-- ARM_SW_LIST ("SA"=1 … "SH"=8); 0 means no switch configured. Called
-- automatically when the config overlay closes after any change
-- (cfg_changed == true), and from handle_cfg_events() on EXIT. Safe to call
-- at any time; silently does nothing if the file cannot be opened.
local function save_config()
    local file = io.open(CFG_FILE, "w")
    local arm_idx = 0
    for i, sw in ipairs(ARM_SW_LIST) do
	if sw == ARM_SWITCH then arm_idx = i; break end
    end
    if file then
	io.write(file, string_fmt("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
	    UPDATE_RATE, BATTERY_ALERT_ENABLED and 1 or 0,
	    BATTERY_ALERT_AUDIO and 1 or 0,
	    BATTERY_ALERT_INTERVAL,
	    math_floor(BATTERY_ALERT_STEP * 100),
	    SAG_CURRENT_THRESHOLD,
	    math_floor(TX_BAT_WARN * 10),
	    TOAST_DURATION, BAT_CAPACITY_MAH, MIN_SATS,
	    HAPTIC and 1 or 0, AUTO_TAB and 1 or 0, arm_idx,
	    ARM_VALUE))
        io.close(file)
    end
end

-- Handles touch-screen tab navigation for radios that support EVT_TOUCH_FIRST
-- (TX16S, Boxer, etc.). Reads the touch coordinates and switches current_page
-- when the tap falls within the tab bar area. Returns 0 to consume the event.
local function handle_touch_nav()
    if getTouchState then
        local touch = getTouchState()
        if touch and touch.y <= TAB_H then
            local tapped = math_floor(touch.x / TAB_W) + 1
            if tapped <= #TABS then current_page = tapped end
        end
    end
    return 0
end

-- Toggles the config overlay open or closed on EVT_VIRTUAL_MENU_LONG.
-- Refreshes displayed cfg values on open; exits edit mode and auto-saves
-- to SD card on close if any setting was modified during the session.
-- Returns 0 to consume the event.
local function handle_cfg_toggle()
    show_cfg = not show_cfg
    if show_cfg then
        refresh_cfg_vals()
    else
        cfg_edit = false
        sw_listen = false
        sw_pending = ""
	cfg_edit_snapshot = nil
        if cfg_changed then
            save_config()
            cfg_changed = false
        end
    end
    return 0
end

-- Commits the current arm-switch capture session and clears the listen state.
-- If a switch was identified during the scan (sw_pending ~= ""), stores it as
-- ARM_SWITCH / ARM_VALUE and marks the config dirty. Always clears sw_listen
-- and sw_pending regardless of whether a switch was captured, so the UI
-- returns to normal edit mode. Callers are responsible for calling
-- refresh_cfg_vals() afterwards to reflect the updated ARM_SWITCH value.
local function confirm_sw_listen()
    if sw_pending ~= "" then
        ARM_SWITCH  = sw_pending
        ARM_VALUE   = sw_pending_val
        cfg_changed = true
    end
    sw_listen  = false
    sw_pending = ""
end

-- Handles all keyboard and rotary events while the config overlay is visible.
-- Covers: EXIT to close or cancel an active sw-listen session, rotary navigation
-- between items, ENTER to enter or exit edit mode, value adjustment for each
-- config item, and cfg_scroll synchronisation with the selected item.
-- Returns 0 to consume every event routed through it.
local function handle_cfg_events(event)
    if event == EVT_EXIT_BREAK and not cfg_edit then
        show_cfg = false
        if cfg_changed then save_config(); cfg_changed = false end
        return 0
    end

    if not cfg_edit then
        if event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST then
            cfg_sel = cycle(cfg_sel, #cfg_items, 1)
        elseif event == EVT_ROT_LEFT or event == EVT_MINUS_FIRST then
            cfg_sel = cycle(cfg_sel, #cfg_items, -1)
        elseif event == EVT_ENTER_BREAK then
            if cfg_sel == 13 then
                if sw_listen then
                    confirm_sw_listen()
                    refresh_cfg_vals()
                else
                    for _, sw in ipairs(ARM_SW_LIST) do
                        sw_snapshot[sw] = getValue(sw) or 0
                    end
                    sw_pending = ""
                    sw_listen = true
                    cfg_edit = true
                    refresh_cfg_vals()
                end
            else
                if     cfg_sel == 1  then cfg_edit_snapshot = UPDATE_RATE
                elseif cfg_sel == 2  then cfg_edit_snapshot = BATTERY_ALERT_ENABLED
                elseif cfg_sel == 3  then cfg_edit_snapshot = BATTERY_ALERT_AUDIO
                elseif cfg_sel == 4  then cfg_edit_snapshot = BATTERY_ALERT_INTERVAL
                elseif cfg_sel == 5  then cfg_edit_snapshot = BATTERY_ALERT_STEP
                elseif cfg_sel == 6  then cfg_edit_snapshot = SAG_CURRENT_THRESHOLD
                elseif cfg_sel == 7  then cfg_edit_snapshot = TX_BAT_WARN
                elseif cfg_sel == 8  then cfg_edit_snapshot = TOAST_DURATION
                elseif cfg_sel == 9  then cfg_edit_snapshot = BAT_CAPACITY_MAH
                elseif cfg_sel == 10 then cfg_edit_snapshot = MIN_SATS
                elseif cfg_sel == 11 then cfg_edit_snapshot = HAPTIC
                elseif cfg_sel == 12 then cfg_edit_snapshot = AUTO_TAB
                end
                cfg_edit = true
            end
        end
    else
        -- In edit mode
        if event == EVT_ENTER_BREAK then
            if cfg_sel == 13 and sw_listen then
                confirm_sw_listen()
                refresh_cfg_vals()
            end
            cfg_edit_snapshot = nil
            cfg_edit = false
        elseif event == EVT_EXIT_BREAK then
            if cfg_sel == 13 and sw_listen then
                sw_listen = false
                sw_pending = ""
                refresh_cfg_vals()
            elseif cfg_edit_snapshot ~= nil then
                cfg_set_var(cfg_sel, cfg_edit_snapshot)   -- restore original value
                cfg_edit_snapshot = nil
                refresh_cfg_vals()
            end
            cfg_edit = false
        elseif event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST or
               event == EVT_ROT_LEFT  or event == EVT_MINUS_FIRST then
            if cfg_sel ~= 13 then
                local dir = (event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST) and 1 or -1
                local nv
                if     cfg_sel == 1  then nv = math_max(10,   math_min(500,   UPDATE_RATE            + 10    * dir))
                elseif cfg_sel == 2  then nv = not BATTERY_ALERT_ENABLED
                elseif cfg_sel == 3  then nv = not BATTERY_ALERT_AUDIO
                elseif cfg_sel == 4  then nv = math_max(0,    math_min(10000, BATTERY_ALERT_INTERVAL + 100   * dir))
                elseif cfg_sel == 5  then nv = math_max(0.05, math_min(1.0,   BATTERY_ALERT_STEP     + 0.05  * dir))
                elseif cfg_sel == 6  then nv = math_max(5,    math_min(100,   SAG_CURRENT_THRESHOLD  + 5     * dir))
                elseif cfg_sel == 7  then nv = TX_BAT_WARN > 0 and 0 or bat_warn_default
                elseif cfg_sel == 8  then nv = math_max(50,   math_min(500,   TOAST_DURATION         + 50    * dir))
                elseif cfg_sel == 9  then nv = math_max(100,  math_min(20000, BAT_CAPACITY_MAH       + 100   * dir))
                elseif cfg_sel == 10 then nv = math_max(3,    math_min(8,     MIN_SATS               + dir))
                elseif cfg_sel == 11 then nv = not HAPTIC
                elseif cfg_sel == 12 then nv = not AUTO_TAB
                end
                if nv ~= nil then
            	    cfg_set_var(cfg_sel, nv)
            	    cfg_changed = true
            	end
                refresh_cfg_vals()
            end
        end
    end

    if cfg_sel > cfg_scroll + LAYOUT.cfg_visible then
        cfg_scroll = cfg_sel - LAYOUT.cfg_visible
    elseif cfg_sel <= cfg_scroll then
        cfg_scroll = cfg_sel - 1
    end

    return 0
end

-- Handles EVT_ENTER_BREAK on the four main pages (outside the config overlay).
-- BAT: cycles through battery chemistry types and updates threshold strings.
-- GPS: triggers a screenshot if a GPS fix and QR code are available.
-- TOT: resets all flight statistics to their default values.
-- LOC: toggles the locator active state; clears signal cache on deactivation.
local function handle_page_enter()
    if current_page == 1 then
        bat_state.cfg_idx = (bat_state.cfg_idx % #BAT_CONFIG) + 1
        local bcfg = BAT_CONFIG[bat_state.cfg_idx]
        bat_state.threshold     = bcfg.volt
        bat_state.lbl_vmin      = string_fmt("%.2fV", bcfg.v_min)
        bat_state.lbl_vmax      = string_fmt("%.2fV", bcfg.v_max)
        bat_state.chem_cell_str = string_fmt("%s [%s]", bcfg.text,
            bat_state.cells > 0 and bat_state.cell_s or "-S")
        show_toast(string_fmt("** %s (%.1fV) **", bcfg.text, bat_state.threshold))
	bat_state.last_volt = bat_state.rx_bt + 2.0
	bat_state.last_cells = -1
    elseif current_page == 2 then
        if gps_state.fix then
            if type(screenshot) == "function" then screenshot() end
            show_toast(toast_shot)
        end
    elseif current_page == 3 then
        reset_stats()
        show_toast(toast_resetted)
    elseif current_page == 4 then
        loc_active = not loc_active
        if not loc_active then
            loc_next_play = 0
            loc_sig       = nil
            loc_peak_pct  = 0
        end
    end
end

-- ------------------------------------------------------------
-- 13. MAIN (RUN) & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Normalises a raw LOC sensor reading to a 0–100% signal strength value.
-- Returns 0 immediately when sig is nil (no sensor read).
-- Two scaling modes depending on loc_is_elrs:
--   · ELRS (1RSS/2RSS): segmented dBm mapping using LOC_SEG_NEAR (-15 dBm)
--     and LOC_SEG_FAR (-70 dBm) as boundaries. Values at or above
--     LOC_SEG_NEAR return 100; at or below LOC_SEG_FAR return 10 (never 0,
--     to distinguish a weak-but-present signal from no signal at all).
--     Values in between are linearly interpolated into the 10–100 range.
--   · RSSI: direct 0–100 passthrough clamped to [0, 100].
-- Output drives bar fill, beep rate, haptic intensity and the peak marker
-- in draw_loc_page() and update_loc_sensor().
local function loc_normalise(sig)
    if not sig then return 0 end
    if loc_is_elrs then
        -- dBm → 0–100, using LOC_SEG_NEAR/LOC_SEG_FAR
        if     sig >= LOC_SEG_NEAR then return 100
        elseif sig <= LOC_SEG_FAR  then return 10
        else
            return math_floor((sig - LOC_SEG_FAR) * 90 / (LOC_SEG_NEAR - LOC_SEG_FAR) + 10)
        end
    else
        -- RSSI 0–100 direct
        return math_max(0, math_min(100, sig))
    end
end

-- Returns the raw signal value from the active LOC sensor, or nil if
-- unavailable. Reads the sensor name resolved by detect_sensors() (sensors.loc),
-- which is one of: 1RSS or 2RSS (ELRS, value in dBm, negative) or RSSI
-- (value 0–100). Returns nil when the sensor is not present (sensors.loc == nil)
-- or when the reading is exactly 0, treating zero as the no-signal sentinel
-- rather than a valid measurement. Callers must check for nil before
-- passing the result to loc_normalise().
local function loc_get_signal()
    if not sensors.loc then return nil end
    local v = getValue(sensors.loc)
    return v ~= 0 and v or nil
end

-- Fires a two-tier battery low-voltage alert when cell voltage drops below
-- the configured threshold. Tier 1 enforces a minimum time gap between alerts
-- (BATTERY_ALERT_INTERVAL). Tier 2 requires a minimum additional voltage drop
-- (BATTERY_ALERT_STEP) since the last alert. Both tiers must be satisfied
-- simultaneously to prevent alert spam during voltage sag under load.
-- All alerts are suppressed when current draw exceeds SAG_CURRENT_THRESHOLD.
local function update_battery_alert(current_time)
    if not BATTERY_ALERT_ENABLED or bat_state.cells == 0
        or bat_state.curr > SAG_CURRENT_THRESHOLD then return end

    if bat_state.cell_voltage < bat_state.threshold then
        if bat_state.alert_volt == 0 or
            (current_time - bat_state.alert_time >= BATTERY_ALERT_INTERVAL and
             bat_state.alert_volt - bat_state.cell_voltage >= BATTERY_ALERT_STEP) then
            if BATTERY_ALERT_AUDIO then playNumber(math_floor(bat_state.cell_voltage * 10), 0, PREC1) end
            if HAPTIC and playHaptic then playHaptic(15, 0, 1) end
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

-- Continuously monitors all ARM_SW_LIST switches during Phase 1 (scan) or
-- the selected switch during Phase 2 (track) of the arm-switch capture process.
-- Phase 1 detects the first switch that moves from the snapshot baseline and
-- promotes it to sw_pending. Phase 2 tracks live value changes and updates
-- the display via refresh_cfg_vals(). Called from run() every frame while
-- sw_listen is true.
local function track_sw_listen()
    if sw_pending ~= "" then
        -- Phase 2: switch already identified → track its current value (allows mid position)
        local v = getValue(sw_pending) or 0
        if v ~= sw_pending_val then
            sw_pending_val = v
            refresh_cfg_vals()
            force_redraw = true
        end
    else
        -- Phase 1: detect which switch moved from the snapshot
        local changed_sw, changed_val
        for _, sw in ipairs(ARM_SW_LIST) do
            local v = getValue(sw) or 0
            if v ~= sw_snapshot[sw] then
                changed_sw, changed_val = sw, v
                break
            end
        end
        if changed_sw then
            sw_pending     = changed_sw
            sw_pending_val = changed_val
            refresh_cfg_vals()
            force_redraw = true
        end
    end
end

-- Reads and caches the LOC signal and TX power every run() frame while the
-- locator is active. Normalises the raw value to 0–100%, updates the peak
-- hold percentage, and triggers a forced redraw only when signal or TX power
-- changes. Fires a proximity beep tone (and haptic if enabled) at a rate that
-- shrinks linearly from LOC_BEEP_MAX_CS (weak) to LOC_BEEP_MIN_CS (strong).
local function update_loc_sensor(current_time)
    local s        = loc_get_signal()
    local tpwr_raw = sensors.tpwr and getValue(sensors.tpwr) or nil

    loc_sig_pct = loc_normalise(s)
    if s and loc_sig_pct > loc_peak_pct then
        loc_peak_pct = loc_sig_pct
    end

    if s ~= loc_sig or tpwr_raw ~= loc_tpwr then
        loc_sig  = s
        loc_tpwr = tpwr_raw
        if s then
            loc_sig_fmt = string_fmt("%d dB", s)
            loc_pct_fmt = string_fmt("%d%%", math_floor(loc_sig_pct))
        end
        loc_tpwr_fmt = tpwr_raw and string_fmt("%dmW", tpwr_raw) or "?mW"
        force_redraw = true
    end

    if current_time >= loc_next_play then
        if loc_sig then
            playTone(math_floor(400 + loc_sig_pct * 6), 80, 0, PLAY_NOW)
            if HAPTIC and playHaptic then playHaptic(7, 0, 1) end
        end
        loc_next_play = current_time + math_floor(LOC_BEEP_MAX_CS - LOC_BEEP_RANGE * loc_sig_pct / 100)
    end
end

-- ------------------------------------------------------------

local function run(event)
    if event ~= 0 then
        force_redraw = true

        -- Touch-screen tab navigation (TX16S, Boxer, and other touch-capable radios).
        -- EVT_TOUCH_FIRST is nil on button-only radios, so the outer guard is safe.
	if EVT_TOUCH_FIRST and event == EVT_TOUCH_FIRST and not show_cfg then
            return handle_touch_nav()
	end

        -- Toggle config overlay; auto-save on close if settings were modified
        if event == EVT_VIRTUAL_MENU_LONG then return handle_cfg_toggle() end

        if show_cfg then return handle_cfg_events(event) end

	if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
	    current_page = cycle(current_page, #TABS,  1)
	elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
	    current_page = cycle(current_page, #TABS, -1)
        elseif event == EVT_ENTER_BREAK then
    	    handle_page_enter()
        end
    end

    local current_time = getTime()
    update_battery_alert(current_time)

    -- Auto-tab: falling edge of telemetry_live → jump to GPS (if had fix) or LOC
    if prev_telem_live and not telemetry_live and AUTO_TAB then
	current_page = gps_state.fix and 2 or 4
    end
    prev_telem_live = telemetry_live

    if sw_listen then track_sw_listen() end

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
    if current_page == 4 and loc_active then update_loc_sensor(current_time) end

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

-- ------------------------------------------------------------

return { init = init, background = background, run = run }

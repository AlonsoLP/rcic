-- =========================================================================
-- rcic.lua — RC Info Center
--
-- Version: 4.1
-- Date:    2026-04-28
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
local BATTERY_ALERT_AUDIO    = true   -- play audio tone alongside the visual low-voltage alert
local BATTERY_ALERT_INTERVAL = 2000   -- min time between alerts (cs)
local BATTERY_ALERT_STEP     = 0.1    -- V drop required for re-alert
local SAG_CURRENT_THRESHOLD  = 20     -- amperes; suppress alerts above this draw
local BAT_CAPACITY_MAH       = 1500   -- mAh; set to your typical battery capacity
local TX_BAT_WARN            = 0      -- visual TX low-voltage warning
local USE_IMPERIAL           = false  -- true = feet/mph/miles; false = metres/kmh/km (auto-set from radio General Settings)
local TOAST_DURATION         = 100    -- centiseconds a toast banner stays on screen (100 = 1 s)
local MIN_SATS               = 4      -- minimum satellites required to accept a GPS fix
local HAPTIC                 = false  -- enables vibration pulses on supported radios
local AUTO_TAB               = true   -- auto-switch to GPS/LOC tab on telemetry loss
local ARM_SWITCH             = ""     -- arm switch name ("" = disabled)
local ARM_VALUE              = 0      -- exact switch value captured during arm-listen
local GPX_LOG_ENABLED        = false  -- enables GPS logs in /LOGS/rcicXXXX.gpx file

-- enable/disable each dashboard tab
local TAB_BAT_EN, TAB_GPS_EN, TAB_TOT_EN, TAB_LOC_EN = true, true, true, true
local TAB_PWR_EN, TAB_LNK_EN, TAB_RAD_EN = true, true, true

local LNK_LQ_WARN            = 70     -- % below which the LQ value blinks INVERS

-- ------------------------------------------------------------
-- 2. CONSTANTS AND INTERNAL CONFIGURATION
-- ------------------------------------------------------------

local CENTISECS_PER_SEC = 100         -- conversion factor; used when dividing UPDATE_RATE into seconds for vario delta
local GPS_MAX_JUMP      = 5000        -- metres; filters impossible GPS teleport jumps

local LOC_BEEP_MAX_CS   = 200         -- slowest beep interval (cs); plays when signal is at 0%
local LOC_BEEP_RANGE    = 180         -- span between fastest (20 cs) and slowest (200 cs) beep interval

-- LOC signal segmentation boundaries (dBm, negative).
-- ELRS reports antenna RSSI in dBm; typical range is -15 (strong) to -115 (lost).
-- LOC_SEG_NEAR: at or above this value the bar reads 100%.
-- LOC_SEG_FAR : at or below this value the bar is clamped to 10% (never 0%,
--               to distinguish "weak signal" from "no signal").
local LOC_SEG_NEAR           = -15         -- & up: 100%
local LOC_SEG_FAR            = -70         -- & below: 10%
local LOC_SEG_RANGE          = LOC_SEG_NEAR - LOC_SEG_FAR
local BATTERY_STABILIZE_TIME = 300         -- (3s) suppress alerts after a >1V jump (battery connect/swap)

-- Flattened battery config to eliminate nested table RAM overhead
local BAT_CFG_TEXT = { "LiPo", "LiHV", "LiIon" }
local BAT_CFG_VOLT = { 3.5, 3.6, 3.2 }
local BAT_CFG_VMAX = { 4.2, 4.35, 4.2 }
local BAT_CFG_VMIN = { 3.2, 3.2, 2.8 }
local BAT_CFG_VRNG = { 1.0, 1.15, 1.4 }

local ARM_SW_LIST = {"SA","SB","SC","SD","SE","SF","SG","SH"}

local FM_AREA_W   = 26                -- pixel width reserved on the right side of the tab bar for the flight-mode indicator

-- Equirectangular distance approximation; accurate to ~0.5% for distances < 100 km.
local RAD     = math.pi / 180
local R_EARTH = 6371000  -- metres
local LAT_DIVISORS = { 800000, 40000, 2000, 100, 5 }
local LON_DIVISORS = { 640000, 32000, 1600, 80, 4 }
local ALPHABET     = "23456789CFGHJMPQRVWX"

-- Flattened QR base matrices (String parsed to save AST memory)
local QR_BASE_V, QR_BASE_M, QR_GEN = {}, {}, {}
for v in string.gmatch("1fc007f,1040041,174015d,174005d,174005d,1040041,1fd557f,100,4601f7,0,40,0,40,0,40,0,1f0040,110100,15017f,110141,1f015d,5d,15d,141,17f", "%x+") do QR_BASE_V[#QR_BASE_V+1]=tonumber(v,16) end
for v in string.gmatch("1fe01ff,1fe01ff,1fe01ff,1fe01ff,1fe01ff,1fe01ff,1ffffff,1fe01ff,1fe01ff,40,40,40,40,40,40,40,1f0040,1f01ff,1f01ff,1f01ff,1f01ff,1ff,1ff,1ff,1ff", "%x+") do QR_BASE_M[#QR_BASE_M+1]=tonumber(v,16) end
for v in string.gmatch("59,13,104,189,68,209,30,8,163,65,41,229,98,50,36,59", "%d+") do QR_GEN[#QR_GEN+1]=tonumber(v) end

local CFG_FILE = "/SCRIPTS/TELEMETRY/rcic.cfg" -- shared CSV config file; read by init() and written by rcic_cfg.lua

-- ------------------------------------------------------------
-- 3. EXTERNAL CONSTANTS/FUNCTION LOCALIZATION
-- ------------------------------------------------------------

-- Standard Lua
local math_floor         = math.floor
local math_max           = math.max
local math_min           = math.min
local math_cos           = math.cos
local math_sin           = math.sin
local math_atan          = math.atan
local math_sqrt          = math.sqrt
local string_fmt         = string.format
local string_sub         = string.sub
local string_byte        = string.byte

-- EdgeTX API
local lcd_drawText       = lcd.drawText
local lcd_drawRect       = lcd.drawRectangle
local lcd_drawFilledRect = lcd.drawFilledRectangle
local lcd_clear          = lcd.clear
local getTime            = getTime
local getValue           = getValue
local playNumber         = playNumber
local playTone           = playTone
local playHaptic         = playHaptic
local EVT_TOUCH_FIRST    = EVT_TOUCH_FIRST   -- nil on non-touch radios
local ERASE_FLAG         = ERASE or 0  -- ERASE may be nil on monochrome radios; 0 = safe no-op fallback

-- ------------------------------------------------------------
-- 4. ENVIRONMENT AND LAYOUT VARIABLES
-- ------------------------------------------------------------

-- Screen geometry — set once in detect_screen(); used throughout all draw functions
local SCREEN_W, SCREEN_H, SCREEN_CENTER_X

-- Font aliases selected by detect_screen() based on screen width:
--   SCREEN_W < 300 px → FONT_COORDS = MIDSIZE, FONT_INFO = SMLSIZE
--   SCREEN_W ≥ 300 px → FONT_COORDS = DBLSIZE,  FONT_INFO = MIDSIZE
local FONT_COORDS, FONT_INFO

-- Tab bar and content area geometry — set once in compute_layout()
local TAB_H      -- tab bar height in pixels (9 px)
local CONTENT_Y  -- first pixel row below the tab bar (TAB_H + 1)
local CONTENT_H  -- usable content height in pixels (SCREEN_H - CONTENT_Y)

-- Flat table of all pre-computed pixel positions for every page; built once
-- in compute_layout() to avoid repeated arithmetic inside draw functions
local LAYOUT

-- Ordered list of active tab names (e.g. {"BAT","GPS","TOT"})
local TABS = {}

-- Parallel arrays indexed by visible slot position (1..VISIBLE_TABS):
--   TAB_NAME[i] — display string ("BAT", "GPS", …)
--   TAB_X[i]   — left edge pixel of slot i
--   TAB_CX[i]  — horizontal centre pixel of slot i (for centred text)
local TAB_NAME, TAB_X, TAB_CX = {}, {}, {}

local TAB_W      = 0  -- uniform slot width in pixels; last slot extends to SCREEN_W - FM_AREA_W
local TABS_LEN   = 0  -- total number of enabled tabs (length of TABS[])
local VISIBLE_TABS = 4  -- number of tab slots shown on screen simultaneously; capped at TABS_LEN

-- First tab index shown in the left-most slot; incremented when current_page
-- scrolls past the right edge of the visible window
local tab_scroll = 1

-- Unit and scale factor pairs; derived from USE_IMPERIAL in init()
local alt_unit   = "m"    -- display unit string for altitude ("m" or "ft")
local alt_factor = 1.0    -- multiplier applied to raw metre values before display
local spd_unit   = "kmh"  -- display unit string for speed ("kmh" or "mph")
local spd_factor = 1.0    -- multiplier applied to raw m/s values before display

local qr_scale   = 1      -- pixels per QR module

-- fallback TX warning threshold when getGeneralSettings() provides no battWarn value
local bat_warn_default = 6.6

-- ------------------------------------------------------------
-- 5. TELEMETRY ENGINE STATUS VARIABLES (Background)
-- ------------------------------------------------------------

-- Timestamp (cs) of the last background() data update; compared against
-- UPDATE_RATE to enforce the configured refresh interval
local last_update_time = 0

-- true when the link-quality sensor reports a non-zero value this cycle;
-- drives telemetry-loss detection and AUTO_TAB switching in run()
local telemetry_live = false

-- Sensor name cache populated by detect_sensors(); keys map to the first
-- responding sensor name found during probing (e.g. sensors.gps = "GPS")
local sensors = {}

-- true when the capacity sensor is "Fuel" (percentage source instead of mAh);
-- changes how mahdrain is formatted in update_tot_strings() and pwr_strs[4]
local capa_is_pct = false

-- true when the sensor resolved to an ELRS antenna (1RSS or 2RSS);
-- selects dBm-based scaling in loc_normalise() instead of 0–100 passthrough
local link_is_elrs = false

local gps_state = {
    lat = 0, lon = 0, alt = 0,
    fix = false,
    had_fix = false,   -- latched true once a valid fix is acquired; never resets (distinguishes "waiting" from "lost")
    lat_str = "0.000000", lon_str = "0.000000",
    plus_code = "---",
    sats = 0, vspd = 0, prev_alt = 0, hdop = 0, hdop_str = "HDOP:--"
}

local bat_state = {
    cells        = 0,   -- detected cell count (0 = unknown; re-detected on >1 V pack voltage change)
    identified   = false,   -- true once cell count has been reliably detected; prevents false
    last_volt    = 0,   -- pack voltage from the previous cycle; used to detect >1 V jumps for cell re-detection
    connect_time = 0,   -- getTime() cs of last >1V jump; alerts suppressed during stabilization
    alert_time   = 0,   -- getTime() timestamp of the last low-voltage alert (cs)
    alert_volt   = 0,   -- cell voltage at the time of the last alert; drives BATTERY_ALERT_STEP comparison
    cfg_idx      = 1,   -- active battery chemistry index into BAT_CFG_* arrays (1=LiPo, 2=LiHV, 3=LiIon)
    threshold    = BAT_CFG_VOLT[1], -- per-cell low-voltage alert trigger (V); set from BAT_CFG_VOLT[cfg_idx]
    lbl_vmin     = string_fmt("%.2fV", BAT_CFG_VMIN[1]), -- pre-formatted minimum voltage label for BAT page
    lbl_vmax     = string_fmt("%.2fV", BAT_CFG_VMAX[1]), -- pre-formatted maximum voltage label for BAT page
    rx_bt        = 0,   -- raw pack voltage from RxBt/VFAS/A1 sensor (V)
    cell_voltage = 0,   -- per-cell voltage = rx_bt / cells (0 when cells == 0)
    curr         = 0,   -- current draw from Curr sensor (A)
    -- Cached strings for drawing (rebuilt only when values change)
    rx_fmt       = "0.00V", -- formatted pack voltage  ("16.80V")
    cell_fmt     = "0.00V", -- formatted cell voltage  ("4.20V")
    pct_val      = 0,       -- battery state-of-charge 0.0–1.0 (linear between VMIN and VMAX)
    cell_s       = "0S",    -- formatted cell count    ("4S")
    pct_str      = "0%",    -- formatted state-of-charge percentage ("84%")
    -- TX battery
    bat_tx       = 0,    -- TX battery voltage from "tx-voltage" sensor (V)
    bat_tx_fmt   = "--V", -- formatted TX voltage; "--V" until first valid reading
    chem_cell_str = "",   -- combined chemistry + cell-count label, e.g. "LiPo [4S]" or "LiPo [-S]"
    -- Change-detection sentinels (initialised to -1 so the first real value always triggers a string rebuild)
    last_cells   = -1,
    last_rx_bt   = -1,
    last_bat_tx  = 0
}

local pwr_state = {
    watts   = 0,  -- last integer watt value; gate for pwr_strs[1..3] rebuild
    eff     = 0,  -- last integer efficiency value (mAh/km or %/km); gate for pwr_strs[4..6] rebuild
    mins    = 0   -- last estimated flight-time remaining in minutes; gate for pwr_strs[7] rebuild
}

local lnk_state = {
    lq_pct  = 0,    -- normalised 0–100 for draw_fill_bar (= lq clamped 0..100)
    -- Change-detection sentinels (-1 / -999 so first real value always rebuilds)
    last_lq   = -1, last_tqly = -1,
    last_rss1 = -999, last_rss2 = -999,
    last_rsnr = -999, last_rfmd = -1, last_tpwr = -1
}

-- Home position locked on first valid GPS fix; used by the RAD tab.
local home_state = {
    lat = nil,   -- home latitude  (nil until locked)
    lon = nil,   -- home longitude (nil until locked)
    set = false  -- true once home is locked
}

-- Live flight statistics; populated by background(), reset by reset_stats()
local stats = {
  max_alt=0, total_dist=0, min_voltage=0, max_speed=0, max_current=0,
  max_sats=0, mahdrain=0, flight_time=0, min_lq=999,
  last_min_v=-1, last_max_a=-1, last_max_alt=-1, last_dist=-1,
  last_max_spd=-1, last_sats=-1, last_mah=-1, last_flt_s=-1, last_min_lq=-1
}

local fm_str      = nil    -- raw flight-mode string from FM/FMod sensor; nil when telemetry is lost
local fm_armed    = false  -- true when fm_str is not nil and not in FM_DISARMED{}
local armed_display = false  -- true when the craft should be considered armed for display, timer and GPX purposes
local bg_prev_telem = false  -- previous-cycle telemetry_live; edge-detects link loss to trigger sensor cache reset

-- ------------------------------------------------------------
-- 6. INTERFACE STATE AND EVENTS VARIABLES (run)
-- ------------------------------------------------------------

local current_page    = 1      -- 1-based index into TABS[]; the currently displayed tab
local last_page       = 1      -- page index from the previous run() call; detects tab switches for immediate string refresh
local force_redraw    = true   -- when true, run() clears and redraws the screen this frame; cleared after draw
local last_blink_state = false -- tracks the last 1 Hz blink phase to trigger a redraw on state change

local last_run_time    = 0     -- Tracks interface wake-up after being paused

local loc_active       = false -- true while the LOC locator mode is running (toggled by ENTER on LOC tab)
local loc_next_play    = 0     -- getTime() timestamp (cs) when the next proximity beep may fire
local loc_sig          = nil   -- last raw signal value (dBm for ELRS, 0-100 for RSSI). nil = no sensor read.
local loc_tpwr         = nil   -- TX power in mW from TPWR sensor; nil if sensor absent.
local loc_sig_pct      = 0     -- normalised 0-100 value driving bar fill, beep rate and haptic.
local loc_peak_pct     = 0     -- normalised peak 0-100, drives bar marker

-- Toast notification geometry
local toast_msg        = nil   -- string currently displayed; nil = no active toast
local toast_time       = 0     -- getTime() (cs) when the current toast was triggered; used for auto-dismiss
local toast_x          = 0     -- pre-computed left edge pixel of the toast banner
local toast_y          = 0     -- vertical centre pixel; set once in compute_layout()
local toast_w          = 0     -- banner width in pixels; recalculated in show_toast() per message length
local toast_h          = 0    -- banner height in pixels (font height + 2 px padding)

local gpx_file_current = nil   -- absolute path of the GPX file currently being written; nil when not recording
local gpx_is_recording = false -- true between arm-start and arm-stop while GPX_LOG_ENABLED is active

-- Previous-cycle value of telemetry_live; used by run() to detect the falling
-- edge of link loss that triggers AUTO_TAB switching
local prev_telem_live = false

-- ------------------------------------------------------------
-- 7. RENDERING BUFFERS & GC CACHE VARIABLES
-- ------------------------------------------------------------

-- 10-slot pre-formatted string cache for the TOT page, rebuilt by update_tot_strings()
-- only when underlying stat values change. Index map:
--   [1] MIN V   [2] MAX AMP  [3] MAX ALT  [4] DIST    [5] MAX SPD
--   [6] MAX SATS [7] DRAIN  [8] FLT TIME [9] MIN LQ  [10] EFF
local tot_strs = { "", "", "", "", "", "", "", "", "", "" }

-- Shared GPS string cache rebuilt in background(); used by both draw_gps_page()
-- and the waiting-for-fix screen
local gps_str_info = ""   -- "ALT:42m +1.2" — altitude + vertical speed
local gps_sats_str = ""   -- "SAT:9"
local last_sats    = -1   -- sentinel for change-detection; forces gps_sats_str rebuild on first read

local qr_e, qr_l = nil, nil  -- GF(256) exp/log tables, built once in init()
local qr_b       = {}        -- 12 integers * 32 bits = 384 bits
local qr_m       = {}        -- 28 data codewords as integers
local qr_ec      = {}        -- 16 Reed-Solomon error correction codewords
local qr_bi      = 0         -- Global bit index for QR generation

local str_minus_minus_V = "--V"  -- placeholder shown when cell count is unknown

local loc_sig_fmt  = ""      -- "%d dBm"
local loc_tpwr_fmt = "?mW"   -- "%dmW" or "?mW"
local loc_pct_fmt  = "0%"    -- "%d%%"

-- 8-slot pre-formatted string cache for the PWR page, rebuilt by update_pwr_strings().
-- Index map:
--   [1] pack voltage  ("16.8V")    [2] current       ("12.3A")
--   [3] watts         ("207W")     [4] mAh consumed  ("450mAh") or % consumed
--   [5] distance      ("1.23km")   [6] efficiency    ("365")
--   [7] est. time     ("EST: 8m")  [8] efficiency unit ("mAh/km", "%/mi", …)
local pwr_strs = { "0.0V", "0.0A", "0W", "0mAh", "0m", "0", "EST: --m", "mAh/km" }

-- 6-slot pre-formatted string cache for the LNK page, rebuilt by update_lnk_strings().
-- Index map:
--   [1] LQ value    ("98%")
--   [2] TQly        ("TQly:97%"  or "" when sensor absent)
--   [3] RSS pair    ("1:-42  2:-45"  or "" on non-ELRS)
--   [4] SNR         ("SNR:9dB"   or "" when sensor absent)
--   [5] RFMD        ("250Hz"     or "" when sensor absent)
--   [6] TX power    ("100mW"     or "?mW")
local lnk_strs = { "0%", "", "", "", "", "TXP:---" }

local rad_state = { dist = -1, alt = -999, vspd = -999, bear_rad = 0 }
local rad_strs  = { "---", "---", "---" }

-- ------------------------------------------------------------
-- 8. UTILITY FUNCTIONS
-- ------------------------------------------------------------

-- Wraps a 1-based index cyclically within [1..n], stepping by dir (+1 or -1).
-- Handles both forward and backward wrapping: stepping past n returns 1,
-- stepping before 1 returns n. Used for tab navigation in run() and for
-- scrolling through cfg_items[] in handle_cfg_events().
-- Example: cycle(4, 4, 1) → 1,  cycle(1, 4, -1) → 4
local function cycle(val, n, dir) return (val - 1 + dir + n) % n + 1 end

-- ------------------------------------------------------------
-- 9. INIT & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Resets all flight statistics to their zero/default values.
-- min_lq resets to 999 so the first real reading always becomes the new minimum.
-- Called once at startup and whenever the user triggers a manual reset.
local function reset_stats()
    stats.max_alt = 0; stats.total_dist = 0; stats.min_voltage = 0
    stats.max_speed = 0; stats.max_current = 0; stats.max_sats = 0
    stats.mahdrain = 0; stats.flight_time = 0; stats.min_lq = 999
    -- Reset sentinels so update_tot_strings() rebuilds after manual reset
    stats.last_min_v   = -1;  stats.last_max_a   = -1
    stats.last_max_alt = -1;  stats.last_dist    = -1
    stats.last_max_spd = -1;  stats.last_sats    = -1
    stats.last_mah     = -1;  stats.last_flt_s   = -1
    stats.last_min_lq  = -1
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
            qr_l[x] = i
            x = x * 2
            if x > 255 then x = x ~ 285 end
        end
        qr_e[255] = qr_e[0]
    end
end

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

-- Rebuilds the ordered TABS[] array from the current TAB_*_EN flags and
-- recomputes all tab bar geometry. current_page is clamped to the new TABS_LEN.
-- Called during startup and whenever config changes.
local function rebuild_tabs()
    TABS = {}
    if TAB_BAT_EN then TABS[#TABS + 1] = "BAT" end
    if TAB_GPS_EN then TABS[#TABS + 1] = "GPS" end
    if TAB_TOT_EN then TABS[#TABS + 1] = "TOT" end
    if TAB_LOC_EN then TABS[#TABS + 1] = "LOC" end
    if TAB_LNK_EN then TABS[#TABS + 1] = "LNK" end
    if TAB_PWR_EN then TABS[#TABS + 1] = "PWR" end
    if TAB_RAD_EN then TABS[#TABS + 1] = "RAD" end
    
    TABS_LEN = #TABS

    if current_page > TABS_LEN then current_page = math_max(1, TABS_LEN) end

    VISIBLE_TABS = math_min(TABS_LEN, (SCREEN_W >= 300) and 8 or 4)
    if VISIBLE_TABS > 0 then
        TAB_W = math_floor((SCREEN_W - FM_AREA_W) / VISIBLE_TABS)
        for i = 1, VISIBLE_TABS do
            local x = (i - 1) * TAB_W
            TAB_X[i]  = x
            TAB_CX[i] = x + math_floor(((i == VISIBLE_TABS) and (SCREEN_W - FM_AREA_W - x) or TAB_W) / 2)
        end
    end
    for i = 1, TABS_LEN do TAB_NAME[i] = TABS[i] end
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

    local _loc_h = math_floor(CONTENT_H * 0.40)
    local _loc_y = SCREEN_H - _loc_h - 1
    local _loc_sig_y = CONTENT_Y + math_floor((_loc_y - CONTENT_Y) * 0.25)

    -- Dynamic PWR anchors: pixel-perfect for B/W, proportional for color screens
    local _pwr1 = (SCREEN_H <= 64) and 17 or math_floor(CONTENT_H * 0.35)
    local _pwr2 = (SCREEN_H <= 64) and 26 or math_floor(CONTENT_H * 0.55)
    local _pwr3 = (SCREEN_H <= 64) and 35 or math_floor(CONTENT_H * 0.75)

    LAYOUT = {
        coord_lat_y = CONTENT_Y + math_floor(CONTENT_H * 0.09),
        coord_lon_y = CONTENT_Y + math_floor(CONTENT_H * 0.37),
        info_y      = CONTENT_Y + math_floor(CONTENT_H * 0.65),
        url_y       = CONTENT_Y + math_floor(CONTENT_H * 0.84),
        waiting_y   = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        sats_y      = CONTENT_Y + math_floor(CONTENT_H * 0.70),

        bat_label_y = CONTENT_Y + math_floor(CONTENT_H * 0.038),
        bat_cell_y  = CONTENT_Y + math_floor(CONTENT_H * 0.25),
        bat_pct_y   = CONTENT_Y + math_floor(CONTENT_H * 0.65),
        bat_bar_y   = CONTENT_Y + math_floor(CONTENT_H * 0.815),
        bar_x       = 2,
        bar_w       = SCREEN_W - 4,

	pwr_y0      = CONTENT_Y,
        pwr_y1      = CONTENT_Y + _pwr1,
        pwr_y2      = CONTENT_Y + _pwr2,
        pwr_y3      = CONTENT_Y + _pwr3,

        tot_line1_y = CONTENT_Y + math_floor(CONTENT_H * 0.03),
        tot_line2_y = CONTENT_Y + math_floor(CONTENT_H * 0.22),
        tot_line3_y = CONTENT_Y + math_floor(CONTENT_H * 0.40),
        tot_line4_y = CONTENT_Y + math_floor(CONTENT_H * 0.56),
        tot_line5_y = CONTENT_Y + math_floor(CONTENT_H * 0.78),
        gps_lost_h  = SCREEN_H - CONTENT_Y,

        gps_tl_y    = CONTENT_Y + math_floor(CONTENT_H * 0.04),
        qr_x        = 18,
        qr_y        = CONTENT_Y + math_floor(CONTENT_H * 0.22),

	lnk_main_y  = CONTENT_Y + math_floor(CONTENT_H * 0.08),
	lnk_lq_y    = CONTENT_Y + math_floor(CONTENT_H * 0.25),
	lnk_line2_y = CONTENT_Y + math_floor(CONTENT_H * 0.53),
	lnk_line3_y = CONTENT_Y + math_floor(CONTENT_H * 0.70),

        rad_r   = math_floor(CONTENT_H * 0.44),
        rad_cx  = math_floor(CONTENT_H * 0.44) + 2,
        rad_cy  = CONTENT_Y + math_floor(CONTENT_H * 0.50),
        rad_dx  = (math_floor(CONTENT_H * 0.44) + 2) * 2 + 4,
        rad_dy1 = CONTENT_Y + math_floor(CONTENT_H * 0.10),
        rad_dy2 = CONTENT_Y + math_floor(CONTENT_H * 0.45),
        rad_dy3 = CONTENT_Y + math_floor(CONTENT_H * 0.78),

        loc_bar_h   = _loc_h,
        loc_bar_y   = _loc_y,
        loc_bar_x   = 2,
        loc_bar_w   = SCREEN_W - 4,
        loc_sig_y   = _loc_sig_y,
        loc_info_y  = _loc_sig_y + ((SCREEN_W >= 300) and 8 or 4)
    }

    -- Toast geometry scales with screen size
    toast_h = (SCREEN_W >= 300) and 20 or 11
    toast_y = math_floor(SCREEN_H / 2) - math_floor(toast_h / 2)

    rebuild_tabs()
end

-- ------------------------------------------------------------

-- Initializes the script environment. Resets statistics, prepares the GF(256) 
-- tables for QR generation, detects screen capabilities, loads saved user 
-- configurations from the SD card, and pre-computes the UI layout coordinates.
local function init()
    reset_stats()

    local gs = getGeneralSettings() or {}
    TX_BAT_WARN       = gs.battWarn or bat_warn_default
    
    if gs.imperial ~= nil then USE_IMPERIAL = gs.imperial ~= 0 end
    if USE_IMPERIAL then
        alt_unit   = "ft";  alt_factor  = 3.28084
        spd_unit   = "mph"; spd_factor  = 0.621371
    end

    detect_screen()
    load_config()
    compute_layout()
end

-- ------------------------------------------------------------
-- 10. DATA UPDATE (BACKGROUND) & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Probes all sensor candidates and caches the first responding name.
-- SENSOR_MAP is declared locally so the Garbage Collector destroys it
-- and reclaims its RAM immediately after the first successful link.
local function detect_sensors()
    local smap = "link:RQly,RSSI|rxbt:RxBt,VFAS,A1|capa:Capa,Fuel|sats:Sats|gps:GPS|alt:Alt,GAlt|gspd:GSpd|curr:Curr|vspd:VSpd|loc:1RSS,2RSS,RSSI|fmode:FM,FMod|tpwr:TPWR|tqly:TQly|rss1:1RSS|rss2:2RSS|rsnr:RSNR,RSnr|rfmd:RFMD|hdg:Hdg,Crs"
    for cat, items in string.gmatch(smap, "(%w+):([^|]+)") do
        for name in string.gmatch(items, "[^,]+") do
            if getValue(name) ~= nil then sensors[cat] = name; break end
        end
    end
    capa_is_pct = (sensors.capa == "Fuel")
    link_is_elrs = (sensors.loc == "1RSS" or sensors.loc == "2RSS")
    sensors.done = true

    pwr_strs[8] = (capa_is_pct and USE_IMPERIAL) and "%/mi"
           or (capa_is_pct)                  and "%/km"
           or USE_IMPERIAL                   and "mAh/mi"
           or                                    "mAh/km"
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

-- Packs `c` bits from integer `v` into qr_b[] using bitwise operators
-- to avoid massive table allocations (RAM overhead).
local function qr_pack_bits(v, c)
    for i = c - 1, 0, -1 do
        local bit_val = (v >> i) & 1
        local int_idx = math_floor(qr_bi / 32) + 1
        local bit_pos = qr_bi % 32
        
        if bit_val == 1 then
            qr_b[int_idx] = qr_b[int_idx] | (1 << bit_pos)
        else
            qr_b[int_idx] = qr_b[int_idx] & ~(1 << bit_pos)
        end
        qr_bi = qr_bi + 1
    end
end

-- Records a new track point into the current GPX file.
-- Optimized for low RAM usage by avoiding large string concatenations.
-- Writes directly to the file stream.
local function log_gpx_point(lat, lon, alt)
    if not gpx_file_current then return end
    local file = io.open(gpx_file_current, "a")
    if file then
        local dt = getDateTime()
	io.write(file, string_fmt('  <trkpt lat="%.6f" lon="%.6f">\n', lat, lon))
        io.write(file, string_fmt('    <ele>%.1f</ele>\n', alt))
        io.write(file, string_fmt('    <time>%04d-%02d-%02dT%02d:%02d:%02dZ</time>\n', dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec))
        io.write(file, '  </trkpt>\n')
        io.close(file)
    end
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
            gps_state.lat_str = string_fmt("%.6f", cur_lat)
            gps_state.lon_str = string_fmt("%.6f", cur_lon)
	    gps_state.plus_code = to_plus_code(cur_lat, cur_lon)
            if gpx_is_recording then log_gpx_point(cur_lat, cur_lon, alt) end
        end
    end

    gps_state.lat = cur_lat
    gps_state.lon = cur_lon
    gps_state.alt = alt
    gps_state.fix = true
    gps_state.had_fix = true   -- latch: at least one valid fix has been acquired this session

    if alt  > stats.max_alt   then stats.max_alt   = alt  end
    if gspd > stats.max_speed then stats.max_speed = gspd end
end

-- Pre-formats all battery display strings into bat_state to avoid string
-- allocations inside draw functions. Updates rx_fmt, cell_fmt, bat_tx_fmt,
-- pct_val and pct_str every cycle. Rebuilds cell_s and chem_cell_str only
-- when the detected cell count changes.
local function update_bat_strings()
    local idx = bat_state.cfg_idx

    if bat_state.rx_bt ~= bat_state.last_rx_bt then
        bat_state.last_rx_bt = bat_state.rx_bt
        bat_state.rx_fmt     = string_fmt("%.2fV", bat_state.rx_bt)
        bat_state.cell_fmt   = string_fmt("%.2fV", bat_state.cell_voltage)
        bat_state.pct_val    = bat_state.identified and
            math_max(0, math_min(1, (bat_state.cell_voltage - BAT_CFG_VMIN[idx]) / BAT_CFG_VRNG[idx])) or 0
        bat_state.pct_str = string_fmt("%d%%", math_floor(bat_state.pct_val * 100))
    end

    if bat_state.bat_tx ~= bat_state.last_bat_tx then
        bat_state.last_bat_tx = bat_state.bat_tx
        bat_state.bat_tx_fmt  = string_fmt("%.1fV", bat_state.bat_tx)
    end

    if bat_state.cells ~= bat_state.last_cells then
        bat_state.last_cells    = bat_state.cells
        bat_state.cell_s        = string_fmt("%dS", bat_state.cells)
        bat_state.chem_cell_str = string_fmt("%s [%s]", BAT_CFG_TEXT[idx],
            bat_state.identified and bat_state.cell_s or "-S")
    end
end

-- Pre-formats all LNK page strings into lnk_strs[], rebuilding each slot
-- only when its underlying sensor value changes (lazy evaluation). Normalises
-- lq_pct to 0.0–1.0 every cycle for draw_fill_bar. Gracefully degrades on
-- non-ELRS links by leaving antenna/SNR/RFMD slots as empty strings, which
-- draw_lnk_page() skips entirely when drawing.
local function update_lnk_strings()
    local lq = sensors.link and getValue(sensors.link) or 0
    lnk_state.lq_pct = math_min(100, math_max(0, lq))
    if lq ~= lnk_state.last_lq then
        lnk_state.last_lq = lq
        lnk_strs[1] = string_fmt("%d%%", lq)
    end

    local tq = sensors.tqly and getValue(sensors.tqly) or 0
    if tq ~= lnk_state.last_tqly then
        lnk_state.last_tqly = tq
        lnk_strs[2] = sensors.tqly and string_fmt("TQly:%d%%", tq) or ""
    end

    local r1 = sensors.rss1 and getValue(sensors.rss1) or 0
    local r2 = sensors.rss2 and getValue(sensors.rss2) or 0
    if r1 ~= lnk_state.last_rss1 or r2 ~= lnk_state.last_rss2 then
        lnk_state.last_rss1, lnk_state.last_rss2 = r1, r2
        lnk_strs[3] = link_is_elrs and string_fmt("1:%d  2:%d", r1, r2) or ""
    end

    local snr = sensors.rsnr and getValue(sensors.rsnr) or 0
    if snr ~= lnk_state.last_rsnr then
        lnk_state.last_rsnr = snr
        lnk_strs[4] = sensors.rsnr and string_fmt("SNR:%ddB", snr) or ""
    end

    local rf = sensors.rfmd and getValue(sensors.rfmd) or 0
    if rf ~= lnk_state.last_rfmd then
        lnk_state.last_rfmd = rf
	lnk_strs[5] = sensors.rfmd and string_fmt("RF:%dHz", rf) or ""
    end

    local tp = sensors.tpwr and getValue(sensors.tpwr) or nil
    if tp ~= lnk_state.last_tpwr then
        lnk_state.last_tpwr = tp
        lnk_strs[6] = tp and string_fmt("TXP:%dmW", tp) or "TXP:---"
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

-- Pre-formats flight statistics only when their underlying values change
-- to prevent memory allocation spam (string fragmentation) during drawing.
local function update_tot_strings()
    if stats.min_voltage ~= stats.last_min_v then
        stats.last_min_v = stats.min_voltage
        tot_strs[1] = string_fmt("MIN V:%.2fV", stats.min_voltage)
    end

    if stats.max_current ~= stats.last_max_a then
        stats.last_max_a = stats.max_current
        tot_strs[2] = string_fmt("MAX AMP: %.1fA", stats.max_current)
    end

    if stats.max_alt ~= stats.last_max_alt then
        stats.last_max_alt = stats.max_alt
        tot_strs[3] = string_fmt("MAX ALT: %.0f%s", stats.max_alt * alt_factor, alt_unit)
    end

    if stats.total_dist ~= stats.last_dist then
        stats.last_dist = stats.total_dist
        tot_strs[4] = string_fmt("DIST: %s", format_dist(stats.total_dist))
    end

    if stats.max_speed ~= stats.last_max_spd then
        stats.last_max_spd = stats.max_speed
        tot_strs[5] = string_fmt("MAX SPD: %.1f%s", stats.max_speed * spd_factor, spd_unit)
    end

    if stats.max_sats ~= stats.last_sats then
        stats.last_sats = stats.max_sats
        tot_strs[6] = string_fmt("MAX SATS: %d", stats.max_sats)
    end

    if stats.mahdrain ~= stats.last_mah then
        stats.last_mah = stats.mahdrain
        tot_strs[7] = capa_is_pct and string_fmt("DRAIN: %d%%", stats.mahdrain) or string_fmt("DRAIN: %dmAh", stats.mahdrain)
        
        local _km = stats.total_dist / 1000
        local _eff_val = (_km > 0.5 and stats.mahdrain > 0)
            and (USE_IMPERIAL and (stats.mahdrain / (_km * 1.60934)) or (stats.mahdrain / _km)) or nil
        tot_strs[10] = _eff_val and string_fmt("EFF:%.0f%s", _eff_val, USE_IMPERIAL and "/mi" or "/km") or "EFF:--"
    end

    local flt_s = math_floor(stats.flight_time / 100)
    if flt_s ~= stats.last_flt_s then
        stats.last_flt_s = flt_s
        tot_strs[8] = string_fmt("FLT: %d:%02d", math_floor(flt_s / 60), flt_s % 60)
    end

    if stats.min_lq ~= stats.last_min_lq then
        stats.last_min_lq = stats.min_lq
        tot_strs[9] = stats.min_lq == 999 and "MIN LQ: --" or string_fmt("MIN LQ: %d%%", stats.min_lq)
    end
end

-- Calculates Power, Efficiency, and Estimated Flight Time.
-- Fully decoupled from BAT tab updates to support pure lazy evaluation.
local function update_pwr_strings()
    -- 1. Instantaneous Power (Centered Top)
    local current_watts = bat_state.rx_bt * bat_state.curr
    local w_int = math_floor(current_watts)
    
    if w_int ~= pwr_state.watts then
        pwr_state.watts = w_int
        pwr_strs[1] = string_fmt("%.1fV", bat_state.rx_bt)
        pwr_strs[2] = string_fmt("%.1fA", bat_state.curr)
        pwr_strs[3] = string_fmt("%dW", w_int)
    end

    -- 2. Cumulative Efficiency (Centered Bottom)
    local dist_km = stats.total_dist / 1000
    if USE_IMPERIAL then dist_km = dist_km * 0.621371 end
    
    local current_eff = 0
    if dist_km > 0.05 and stats.mahdrain > 0 then
        current_eff = stats.mahdrain / dist_km
    end
    
    local eff_int = math_floor(current_eff)
    if eff_int ~= pwr_state.eff then
        pwr_state.eff = eff_int
        pwr_strs[4] = capa_is_pct and string_fmt("%d%%", stats.mahdrain) or string_fmt("%dmAh", stats.mahdrain)
        pwr_strs[5] = format_dist(stats.total_dist)
	pwr_strs[6] = string_fmt("%d", eff_int)
    end

    local mins = 0
    if bat_state.identified and bat_state.curr > 0.5 then
	mins = math_floor(BAT_CAPACITY_MAH * bat_state.pct_val / bat_state.curr * 60 / 1000)
    end

    if mins ~= pwr_state.mins then
        pwr_state.mins = mins
        pwr_strs[7] = bat_state.curr > 0.5 and string_fmt("EST: %dm", mins) or "EST: --m"
    end
end

-- Pre-calculates radar math and formats strings only when values change
-- to completely eliminate Garbage Collection (RAM) spikes.
local function update_rad_strings()
    if home_state.set and gps_state.fix then
        local dist = fast_dist(home_state.lat, home_state.lon, gps_state.lat, gps_state.lon)
        if dist ~= rad_state.dist then
            rad_state.dist = dist
            rad_strs[1] = format_dist(dist)
        end
        
        -- Equirectangular bearing approximation (Drone TO Home)
        local dLat = (home_state.lat - gps_state.lat) * RAD
        local dLon = (home_state.lon - gps_state.lon) * RAD * math_cos(gps_state.lat * RAD)
        rad_state.bear_rad = math_atan(dLon, dLat)
    else
        if rad_state.dist ~= -1 then
            rad_state.dist = -1
            rad_strs[1] = "---"
        end
    end

    if gps_state.fix then
        if gps_state.alt ~= rad_state.alt then
            rad_state.alt = gps_state.alt
            rad_strs[2] = string_fmt("%.0f%s", gps_state.alt * alt_factor, alt_unit)
        end
        if gps_state.vspd ~= rad_state.vspd then
            rad_state.vspd = gps_state.vspd
            rad_strs[3] = string_fmt("%+.1fm/s", gps_state.vspd)
        end
    else
        if rad_state.alt ~= -999 then
            rad_state.alt = -999
            rad_state.vspd = -999
            rad_strs[2] = "---"
            rad_strs[3] = "---"
        end
    end
end

-- Dispatches the correct update_*_strings() function for the currently
-- active tab. Centralises the if/elseif dispatch chain that would otherwise
-- be duplicated between background() (periodic 1 Hz refresh) and run()
-- (immediate refresh on tab switch). Adding a new tab only requires updating
-- this single function instead of two separate call sites.
local function update_active_tab_strings()
    local tab = TABS[current_page]
    if     tab == "BAT" then update_bat_strings()
    elseif tab == "TOT" then update_tot_strings()
    elseif tab == "PWR" then update_pwr_strings()
    elseif tab == "LNK" then update_lnk_strings()
    elseif tab == "RAD" then update_rad_strings()
    end
end

-- Uses v_max + 0.05 V as the per-cell ceiling instead of v_max to avoid
-- misclassifying a freshly charged pack. Example: a 4S LiPo at 16.82 V
-- divided by 4.20 gives 4.004 → floor = 4 correct, but at exactly 16.80 V
-- divided by 4.20 gives exactly 4.000 → floor = 4 still correct.
-- Without the margin, floating-point drift could produce 3.999 → floor = 3.
local function detect_cells(voltage)
    if voltage < 0.5 then return 0 end
    return math_floor(voltage / (BAT_CFG_VMAX[bat_state.cfg_idx] + 0.05)) + 1
end

-- Generates a unique GPX log filename based on the current Real-Time Clock (RTC) time.
-- Format: /LOGS/R_HHMMSS.gpx
-- This bypasses the need for sequential SD card indexing or persistent state saving,
-- ensuring safe zero-write operation during flight.
local function get_next_gpx_filename()
    local dt = getDateTime()
    return string_fmt("/LOGS/R_%02d%02d%02d.gpx", dt.hour, dt.min, dt.sec)
end

-- Manages the lifecycle of the GPX log file.
-- Checks if logging is enabled in the configuration, if a GPS fix is 
-- available, and if the drone is armed. Writes the XML header when the 
-- flight starts and cleanly closes the XML tags upon disarming.
local function gpx_state()
    if GPX_LOG_ENABLED then
        local should_record = armed_display

        if should_record and not gpx_is_recording then
            gpx_file_current = get_next_gpx_filename()
            local file = io.open(gpx_file_current, "w")
            if file then
		io.write(file, '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RCIC">\n<trk><name>Flight Track</name><trkseg>\n')
                io.close(file)
                gpx_is_recording = true
                log_gpx_point(gps_state.lat, gps_state.lon, gps_state.alt)
            end
        elseif not should_record and gpx_is_recording then
            if gpx_file_current then
                local file = io.open(gpx_file_current, "a")
                if file then
                    io.write(file, '  </trkseg>\n</trk>\n</gpx>\n')
                    io.close(file)
                end
            end
            gpx_is_recording = false
            gpx_file_current = nil
        end
    end
end

-- ------------------------------------------------------------

-- Runs continuously in the background to process telemetry data.
-- Responsible for rate-limiting updates, detecting active sensors, computing
-- GPS distances/speeds, managing the GPX log state, and pre-formatting strings
-- for the UI to prevent memory fragmentation during the drawing phase.
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

    -- Edge-triggered cleanup: clears sensor cache only once upon telemetry loss
    if bg_prev_telem and not telemetry_live then
        sensors.done = nil
        fm_str       = nil
        fm_armed     = false
    end
    bg_prev_telem = telemetry_live

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
	    fm_armed = fm_str ~= nil and fm_str ~= "OK" and fm_str ~= "!ERR" and fm_str ~= "WAIT"
	end

	if gps_state.sats > stats.max_sats then
    	    stats.max_sats = gps_state.sats
	end

	local cur_lat, cur_lon = 0, 0
	if type(gps_data) == "table" then
    	    cur_lat = gps_data["lat"] or gps_data[1] or 0
    	    cur_lon = gps_data["lon"] or gps_data[2] or 0
	end

	-- GPS position must be updated regardless of TAB_GPS_EN visibility 
        -- so that Home position locks for the Radar and stats accumulate correctly.
        if gps_state.sats >= MIN_SATS and is_valid_gps(cur_lat, cur_lon) then
            update_gps_position(cur_lat, cur_lon, alt, gspd)
	elseif gps_state.sats < MIN_SATS and gps_state.fix then
	    gps_state.fix      = false
	    gps_state.vspd     = 0
	    gps_state.prev_alt = 0
        end

        -- Lock home on first valid fix; never resets mid-flight.
        if not home_state.set and gps_state.fix and gps_state.sats >= MIN_SATS then
            home_state.lat = gps_state.lat
            home_state.lon = gps_state.lon
            home_state.set = true
        end

        if curr > stats.max_current then stats.max_current = curr end
        if capa > stats.mahdrain    then stats.mahdrain    = capa end

	-- Vario: prefer direct VSpd sensor (INAV/BF); fall back to altitude delta.
	-- Guard prev_alt ~= 0 avoids a spurious spike on the very first fix cycle.
	local raw_vspd = sensors.vspd and getValue(sensors.vspd) or 0
	if raw_vspd ~= 0 then
    	    gps_state.vspd = raw_vspd
	elseif gps_state.fix and gps_state.prev_alt ~= 0 then
    	    gps_state.vspd = (alt - gps_state.prev_alt) * CENTISECS_PER_SEC / UPDATE_RATE
	end
	if gps_state.fix then gps_state.prev_alt = alt end
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

    gpx_state()

    -- Cell count is re-inferred only when the battery is physically reconnected
    -- (last_volt was near zero, indicating a real disconnect) or on the very first
    -- detection (not yet identified). This prevents false re-detection when a deeply
    -- discharged battery sags under load and then recovers by >1 V while the drone
    -- is still flying. A genuine battery swap always passes through near-zero first.
    if (bat_state.rx_bt - bat_state.last_volt) > 1.0 then
        if not bat_state.identified or bat_state.last_volt < 2.0 then
            bat_state.cells = detect_cells(bat_state.rx_bt)
            if bat_state.cells > 0 then bat_state.identified = true end
        end
        bat_state.connect_time = current_time
        bat_state.alert_volt = 0
    elseif bat_state.rx_bt < 2.0 then
        -- elseif prevents a 1S LiIon at 1.0-2.0V from being identified
        -- and immediately cleared in the same cycle.
	bat_state.identified = false
    end

    bat_state.last_volt    = bat_state.rx_bt
    bat_state.cell_voltage = bat_state.identified and (bat_state.rx_bt / bat_state.cells) or 0

    if bat_state.identified then
        if stats.min_voltage == 0 or bat_state.cell_voltage < stats.min_voltage then
            stats.min_voltage = bat_state.cell_voltage
        end
    end

    -- Allocate memory for strings only if viewing their respective page
    update_active_tab_strings()

    -- GPS cache: shared by the fixed-GPS info line and the waiting-for-fix screen
    if gps_state.alt ~= 0 then
        gps_str_info = string_fmt("ALT:%d%s %+.1f", math_floor(gps_state.alt * alt_factor), alt_unit, gps_state.vspd)
    end
    if gps_state.sats ~= last_sats then
        last_sats   = gps_state.sats
        gps_sats_str = string_fmt("SAT:%d", gps_state.sats)
    end

    -- Lazy-load HDOP sensor ONLY after a 3D fix is acquired (solves ELRS delay).
    if gps_state.fix and not sensors.hdop then
        if getValue("HDOP") ~= nil then sensors.hdop = "HDOP"
        elseif getValue("Prec") ~= nil then sensors.hdop = "Prec"
        else sensors.hdop = "NONE" end -- "NONE" prevents checking every cycle
    end
    if sensors.hdop and sensors.hdop ~= "NONE" then
        local h = getValue(sensors.hdop) or 0
        if h ~= gps_state.hdop then
            gps_state.hdop = h
            gps_state.hdop_str = h > 0 and string_fmt("HDOP:%.1f", h) or "HDOP:--"
        end
    end

    force_redraw = true
end

-- ------------------------------------------------------------
-- 11. DRAWING FUNCTIONS
-- ------------------------------------------------------------

-- Computes and draws the QR code directly to the screen without using a memory buffer.
-- This represents 0 bytes of dynamic RAM overhead.
local function draw_qr_directly(lat_str, lon_str)
    -- Lazy-load the Galois Field tables ONLY when the GPS tab is actually rendered
    if not qr_e then init_gf_tables() end

    local qr_size = 25 * qr_scale + 4
    lcd_drawFilledRect(LAYOUT.qr_x, LAYOUT.qr_y, qr_size, qr_size, SOLID)

    -- 1. Draw fixed patterns (Base Matrix)
    for r = 0, 24 do
        local row_bits = QR_BASE_V[r + 1]
        if row_bits ~= 0 then
            for c = 0, 24 do
                if (row_bits & (1 << c)) ~= 0 then
                    lcd_drawFilledRect(LAYOUT.qr_x + 2 + c * qr_scale, LAYOUT.qr_y + 2 + r * qr_scale, qr_scale, qr_scale, ERASE_FLAG)
                end
            end
        end
    end

    local t = "geo:" .. lat_str .. "," .. lon_str
    qr_bi = 0
    for i = 1, 12 do qr_b[i] = 0 end

    -- Bit packing
    qr_pack_bits(4, 4)
    qr_pack_bits(#t, 8)
    for i = 1, #t do qr_pack_bits(string_byte(t, i), 8) end
    qr_pack_bits(0, 4)
    while qr_bi % 8 ~= 0 do qr_pack_bits(0, 1) end

    local pi = 0
    while qr_bi < 224 do
        qr_pack_bits((pi % 2 == 0) and 236 or 17, 8)
        pi = pi + 1
    end

    for i = 0, 27 do
        local acc = 0
        for j = 0, 7 do 
            local bit_idx = i * 8 + j
            local int_idx = math_floor(bit_idx / 32) + 1
            local bit_pos = bit_idx % 32
            local bit = (qr_b[int_idx] >> bit_pos) & 1
            acc = (acc << 1) | bit
        end
        qr_m[i + 1] = acc
    end

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

    for i = 1, 16 do qr_pack_bits(qr_ec[i], 8) end
    qr_pack_bits(0, 7)

    -- 2. Diagonal scanning and direct rendering to LCD
    local cx, cy, dir, bd = 24, 24, -1, 0
    while cx >= 0 do
        if cx == 6 then cx = cx - 1 end
        for _ = 1, 25 do
            for col = 0, 1 do
                local nx = cx - col
                if (QR_BASE_M[cy + 1] & (1 << nx)) == 0 then
                    local int_idx = math_floor(bd / 32) + 1
                    local bit_pos = bd % 32
                    local bit = (qr_b[int_idx] >> bit_pos) & 1
                    bd = bd + 1
                    if (cy + nx) % 2 == 0 then bit = bit ~ 1 end
                    
                    if bit == 1 then 
                        -- ¡Magia! En lugar de guardar en tabla, dibujamos el pixel
                        lcd_drawFilledRect(LAYOUT.qr_x + 2 + nx * qr_scale, LAYOUT.qr_y + 2 + cy * qr_scale, qr_scale, qr_scale, ERASE_FLAG)
                    end
                end
            end
            cy = cy + dir
        end
        cy = cy - dir
        dir = -dir
        cx = cx - 2
    end
end

-- Draws a rectangle with visually rounded corners by erasing the 4 sharp edge pixels.
-- Perfectly frames the native rounded filled rectangles of EdgeTX monochrome screens.
local function draw_rounded_rect(x, y, w, h)
    lcd_drawRect(x, y, w, h, SOLID)
    lcd_drawRect(x, y, 1, 1, ERASE_FLAG)
    lcd_drawRect(x + w - 1, y, 1, 1, ERASE_FLAG)
    lcd_drawRect(x, y + h - 1, 1, 1, ERASE_FLAG)
    lcd_drawRect(x + w - 1, y + h - 1, 1, 1, ERASE_FLAG)
end

-- Draws a filled progress bar with a rounded border and a vertical cap pixel
-- at the fill boundary to prevent antialiasing artifacts on B/W screens.
-- x,y: top-left origin; w,h: dimensions in pixels; pct: fill fraction 0.0–1.0.
-- Always draws the rounded border; fill is skipped when pct == 0.
-- Supports variable height: h=7 for slim bars (BAT/PWR/LNK), larger values
-- for signal bars (LOC uses ~40% of CONTENT_H for easy visual scanning).
local function draw_fill_bar(x, y, w, h, pct)
    local fill = math_floor(pct * w)
    if fill > 0 then
        lcd_drawFilledRect(x, y, fill, h, SOLID)
        if fill < w - 1 then
            lcd_drawRect(x + fill - 1, y, 1, h, SOLID)
        end
    end
    draw_rounded_rect(x, y, w, h)
end

-- Renders the tab bar at the top of the screen (rows 0..TAB_H-1).
-- The active tab slot gets a filled background with inverted text;
-- all other slots get an outline border with normal text.
-- The flight-mode indicator is drawn right-aligned in the FM_AREA_W
-- reserved zone: shows fm_str (inverted when armed), "ARM" when the
-- arm switch is active without fmode, or "---" otherwise.
local function draw_tabs()
    for i = 1, VISIBLE_TABS do
        local actual_tab = tab_scroll + i - 1
        if actual_tab <= TABS_LEN then
            local w = (i == VISIBLE_TABS) and (SCREEN_W - FM_AREA_W - TAB_X[i]) or TAB_W
            if actual_tab == current_page then
                lcd_drawFilledRect(TAB_X[i], 0, w, TAB_H, SOLID)
                lcd_drawText(TAB_CX[i], 1, TAB_NAME[actual_tab], SMLSIZE + CENTER + INVERS)
            else
                lcd_drawRect(TAB_X[i], 0, w, TAB_H, SOLID)
                lcd_drawText(TAB_CX[i], 1, TAB_NAME[actual_tab], SMLSIZE + CENTER)
            end
        end
    end

    -- Flight mode indicator: right of last tab
    local fx = SCREEN_W - FM_AREA_W + math_floor(FM_AREA_W / 2)
    if fm_str then
        lcd_drawText(fx, 1, fm_str, SMLSIZE + CENTER + (armed_display and INVERS or 0))
    elseif ARM_SWITCH ~= "" and armed_display then
        lcd_drawText(fx, 1, "ARM", SMLSIZE + CENTER)
    else
        lcd_drawText(fx, 1, "---", SMLSIZE + CENTER)
    end
end

-- Renders the BAT (battery) page.
-- Top centre: pack voltage in DBLSIZE. Left: per-cell voltage (blinks
-- INVERS when below threshold). Right: TX voltage (blinks when below
-- TX_BAT_WARN). Centre label: chemistry + cell count ("LiPo [4S]").
-- Bottom area: Vmin / SoC% / Vmax row followed by a filled capacity bar.
-- The bar and percentage are hidden while a low-voltage alert blinks.
local function draw_bat_page(blink_on)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_cell_y, bat_state.rx_fmt, DBLSIZE + CENTER)
    lcd_drawText(0, LAYOUT.bat_label_y, "VCELL", SMLSIZE)
    lcd_drawText(SCREEN_W, LAYOUT.bat_label_y, "TX", SMLSIZE + RIGHT)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_label_y, bat_state.chem_cell_str, SMLSIZE + CENTER)

    local cell_voltage_alert = (BATTERY_ALERT_ENABLED and bat_state.identified and bat_state.cell_voltage < bat_state.threshold)

    if bat_state.identified then
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
        lcd_drawText(0, LAYOUT.bat_pct_y, bat_state.lbl_vmin, SMLSIZE)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.bat_pct_y, bat_state.pct_str, SMLSIZE + CENTER)
        lcd_drawText(SCREEN_W, LAYOUT.bat_pct_y, bat_state.lbl_vmax, SMLSIZE + RIGHT)

	draw_fill_bar(LAYOUT.bar_x, LAYOUT.bat_bar_y, LAYOUT.bar_w, 7,
            bat_state.identified and bat_state.pct_val or 0)
    end
end

-- Renders the GPS telemetry page with real-time coordinates and metrics.
-- Displays Latitude, Longitude, Altitude, Vertical Speed, Satellites, and HDOP.
-- Features a zero-RAM-overhead rendering pipeline: the Open Location Code (Plus Code)
-- and the QR code are calculated and drawn directly to the LCD layer only when
-- this page is active, entirely eliminating background memory allocation.
-- If the GPS fix is lost or pending, displays a "WAITING GPS" prompt.
local function draw_gps_page(blink_on)
    local gps_lost = gps_state.had_fix and not gps_state.fix
    if (gps_lost or (gps_state.fix and not telemetry_live)) and blink_on then
        lcd_drawRect(0, CONTENT_Y, SCREEN_W, LAYOUT.gps_lost_h, SOLID)
    end

    if gps_state.fix then
        lcd_drawText(SCREEN_W - 4, LAYOUT.coord_lat_y, gps_state.lat_str, FONT_COORDS + RIGHT)
        lcd_drawText(SCREEN_W - 4, LAYOUT.coord_lon_y, gps_state.lon_str, FONT_COORDS + RIGHT)
        lcd_drawText(SCREEN_W - 4, LAYOUT.info_y,      gps_str_info,      FONT_INFO + RIGHT)
        lcd_drawText(4,            LAYOUT.gps_tl_y,    gps_sats_str,      FONT_INFO)
        lcd_drawText(4,            LAYOUT.url_y,       gps_state.hdop_str,FONT_INFO)
	-- Reads the pre-calculated Plus Code string to guarantee 0 bytes RAM overhead per frame
	lcd_drawText(SCREEN_W - 4, LAYOUT.url_y, gps_state.plus_code, FONT_INFO + RIGHT)
	draw_qr_directly(gps_state.lat_str, gps_state.lon_str)
    elseif gps_state.had_fix then
	-- GPS lost mid-flight: render last known position in full, including QR.
	-- The QR encodes the last valid plus_code, which is the pilot's only
	-- reference to locate the drone if it crashes during the shadow.
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.gps_tl_y,    "GPS LOST",        FONT_INFO   + CENTER + INVERS)
	lcd_drawText(SCREEN_W - 4,    LAYOUT.coord_lat_y, gps_state.lat_str, FONT_COORDS + RIGHT)
	lcd_drawText(SCREEN_W - 4,    LAYOUT.coord_lon_y, gps_state.lon_str, FONT_COORDS + RIGHT)
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.info_y,      gps_str_info,      FONT_INFO   + CENTER)
	lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y,      gps_sats_str,      FONT_INFO   + CENTER)
	draw_qr_directly(gps_state.lat_str, gps_state.lon_str)
    else
	-- cold start: no fix has ever been acquired this session
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, "WAITING GPS", FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y, gps_sats_str, FONT_INFO + CENTER)
    end
end

-- Renders the TOT (flight statistics) page.
-- Draws 5 rows of two columns each from the pre-formatted tot_strs[] cache:
--   Left  / Right pairs: MIN V / MAX AMP, MAX ALT / DIST, MAX SPD / MAX SATS,
--   DRAIN / FLT TIME, MIN LQ / EFF.
-- No computation is done here; all strings are prepared by update_tot_strings().
local function draw_tot_page()
    local ys = {LAYOUT.tot_line1_y, LAYOUT.tot_line2_y, LAYOUT.tot_line3_y, LAYOUT.tot_line4_y, LAYOUT.tot_line5_y}
    for i=1, 5 do
	lcd_drawText(0, ys[i], tot_strs[i*2-1], SMLSIZE)
	lcd_drawText(SCREEN_W, ys[i], tot_strs[i*2], SMLSIZE + RIGHT)
    end
end

-- Renders the LOC (locator / drone finder) page.
-- Idle state (loc_active == false): shows an "ENTER: START" prompt.
-- Active, no signal: shows a blinking "NO SIGNAL" notice.
-- Active with signal: shows the raw dBm / percentage value centred above a
-- filled signal-strength bar. A peak-hold marker is drawn at the highest
-- percentage seen since activation. The bar and beep rate are updated by
-- update_loc_sensor() every frame.
local function draw_loc_page(blink_on)
    if not loc_active then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, "ENTER: START", FONT_COORDS + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y - 6, "Best results obtained if", FONT_INFO + CENTER)
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.sats_y + 2, "disable TX Dynamic Power", FONT_INFO + CENTER)
        return
    end

    if not loc_sig then
        lcd_drawText(SCREEN_CENTER_X, LAYOUT.waiting_y, "NO SIGNAL", FONT_COORDS + CENTER + (blink_on and INVERS or 0))
        return
    end

    lcd_drawText(SCREEN_CENTER_X, LAYOUT.loc_sig_y,  loc_sig_fmt,  DBLSIZE + CENTER)
    lcd_drawText(2,               LAYOUT.loc_info_y, loc_tpwr_fmt, FONT_INFO)
    lcd_drawText(SCREEN_W - 2,    LAYOUT.loc_info_y, loc_pct_fmt,  FONT_INFO + RIGHT)

    draw_fill_bar(LAYOUT.loc_bar_x, LAYOUT.loc_bar_y, LAYOUT.loc_bar_w, LAYOUT.loc_bar_h, loc_sig_pct / 100)

    if loc_peak_pct > loc_sig_pct then
        local peak_offset = math_floor((loc_peak_pct / 100) * (LAYOUT.loc_bar_w - 3))
        lcd_drawFilledRect(LAYOUT.loc_bar_x + 1 + peak_offset, LAYOUT.loc_bar_y, 2, LAYOUT.loc_bar_h, SOLID)
    end
end

-- Renders the LNK (link quality) tab. Adapts layout to protocol:
-- - ELRS / Crossfire: shows RQly large, plus antenna RSS, SNR, RFMD, TQly.
-- - Classic RSSI (FrSky): shows only RSSI and TPWR; secondary rows hidden.
-- The LQ value blinks INVERS when below LNK_LQ_WARN to signal degraded link.
-- The bottom fill bar mirrors the BAT page bar using the shared draw_fill_bar().
-- All strings come from the pre-formatted lnk_strs[] cache built in
-- update_lnk_strings() so no string allocations occur during drawing.
local function draw_lnk_page(blink_on)
    local warn    = lnk_state.lq_pct < LNK_LQ_WARN
    local lq_flag = FONT_COORDS + CENTER + (warn and blink_on and INVERS or 0)
    local lbl     = link_is_elrs and "RQly" or "RSSI"

    lcd_drawText(SCREEN_CENTER_X, LAYOUT.lnk_lq_y, lnk_strs[1], lq_flag)
    if link_is_elrs then
        lcd_drawText(0, LAYOUT.lnk_main_y, lnk_strs[4], SMLSIZE)
        lcd_drawText(SCREEN_W, LAYOUT.lnk_main_y, lnk_strs[5], SMLSIZE + RIGHT)
        lcd_drawText(0,        LAYOUT.lnk_line2_y, lnk_strs[3], SMLSIZE)
    end
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.lnk_main_y, lbl, SMLSIZE + CENTER)
    lcd_drawText(SCREEN_W, LAYOUT.lnk_line2_y, lnk_strs[6], SMLSIZE + RIGHT)
    lcd_drawText(SCREEN_CENTER_X, LAYOUT.lnk_line3_y, lnk_strs[2], SMLSIZE + CENTER)

    draw_fill_bar(LAYOUT.bar_x, LAYOUT.bat_bar_y, LAYOUT.bar_w, 7, lnk_state.lq_pct / 100)
end

-- Draws the Power & Efficiency page using a responsive 2-column layout.
-- Giant values are anchored to the top. Small values are mapped either via
-- strict pixel offsets (128x64 B/W) or proportional layout fractions (Color).
local function draw_pwr_page()
    -- Top: Giant Values (Left / Right)
    lcd_drawText(4, LAYOUT.pwr_y0, pwr_strs[3], DBLSIZE)
    lcd_drawText(SCREEN_W - 4, LAYOUT.pwr_y0, pwr_strs[6], DBLSIZE + RIGHT)

    -- Row 1: Voltage (L) & Efficiency Unit (R)
    -- Row 2: Consumed (L) & Current/Amps (R)
    -- Row 3: Estimated Time (L) & Distance (R)
    local pys = {LAYOUT.pwr_y1, LAYOUT.pwr_y2, LAYOUT.pwr_y3}
    local pli = {1, 4, 7}
    local pri = {8, 2, 5}
    for i = 1, 3 do
	lcd_drawText(4,            pys[i], pwr_strs[pli[i]], FONT_INFO)
	lcd_drawText(SCREEN_W - 4, pys[i], pwr_strs[pri[i]], FONT_INFO + RIGHT)
    end

    -- Bottom Bar: Remaining Battery Capacity
    draw_fill_bar(LAYOUT.bar_x, LAYOUT.bat_bar_y, LAYOUT.bar_w, 7, bat_state.pct_val)
end

-- Draws the RAD (Radar) tab: a head-up tactical radar on the left and a
-- critical-data panel on the right.
--
-- LEFT BLOCK — radar square:
--   A static square represents the radar area. A small cross at the centre
--   marks the drone. A filled 3x3 square marks the home point, plotted at
--   a heading-relative angle (bear - hdg) so the top of the square always
--   points in the drone's current forward direction (head-up convention).
--   Distance is mapped to the dot radius using a dynamic range that steps
--   through 100 / 500 / 1000 / n*1000 m so the dot scales inward as the
--   drone approaches home.
--   Safety nets:
--     · "NO GPS" in inverse video if fix is absent or sats < MIN_SATS.
--     · "..."   if fix is valid but home has not been locked yet.
--
-- RIGHT BLOCK — data panel (shifted right, no separator):
--   DIST  horizontal distance to home, auto-switching m ↔ km.
--   ALT   altitude above the home point in alt_unit (m or ft).
--   VSPD  vertical speed in m/s, signed (+ ascending, − descending).
--
-- All numeric values come from the rad_strs[] cache; no string allocations
-- occur during drawing. Geometry is fully proportional via LAYOUT keys
-- pre-computed once in compute_layout().
local function draw_rad_page()
    local cx = LAYOUT.rad_cx
    local cy = LAYOUT.rad_cy
    local r  = LAYOUT.rad_r
    local dx = LAYOUT.rad_dx

    lcd_drawRect(cx - r, cy - r, r * 2, r * 2)

    -- Centre cross (drone position)
    lcd_drawFilledRect(cx - 1, cy,     3, 1, SOLID)
    lcd_drawFilledRect(cx,     cy - 1, 1, 3, SOLID)

    local has_fix = gps_state.fix and gps_state.sats >= MIN_SATS
    if not has_fix then
        lcd_drawText(cx, cy - 7, "NO",  SMLSIZE + CENTER + INVERS)
        lcd_drawText(cx, cy + 3, "GPS", SMLSIZE + CENTER + INVERS)
    elseif home_state.set then
        -- Only fetch the fast-updating compass heading here
        local hdg = sensors.hdg and getValue(sensors.hdg) or 0
        local rel_rad = rad_state.bear_rad - (hdg * RAD)

        local dist = rad_state.dist
        local max_range = 100
        if dist > 100 then
            max_range = dist <= 500 and 500 or (dist <= 1000 and 1000 or math_floor(dist / 1000 + 1) * 1000)
        end
        local dot_r = math_min(r - 3, math_floor(dist / max_range * (r - 3)))

        -- 0 deg is UP -> X = +sin(angle), Y = -cos(angle)
        local hx = cx + math_floor(math_sin(rel_rad) * dot_r)
        local hy = cy - math_floor(math_cos(rel_rad) * dot_r)
        lcd_drawFilledRect(hx - 1, hy - 1, 3, 3, SOLID)
    else
        lcd_drawText(cx, cy - 3, "...", SMLSIZE + CENTER)
    end

    -- Data Panel (Vertical separator removed, labels shifted right)
    local lbl_x = dx + 6
    local rys  = {LAYOUT.rad_dy1, LAYOUT.rad_dy2, LAYOUT.rad_dy3}
    local rlbl = {"DIST", "ALT", "VSPD"}
    for i = 1, 3 do
	lcd_drawText(lbl_x,   rys[i], rlbl[i],    SMLSIZE)
	lcd_drawText(SCREEN_W, rys[i], rad_strs[i], SMLSIZE + RIGHT)
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
    toast_w = math_max(#msg * 6 + 10, 60)
    toast_x = math_floor((SCREEN_W - toast_w) / 2)
end

-- Renders a full-screen notice when all tabs are disabled in configuration.
-- Drawn once per update cycle; skipped when force_redraw is false.
local function draw_no_tabs(blink_on)
    lcd_clear()
    lcd_drawText(SCREEN_CENTER_X, math_floor(SCREEN_H / 2) - 6, "TABS DISABLED",
        MIDSIZE + CENTER + (blink_on and INVERS or 0))
    lcd_drawText(SCREEN_CENTER_X, SCREEN_H - 7, "Enable one in Config", SMLSIZE + CENTER)
end

-- ------------------------------------------------------------
-- 12. EVENT & RELATED FUNCTIONS
-- ------------------------------------------------------------

-- Handles touch-screen tab navigation for radios that support EVT_TOUCH_FIRST
-- (TX16S, Boxer, etc.). Reads the touch coordinates and switches current_page
-- when the tap falls within the tab bar area. Returns 0 to consume the event.
local function handle_touch_nav()
    if getTouchState then
        local touch = getTouchState()
        if touch and touch.y <= TAB_H then
            for i = 1, VISIBLE_TABS do
                local x_end = (i == VISIBLE_TABS) and (SCREEN_W - FM_AREA_W) or (TAB_X[i] + TAB_W)
                if touch.x < x_end then
                    local actual_tab = tab_scroll + i - 1
                    if actual_tab <= TABS_LEN then
                        current_page = actual_tab
                        force_redraw = true
                    end
                    break
                end
            end
        end
    end
    return 0
end

-- Handles EVT_ENTER_BREAK on the four main pages (outside the config overlay).
-- BAT: cycles through battery chemistry types and updates threshold strings.
-- GPS: triggers a screenshot if a GPS fix and QR code are available.
-- TOT: resets all flight statistics to their default values.
-- LOC: toggles the locator active state; clears signal cache on deactivation.
local function handle_page_enter()
    local current_tab_name = TABS[current_page]
    if current_tab_name == "BAT" then
        bat_state.cfg_idx = (bat_state.cfg_idx % #BAT_CFG_TEXT) + 1
        local idx = bat_state.cfg_idx
        bat_state.threshold = BAT_CFG_VOLT[idx]
        bat_state.lbl_vmin  = string_fmt("%.2fV", BAT_CFG_VMIN[idx])
        bat_state.lbl_vmax  = string_fmt("%.2fV", BAT_CFG_VMAX[idx])
        bat_state.cells = detect_cells(bat_state.rx_bt)
        bat_state.identified = bat_state.cells > 0
        bat_state.cell_voltage = bat_state.cells > 0 and (bat_state.rx_bt / bat_state.cells) or 0
        bat_state.last_volt  = bat_state.rx_bt
        bat_state.last_rx_bt = -1
        bat_state.last_cells = -1
        update_bat_strings()
        show_toast(string_fmt("** %s (%.1fV) **", BAT_CFG_TEXT[idx], bat_state.threshold))
    elseif current_tab_name == "GPS" then
        if gps_state.fix then
	    screenshot()
            show_toast("** SCREENSHOT **")
        end
    elseif current_tab_name == "TOT" then
        reset_stats()
        show_toast("** RESET **")
    elseif current_tab_name == "LOC" then
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
-- Two scaling modes depending on link_is_elrs:
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
    if link_is_elrs then
        -- dBm 0–100, using LOC_SEG_NEAR/LOC_SEG_FAR
        if     sig >= LOC_SEG_NEAR then return 100
        elseif sig <= LOC_SEG_FAR  then return 10
        else
	    return math_floor((sig - LOC_SEG_FAR) * 90 / LOC_SEG_RANGE + 10)
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
-- Alerts are also suppressed for BATTERY_STABILIZE_TIME cs after a >1V voltage
-- jump to prevent false positives during battery connection/swap.
local function update_battery_alert(current_time)
    if not BATTERY_ALERT_ENABLED or not bat_state.identified
        or bat_state.curr > SAG_CURRENT_THRESHOLD
        or (current_time - bat_state.connect_time) < BATTERY_STABILIZE_TIME then return end

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
            loc_sig_fmt = string_fmt("%d dBm", s)
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

-- Main execution loop and UI rendering engine.
-- Handles hardware events (buttons, touch, rotary dial), manages tab navigation,
-- triggers periodic alerts (audio/haptic), and dispatches the corresponding 
-- drawing functions based on the currently active page or overlay.
local function run(event)
    local current_time = getTime()

    -- Wake-up detector: reloads SD config only if script was paused > 1 second
    if last_run_time > 0 and (current_time - last_run_time > 100) then
        load_config()
	rebuild_tabs()
        force_redraw = true
    end
    last_run_time = current_time

    if TABS_LEN == 0 then
	local blink_on = (math_floor(getTime() / 100) % 2) == 0
	draw_no_tabs(blink_on)
        return 0
    end

    if event ~= 0 then
        force_redraw = true

	if EVT_TOUCH_FIRST and event == EVT_TOUCH_FIRST then
            return handle_touch_nav()
        end

        if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
	    current_page = cycle(current_page, TABS_LEN,  1)
	elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
	    current_page = cycle(current_page, TABS_LEN, -1)
        elseif event == EVT_ENTER_BREAK then
    	    handle_page_enter()
        end

	if current_page > tab_scroll + VISIBLE_TABS - 1 then
            tab_scroll = current_page - VISIBLE_TABS + 1
        elseif current_page < tab_scroll then
            tab_scroll = current_page
        end
    end


    -- Bypasses the background UPDATE_RATE limit to ensure immediate fresh data
    if current_page ~= last_page then
        update_active_tab_strings()
        last_page = current_page
        force_redraw = true
    end

    update_battery_alert(current_time)

    -- Auto-tab: falling edge of telemetry_live → jump to GPS or LOC dynamically
    -- Completely bypassed if both target tabs are disabled by the user
    if prev_telem_live and not telemetry_live and AUTO_TAB and (TAB_GPS_EN or TAB_LOC_EN) then
        local tgt_name
        if gps_state.fix and TAB_GPS_EN then
            tgt_name = "GPS"
        elseif TAB_LOC_EN then
            tgt_name = "LOC"
        else
            tgt_name = "GPS"
        end
        
        for i = 1, TABS_LEN do 
            if TABS[i] == tgt_name then current_page = i; break end 
        end
    end
    prev_telem_live = telemetry_live

    local blink_on = (math_floor(current_time / CENTISECS_PER_SEC) % 2) == 0
    if blink_on ~= last_blink_state then
        last_blink_state = blink_on
        force_redraw = true
    end

    -- Auto-dismiss toast and trigger a final redraw to clear the screen
    if toast_msg then
	if (current_time - toast_time) >= TOAST_DURATION then
    	    toast_msg = nil
	end
	force_redraw = true
    end

    -- Locator
    local current_tab_name = TABS[current_page]
    if current_tab_name == "LOC" and loc_active then update_loc_sensor(current_time) end

    if not force_redraw then return 0 end
    force_redraw = false

    lcd_clear()
    draw_tabs()

    if     current_tab_name == "BAT" then draw_bat_page(blink_on)
    elseif current_tab_name == "GPS" then draw_gps_page(blink_on)
    elseif current_tab_name == "TOT" then draw_tot_page()
    elseif current_tab_name == "LOC" then draw_loc_page(blink_on)
    elseif current_tab_name == "LNK" then draw_lnk_page(blink_on)
    elseif current_tab_name == "PWR" then draw_pwr_page()
    elseif current_tab_name == "RAD" then draw_rad_page()
    end

    if toast_msg then
        lcd_drawFilledRect(toast_x - 2, toast_y - 1, toast_w + 4, toast_h, SOLID)
        lcd_drawText(SCREEN_CENTER_X, toast_y, toast_msg, FONT_INFO + CENTER + INVERS)
    end

    return 0
end

-- ------------------------------------------------------------

return { init = init, background = background, run = run }

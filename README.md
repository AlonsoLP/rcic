# RCIC (RC Info Center) - Advanced Telemetry Suite for EdgeTX

<p align="center">
  <img src="https://github.com/user-attachments/assets/d57b3e07-3253-45db-b4e3-b29efeb48ab9">
</p>

**RC Info Center (RCIC)** is a highly optimized, full-featured telemetry suite designed exclusively for radio transmitters running **EdgeTX 2.9 or higher**. What started as a simple script has evolved into a powerful dual-module architecture featuring a lightweight background telemetry dashboard and a dedicated full-screen configuration tool.

RCIC provides a highly modular 7-tab dashboard, real-time battery analytics, GPX blackbox logging, a head-up tactical radar, and an acoustic drone locator.

![EdgeTX](https://img.shields.io/badge/EdgeTX-2.9%2B-blue)
![Lua](https://img.shields.io/badge/Lua-5.3-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## ✨ Key Features

* **7-Tab Modular Dashboard:** Seamless touch-screen navigation between Battery (BAT), GPS Navigation (GPS), Tactical Radar (RAD), Link Quality (LNK), Power & Efficiency (PWR), Drone Locator (LOC), and Flight Statistics (TOT). Customize your interface by disabling any tabs you don't need.
* **Dual-Script Architecture:** A strictly optimized telemetry engine (`rcic.lua`) paired with an independent, instant-save Configuration Tool (`rcic_cfg.lua`) to ensure zero-lag performance during flight.
* **GPX Blackbox Logging:** Automatically records your flight path (coordinates, altitude, and time) into standard `.gpx` files on your SD card whenever the drone is armed with a valid 3D fix.
* **Zero-RAM QR & Plus Code:** Instantly generates a standard `geo:lat,lon` QR Code and an Open Location Code natively in Lua. It draws directly to the screen pixels, requiring absolutely zero internet connection and 0 bytes of dynamic RAM overhead.
* **Smart Power & Anti-Sag:** Advanced algorithms monitor your instant current draw to suppress false low-voltage alarms during heavy throttle punch-outs.
* **Head-Up Tactical Radar:** A dynamic, auto-scaling radar screen that plots your home position relative to the drone's current heading.
* **Multi-Protocol Drone Locator:** An acoustic (Geiger-counter style) and visual RSSI tracker to find your downed quadcopter. It automatically normalizes ELRS, Crossfire, and FrSky signals into an intuitive 0–100% interface.

## 🚀 Quick Installation

Installing RCIC requires copying two files to your SD card:

1. Download the latest release from the repository.
2. Copy `rcic.lua` to your radio's SD card under `/SCRIPTS/TELEMETRY/`.
3. Copy `rcic_cfg.lua` to your radio's SD card under `/SCRIPTS/TOOLS/`.
4. On your radio, go to your Model settings -> **TELEMETRY** (or **DISPLAYS**) page.
5. Set *Screen 1* to **Script** and select `rcic`.

To configure the suite, press the **[SYS]** button, navigate to the **Tools** page, and run **RCIC Config**. To launch the flight dashboard, long-press your configured telemetry button (usually `[TELE]`) from the main screen.

## 📖 Documentation

For detailed step-by-step setup guides, feature breakdowns, and advanced tracking tips, please visit the official documentation:

👉 **[RCIC GitHub Wiki](../../wiki)**

## 🤝 Support & Community

This project thrives on community involvement. If you encounter bugs, have feature requests, or want to help test new versions, please open an issue in the repository. 

If this script saved your drone or you want to support continuous development and hardware compatibility testing, you can help by **[becoming a member on Patreon](https://www.patreon.com/join/AlonsoLP)**.

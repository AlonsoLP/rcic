# RCIC (RC Info Center) - Telemetry Dashboard for EdgeTX

<p align="center">
  <img src="https://github.com/user-attachments/assets/d57b3e07-3253-45db-b4e3-b29efeb48ab9">
</p>

**RC Info Center (RCIC)** is a highly optimized, full-featured telemetry script designed for radio transmitters running **EdgeTX 2.9 or higher** (and compatible OpenTX). It provides a multifunctional tabbed dashboard, real-time configurable battery alerts, GPS coordinate validation, an integrated drone locator, and fast local QR/OLC generation.

![EdgeTX](https://img.shields.io/badge/EdgeTX-2.9%2B-blue)
![Lua](https://img.shields.io/badge/Lua-5.3-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Key Features

* **4-Tab Interface:** Smooth navigation between Battery info (BAT), GPS Navigation Data (GPS), Total Flight Statistics (TOT), and Drone Locator (LOC). Touch-screen support included.
* **Smart Battery Monitoring:** Advanced Anti-Sag algorithms, estimated remaining flight time, chemistry selector (LiPo, LiHV, LiIon), and TX voltage warnings.
* **Lost Drone Locator:** Acoustic (Geiger-counter style) and visual RSSI tracker to find your downed quadcopter, compatible with ELRS, Crossfire, and FrSky.
* **On-Screen Local QR Code:** Instantly generates a standard `geo:lat,lon` QR Code and Plus Code from your coordinates, natively in Lua (no internet required).
* **In-App Configuration:** Adjust all telemetry parameters (rates, alarms, capacities) directly from your radio via a built-in overlay menu.
* **Automatic Multilanguage:** Supports English, Spanish, French, German, Italian, Portuguese, Russian, Polish, Czech, and Japanese.

## Quick Installation

1. Download `rcic.lua` and copy it to your radio's SD card under `/SCRIPTS/TELEMETRY/`.
2. On your radio, go to your Model settings -> **TELEMETRY** or **DISPLAYS** page.
3. Set *Screen 1* to **Script** and select `rcic`.
4. Long-press your configured telemetry button (usually `[TELE]`) to launch the dashboard.

## More info

Visit the **[RCIC GitHub Wiki](../../wiki)** for detailed instructions, feature breakdowns and configuration guides.

## Support

If you like this project, you can help me by **[becoming a member on Patreon](https://www.patreon.com/join/AlonsoLP)**.

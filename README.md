# RC Info Center (RCIC) for EdgeTX

**RC Info Center (rcic.lua)** is a lightweight, fast, and highly optimized telemetry script designed for radio controllers (RC) running EdgeTX (or compatible with OpenTX).

It provides an interactive 3-screen dashboard ("BAT", "GPS", and "TOT"), allowing you to constantly monitor your battery health, pinpoint your geographic position with high precision, and review your flight statistics.

Last update: **v1.31** (2026-02-21)

![RC Info Center](https://img.shields.io/badge/EdgeTX-2.9%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Key Features

### 1. Smart Battery System (BAT Screen)

<p align="center">
   <img src="https://github.com/user-attachments/files/25429081/BAT2.bmp" width="128" height="64">
</p>

- **Auto Cell Detection:** Detects whether your battery is 1S, 2S, 3S, 4S... based on the active telemetry voltage without requiring menu confirmation.
- **Multi-Chemistry Support:** Quickly switch between **LiPo, LiHV, and LiIon** (and their associated voltages) by simply pressing the main button (ENTER).
- **Relative Percentage Graph and Extremes:** A progressive and accurate visualizer of the battery percentage relative to the minimum safe flight voltage.
- **Voltage Alerts:** Configurable audible announcements if a cell drops below the safe margin for your battery's chemistry, preventing irreversible damage.

### 2. Optimized GPS Dashboard (GPS Screen)

<p align="center">
   <img src="https://github.com/user-attachments/files/25436572/GPS1.bmp" width="128" height="64">
   &nbsp;
   <img src="https://github.com/user-attachments/assets/c1d2bee6-6556-416a-87c2-683bc8b5dd13" width="128" height="64">
</p>

- **Simultaneous Reading:** Monitor your `Latitude`, `Longitude`, `Altitude`, and the number of `Satellites (Sats)` at a glance.
- **High-Precision Open Location Codes:** The script automatically generates extended 11-character local "Plus Codes". It provides technical local precision (up to a 2-3 meter offline grid) to infallibly locate a crashed model.
- **Advanced Cache Management:** Designed with the Lua Garbage Collector in mind, it stops `string` recalculations if the drone is stationary, saving precious CPU cycles.
- **Save Position:** Quickly generates a screenshot with the GPS position in the `SCREENSHOTS` folder by pressing the main button (ENTER).

### 3. Total Flight Statistics (TOT Screen)

<p align="center">
   <img src="https://github.com/user-attachments/files/25436638/TOT2.bmp" width="128" height="64">
</p>

Automatically saves the absolute minimums and major milestones of your session.
- **Absolute Minimum Voltage:** Useful for viewing the maximum battery *voltage sag* during climbs or punch-outs.
- **Distance:** Live internal computation using Equirectangular projection.
- **Flight Extremes:** Maximum Altitude, Peak Current (Amperage), and Maximum Speed.
- **Manual Reset:** Everything can be quickly reset by pressing ENTER on this specific tab.

---

## Requirements
- **Operating System:** Radio supported by EdgeTX v2.9 or higher. Likely compatible with OpenTX systems.
- **Compatible Protocols:** ELRS, Crossfire, or other telemetry protocols that expose basic sensors for RxBt, Satellites, GPS (Lat, Lon, Alt), and Speed via the Lua `getValue()` function.
- **Sensor:** A GPS module holding a minimum of 4 or more linked satellites to start reporting a valid location and acquire a *Fix*.

## Installation

1. Download the `rcic.lua` file.
2. Connect your radio controller to your PC via USB and mount the SD Card or Mass Storage.
3. Copy `rcic.lua` into the `SCRIPTS/TELEMETRY` folder on your SD card.
4. Disconnect the radio.
5. From your selected model's menu ("Telemetry" button/page), pick the empty screen slot you prefer.
6. Set the type to **Script** and choose **`rcic`** as your main script.

##  Usage

Use your **scroll wheel**, directional pad, or menu navigation axis to cycle forward and backward across the views.

Press **ENTER** in:
1. **BAT**, to switch between LiPo, LiHV, and LiIon.
2. **GPS**, to make a screenshot.
3. **TOT**, to reset stats.

---


This project is part of a continuous effort to push the limits of the Lua environment inside constrained STM32 processors, utilizing precalculated routines of local variables, systematic removal of useless concatenations, and ultra-low GC (Garbage Collection) cycles.









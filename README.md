# RCIC (RC Info Center) - Telemetry Dashboard for EdgeTX

**RC Info Center (RCIC)** is a lightweight, fast, and highly optimized telemetry script designed for radio transmitters running **EdgeTX 2.9 or higher** (and compatible OpenTX). It provides a multifunctional tabbed dashboard, real-time configurable battery alerts, GPS coordinate validation, and fast Plus Code generation for location tracking.

> This project is part of a continuous effort to push the limits of the Lua environment inside constrained STM32 processors, utilizing precalculated routines of local variables, systematic removal of useless concatenations, and ultra-low GC (Garbage Collection) cycles.

*(c) 2026 Alonso Lara.*

![RC Info Center](https://img.shields.io/badge/EdgeTX-2.9%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Key Features

- **3-Tab Interface (BAT, GPS, TOT):** Quick and smooth navigation between Battery info, GPS Navigation Data, and Total Flight Statistics.
- **Automatic Multilanguage:** Intelligently detects the transmitter's language (Support for Spanish, English, French, German, Italian, Portuguese, Russian, Polish, Czech, and Japanese).
- **Integrated Configuration Menu:** Allows adjusting telemetry parameters directly from the transmitter without having to edit the source code via a visual overlay panel.
- **On-Screen Local QR Code Generator:** Instantly builds a standard Version 2 `geo:` format QR Code from your current coordinates (6-decimal precision) natively in Lua without external libraries, scannable by any smartphone camera.
- **"Plus Codes" Generation:** Converts your GPS coordinates into a short [Plus Code](https://maps.google.com/pluscodes/), making it easier to share exact locations if you need to recover your aircraft (even without a map visible on the radio).
- **Optimized Performance:** Minimal CPU and memory usage (Reduced Garbage Collection through static QR masks and variable pre-allocation, plus efficient mathematical distance calculation), ensuring your radio always responds instantly and without "lag".
- **Smart Battery Alerts:** Blinking visual notifications and configurable voice alerts (with exact numerical voltage readouts) to prevent draining the battery beyond its safe zone. Features LiPo, LiHV, and LiIon profiles.

---

## Screens and Functions

Vital information is divided into logical views. To scroll, use the **Rotary Wheel** or the hardware **[+] / [-]** buttons.

### 1. BAT Tab (Battery)

<p align="center">
   <img src="https://github.com/user-attachments/files/25429081/BAT2.bmp" width="128" height="64">
</p>

The main screen focused on monitoring the propulsion system.
- **Total Voltage (RxBt):** Clear and giant font (DBLSIZE) reading of the total voltage returned by the model's receiver or sensor.
- **Cell Voltage (VCELL) / Cells (CELLS):** Autonomously counts how many cells the connected battery of your drone / plane has and calculates its unit voltage.
- **Battery Chemistry Selector:** You can alter the range with which the script will judge your total voltage by pressing **[ENTER]** on this page:
  - **LiPo** (Min 3.2v - Max 4.2v)
  - **LiHV** (Min 3.2v - Max 4.35v)
  - **LiIon** (Min 2.8v - Max 4.2v)
- **Visual Percentage Bar:** A graphical bar that dynamically empties and displays a relative percentage with respect to the real-time chemical voltage.
- **Blinking Visual Alerts:** In the hypothetical case that the cell voltage drops below the nominal value of the chosen battery type, the relevant indicators will dynamically invert color warning you that it is time to land.

### 2. GPS Tab (Navigation and Location)

<p align="center">
   <img src="https://github.com/user-attachments/files/25436572/GPS1.bmp" width="128" height="64">
   &nbsp;
   <img src="https://github.com/user-attachments/assets/c1d2bee6-6556-416a-87c2-683bc8b5dd13" width="128" height="64">
</p>

Main coordinate visualizer if you are equipping your model with a GNSS/GPS module.
- **Lat / Lon Coordinates:** Pure and readable exposure of absolute Latitude and Longitude with up to 6 decimals, properly aligned.
- **Dynamic QR Code:** Rendered simultaneously on the left side of the screen. This is generated locally (pure math) by the EdgeTX controller without relying on internet access. Scanning it with an Android/iOS smartphone immediately opens Google Maps/Apple Maps to the exact recovery location (`geo:lat,lon` RFC 5870 standard). Highly optimized using pre-calculated Bitmasks to avoid RAM overhead.
- **GPS Signal Detail:** Always reports the number of locked satellites (`SAT`) and even displays the current altitude (`ALT`). Flashes "WAITING GPS" if the configured minimum satellites fail to create a 3D tracking space fix.
- **Plus Code URL:** A text encoded under the Google `+CODE XXXX+XX` standard to quickly transcribe it to a mobile phone or map in a craft rescue without a live internet connection on the controller.
- **Loss Protection (LOST):** If a generalized feed drop occurs in mid-flight and the frame jump fails (telemetry crashes or radio signal turns off), the screen will start drawing thick bounding boxes on all sides of the frame, storing the last traces in memory over any other window, thus guaranteeing a foolproof backup.
- **Save Screenshot:** Executable by pressing **[ENTER]**; triggers the operating system's internal screenshot function to export a quick BMP format photograph of the coordinates to your SD Card.

### 3. TOT Tab (Totals and Statistics)

<p align="center">
   <img src="https://github.com/user-attachments/files/25457929/TOT1.bmp" width="128" height="64">
</p

Dedicated to the historical recording and end of flight, it is where everything is accumulated in memory. Displays the pairing of the minimum / maximum timestamps captured without restarting.
- **MIN V (Minimum Voltage):** Maintenance of the worst-case scenario *sag* reading.
- **MAX AMP (Maximum Current):** Measurement of peak load effort detected by your FC or shunt resistor.
- **MAX ALT (Maximum Altitude):** Pure vertical maximum altitude from takeoff based on 0 m.
- **DIST (Total Distance):** Trajectory and odometry generated by adding all latitude/longitude movements in real time from frame to frame and transformed into m / km.
- **MAX SPD (Max Speed):** Maximum achieved thrust of the model relative to the ground (GSpd).
- **MAX SAT (Max Satellites):** Highest concentration of static satellites obtained during the session.
- **DRAIN (Drained Capacity):** Direct discount in 'mAh' based on amperometric count sensors (Capa) vital not to fry the model.
- **RESET Button:** Resets these counters by pressing **[ENTER]** when viewing this tab to take off fresh when changing batteries. A prompt reading `** RESET **` will appear at the bottom.

---

## Dynamic Configuration Menu

Instead of requiring constantly connecting your USB cable to the computer or employing cumbersome native LUA menus, the key that launches telemetry on the primary screen (usually a *long press* of the **[TELE]** button) will centrally invoke a native setup menu for RCIC that overlays the ongoing graphical display action.

To cycle or close, press the same invocation key. The interactable data of the setup box are the following:
1. **UPDATE RATE:** Recalculation module/thousandths (chronological axes / `x ms`); the smaller it is, the more CPU load it demands, the higher the less sensitive but smoother the machine.
2. **BAT ALERT:** Toggle to turn on/off (`ON/OFF`) any visual/auditory battery sink alert algorithm (useful in simulators/testing).
3. **AUDIO:** Sound toggle. It will sing or numerically read the remaining voltage, skipping just using hardware base acoustic tones.
4. **ALERT INT. (Alarm Intervention):** Timed pause between chants so as not to incessantly saturate your radio's auditory buffer if it rises or falls with the wind or aggressive aileron use.
5. **ALERT STEP:** Constant voltage decay between repetitions. For example; a *Step* set to `.10v` indicates the transmitter to sing your voltage by voice only if your battery descends an extra static total with respect to the past warning (e.g.: dropped to "3.61v", warn. It will sing a drop again only when it reads \~"3.51v" or less).

> 💡 *Use within Configuration Mode:* Move the cursor with **[+]** and **[-]**. When you want to change a specific value, press **[ENTER]**, noting that the inverted text will jump from the category to the value itself. There you rotate to define the amount in numbers, then you use **[ENTER]** or the return button **[RTN]** again. Closing this final menu ([TELE] key), we trigger a persistent micro-level safeguard on your SD card (creates a small text file in `/SCRIPTS/TELEMETRY/rcic.cfg`). You can now safely turn off the controller, all parameters will be identical tomorrow.

---

## Quick Installation

1. Settle your model and fully download the original `rcic.lua` file.
2. Enable USB to computer if using Companion / Cable; choose "USB Storage" (SD Card Mode) on your Radio.
3. Enter the standard internal structure and open the parent folder `/SCRIPTS/TELEMETRY/`.
4. Copy the aforementioned file there (the auto-seeded config file does not exist until normal use, it is natural).
5. Disconnect in *Safe USB* mode, return to your EdgeTX controller and make sure to go to the physical preferences of the selected model (Typically pressing *MDL* briefly once).
6. Press to turn pages (Page >) to the *TELEMETRY* or *DISPLAYS* settings.
7. Configure *Screen 1* by changing from "Nums/Bars" to **"Script"**, then selecting the destination "rcic".
8. Save properties by returning to your main piloting view, long-pressing the assigned switch. Your metrics will now look impeccable!
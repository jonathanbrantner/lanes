# Changelog

## 2.0.0 (unreleased): new interface

Version 2.0 redesigns the panel and adds temperatures, per-core details and a simpler Settings screen.

New interface
- The panel is a grid of tiles (CPU, GPU, Memory, Power, Drives, Disk), each with one big number, a short caption and a small graph. Average temperature, batteries and the rest are tiles in the same grid (or one compact row each: Settings, Panel, Rows). About half the height of the old panel.
- Click the CPU, GPU or Memory tile for its full page. The other tiles show everything there is on the tile itself.
- Graphs zoom to their own recent range with 10% headroom, so they always show detail and a spike never looks like it hits the maximum.
- Read and write arrows on the drive tiles match the menu bar: blue down, orange up.
- Settings is simpler: icon buttons for what shows in the menu bar and the panel, grouped Display and General sections, one `Off | °C | °F` control, and a separate page for the chip choice and definitions.

More in this release
- Network: download and upload for the connections in use (Wi-Fi, Ethernet; idle ones are hidden), with a tile, a page with a graph per connection, and a menu bar cell.
- Drives show free space on the tile, and a red "SMART" warning if macOS reports a drive failing.
- Batteries: the Mac's own battery on laptops and connected Bluetooth devices (AirPods, mouse, keyboard) in one strip with an arrow; click it for a page with a bar for every part (left, right, case).
- Busiest apps by CPU on the CPU page and by memory on the Memory page (read only while that page is open): readable names, helper processes added to their app, the app icon and a bar.
- Sensors page (click the Avg temp tile): CPU, GPU, memory and SSD temperatures, the chip sensors as one line (average and highest), fans and power, with every reading one click away; and a warning when macOS is throttling. The Power tile opens a Power page: draw over time, power adapter in, processor package power and GPU.
- Menu bar: Names or Icons, with red temperatures and steady widths so the bar does not bounce. The Display settings are three rows: Temperatures, Panel (Grid or Rows) and Menu bar.
- Graph hover: hover a graph on a page to see the exact value and how long ago.
- Settings: type what Activity Monitor shows and "Calibrate" corrects Memory used for that Mac (Reset undoes it). Batteries also reads Bluetooth LE keyboards such as the Logitech MX Keys and Logitech mice on a USB receiver (HID++) while the Batteries item is on; macOS may ask for Bluetooth or input access once.
- Settings: "Check accuracy" compares the memory numbers with vm_stat; the GPU tile shows the GPU core count; Memory page shows compressed memory over time.

New features
- Temperatures (CPU, GPU, SSD, and memory where the chip has a sensor), in °C or °F, plus fan speed and an average, read without admin rights. Sensor tables for M1 to M6 with an automatic chip choice.
- Cores: the CPU page shows one card per core class (Super, Performance, Efficiency) with its temperature and a small box with its own last-minute graph for every core. The GPU page shows Device, Renderer and Tiler load, GPU power, GPU memory, and a graph for each GPU temperature sensor. Per-class temperatures are checked on the M6 only.
- Definitions of the memory terms and of cores in Settings.
- `powermon --temps` lists every temperature sensor a Mac exposes, and `powermon --cluster-probe` finds which sensors belong to which core class.

Fixes
- Memory Used no longer reads about 0.5 GB low when macOS has pre-loaded (speculative) pages. It matches `vm_stat` within 0.1% again.

Also in this release
- Memory Used matches Activity Monitor's definition (was 4.8% low).
- Displayed CPU and drive speeds are averaged over a 5 s window like Activity Monitor; charts keep 1 s samples.
- `lanes-verify` checks Lanes against vm_stat, top and iostat and fails above 1% error.
- Idle footprint about 14 MB and about 0.6% CPU at a 5 second update interval (sampling on a utility queue, panel freed when closed).

## 0.3.0 (2026-11-05)

First public release.

- Menu bar icon showing memory and external drive read/write speed.
- Panel with memory breakdown, per-drive charts, optional internal disk, power, CPU, GPU.
- Settings for menu bar and panel contents, update interval, start at login.
- Idle footprint about 14 MB and 0.2% CPU.

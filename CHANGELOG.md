# Changelog

## 2.0.0 (unreleased): new interface

Version 2.0 redesigns the panel and adds temperatures, per-core details and a simpler Settings screen.

New interface
- The panel is a grid of tiles (CPU, GPU, Memory, Power, Drives, Disk), each with one big number, a short caption and a small graph. Average temperature and fan speed sit in a strip underneath. About half the height of the old panel.
- Click the CPU, GPU or Memory tile for its full page. The other tiles show everything there is on the tile itself.
- Graphs zoom to their own recent range with 10% headroom, so they always show detail and a spike never looks like it hits the maximum.
- Read and write arrows on the drive tiles match the menu bar: blue down, orange up.
- Settings is simpler: icon buttons for what shows in the menu bar and the panel, grouped Display and General sections, one `Off | °C | °F` control, and a separate page for the chip choice and definitions.

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

# Changelog

## 0.4.0 (unreleased)

- Tile graphs zoom to their own recent range, so they always show detail.
- The panel is now a grid of tiles (big number, caption, small graph, temperature). Click a tile for its full chart, cores or legend. About half the height of the old panel.
- Settings: Update every and Temperatures (Off, °C, °F) are single segmented controls; chip choice and definitions moved to their own page.
- Core details (Settings, off by default): the CPU page shows one card per core class (Super, Performance, Efficiency) with its average load graph and temperature, and a small box with its own last-minute graph for every core; the GPU page shows Device, Renderer and Tiler graphs and one graph per GPU temperature sensor. Per-cluster temperatures are checked on the M6 only.
- `powermon --cluster-probe` finds which temperature sensors belong to which core class by loading one class at a time.
- **Temperatures are now available.** CPU, GPU, SSD (and memory where the chip has a sensor) in each panel section with a small graph, plus an "Avg temp & fan" item. Definitions of the memory terms added to Settings.
- Optional Temperature item: CPU, GPU and SSD temperature plus fan speed, read without admin rights. Hidden when a Mac does not expose the sensors.
- Temperature unit (°C or °F) and chip picker in Settings (Automatic, M1 to M6, or Other / newer).
- `powermon --temps` lists every temperature sensor and SMC temperature/fan key a Mac exposes.
- Memory Used now matches Activity Monitor's definition (was 4.8% low).
- Displayed CPU and drive speeds averaged over a 5 s window like Activity Monitor; charts keep 1 s samples.
- `lanes-verify` tool: checks Lanes against vm_stat, top and iostat and fails above 1% error.
- README pictures rendered from demo data; menu bar icon text centred.
- Idle footprint cut to about 14 MB and 0.2% CPU (sampling on a utility queue, panel freed when closed).

## 0.3.0 (2026-11-05)

First public release.

- Menu bar icon showing memory and external drive read/write speed.
- Panel with memory breakdown, per-drive charts, optional internal disk, power, CPU, GPU.
- Settings for menu bar and panel contents, update interval, start at login.
- Idle footprint about 14 MB and 0.2% CPU.

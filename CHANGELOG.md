# Changelog

## 0.4.0 (unreleased)

- Optional Temperature item: CPU, GPU and SSD temperature plus fan speed, read without admin rights. Hidden when a Mac does not expose the sensors.
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

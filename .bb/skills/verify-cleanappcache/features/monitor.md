# System Monitor

Read live CPU and memory figures and check the temperature display in the native window.

## Sub-features

- `monitor-overview` renders the live CPU and memory cards.
- `monitor-sensors` renders the CPU, GPU and battery temperature status or an unavailable mark.

## How to get to it (user POV)

Choose **Monitor** in the System sidebar. The Audit launcher can open the same screen directly.

## Driving it with cac-verify

Start with the Audit app and a passing Doctor. Use `"$cac" launch --screen monitor` for the direct entry or `"$cac" press AXButton Monitor` for the sidebar.

- **Overview.** Run `"$cac" wait-for AXStaticText 'System Monitor'`, then `"$cac" shot monitor-overview`. The AX tree contains buttons whose descriptions begin with `CPU, ` and `Memory, ` followed by a reading. Confirm the figures render in the screenshot.
- **Temperature.** With the CPU card active, wait for `"$cac" wait-for AXStaticText 'Average temperature'`. Capture the CPU detail and the temperature summary. Readings show temperatures in the app, or **—** where the sensor is unavailable.
- **Change of card.** Capture the CPU state, run `"$cac" press-prefix AXButton 'Memory, '`, and capture the updated Monitor. The Memory card is highlighted and the detail uses memory units.

## Gotchas

- Monitor starts live sampling on appear. It needs no protected-folder scan. It reads the user's actual processes, volumes, and sensors. Unavailable hardware readings can be normal on Intel or a VM.
- Keep the window visible to observe live updates. The numeric parts of accessible card names change as samples arrive.
- Monitor history and any external IP setting use the persistent Audit state. The app may reuse its Audit settings from an earlier run. The OS, network, sensors and process list are shared.

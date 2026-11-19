# Storage

Read the main disk's capacity and category distribution from the landing screen.

## Sub-features

- `storage-overview` renders live used and free values.
- `storage-distribution` shows the breakdown and the selected category detail at rest.

## How to get to it (user POV)

Open CleanAppCache, which normally opens on Storage, or choose **Storage** in the System sidebar.

## Driving it with cac-verify

Launch with `"$cac" launch --screen storage` for the startup entry point, or start on Monitor for the sidebar entry point. Run Doctor and finish onboarding if needed.

- **Sidebar entry.** Run `"$cac" shot storage-before`, then `"$cac" press AXButton Storage`. Wait with `"$cac" wait-for AXStaticText Storage`.
- **Overview.** Capture `"$cac" shot storage-overview`. The AX tree shows the **Storage** heading, a **Used, …** static value, a **Free, …** static value, and **Distribution**. Check the values against the rendered figures in the same image.
- **Breakdown.** If the view shows **Analyzing storage…**, collect another capture after that progress label is gone and category rows appear under **Category**, **Share** and **Size**. The resting detail says **Pick a category to see what it is made of.** Report a stalled or partial breakdown with its current state.

## Gotchas

- Storage reads real disk and volume data, captures free-space history, and starts category measurement when opened. A protected folder or mounted volume can affect those measurements or prompt for access. Leave permissions as configured.
- Capacity is live. Assert the presence, units and consistency of the readings. The Audit app shares the same disk and mounted volumes as the operator's app.

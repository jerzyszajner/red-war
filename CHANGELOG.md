# Changelog

Changes made in Red War on top of the unmodified OpenRA `bleed` branch, oldest first.
The git history has the exact code changes.

## Flak Tank (2026-10-16)

New Allied unit for the Red Alert mod: a Medium Tank variant that adds mobile anti-air.

- Cost 1000, requires Service Depot and Radar Dome.
- Improved main gun (`90mmHV`) and two flak guns that fire alternately at aircraft.
- AI players can build it.
- Uses the original Medium Tank and Mobile Flak sprites, plus a few small new overlay files, a build icon and a wreck.

## Larger resource storage (2026-10-16)

Red Alert mod, `mods/ra/rules/structures.yaml`.

- Ore Refinery capacity: 2000 -> 20000.
- Silo capacity: 3000 -> 10000.

## Hold to queue and cancel production (2026-10-17)

Production icons in the sidebar can now be held down instead of clicked repeatedly.
Applies to all production queues (infantry, vehicles, aircraft, ships, buildings).
Implemented in `ProductionPaletteWidget`.

- **Hold left button:** keeps adding items to the queue, starting at 4 per second and accelerating to 20 per second after 3 seconds.
  Stops when you release, run out of money, the queue is full, or the item is on hold.
- **Hold right button:** keeps cancelling items at the same pace. This starts only after an item was cancelled,
  so the first right click still puts a running item on hold.
- **Left click while holding right:** cancels all queued items of that type at once.
- Shift+click (5 items) and the other click behaviors are unchanged.

## Repair All button (2026-10-22)

New button in the Red Alert sidebar, right next to Repair. Implemented in `RepairAllOrderButtonLogic`.

- **Click:** starts repairs on every damaged building you own that is not being repaired yet.
  Costs and speed are the same as repairing each building by hand.
- **Click again while repairs run:** stops the repairs.
- The icon (two wrenches, built from the Repair icon) lights up amber like the Repair button while any building is being repaired.
- **Hotkey:** Shift+C (`RepairAll`, can be changed in the settings).
- A batch of orders plays the "Repairing" notification once instead of once per building.

## Oil Spill bots (2026-11-01)

Bots can be added on the Oil Spill map and play its oil derrick fight with engineers and boats.
Implemented in the map script `mods/ra/maps/oil-spill/oil-spill.lua`, so it applies to this map only.

- Capture neutral oil derricks and Forward Command Posts with engineers carried by transports, and retake them when lost.
- Skip defended targets, and land boats only next to open ground.
- Warships escort the transports.
- Bots can build defences while short on cash.

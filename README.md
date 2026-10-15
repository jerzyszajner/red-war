# Red War

Red War is a personal real-time strategy project built on top of the [OpenRA](https://www.openra.net) engine.
It started as a copy of OpenRA and is being reshaped step by step as a way to learn how such a game is put together
and to see what can be achieved by changing it.

> **This project is not affiliated with, endorsed by or supported by the OpenRA project or Electronic Arts.**
> It is an independent fork and I am not collaborating with the upstream project.

## What is different from OpenRA

Everything below is on top of the unmodified OpenRA `bleed` branch as of October 2026.

### Flak Tank (Allies, Red Alert mod)

A support tank that fills the Allies' missing mobile anti-air role.

| | Medium Tank | Flak Tank |
|---|---|---|
| Cost | 850 | 1000 |
| Health | 46000 | 46000 |
| Requires | Service Depot | Service Depot and Radar Dome |
| Main gun | 90mm | improved 90mm (`90mmHV`): 5200 damage, 6 cell range, splash 192 |
| Anti-air | none | two independent flak guns that fire alternately |

- The hull and turret use the original Medium Tank sprites, and the flak guns use the Mobile Flak turret sprites.
  Only small overlays (a lengthened barrel and rear antennas), the build icon and a dedicated wreck are new files.
- Each flak gun has its own turret and recoil. The main gun has a longer barrel to match its longer range.

## Building and running

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). Then:

```
make
./launch-game.sh Game.Mod=ra
```

See [INSTALL.md](INSTALL.md) for platform specific notes (Windows, Linux, macOS), and run `make help` for more targets
(`make check` for style checks, `make test` for YAML checks, `make tests` for the unit tests).

## Original game content

The sprites, sounds and music of the original Red Alert are **not** part of this repository and are not redistributed.
On first start the game offers to install the content, either from your own copy of the original game or via its
content installer. Without that content the game cannot show the original graphics.

## Multiplayer

Multiplayer still works, but only between players running the **same build of this project**.
The rules differ from official OpenRA, so this version cannot join official OpenRA games, and official clients
cannot join games hosted from this version. Every player must use exactly the same code, otherwise a match will
go out of sync.

To play with a friend: one player hosts (`Multiplayer` -> `Host`), the others join by IP address or over the local network.

## License and credits

This project is free software released under the terms of the
[GNU General Public License, version 3 or later](COPYING), the same license as OpenRA.

- The engine and most of the game data are the work of the [OpenRA developers and contributors](AUTHORS).
  Their copyright notices are kept in the source files.
- Modified in 2026 by Jerzy Szajner (see the git history for the exact changes).
- *Command & Conquer* and *Red Alert* are trademarks of Electronic Arts. They are mentioned here only to describe
  the games this project is based on.

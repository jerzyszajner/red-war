# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

OpenRA is a C#/.NET RTS engine (GPLv3) with mods recreating Red Alert (`ra`), Tiberian Dawn (`cnc`), Dune 2000 (`d2k`) and Tiberian Sun (`ts`). Main branch is `bleed`. Contributions: rebase on `bleed`, add yourself to `AUTHORS`, follow the wiki Coding Standard (style is enforced by `.editorconfig` and `make check`).

## Commands

- Build: `make` (Release; `make CONFIGURATION=Debug`, `make DEPENDENCIES=system` for system native libs). Output goes to `bin/`. Equivalent without make: `dotnet build -c Debug -p:TargetPlatform=<rid>` (e.g. `osx-arm64`).
- Run game: `./launch-game.sh` (add `Game.Mod=ra`); dedicated server: `./launch-dedicated.sh`.
- Style / lint: `make check` (Debug build with `-warnaserror`, plus explicit-interface and conditional-trait-interface checks via `utility.sh`).
- YAML validation of all mods: `make test` (runs `./utility.sh <mod> --check-yaml`; run one mod, e.g. `./utility.sh ra --check-yaml`).
- Unit tests (NUnit): `make tests`. Single test: after building `OpenRA.Test`, `dotnet test bin/OpenRA.Test.dll --test-adapter-path:. --filter "FullyQualifiedName~MapPlayersTest"`.
- Lua syntax check: `make check-scripts` (needs `luac`).
- Utility CLI: `./utility.sh <mod> --help` (map tools, yaml checks, doc generation, update rules).

## Architecture

- `OpenRA.Game` — the engine core: `Game`, `ModData`, `Manifest`, `World`/`Actor`, networking/`Server`, `Graphics`/`Renderer`, `Map`, `MiniYaml`, `FieldLoader` (reflection-based YAML→object loading), `FluentBundle` (localization).
- `OpenRA.Mods.Common` — the shared gameplay library: nearly all traits (`Traits/`), activities, warheads, projectiles, widgets, pathfinder, Lua scripting bindings, lint checks, update rules, utility commands. Mod-specific code lives in `OpenRA.Mods.Cnc` and `OpenRA.Mods.D2k`.
- `OpenRA.Platforms.Default` — SDL/OpenGL platform layer; `OpenRA.Server` dedicated server; `OpenRA.Utility` CLI; `OpenRA.Launcher`/`OpenRA.WindowsLauncher` launchers; `OpenRA.Test` NUnit tests.
- `mods/<name>/` — data-driven content. `mod.yaml` is the manifest pointing at `rules/`, `sequences/`, `weapons/`, `chrome/` (UI widgets), `fluent/` (`.ftl` strings), `maps/`, `scripts/` (Lua). `mods/common` and `mods/all` hold shared definitions inherited by the others.
- Trait system: actors are composed in MiniYAML of `*Info` classes (trait definitions) that create runtime trait instances; behaviour is wired through interfaces in `TraitsInterfaces.cs` (Game and Mods.Common). Trait fields are loaded by `FieldLoader`, so renaming a field/trait is a breaking change requiring an update rule in `OpenRA.Mods.Common/UpdateRules` for mod/map compatibility.
- Engine modules are found via `ObjectCreator` reflection by class name from YAML, so classes must be public and named exactly as referenced.

## Conventions

- Trait interface implementations must be explicit/implicit per the rules checked by `make check` (explicit interface violations and conditional-trait overrides fail CI).
- Repo uses tabs and UTF-8; `.editorconfig` is authoritative.

# MultiLibrairies

Play your Epic Games library inside Steam. Every game you own on Epic shows up in
your Steam library with its artwork, and you install, launch and track it without
ever leaving the client.

> [!IMPORTANT]
> This plugin is young. It has not been tested on every Steam build, and it
> patches parts of Steam's interface to work. Expect rough edges. If something
> breaks, the [troubleshooting](#troubleshooting) section below is the first
> place to look.

## Features

- Every Epic game in your Steam library, with an Epic badge on the tiles
- Install, update, pause and uninstall games from Steam, with progress on the tiles
- Launch from Steam with playtime tracking, "Currently playing" and the overlay
- Full artwork: box art, heroes, headers and icons
- Epic achievements on the game page and in Steam's achievements page
- Cloud saves, synced automatically when a game closes
- Epic downloads shown in Steam's own Downloads page, with pause/resume and cancel
- Uninstalled games look like uninstalled Steam games: greyed out, with an Install button
- Sizes counted in Steam's **Settings ▸ Storage** page
- Your Epic games grouped in the Store dropdown, next to Steam's own store

## Requirements

| You need | Where | Why |
|---|---|---|
| [Millennium](https://steambrew.app/) | Windows and Linux | The plugin loader for Steam — install it first |
| Sign in to Epic from the plugin panel | Windows and Linux | The plugin reads your library through it |
| [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher) | **Linux only** | Lets games run through the same Proton Steam already has |

**Nothing else.** The plugin downloads
[Legendary](https://github.com/derrod/legendary) — the tool that talks to Epic —
the first time it runs. You do not need the Epic Games Launcher installed, and
you do not need to own anything standalone.

## Windows vs Linux

**Windows users: you are fine.** Windows runs Epic's games natively, so the
plugin just launches each game's own `.exe` directly. No Proton, no Wine, no
extra tools — install Millennium, sign in to Epic from the plugin panel, and
play.

**Linux users:** Epic games are Windows programs, so they need translating.
The plugin does this through [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher),
which runs the game through the **same Proton** Steam already has installed —
so you get the Proton version you chose, its compatibility data, and Steam's
overlay, just like any Steam game. Games will not start if `umu-run` is missing
from your system; install it, or the plugin falls back to plain Wine, which
most machines do not have.

You never pick a Proton build inside the plugin. **Steam's own compatibility
settings decide** — the game's _Properties ▸ Compatibility_ first, then
_Settings ▸ Compatibility_ as the global default. Change the build in Steam and
the change is picked up on the very next launch, no sync or restart needed.

On SteamOS / Bazzite / Nobara, `umu-launcher` is usually preinstalled or
available as an easy package install from your system's app store.

## Setup

1. Install [Millennium](https://steambrew.app/) and restart Steam.
2. Download the plugin — either from the [release](https://github.com/PissenlitVert/MultiLibrairies/releases)
   (unpack it into `~/.local/share/millennium/plugins/` or the Windows plugin
   folder), or by cloning this repository into that same plugins folder.
3. Open Steam again. The plugin appears in Millennium's plugin list; open the
   **Epic Games** panel from it.
4. Press **Sign in**. Epic's login page opens in a Steam tab; sign in as usual.
   You'll get a block of text — copy all of it, paste it into the panel, press
   **Continue**.
5. Press **Sync**. Every game in your Epic library appears in your Steam library.

That's the whole routine. The first sync on a large account takes a few minutes;
after that it picks up only what changed.

The panel has four buttons and no more: **Sign in** and **Sign out** (the
account line), **Sync**, and **Remove everything**. **Remove everything** asks
first, and it deletes no installed files either — it only removes the
shortcuts and artwork out of Steam until the next Sync restores them.

## Troubleshooting

**Where the plugin writes what it's doing** — `backend/data/trace.log` (relative
to the plugin folder), one line per event. Everything the backend, the frontend
and the launcher say shows up here.

**A game does not start on Linux.** Check that `umu-run` is on your `PATH`. If
it is, use the plugin panel's **Show launch log** — Steam gives a non-Steam game
no window or console of its own, so this log is where anything that went wrong
is written out, along with what the launcher and Proton actually printed.

**My games are missing / don't sync.** Press **Sync** again from the plugin
panel. If individual games are still missing, check the plugin's log for the
game's name — catalog problems usually mean a new game just got added and the
plugin didn't fetch it yet.

**Legendary won't download.** Rare, but it happens behind firewalls — the
plugin retries on its own the next time Steam starts.

Want more detail on _how_ any of this works — the patches, the shortcuts, the
storage and install manifests, the deep Proton setup on Linux, all of it? The
original, much bigger write-up lives in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Known issues

**The information block (portrait, description, developer) briefly disappears while scrolling.**
Steam re-renders the page as you scroll, and the block can measure itself at zero height in
one of those passes — it comes back on its own as soon as the page settles or you scroll back.
A fix applying the height through a ResizeObserver is in this version; if you still see it,
press the ⓘ button in the play bar to collapse and re-expand the block.

## Credits

Built on [Legendary](https://github.com/derrod/legendary), powered by
[Millennium](https://steambrew.app/). This plugin wouldn't work without either.

<a href='https://ko-fi.com/X8X554X28' target='_blank'>☕ Support on Ko-fi</a>

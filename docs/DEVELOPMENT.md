# Epic Games <a href='https://ko-fi.com/X8X554X28' target='_blank'>☕</a>

A Millennium plugin that brings your Epic Games library into Steam - install, launch and track
playtime without leaving the client.

> [!IMPORTANT]
> Work in progress. The pieces below work, but this hasn't been tested on many
> Steam builds or many machines yet, and every patch it applies reaches into
> Steam's own stores. Expect rough edges, and expect them to move.

## What it does

- Every game you own on Epic appears in your Steam library, with an Epic badge on the tile
- Install, update, pause and uninstall from Steam, with progress on the library tile
- Launch from Steam, with playtime tracking, "Currently playing" and the overlay
- Full artwork: box art, heroes, headers and icons
- Epic achievements in the app details page and Steam's achievements page
- Uninstalled games behave like uninstalled Steam games - greyed out, with an Install button
- A Steam Store and an Epic Games Store group in the Store dropdown, separated from each other
- Steam's own link row and game information block on the app details page, taken from the game's own Steam version where it has one
- Your Epic games counted in Steam's own **Settings > Storage**, through the install manifests the plugin writes

## Prerequisites

- [Millennium](https://steambrew.app/)
- On Linux: [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher), so
  games launch through the Proton build Steam already has

That's it. The plugin talks to Epic through
[Legendary](https://github.com/derrod/legendary), which it downloads for you the
first time it runs.

## Linux

The plugin runs on Linux as well as Windows, and everything in the library -
installing, updating, uninstalling, progress, playtime, achievements - works the
same way. Two things are worth knowing:

**Games run through Steam's own Proton.** A shortcut points at `launch.sh`,
which the plugin writes into `backend/vendor/` and which runs `legendary` - a
Linux program, running natively - after clearing the parts of Steam's
environment a PyInstaller build does not survive. `legendary` is then told to put
`umu-run` in front of the game's own executable rather than a Wine of its own.
The game therefore starts in the Proton installation Steam manages, with the
Proton version you chose, its compatibility data, and Steam's overlay, rather
than in a separate Wine that knows nothing about any of that. (The two cannot be
swapped round: `umu-run <game-id> <command>` takes a umu _id_ as its first
argument, so a shortcut whose executable is `umu-run` would ask it to run a game
called "launch" - and it would try, inside Wine, where a Linux binary cannot
execute.)

The umu id travels as the `GAMEID` environment variable rather than as
`umu-run`'s first argument, because `umu-run` has no such argument: its synopsis
is `umu-run [FILE [ARG...]]`, and the positional it does take is the executable
to run. So the wrapper is `env GAMEID=umu-win32 /usr/bin/umu-run`, and
`legendary`'s `--wrapper` is what puts it in front of the game's own executable.

Which Proton build that id resolves to is handed to umu as `PROTONPATH`, in the
environment, at launch. **Steam's own compatibility setting decides**, and nothing
else: _Settings > Compatibility_, appid `0` — the entry that applies to every
app with no mapping of its own, so to every Epic game here.

`launch.sh` reads that setting **when the game is started**, not when the file
was written. That is the whole reason: the setting changes while Steam runs, and
a path baked into a file written at start-up is one decision behind — the build
is changed in Steam, play is pressed a moment later, and the game starts under a
different one while the app details page names the new one. So **changing the
build takes effect on the very next press of play**, with no sync, no Steam
restart, and no game failing to start while a library is rewritten.

Steam records its own builds under an internal name while the folder on disk is
a display name: `proton_experimental` is installed as `Proton - Experimental`,
`proton_11` as `Proton 11.0`. A build you installed yourself is spelled the same
in both places, which is why those always worked and Steam's own never did.

Anything else you put in `config.json` is kept, so a setting added by a later
version is not deleted by an older one writing the file back, and a file that
does not parse is ignored in favour of the defaults rather than being allowed to
stop games from starting.

umu has no configuration file it reads by itself. It accepts `PROTON` only in a
TOML file passed to `umu-run --config`, which also requires `prefix` and `exe` to
be present and is a different mechanism entirely. Writing
`~/.config/umu-run/umu.conf` — or any umu-looking configuration — changes nothing
at all while appearing to work.

`PROTONPATH` is set by `launch.sh` rather than in the shortcut's arguments. It
was in the arguments, escaped with backslashes for the `shlex.split` that
legendary does on `--wrapper` — and that does not work. The wrapper is a single
string that Steam's launch-options splitter cuts up _first_, and Steam does not
decode backslashes on the way in, so the escaping arrived doubled and `shlex`
split `Proton\\ -\\ Experimental` into three arguments. Every Proton build's name
has a space in it, so choosing any of them broke every game. One shell and one
quoting style is the only way a path survives that trip.

It does **not** set anything in Steam's _Properties > Compatibility_ tab, and you
should not either: anything set there makes Steam run the shortcut _inside_ that
tool, and the shortcut is a shell script, which Wine cannot execute. The game then
does not start, silently.

A build is marked `- no video` when it cannot decode video on this machine. That
happens when a build's GStreamer plugins were linked against one FFmpeg and it
ships another - the plugin cannot load, so there is no decoder at all - and it
shows up as videos that never play and, for a Unity game, as
`WindowsVideoMedia error unhandled Color Standard: 0` on screen, which reads
like a graphics fault and is not one. The check is made on disk, because the
build's name says nothing: on one machine here every build but one shipped a
matching FFmpeg, and the one that did not was umu's own default.

If your intro videos do not play but the game otherwise does, this is the first
thing to check. Pick a build that is **not** marked `- no video`, sync, and try
again.

Set `EPIC_GAMES_UMU_ID` before starting Steam to pin the umu id instead (e.g.
`umu-ge-proton9-20`).

Install `umu-run` from your distribution (`pacman -S umu-launcher`,
`apt install umu-launcher`, `brew install umu-launcher`); without it, games fall
back to whatever Wine is on `PATH`, and a machine with none of either cannot
start one.

**Epic ships Windows builds**, so that is what gets installed. Anything requiring
the Windows runtime is handled by Proton as it would be for any other
non-Steam game.

One thing that does not carry over: games already installed by the Epic Games
Launcher are picked up from that launcher's manifests, which is a Windows path.
On Linux, install through the plugin and everything else follows from there.

`dev.sh` is the Linux counterpart of `dev.ps1`: it builds, deploys into your
Steam, enables the `-dev` copy and leaves the released one alone.

## Where games are installed

Into the Steam library you pick, under `steamapps/common/`:

```
<library>/steamapps/common/<game folder>
```

That is Steam's own directory for installed games, not a tidier location of the
plugin's choosing, and it is what the plugin's own accounting measures: a game is
counted by walking that one directory, so anywhere else would need a second
convention for everything - the panel, the storage page, the sizes a download is
measured against. It is also what a person deleting a game by hand expects to
find.

Steam's own **Settings -> Storage** picks it up because the plugin gives Steam an
install manifest for it - one `steamapps/appmanifest_<appid>.acf` per installed
game, written by the backend, which is the only thing that page reads. No working
directory does this; the file is the page's whole input. See _Storage, and
uninstalling_ below.

The second one has a trap in it. Epic's own `InstallLocation`, which is what
`legendary list-installed` answers with, is the folder the **executable** is in -
one level inside the game's directory for every launcher build that keeps its
binary in a subfolder, so Shogun Showdown reports

```
/var/mnt/Jeux/SteamLibrary/steamapps/common/ShogunShowdown611f6/ShogunShowdown611f6
```

when the game's own directory is the one above it. Measuring or naming that path
counts the launcher subfolder and nothing else - the manifests, the shader cache
and everything a patch dropped beside the binary are all outside it. So the path
is cut at the first directory under `steamapps/common/`, which is the same value
every time it is asked for - which is what makes it safe to do so over a whole
library on every startup, and what lets a cache written before the correction fix
itself as it is read back.

A shortcut is created before its game exists, so its working directory can only be
a placeholder at that moment. The plugin points it at the real folder as soon as
the install finishes, and once for the whole library on every startup - the second
pass is the one that matters for a game installed before any of this, and the one
that fixes every shortcut at once when the path above is corrected.

Games installed by an older version of this plugin, anywhere outside
`steamapps/common`, are measured against a folder Steam would not look in and
listed against a path nobody wrote down. Uninstall and reinstall them, or move the
folders in yourself - a shortcut's working directory has to be moved to match.

## Cloud saves

Epic keeps saves in the cloud for most of its games, and this plugin syncs them
with `legendary sync-saves`:

- automatically, when a game is closed - a session ending is the one moment a
  save is certainly different from the one on Epic's side
- from the plugin panel, where you can also sync in one direction only, for the
  day a save looks wrong on one side and you want to choose which copy wins
  before anything is overwritten
- from a game's **Manage** menu, for one game

A game Epic has no cloud saves for is left alone rather than reported as an
error, and a game whose save folder has never been confirmed is skipped by
legendary itself.

The **Manage** menu of an Epic game also carries an **Uninstall**, which Steam
leaves out for a non-Steam shortcut: its list is hardcoded per app type, and the
only way to change which one we get would be to make Steam think a shortcut is
something else everywhere else too. So the item is added to the rendered submenu
instead, and the original method is put back when the plugin unloads. Nothing is
removed — "Remove non-Steam game" drops the shortcut and un-syncs the game, which
is a different thing from uninstalling it.

It is drawn the way Steam draws one: a rule above it, separating what destroys
from what does not, and the same word Steam uses, in the user's language rather
than ours.

Both come from Steam rather than from us. The rule is `MenuSeparator`, the
component Steam's own Manage submenu draws between groups with — a `MenuItem`
would not do: it is the row class, and given no handler and no label it still
draws an empty, clickable row. The word is the token Steam's own uninstall dialog
is built from, `#UninstallDialog_Uninstall`, asked of `LocalizationManager` — the
singleton Steam renders every string of its own UI through. "Uninstall" is not
what becomes "Désinstaller" in every language Steam ships, so it is not written
here.

## Store menu

The **Store** dropdown is two groups: **Steam Store** with the entries Steam puts
there itself, and **Epic Games Store** below a rule, with the pages of Epic's own
store. Epic has no pages inside Steam, so its entries open `store.epicgames.com`
in a Steam tab.

Steam builds that dropdown as data - a list of `{ name, steamURL, visible }`,
drawn one row per entry by a component that knows nothing of submenus. So the
popup's contents are replaced rather than the list.

Every popup in the client is opened by one call, which is told what to draw, and
that call is the patch: a popup without Steam's store list in it - `#Menu_Featured`
is the first of that list and the only name Steam gives to it - is opened with
exactly what it came in with. The two groups and the rule between them are Steam's
own `MenuSeparator` and submenu component, the ones behind "Gérer >" and the rules
in Steam's menus.

Steam closes this popup 200ms after the pointer leaves it - enough for a row,
nowhere near enough to cross into a submenu beside it, where the pointer leaves
on the way. So that one handler is dropped from the Store popup; it still closes
on a click outside and on Escape, as it always did.

Steam's six entries are read back out of the list Steam built, not written again
here, so a Steam update that adds, removes or reorders one comes along, and an
entry Steam hides stays hidden. Their labels are its own tokens, and so are the
two Epic entries that name the same thing ("Actualités", "Liste de souhaits") -
so those follow the client's language. The other four are ours, Epic having no
token for them.

Everything stays in the launcher, on the same tab the store itself is drawn in.
Steam's own entries are the `steam://` links its menu rows already carry, given
to Steam's own window browser; Epic's pages go through the same call, so a link
navigates that tab rather than opening another one - which is what a menu of
links should do, and what Steam's own navigation does when it follows a link.

Not `steam://openurl`, whose handling is the client's business and which hands
the page to the system's browser here, and not `openurl_external`, which is
built for exactly that. Before the library window is up there is no browser to
open a tab on yet, so the client's `steam://` call is the fallback until then.

## App details links

Steam puts a row of links under an app's play bar - **Store page**, **Community
hub**, **Discussions**, **Guides** - and an Epic game gets none of it. The section
is drawn for every app page; what is empty is the list inside it, because Steam
gates the whole thing on the app being a real Steam game rather than a shortcut.
Nothing reachable fills that list in, so the row is drawn here instead, into the
panel Steam draws it in, using the class names Steam's own stylesheets export -
so it is Steam's own row rather than a copy of it, and it follows the styling
through a Steam update that regenerates those names.

Only the store link is the plugin's own:

- **Page du magasin** opens **Epic's own product page** for the game — its poster,
  its description, its reviews — and falls back to Epic's search for the title
  only where the store has no page under that address.

  That is not a thing the plugin can look up, and pretending otherwise is how
  this link came to be a filtered list: Epic addresses a product page by a slug,
  and the cache a real library is read from holds a title, an install path and a
  version — `legendary list` files its entries under sixteen paths and neither
  `customAttributes` nor `metadata` carries an offer id, a catalogue namespace or
  a slug. Its search endpoint refuses to say before it answers.

  So the slug is **derived from the title and then checked against the store**:
  one HTTP request, for a game whose page someone actually opens, answered once
  and remembered in `backend/data/cache/store.json`. Two things that guessing
  alone would not give: the address is _right_ rather than plausible, because a
  404 is a 404 and not a page with an error on it; and it cannot be worse than
  what it replaces, because every path out of it ends at a URL that works. A
  store that answers 429 or not at all is **not** remembered — nothing was
  learned, so the next click asks again rather than being told for ever that the
  page does not exist.

  The row is drawn while that request is on its way, with the search, and redrawn
  when the real page lands. It opens in a Steam tab, like the store menu's
  entries.

- **Hub de la communauté**, **Discussions** and **Guides** are Steam's own rows,
  at the addresses Steam's own URL table resolves them to. They are drawn only for
  a game that is also on Steam, and they point at that game's own appid: a
  non-Steam shortcut has no hub, and Steam sends its community pages to the front
  page of the store, so linking from the shortcut would always be a dead end.
  Whether a game is on Steam is asked of the store's own search - the one that
  drives the client's search box - with the client's country, language and page
  origin, and only a suggestion whose name is the game's own name counts. Asking
  Steam for the addresses rather than writing them out keeps the links right if
  Steam ever moves those pages.
- **Succès** and **Activité** jump to the sections the page is already drawing.
  They are there only when their section is: a game Epic holds no achievements for
  gets no button rather than one that does nothing. The section is found by the
  label Steam gave it, which is why the button reads in the client's language.

The row goes where Steam puts its own: inside the app's details panel, between the
block of game information and the columns of sections below it.

The row is redrawn whenever Steam re-renders the panel, which it does on every
repaint of the plugin's, and taken away again when the page is not an Epic game's.
A page for an app Steam knows is left alone as well: Steam draws its own links
there, and it places every one of them absolutely, at the left it worked out for
its own count, so a second row lands on top of the first instead of beside it.

## App details information

The block under the play bar that says what a game is - its portrait, its
description, who developed it, who published it and when it came out - is the one
Steam draws for every app and refuses for a shortcut. Opening the flag that
refuses it would not help: the panel reads Steam's description and association
stores for the app the page belongs to, and the shortcut is an app the store has
never heard of.

So it is drawn here instead, from what the store says about the game's Steam
version - which is the same app whose hub the link row below points at, so a game
that is only on Epic gets neither. The wording is the store's own, in the
client's language, and the developer and publisher are linked to the rest of
their work the way Steam links them.

Every name of a row goes in **one** box, the way Steam's own component puts them,
and that is what separates them: Steam's rule for the box is `display: flex;
flex-flow: column; flex-wrap: wrap`, so two publishers read as two lines. A box
per name puts one name in each of several flex containers, which the row lays
side by side with no gap between them - `Goblinz PublishingGamorror Games`.

It is shown the way Steam shows it - open, and directly under the play bar, as a
sibling of it, which is where Steam puts it - and the **i** button Steam draws
in the row beside the play bar to show and hide it is drawn too, since Steam
leaves that out for a shortcut along with the panel it opens. It goes in Steam's
own place in that row: after the box holding **Manage**, before the heart.

Opening and closing go through the panel's height, which is what Steam transitions
on it - `.3s`, ease in and out, with `overflow: hidden` clipping the rest. Setting
`display: none` outright instead is what made closing the one direction that did
not move: nothing is left for a transition to run on, while opening went through
the height and animated by itself.

Under that panel, in its own box, is the line Steam would have drawn for a game it
knew: **Fonctionne sur cet ordinateur via _Steam Epic Play_. Votre sélection pour
ce titre&nbsp;: …** - in French, in Steam's own shape, naming the Proton build that
actually runs the game, and, when there is one, the launch options that apply to
every game by default, so the page says which build is in use rather than leaving
it to the panel. It is drawn as the last
line of the panel's box, because that box is a grid of one row of named areas
(`portrait desc stats features`): a line drawn _in_ it takes the next free cell of
that row, and one spanning every column still lands level with the foot of the
portrait.

That box is the only place it goes. With no panel on the page yet there is nowhere
to put it, and the panel itself is the one thing that looks like somewhere: a line
appended there is the **last child of the whole page**, under the columns and
under the activity feed, a screen away from the game it is about. So nothing is
written until the panel is, and whatever an earlier pass wrote is taken back off
the page rather than left to be copied into the new box - which is how the phrase
came to sit at the foot of the page and stay there.

The press is taken on the document, in the capture phase, and tested against the
button's own rectangle. Steam re-renders the play bar and takes our node out of
the tree while the button is held down, so the click that ends the press is
dispatched to whatever is under the pointer by then - which is no longer the
button. Heard that early, the press cannot be lost that way.

The state is re-asserted on every repaint rather than written once. Steam
re-renders the play bar on its own schedule - a hover, a focus, a download
ticking over - and what it draws over the button carries none of it, so a panel
closed a moment earlier came back until the page was changed and returned to.

The panel carries **no feature chips** - no _Solo_, no _Succès_, no _Partage
familial_ - and that absence is deliberate rather than unfinished.

Epic publishes no feature list, so there is nothing on its side to copy. Read
raw, out of a 622-entry `legendary list`, Epic files entries under sixteen paths
and not one of them is a feature.

| Path                        | Entries | What it is                                                |
| --------------------------- | ------- | --------------------------------------------------------- |
| `applications`              | 552     | what Epic tags **every** product it sells, games included |
| `games`                     | 550     | the shelf the entry sits on                               |
| `public`                    | 229     | whether the entry is visible in the store                 |
| `asset-format/game-engine…` | 70      | what the download is, not what the game is                |
| `projects/completeprojects` | 13      | an engine sample, not a game                              |
| `freegames`                 | 3       | free to play                                              |
| `games/edition`             | 2       | an edition rather than the game                           |
| `digitalextras`             | 1       | downloadable content                                      |

`customAttributes` carries `FolderName`, `CloudSaveFolder` and `RequirementsJson`,
nothing about features. `metadata` carries no slug, no offer id and no catalogue
namespace, so even the store page that does list _Fonctionnalités_ cannot be
addressed for a given game without searching for it first - and the store's own
GraphQL answers `403` to a client like this one.

The only list available is Steam's, for the Steam copy of the game, and a badge
Epic does not publish is a badge about the wrong copy. They were drawn for a
while, and they were wrong: for Shogun Showdown the panel showed _Partage
familial_ where Epic says _Solo_ and nothing else.

What is true of the Epic copy, and worth the space, is the cloud - see
[Cloud saves in the play bar](#cloud-saves-in-the-play-bar).

## App details activity

What the game has been saying lately, as **Steam's own activity feed** rather than
as a list of headlines: the `ActivityFeedContainer` block headed **Activité**,
posts grouped under the day they were posted on with the date over a rule, a card
each with the publisher's picture beside its kind and headline and the two lines
of it under, the counts of comments and likes, and the **load more activity**
button at the foot.

The block goes in the page's **left hand column**, beside the achievements, the
reviews and the screenshots that Steam draws down its right hand side, which is
where the client itself puts its own feed. It has to be that column and it has
to go _below_ the right hand one: Steam lays the two out with the right column a
float, and a block that comes after a float is shortened by it, while a float
has no effect at all on what comes before it. The same block put anywhere else
on the page - above the columns, or in the spotlights row - drops to the full
width of the page and pushes the achievements down under it, which is what a
screenshot of the page cannot tell apart from the feed being too narrow.

The column is Steam's own node where the page drew one, and is made - as the
last child, in the position Steam renders it in - where the page has none, which
is the case for a page drawn for a shortcut. No position or size is set here:
the node carries the whole of the layout, and gives the feed the same two thirds
of the page less the gap that Steam gives everything it draws there. The columns
are found the way the link row above them finds them, as the child of the
panel's own frame that holds the sections, so nothing about their class names is
assumed.

The feed is `events/ajaxgetpartnereventspageable`, the endpoint the client's own
feed component reads, asked about the game's **Steam** app rather than the
shortcut - the only appid the store will answer about, since asked about a
shortcut it says "no events", which is not the same answer as "no events for this
game". It is the feed that carries what a card of this block is drawn from: the
kind of post, the headline, the text, the date, the comment andlike counts, and the publisher's own picture for the post - its capsule, out of
`jsondata`, under the clan's **account id** rather than the 64 bit SteamID the
event carries, since that is what the address is filed under and an image asked
for under the other is not found. A post with no picture is drawn in the other of
the component's two shapes, the one without one. The other feed,
`ISteamNews/GetNewsForApp`, carries a title, a URL and a source label and nothing
else, which is why this block used to be bare headlines with a source under them,
laid over one another.

Steam draws no feed on a shortcut's page - it is gated on the same flag as the
panel above it - so the block is drawn from that component's own markup and its
own class names, in the same shape the component draws it: a row, then a box in
it, then the card, with the counts in their own bar beside the row rather than
under the card. The row is not fussiness - it is what its stylesheet gives
`:first-child { height: 100% }`, so a card drawn without one is a page deciding
the height of a box it has not got.

Its class names are read out of six different sheets, each through a marker that
belongs to exactly one of them: `ActivityFeedContainer` and `AppDetailsSection`
are both filed under more than one sheet in this build, each with its own hashed
value, and the wrong sheet's value is a class the page has never heard of. The
marker has to be a _declaration_ of one - `SeekTarget:"..."` inside a table -
and not a mention of one, because a mention is what every component that draws
with the class carries, and those are the modules the search reaches first:
`Event` is declared by eight stylesheets and `RightColumn` by twelve, and the
wrong one is a real class of a sheet this page was never styled from - a rule
that exists, applied to nothing.

Two things are not Steam's, and are the whole of what is missing: the comment and
like icons, which are the store's own artwork, so the counts sit in the nodes
those icons occupy, without them; and the icon of a card with no picture, which
is one SVG per kind of post out of the client's own set. The kind of each post is
read the way the component reads it, out of the number the store answers with -
`#PartnerEvent_<that number>`, which is the string Steam itself prints for it.
An app with no feed draws nothing.

**Where a card opens.** Pressing a card opens **the client's own news page**, the
overlay that carries the post, its widgets and its comments - **over the page you
are on**, not over the library and not in a tab of the store's.

That page has no address. The client draws it out of the state of the route being
shown: `event_to_show`, an app id and a post id. Two pages read that state back
and put their own overlay up - the **app page**, which is where a card of this
block is pressed, and the **library**, which is why the same overlay appears over
the library when a card of the library's own feed is pressed.

There are two ways to write it, and they are not the same thing:

- **On the page already shown**, by the router. Steam's router is a _memory_
  router: `replace` with the path that is shown and the state it has, plus
  `event_to_show`, changes what the page shows with no address and no entry in
  the back stack - the exact mirror of what the client's own close button does
  with that state removed. The router is the one the client published in the
  store it keeps on `window`, found by that line and by nothing else.
- **Over the library**, by the navigator, which is what the client's own cards do:

  ```js
  navigator.Home({ partnerEvent: { appid, gid } });
  ```

  which navigates to the library route with that state in it. Every news card of
  the library's own feed is pressed that way - the card in the feed, the item
  under **Terminé récemment**, the row of the news popup - so this is the client's
  own way in and not one that was found.

The first is what a card of this block uses, because a card of this block is on
the app page and the reader should stay there. The second is the fallback for a
build where the router cannot be reached, and the store's page is the last
resort of all - with a warning saying which of the three happened.

The navigator is normally a React hook, reading a context the client fills in
around its own tree. Beside it the module holds a plain function that asks the
window store for the active window's navigator and falls back to the one the
routing store published on `window`, and it is found by the error it prints when
there is none - a string that is in that one function and nowhere else. It is
told apart from the hook beside it by what it returns: calling the hook outside
a component throws, and that is caught rather than believed.

What does _not_ reach the overlay is the address on the card itself. The title of
every news card of the client is an external link,
`steam://openurl/https://store.steampowered.com/news/app/<app>/view/<post>`,
because the component that draws it asks a context whether it may navigate in
client and that context is `false` by default and never provided in this build.
The client's own handler for that scheme (`module 89748`) answers its `openurl`
row with `navigate.SteamWeb(url)`, so that address opens the store's page for the
post in the launcher - which is the whole of what a card is _not_ to do here.

So the store's page is kept as the **last resort** of `openNewsPost`, and the
navigator as the one before it.

## Cloud saves in the play bar

The tell that **the Epic copy** of the game keeps its saves in the cloud, drawn
in the play bar as one of Steam's own stats.

Steam draws that stat itself for any app the store holds data for. It does not
for this one, and not by accident: in the client's own play-bar component, the
cloud stat returns nothing for a mod or a shortcut, and the wrapper around it
only draws when the cloud is enabled for the app, for the account and for local
content. An Epic game is a shortcut, so the row says nothing at all. What it
would say is known: it is in the catalogue entry Epic hands the backend, which is
where the plugin's own cloud counter already reads it.

So it is drawn as the client draws it - the same component's output, rebuilt
node for node: `SuperimposedGridItems`/`Visible`/`GameStat` on the wrapper,
`GameStatIconForced`/`PlaytimeIconForced` on the icon box, Steam's own
`CloudIconSVG` and the path it carries, `HideWhenNarrow`/`GameStatRight` around
`PlayBarLabel` and `PlayBarDetailLabel`, and Steam's own tokens for the words.
It goes beside the play button: the play bar's row is
`[play button] [stats] [⚙ ⓘ 🎮 ♥]`, and this one is put in in front of the stats
box, so it sits immediately after the thing that starts the game.

Each class is written as the pair the client writes - the hashed name its
stylesheet exports _and_ the plain name it is filed under - because a node
carrying only one of the two is styled by half the rules the original gets.

And because the rest of its layout lives in descendant rules that key off
those same hashed names (`.GameStat .GameStatRight`, `.PlayBarLabel`, and so
on), the handful of declarations that make it legible are set outright on the
nodes, with the values the client itself declares for them. A node that misses
one of those rules collapses to its icon with the words nowhere to be seen.

It is drawn either way. A game Epic does not sync gets the very same cloud with a
bar struck across it and the value Steam shows for a cloud that is not there,
because no stat at all reads as "nobody knows" - and here the answer is a
definite no, which is the question the stat is there to answer.

## What a game will actually start with

On the app details page, the plugin says which Proton build the game really gets,
and what is put in front of it. The line is the last thing in the box the panel
is drawn in, wearing Steam's own **"Works on this computer via …"** container
class - which is where Steam draws that line itself: in its own component it is
a child of the box and not of the grid, after the grid and after whatever else
the box holds. Nothing about the type is the plugin's: the box gives the line
Steam's `font-size: 13px` and `#808486`, and the container class carries
`white-space: pre` and `margin-inline-start: 8px`.

A child of the grid would be somewhere else entirely. That grid has one row of
named areas, `portrait desc stats features`, so a line drawn in it takes the
next free cell of the first row, and one spanning every column still lands level
with the foot of the portrait - a row too high, with a font size guessed to
match. The panel's own height is measured on the box rather than on the grid for
the same reason: the line is below the grid, and a height measured without it
would be a panel with its last line cut off.

Steam's own line is read and never written to. It is a node in a React tree, and
the reconciler takes out of the tree any child of a node it re-renders that it
did not draw itself, so a line written inside Steam's line went out with it and
the answer then spent every pass after that looking for somewhere else to be -
drawn in Steam's line, then under the panel, then in Steam's again, once a
second, which was the flickering. There is now one place to be, and it does not
depend on what Steam happened to draw.

Steam's line names the compatibility tool the _shortcut_ is set to, which is a
different question from the one it looks like. Steam starts a non-Steam shortcut
**inside** whatever tool it is mapped to, and the plugin's own build only decides
anything when Steam is not overriding it - so the two can disagree, and when they
do, only the plugin knows which one wins. The answer is resolved in this order:
the tool Steam has mapped to **this** title, then Steam's global tool, then the
build chosen in the panel, then umu's own default. Nothing is written until the
build has actually been read, rather than written with a guess in it.

Both answers are read once and kept (`state/umu.ts`). The details page draws this
on every pass of `sync`, and `sync` runs off a `MutationObserver` over the same
subtree, so asking the backend each time would be a call a frame, for an answer
that only changes when a setting is changed in the panel - which is also what
tells the open page to redraw it. The observer also ignores the nodes the plugin
draws itself, since a line that rewrote itself would ask for the pass that
rewrites it; a node _taken out_ of the page still counts, since Steam dropping
one of the plugin's panels is exactly what the next pass is for.

The wording is French, and Steam's own shape rather than a note somebody left: the
same sentence Steam would have drawn, with the same emphasis, naming **Steam
Epic Play** rather than Steam Play, since a non-Steam shortcut reaching a Proton
build at all is this plugin's doing and not Steam's.

## Achievements

Epic achievements are shown on the app details page and in Steam's own
achievements page, with Epic's rarity and unlock dates. They are read from Epic
rather than tracked locally, so they are correct for whichever account is signed
in, and a game played outside Steam is still counted once its session ends.

**Succès takes a while to appear the first time.** The section is Steam's, and
Steam does not draw it for a shortcut at all - so until Epic answers, there is
nothing on the page to draw it with, and the read that answers costs one
`legendary achievements` run, which is a process launch and a round trip to Epic
through the one Lua state every other call shares. It is seconds, and it is once
per game: after that the answer is on disk and the section is there on the next
render. What is _not_ acceptable is a game that never gets one, which is what an
answer saying "no achievements" used to turn into - the backend keeps that
answer on disk and hands it back without asking Epic again, so an empty answer
is now dated like any other and a game is re-read once its cached answer is more
than ten minutes old.

The **"this game is not on Steam"** notice Steam draws above the sections of a
shortcut is removed, for every game of ours and whether or not Epic has answered
yet - it is the one thing on the page the plugin makes untrue, and leaving it up
while the section above it filled in said the opposite of what was happening.

## Setup

1. Open the **Epic Games** panel from Millennium's plugin list.
2. Press **Sign in**. Epic's login page opens in a Steam tab.
3. Sign in on Epic's website as usual. It ends on a page showing a block of
   text: select all of it, copy it, paste it into the panel, and press
   **Continue**.
4. Press **Sync**.

The panel has four things on it and no more: **Sign in** and **Sign out** (the
account line), **Sync**, and **Remove everything**. Anything else it used to
carry has a better home — the sizes are on Steam's own storage page, a game's
cloud saves sync themselves when it exits and are one item away in Steam's
**Manage** menu, and uninstalling is next to **Install** on the tile.

**Sync** reads Epic again — not the plugin's cache, so a game bought since the
last read is picked up — and then makes Steam match: shortcuts for what is
missing, removed for what is no longer on the account, artwork fetched once.
It then re-applies the housekeeping a restart of Steam used to be needed for:
every installed shortcut's working directory is pointed at its game folder, the
install manifests are rewritten so Steam's **Settings > Storage** counts the
games right away, and the cached achievement counts are re-seeded.

**Remove everything** asks first, and takes out every Epic shortcut the plugin
created, the icons it wrote and the install manifests it put in
`steamapps/appmanifest_`. **Your games are not uninstalled and nothing is
deleted from disk**: the shortcut goes, the game stays where it is, and **Sync**
puts the shortcut back. Signing out of Epic is separate, and signing out is not
the same as removing — the library is read again either way.

If the browser did not open, the panel shows the address to open by hand under
**If the page did not open**.

The first run takes a few minutes on a large account. After that it only picks
up what's changed.

> [!NOTE]
> The code Epic gives you is good for one use and expires quickly. If
> **Continue** doesn't work, press **Sign in** again for a fresh one.

> [!TIP]
> A rejected code costs you nothing: Legendary clears the stored session before
> it tries a code, so the plugin copies that session aside first and puts it
> back if the code turns out to be bad. You stay signed in to whatever you were
> signed in to before.

## Notes & Troubleshooting

### Where the plugin writes what it is doing

`backend/data/trace.log`, one line per event, oldest first:

```
tail -f ~/.local/share/millennium/plugins/steam-epic-games-nathan/backend/data/trace.log
```

It holds the backend's own breadcrumbs - every RPC, every job, every anomaly -
and, since the frontend log was wired to it, everything the browser half says
too. Those lines start with a build marker (the date in `BUILD`, above), which is the answer
to "is Steam still running the build I just made": a plugin is read when Steam
starts it and not before, so anything on screen may be a bundle that was
replaced hours earlier. The app details patches write one line per draw saying
which slot the panel went into and how tall it came out, and one line per repaint
saying which Steam app was matched and what came back for it.

### Why does a terminal flash on screen when Steam starts?

On Windows: Steam gives Legendary nowhere to run, so the plugin starts a hidden
background helper when Steam loads and runs every command through that instead.
Starting it is the one thing that can't be hidden, hence the flash. You should
only see it once per Steam launch. On Linux there is no window to hide and no
daemon: commands are run through `/bin/sh` directly.

### Games will not start on Linux

Check that `umu-run` is on your `PATH`. Without it the plugin launches through
plain Wine, which most machines do not have; the plugin says so in the logs when
it cannot find it.

**Show launch log**, in the panel's menu, is the first thing to try. Steam gives
a non-Steam shortcut no window and no console, so a launch that fails normally
leaves nothing anywhere - not on screen, and in Steam's own logs only a process
appearing and going away again. That menu item puts the last few launches into
the plugin's log file, where whatever went wrong is written out in full.

**Diagnose a game** answers the same question without waiting for a failure. It
runs the real chain with `--dry-run`, which does all of legendary's own work and
stops just before it spawns anything, so the command it _would_ have run comes
back in full - the Proton wrapper, the game's own executable, and the Epic
authentication arguments. It then reads `shortcuts.vdf` back and reports the
program, arguments, working directory and icon Steam really holds for that
shortcut. Both halves go to the log in full.

Whichever you use, `backend/launch.log` is written by `launch.sh` on every
launch and contains, in order: the environment exactly as Steam handed it over,
`argv` and the working directory, the umu configuration as resolved (`GAMEID`,
`PROTONPATH`, `WINEPREFIX`, the contents of `backend/data/config.json`, and
whether `umu-run` is on `PATH` at all), the environment after cleaning, then
everything legendary and Proton print, and the exit code. The first of those is
the one that cannot be recovered afterwards.

### Which Proton build will my games use?

**Steam's own setting, and only Steam's own.** There is no second copy of it in
the plugin: no panel field, no `config.json` key, nothing that can disagree with
what Steam says. In priority order:

1. **The game's own Properties** — a tool set for one game in _Properties >
   Compatibility_ is that game's build. `launch.sh` finds it by `SteamAppId`,
   the appid Steam puts in the environment when it starts a shortcut, which is
   the same key Steam keeps the setting under — not the Epic app id, which is a
   different number in a different space.
2. **Steam's global default** — _Settings > Compatibility_, appid `0`. This is
   what the games with no entry of their own get, and it is also what a game
   gets when Steam exports no appid at all.
3. **umu's own build** — when Steam is set to **No tool**, or names a build that
   is not installed on this machine. Both are written to the launch log.

So choosing a build on one game's Properties changes that game and nothing else,
and it takes effect on the next press of play — the script reads both entries
when the game starts, not when the script was written.

**A tool set in Steam's _Compatibility_ tab works either way.** It makes Steam
start that shortcut inside that build's container, which used to be the one way
to guarantee a game would not start, because this plugin's program is
`launch.sh`, a shell script, and umu cannot be used in there:

```
env: '/usr/bin/umu-run': No such file or directory
```

said about a program that is installed and that runs, because the container has
replaced the environment it is looked up in.

So `launch.sh` no longer refuses that case. When it finds itself inside a
container it runs the game itself, through **the Proton that is already running**:
that build's own `wine` is the first thing on the `PATH` there, the prefix Steam
created for the shortcut is the one it uses, and the game starts. That is
priority 1 above, and it is why a per-game choice in Steam beats everything
else here — exactly as it beats everything else for a Steam game.

Two consequences worth knowing:

- The game is started directly by `wine`, not through umu, so umu's game-id
  database and Proton's `protonfixes` do not apply on that route. A game that
  needs one of them can still fail there; setting that game's Compatibility to
  **No tool** puts it back on the umu route with the panel's build.
- The executable is not guessed. Epic's manifests are encrypted, so the plugin
  asks `legendary info` once per installed game and writes the answer to
  `backend/data/cache/exes/<app id>`. Until that file exists for a game, a launch
  inside a container stops with a line saying so rather than starting a prefix
  with nothing to run.

With Compatibility set to **No tool** — the usual case — priorities 2 and 3
apply, and `launch.sh` works out which at every launch.

**Changing the build takes effect immediately**, because it is read at launch
rather than written into the file or into each shortcut's arguments. There is
nothing in Steam to bring up to date and no sync to wait for.

It used to rewrite all 548 shortcuts anyway, and that was the bug behind
"changing the Proton breaks the game": the rewrites were useless, they took
minutes, and a press of play during the progress bar got a game that did not
start.

Builds that cannot decode video are marked. Such a build starts the game and
plays it perfectly, and shows no intro video — the symptom is videos that never
appear and, on a Unity game, a `WindowsVideoMedia error unhandled Color
Standard: 0` message that reads like a graphics fault.

### MangoHud, gamemode, gamescope

**Per game, in Steam's own box.** Open the game's _Propriétés_ → _Raccourci_ →
**OPTIONS DE LANCEMENT**, and write whatever you would on a Windows game:

```
mangohud=1
mangohud=1 gamemoderun
gamescope --fsr
mangohud=1 %command%
```

That box is yours alone now. The plugin writes nothing in it, nothing overwrites
it at the next sync, and what is in it goes in front of **that** game only —
which is what makes MangoHud a choice per game rather than a setting for all
551 of them.

It works because of where those words land. Each game's own program in `~/.local/bin`
carries the game's id, so the words arriving with it are unambiguous, and
`launch.sh` puts them in front of umu-run in the wrapper rather than passing
them to legendary as arguments it would ignore:

```
OSError: [Errno 8] Exec format error: '…/RiverCityGirls.exe'
```

— which is what happened when they were appended after the whole command, leaving
the game to be launched directly with no Proton at all.

`%command%` is Steam's placeholder for the game itself. It is accepted and
dropped: the game is already what gets run, so the placeholder is already
honoured, and a literal `%command%` handed to the game would be an argument
nobody asked for.

What is refused is anything the shell would read as more than a word — a quote,
`$`, `;`, `&`, `|`, `<`, `>`, a backslash. Those survive one parser and are
re-read by the next; `mangohud; rm -rf ~` is not a launch option. It is named in
`backend/launch.log` and dropped, and the game still starts.

**A default for every game** is still available, for the words you want
everywhere. `backend/data/config.json` — the panel has no field for it:

```json
{ "launch_options": "mangohud=1" }
```

It applies only to the games whose own box says nothing. Edit the file and
**restart Steam**: the launch script is rewritten from that file every time the
plugin loads. The backend method that writes it, `RPC.SetLaunchOptions`, is still
there for anyone driving the plugin from the console, now that no button in the
panel calls it.

Flags go in the environment instead — `GAMEMODERATE`, `MANGOHUD_CONFIG` and the
rest work as they do on any other game.

### What Steam runs when you press play

Steam shows a non-Steam game's _Properties > Shortcut > Target_ and _Start in_
verbatim, and neither of them may be empty: Steam `execve`s the target, so an
empty one is a game whose _Jouer_ button does nothing, silently. What they can
be is the game itself. For an installed game they read:

```
/var/mnt/Jeux/SteamLibrary/steamapps/common/SpiderFoxflDwt/.steam-epic-play.sh
/var/mnt/Jeux/SteamLibrary/steamapps/common/SpiderFoxflDwt
```

**One small program per game, in the game's own folder.** Its whole content is:

```sh
#!/bin/sh
exec '…/backend/vendor/launch.sh' --game '1415ab21633c4687a7ddcfefdee87610' "$@"
```

It is a program rather than a link to the shared script because it has to carry
something a link cannot: **which game it starts**. `launch.sh` is shared by all
551 of them, so the game's id used to travel in the shortcut's launch options —
which is why that box was never empty, why anything typed in it was gone again at
the next sync, and why the target used to say `steam-epic-play` 551 times over
instead of saying which game.

The game's own folder is where it goes because it is the only place on the
machine that is already this game's, and it settles two things that had to be
worked around before: **nothing has to be disambiguated**, because two games
cannot collide in two different folders, and **uninstalling takes the file with
it**, rather than leaving it in a `bin` directory for the rest of the machine's
life. It is a dotfile, because several tools walk a game folder and show what is
in it, and a launcher is none of their business.

Before the game is installed there is no folder to write in — a shortcut is made
first, on purpose, so it exists before its game does — and the target is then
`~/.local/bin/epic-<game>`. `epic-` in front because that directory is on
`PATH`: a game called _Steam_ or _ls_ must not become the command a shell finds
first. Two games that slug to the same name get the game's own id added rather
than sharing a file, and the name a game is first given is the name it keeps, so
a sync does not rewrite the library every time.

A home it cannot write, a `bin` it cannot create, or three names already
belonging to other games all leave the shortcut pointing at the shared
`launch.sh`, which is the old behaviour and starts games.

Shortcut **OPTIONS DE LANCEMENT** is empty by design. For a shortcut written
before these programs existed — `steam-epic-play` with `launch <id>` beside it —
`launch.sh` still reads the id out of there, so those keep starting across the
upgrade; the next sync replaces them.

Menu → **Show what Steam runs** prints the same chain into the log, and the
**Diagnose a game** item runs it without starting anything.

### Downloads

The panel lists every Epic download in flight, with the box art, the
percentage, the speed, the time left, and **Pause**, **Resume** and **Cancel**.
The pause is real: legendary has no pause of its own, so the download is stopped
and resumed from where it stopped, and nothing already fetched is thrown away.

**They appear in Steam's own downloads page too.** Settings ▸ Downloads lists
the Epic install in **Active** or **Queued** with the game's artwork, its name,
a live percentage, the time left and the network graph, and the row's **Pause**,
**Resume** and the ✕ drive the Epic download rather than Steam's — Steam knows
nothing about this appid, so the call is turned into the plugin's own before it
reaches the client.

That page is drawn from `downloadsStore.m_DownloadItems`, the list of items the
client is transferring, and it is a different thing from the overview object
that drives the app page's bar. The plugin writes both: the item goes into the
list, the overview says _which_ download is current. Steam republishes its own
list on every change to any download and that replaces the list wholesale, so
the item is re-asserted on every repaint — about once a second while something
is downloading, which is also how often the bar moves. When the install stops,
the row goes with it; Steam's own rows are never touched.

Writing the list is not enough to move a row: the downloads page does not watch
`m_DownloadItems`, it listens to `downloadsStore.m_fnCallbackDownloadItemsChanged`,
which is what Steam dispatches at the end of its own `OnDownloadItems`. So every
write here dispatches too. Without it the row still moves into the store and the
page goes on drawing the finished download as active — masked for as long as
Steam republishes the list on every progress tick, and visible at exactly the
wrong moment, when the download ends and Steam has nothing left to publish.

When the download ends it goes to Steam's **Terminé** section, with its date,
rather than disappearing — it stays there for an hour (or until **Tout effacer**,
which clears it along with Steam's own), and pressing the row's ✕ cancels it
instead, which is what a dismissal is for.

The banner across the top of the Active section is the wide, blurred background
Steam draws for an app it believes has a hero, and it decides that from a single
flag, `bHasHeroImage`, which `GetHeroImages` fills in from exactly one place:
the app's **store** assets, `GetAppDetails(appid).libraryAssets.strHeroImage`. A
non-Steam shortcut has no store, so the flag is false for every Epic game and the
page keeps its `NoHeroImage` layout — a short header behind the icon and the
name. Custom artwork alone does not change that: it is merged into the list of
image _sources_ to try, and the flag never looks at it. That is why a tile can
look right while the banner stays grey.

So the plugin fills in that one missing field, for its own appids only, and only
where it is absent — `appDetailsStore.prototype.GetAppDetails` is wrapped, and
the original is put back when the plugin unloads. The page then takes the hero
branch, whose first source is `/customimages/<appid>_hero.jpg`: the hero that
`SetCustomArtworkForApp` wrote.

The field is **scoped to the download in flight**. It is added while the app's
row is running and taken back off when it is not — from the very object it was
put on, so the library is not left reading that app as having a store for as long
as Steam holds the details. A game at rest is described exactly as Steam itself
describes it, and the only page whose presentation changes is the one with the
row on it. The patch also checks the appid against the shortcut index, so it can
never answer for a game that is not ours.

The artwork itself is applied when a game enters that list as well as on a full
sync: Epic's box art, hero and header all go to Steam. Both wide assets are
**passed through untouched**, Epic's 2560x1440 as it stands. Composing them to
Steam's own frames is not possible in a way that suits both pages, because the
downloads bar and a library page draw that one image into boxes of different
shapes — roughly 7:1 and 5:1 — and Steam crops to fill whichever it is drawing.
Pre-cropping to a frame here therefore either leaves the bar short of an image at
its sides, or throws away the height the library page then crops again. Handing
Steam the whole picture and letting it crop once, per page, is what fills the bar
edge to edge without over-cropping the library.

Neither is deliberately re-applied across the whole library to catch up: that is
three image downloads for every game the account owns — over a thousand of them —
awaited inside the shortcut sync, which holds every button in the panel disabled
for the duration and reads as "I can't start a download at all". Only the game on
screen is refreshed, once. That is why the artwork-done marker stays at `v1`:
bumping it re-downloads everything for the whole library, and adding the hero and
header to the full sync is what that regression was.

A desinstalled game never appears here. Only installs and updates are transfer
jobs, and a row on screen when an uninstall starts is dropped rather than filed
as a finished download — otherwise a game you just removed sits in **Terminé**
for an hour. Rows left by an earlier session are cleared at start-up, since
they would otherwise be read as Steam's own and kept for good.

One thing Steam decides for us: a row whose `update_result` is not one of its
three "no error" values is drawn as an error, so the value is copied off one of
Steam's own items rather than guessed at — no numeric assumption, which is what
would break on the next client update.

**Pause all downloads** in Steam pauses the Epic ones too.

### Storage, and uninstalling

**Steam's _Settings > Storage_ lists them, because the plugin writes the two files
that page reads.** That page draws its rows from
`SteamClient.InstallFolder.GetInstallFolders()`, and each folder's `vecApps` is
the `apps` list in the `libraryfolders.vdf` the content system loads — which is
also what the count in its header is, and why a manifest on its own changes
nothing: Steam restarted with a correct `appmanifest_2435244972.acf` beside the
game and still said 56. Both are written, together, because one without the other
is a game Steam can read about and will not show.

**Steam keeps that list in two files, and it reads the one that is not the
obvious one.** `content_log.txt` records `Loaded Steam library folders
configuration: ~/.local/share/Steam/steamapps/libraryfolders.vdf`, and the page
follows that copy; `config/libraryfolders.vdf` is the one Steam copies _from_,
when it reloads the configuration — not before, and not on a timer. Writing only
the `config/` copy produced exactly two symptoms, one per direction: a game never
appeared on the page until Steam had been restarted, because Steam had not
reloaded its configuration since the line was written, and an uninstalled game
kept its row indefinitely, because the copy the page reads still had the line in
it. The plugin writes both now, and reports the first one that failed rather than
stopping — Steam copying one over the other would undo a change made to only one.

The manifest is one Steam would have written itself: a name, the directory under
`steamapps/common/`, and that directory's measured size. No depot ids and no build
id, because the content came from Epic and is not in Steam's content system; what
is wanted is a row on a page that adds the folder's size up. The folder entry is
the one line Steam writes per app, `"<appid>"` two tabs `"<bytes>"`, appended
rather than sorted in, and rewritten only when the size or the membership changes.

There is no API for either — Valve never expected anything in `steamapps/common`
that Steam had not installed, and Steam rewrites `libraryfolders.vdf` itself
whenever its libraries change.

The file is named after the appid the shortcut was given, and sits in `steamapps`
beside `common` — spelled **unsigned**, which is not how Steam hands it out: a
non-Steam appid is above 2^31 and travels as a signed 32-bit integer, so
Shogun Showdown's 2 435 244 972 arrives as -1 859 722 324, and
`appmanifest_-1859722324.acf` is a file Steam never opens. The same is true of
the icons the plugin writes into `userdata/<id>/config/grid`, which is why a
build renames any left under the signed name before doing anything else.

Written whole, and only when something changed, so a Steam watching the folder
sees no churn; a game whose size is still being measured is left for the next
pass rather than written with a size of nothing, which Steam would believe. When
a game is uninstalled its manifest is taken away again — a manifest left behind
would list the game at the size it used to be, which is exactly what makes a
finished uninstall look like it failed. A manifest that no longer names the
folder it was written for is never deleted: that is a Steam game's by then, not
ours.

Steam reads both files when it starts, and the page that is already open never
asks again: its rows come out of a store Steam fills when **it** decides to
re-read the library folders, and navigating away and back re-renders from
whatever the store already holds.

**What decides is narrower than it looks, and `content_log.txt` says which.**
Every rebuild of that list is one block, and it always starts with the same line:

```
[01:47:01] Client version: 1782257239
[01:47:01] Loaded Steam library folders configuration: .../steamapps/libraryfolders.vdf
[01:47:01] Loaded 55 apps from install folder ".../SteamLibrary/steamapps\appmanifest_*.acf".
```

Three things follow. Steam builds the list by **scanning the manifests**, so the
`apps` list in `libraryfolders.vdf` is its output rather than its input — the two
are written together because one without the other is a game Steam can read about
and will not show, not because the page reads that array. The count in the
storage page's header is that same number. And `Client version:` is a **client
reconnection**, so the list is rebuilt on start-up and at no other time: a
manifest written 45 s after that line is a manifest Steam has not seen, which is
why a game installed mid-session is a file, a folder entry and no row.

**A freshly installed game is the one case that can fail outright, and it did.**
`SizeOnDisk` is measured, not taken from Epic — a `du` of the folder, so patches
and shader caches are counted — and the manifest is refused rather than written
with a size of nothing, because Steam believes such a file and counts the game as
occupying no space, which looks worse than no row at all. So the pass waits for
the walk and asks again.

Waiting for five seconds and then giving up was the bug, and it was not a
shortcut: `du` walking a 3 GB install on `/var/mnt/Jeux` took longer than that,
so the walk was still going when the budget ran out. The manifest was never
written, the game never appeared on the page, and the next launch started the
walk again from nothing and got exactly as far — permanently, on a machine where
the walk is consistently slower than the patience. The trace said it plainly and
was not read: `skipped: [{appId: 2257310012, reason: 'not measured yet'}]`, once
a second.

So "no size yet" is now told apart from "a walk is still going". A walk in flight
is worth five minutes of waiting; a folder with nothing in it is not worth asking
about again, because the answer is the same absence either way. The two were one
string before, which is what let the first be given up on.

`SteamClient.InstallFolder.RefreshFolders()` — the call behind Steam's own
« Actualiser le lecteur » button — does not rebuild it either. `content_log.txt`
contains no line at all for it: `grep -i "refresh\|rescan"` over the whole file
returns nothing, and the loads at 01:23:10 and 01:25:30 that first looked like
one were Steam restarting. Both are still made, because they are Steam's own and
cost one IPC — and because the store read is the call whose answer the reconcile
follows — but neither is what changes the page.

**So the page is not asked — it is written to.** `window.installFolderStore` is
Steam's own store for that list, and its field is a reactive array that Steam
fills with exactly one call. Its own callback is three lines long:

```js
async OnInstallFolderChanges(e) {
  const t = await SteamClient.InstallFolder.GetInstallFolders();
  ...
  this.m_InstallFolders.replace(t);
}
```

Nothing ever calls that callback again, which is the whole of the problem: a
manifest written since the client connected is a file nobody has read. So the
plugin makes that same call itself, with the games it has manifests for added to
the folder they are installed in, and the ones it has taken away removed. It is
the list Steam would rebuild at the next start, so a row appears as the download
finishes and disappears as the uninstall does, and the header count moves with
it. A restart only confirms what the page already said.

What is in a row is what the page itself reads: `nAppID`, `strAppName`,
`strSortAs` made the way Steam's own sort key is made, `rtLastPlayed`, and
`nUsedSize` — the number the page sorts on and prints, and the same
`bytes` the manifest and the folder entry carry. Note that `nUsedSize` is what
the page uses and `strUsedSize` is what `@steambrew/client` documents: the
typings are behind the client.

Three things are deliberately not done. Steam's own entries are never touched,
and a game Steam already counts — after a restart it finds our manifest itself —
is not added twice, so the reconcile is idempotent. No `InstallFolder` method
that writes is called: `AddInstallFolder`, `RemoveInstallFolder`,
`SetFolderLabel` and `RepairInstallFolder` all make Steam rewrite the library
from its own model, which has no non-Steam appid in it, so each one would take
the folder entry with it, and the last opens Steam's own dialog over an 800 GB
library. And the row is a row, not a patch: nothing is written into the page's
DOM, so a Steam release that renames the store leaves a storage page that is
merely late rather than a broken one.

**A removal has no in-place state, so the row leaves.** On its own rows Steam
swaps the checkbox for a « Désinstallation… » label once the app reaches the
`display_status` it reads from the content system:

```js
k?.display_status == Ul.iO && (
  <div className={z().AppBodyRight}>{we("#DisplayStatus_Uninstalling")}</div>
);
```

which an Epic appid never reaches: no depots means no such state, and nothing
written into Steam's files produces one. So the row is taken out of the list as
soon as the removal is _running_ — not while it is queued, because the files are
all still there — which leaves no button that does nothing and no checkbox to
click twice. A removal that is cancelled or fails puts the row back, because the
pass that follows rebuilds every row from the manifests on disk. The alternative,
patching the label into the page's DOM, would mean writing into a React-rendered
button, which re-renders; that is the one thing this plugin does to that page,
and it does not.

**What the page is then compared against, and said out loud.** After every pass
the plugin reads the same store and compares Steam's appids with the manifests it
wrote: games the page has not counted yet, and rows it still shows for a game
that is gone. The panel says so when either list is not empty — which is now
only ever a client whose store this build cannot write — and stops when a restart
has fixed it.

**Icons are put back where the shortcuts say to look for them.** A shortcut does
not hold an icon's _name_, it holds the **path** Steam drew from, and that path
is what Steam opens again after a restart. Reading `shortcuts.vdf` back, one
entry here said `.../grid/-1859722324_icon.png` — signed, the form a 32-bit appid
over 2³¹ travels in — while the icon itself sat next to it under the unsigned
name this plugin writes everywhere else, `2435244972_icon.png`. A build that
renamed the files into the names Steam reads made that worse rather than better:
it moved the icon and left the entry alone, so Steam came back to a path it had
been given and found nothing there, and several hundred games drew as grey boxes
with nothing in any log to say why — Steam found a file missing, which is not an
error it reports.

So the pass is the other way round. On every launch, for every account on the
machine — not just the signed-in one, because the files are this plugin's own and
which account wrote them is not something the machine still says — it reads the
shortcuts Steam itself lists, and for any entry whose recorded icon path is not a
file, it **copies** the icon written for that appid onto that path. Copied, not
moved: `icon_path` reads the unsigned name to decide an icon is already there,
so moving the file away would send every pass after this one back to the artwork
— a fetch, a crop and a write for every game at once, on every launch — to
replace the copy already sitting there. From the next launch on the repair finds
the file it looks for and does nothing, and the icon under the unsigned name is
what `SetShortcutIcon` is handed from then on, which is a path Steam reads too.
The cost is one duplicate PNG per game repaired, once.

**Uninstalling from that page works, and one thing about it is Steam's own.** Its
**Désinstaller** and **Déplacer** sit in an action bar that stays greyed out until
something is selected: tick the box at the right of the row, or click the row
itself, and they enable. What it opens is Steam's own dialog, whose confirmation
calls `SteamClient.Installs.OpenUninstallWizard` — the function already patched
for the library's own uninstall, so the game goes to legendary rather than to a
content system that holds no depots for it, and its manifest and its entry in
`libraryfolders.vdf` are taken away as soon as the job finishes.

The two pages spell the same appid differently, which is the trap in it: the
library's own uninstall hands over the **signed** appid (-1 859 722 324) and
Steam's storage page, which reads the `libraryfolders.vdf` the plugin writes,
hands over the **unsigned** one (2 435 244 972). Looked up under one form only,
the storage page's button reached an id the plugin did not recognise, left it to
Steam, and Steam's own uninstaller did nothing — a game with no depots to remove
looks exactly like a button that does nothing.

**Steam's page is the only list.** It has the rows, the artwork, the sizes and the
**Désinstaller** buttons. The plugin's own block for that page remains in the tree
— `frontend/patches/storage.ts`, registered in `frontend/index.tsx` — and is the
one-line thing to remove if Steam's own rows turn out to be enough.

**Epic storage** is not a second list any more: the panel's own copy of it is
gone, and this is the only place the figures are shown.

Those figures are measured rather than believed. Epic's own size says what the
game _should_ occupy; the folder also holds the patches, the shader caches, the
crash dumps and whatever a mod manager added — which on a large install is tens of
gigabytes the other figure cannot account for, and "where has my disk gone" is the
question the page is opened to answer. The measurement is a `du` of one directory,
cached by its path, so it is one walk when a path changes and none after that.

If a game that is installed does not appear on Steam's page, `backend/data/trace.log`
says which half of it failed: `Wrote a manifest for <appid>` when the file was
written, `Manifests synced { written = …, skipped = … }` when it was not, and
`Steam can now count N Epic game(s)` when the frontend saw the change. A game
listed under `skipped` with `not under steamapps/common` is installed somewhere
Steam does not look — see _Where games are installed_.

### The cloud-saves mark

A small cloud on a game's artwork — beside the Epic mark on list icons, above it
on grid tiles — says that Epic keeps this game's saves in the cloud, and that the
plugin will push them up when the game closes. No cloud means the game has none
on Epic's side, and the Sync item will not offer it. It is drawn from the same
catalog data as everything else in the library, so it costs nothing at render
time and needs no network.

### A game does nothing when you press play

**Read `backend/launch.log` first.** A non-Steam shortcut that fails leaves
nothing anywhere else: Steam records only that a process appeared and went away.
That file has the environment Steam handed over, the resolved umu configuration,
everything the launcher printed, and the exit code.

**If it says `Steam started this shortcut inside a Proton build`,** the game was
started from Steam's _Properties > Compatibility_, per game or through the global
setting. That used to be fatal; it is supported now, and the game runs with the
Proton Steam chose. Three lines follow it, and which one they are tells you
everything:

- `running: …/RiverCityGirls.exe` then `exit: 0` — it ran. A crash after that is
  the game's own, on that Proton.
- `No executable of <game> is known yet` — the game has never been resolved, so
  there is nothing to run. Open the panel, which resolves one per installed game,
  and press play again.
- `env: '/usr/bin/umu-run': No such file or directory` — the _old_ script, from
  before this was supported. It names an installed program, because the
  container replaced the environment it is looked up in. Reopen the panel to get
  the new one.

**If it does not say that,** the launch went the umu route and whatever is wrong
is further down the file.

**Steam's global setting, appid `0`, in _Settings > Compatibility_,** applies to
every app with no mapping of its own, so it covers every Epic game, and it is the
only setting the plugin reads. The app details page names the build it resolves
to, and every launch writes `Steam's compatibility tool: …` into
`backend/launch.log`. Set it to **No tool** there to go back to umu's own build;
that is Steam's setting and not one the plugin makes on your behalf. Per-game
mappings are the user's and are
left alone - **Check Proton mapping** names the ones that are set, which is how
you find the right game among 548. A shortcut's appid is in its Properties, under
_Shortcut_.

The shortcut itself is the next thing to look at, and Steam will tell you the
whole command: right-click the game, Properties, and read _Target_. It should
read `<game folder>/.steam-epic-play.sh`, with launch options of nothing at all -
everything else lives in the script that program leads to, which is why changing
the Proton build or the default launch options needs no sync and no restart, and
why the words you write in that box reach that game alone.

A target of `umu-run` or of the `legendary` binary means the shortcut predates a
change in how the command is built. Opening the panel rewrites those in place on
its own - there is no button to find - keeping each shortcut's appid, artwork,
collections and playtime. If your Steam build will not move an existing
shortcut's executable, the plugin notices: after each migration it reads
`shortcuts.vdf` back and compares it with what it asked for, so a build that
ignores the call produces a warning in the log and a count in the panel rather
than silence. **Remove everything** followed by **Sync** is then the only fix
left, at the cost of appids, artwork and playtime.

`launch.sh` is written by the plugin, not shipped with it, and is rewritten on
every sync - it names the vendored binary and the log, both of which depend on
where the plugin is installed. It exists because Steam starts a shortcut with an
environment of its own making, which a PyInstaller build like `legendary` does
not always survive: the script drops `OPENSSL_CONF`, `LD_PRELOAD` and
`LD_LIBRARY_PATH`, points `XDG_RUNTIME_DIR` somewhere real when Steam has not
set it, and appends everything `legendary` and the Proton wrapper print to
`backend/launch.log`. That last part is why it exists at all.

### A download shows no progress

The runner writes what it is doing to `backend/data/jobs/<game>/log.txt`, and
anything the runner itself had to say goes there too. If that file is empty, the
command never ran; if it ends in an error, that is the error.

### Downloads and restarts

A download survives Steam closing. Its runner is started with `setsid`, so it is
in its own session and nothing Steam does reaches it; the plugin finds it again
by the PID it wrote down and `/proc`, and carries on reading its progress. The
queue is on disk for the same reason, so a restart mid-queue loses nothing.

What does _not_ survive is the machine going away - a reboot, an out-of-memory
kill, a power cut. A runner killed like that never writes the exit code a
finished one would, which is how it is told apart from a failure. Those bytes
are still on disk and `install` resumes from them, so the plugin starts the job
again rather than reporting a failure, and says so in the log:

```
Picking up the interrupted install for Foo again, attempt 2
```

It gives up after three attempts, because something that reliably kills the
download is broken outside the plugin and retrying for ever would only hide
that. A job that fails normally - Legendary printing an error, a full disk - is
reported as a failure straight away, and is never retried behind your back.

### The plugin logs nothing useful

Check you are reading the panel's log rather than the browser's. The plugin's
log lines are assembled into the first argument of `console.debug`, because that
is the only part of a console call Millennium's log panel captures - a message
passed as a later argument comes out as a blank line.

### Legendary will not download

The plugin tries `curl`, then `wget`, and logs the failing downloader's own
message and exit code, so the log says which and why. Steam exports
`OPENSSL_CONF=/dev/null` and a `pressure-vessel` `LD_LIBRARY_PATH` to everything
it starts, and a downloader that inherits them can fail before writing a byte;
the plugin runs both through `env -u OPENSSL_CONF` so they do not.

### What was removed, and what it cost

Dead code is not free: it is a thing to keep reading, a thing that can be
mistaken for the path a value takes, and a thing that breaks silently when the
thing it wrapped moves. So the passes that found it were mechanical rather than
remembered - every exported name in `backend/` counted across the backend and the
tests, every exported name in `frontend/` counted across the frontend, every
module counted by who imports it - and only names with **zero** callers went.

Removed, all of it with no caller:

- `services/hidden.ts` and `services/collection.ts`, whole files: hiding
  duplicates and syncing a Steam collection. Neither had ever been wired to
  anything.
- `config.clear`, `library_folders.path`, `config_vdf.compat_tool_block` and
  `RPC.Log`: a way to empty the settings file, a convenience over `paths()[1]`,
  a seam no test ended up using, and a log sink the frontend no longer calls.
- `config_vdf.compat_tool_for` **and its test**: this is the one removal that
  lost coverage, and it is worth saying why it was right. Its comment claimed the
  launch path and the panel both asked for it; neither does - `launch.sh` reads
  `config.vdf` at launch through its own awk, and the panel asks
  `global_compat_tool`. A test that guards code nothing calls is a test that
  keeps a wrong claim alive.
- `shortcuts.appIdOf`, `shortcuts.syncedCount`, `paths.onWindows`,
  `dom.rootFiber`, `usage.isMeasuring`: exported, never called.
- `findCompatTools`, `needsRelaunch`, `umu.toolFor` and `extractCode` kept their
  bodies and lost the `export`: they are used inside their own file, and saying
  so is what stops the next reader hunting for an importer.

`store.search_url` took a language it never used, which is the kind of parameter
that makes a reader believe the search URL is localised. It is not, and now it
does not claim to be.

### One optimisation worth naming

`sync()` calls `icons.apply()` for every installed game, on every pass, and every
pass ended in a `SetShortcutIcon` telling the client a path it had already been
told - 551 calls per sync, each of which has to answer before the next game can
be asked. The path Steam was last handed is now remembered per appid, and an
identical one is not sent again. A first sync, an icon that changed and the
migration of a launch command all still send it; the passes in between send
nothing.

The answer is remembered rather than the call skipped blindly, because what the
call says is the one thing this cannot work out for itself: the file may have
moved, and some client builds ignore `SetShortcutExe` without saying so. Removing
a shortcut forgets it, so a game that comes back is told again.

### Running the backend tests

`luajit test/harness.lua` runs the backend outside Steam - the shell, the job
runner, the download queue, the launch command - against stubs for what
Millennium would provide, so a change to any of it can be checked without
launching Steam at all. Add `--vendor` to include a real legendary download,
which is the one test that reaches the network.

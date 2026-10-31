# OpenPairings integration

How `plugins/openpairings_polis` gets into OpenPairings, what it needs once
it is there (very little), and where it stops.

## What the plugin is

An OpenPairings plugin (`PairingsEngine.Plugin`, see that module's docs in
the OpenPairings repository) with two pages, two plain routes and two
tables.

Pages (signed in, administrators only: the core's `:plugins` live_session):

| Path                       | What                                                                 |
|----------------------------|----------------------------------------------------------------------|
| `/p/polis`                 | Every print station of every tournament this account can open        |
| `/p/polis/tournaments/:id` | The tournament's stations; "Add a print station"; Remove; Print again; each station's name, room and share |

Plain routes (`http_routes/0`: no pipeline, no session, no CSRF, no sign-in;
the plugin checks the caller itself):

| Route                       | What                                                         |
|-----------------------------|--------------------------------------------------------------|
| `POST /p/polis/join/:code`  | A station joining with a one-time code (`JoinPlug`)          |
| `GET /p/polis/link`         | The station's WebSocket (`LinkPlug` -> `LinkSocket`)         |

The wire format of both is OpenPairings' contract `hall-link-v1`
(`priv/contracts/hall-link-v1` there, vendored here in
`priv/contracts/vendor/openpairings/hall-link-v1/`); `docs/protocol.md` has
only what Polis does with it. The join answers are the contract's
`join-error` codes: 404 `unknown_code`, 410 `used` or `expired`, 409
`version` (with `v`), 400 `bad_request` (a body that is not a station;
until the contract it was a 422 `device`), 429 `too_many_attempts`.

The plugin adds the feature `polis_print_station`, in the Belgian pack
(`federation: "BEL"`) of the account's Features page. With it on, a
tournament's Settings get a "Print station" page
(`tournament_settings_entries/2`, group `:publishing`, icon
`hero-printer-micro`), drawn inside the Settings frame so the rail stays
beside it. It has no tab in the tournament's top bar: a print station is
set up once and then left alone.

The feature is access, not just a menu entry: the plugin asks whether the
tournament owner's account still has it on when a station joins (a join link
made before the switch-off is refused as expired) and at every `hello` (a
station that was joined before is refused as `revoked`, and the admin can
still remove it from the page, which keeps listing what had joined).

## What happens

1. On `/p/polis/tournaments/:id` (the tournament's Settings → Print
   station) the arbiter presses "Add a print station".
   The page shows a join link `https://<host>/p/polis/join/<code>` (built
   from `PairingsEngineWeb.Endpoint.url()`), a copy button and a QR code.
   The code is the one every hall app uses: 32 random bytes, base64url (43
   characters), good once, for 15 minutes, bound to that tournament; only
   its SHA-256 is stored. A code from before (16 base32 characters, any
   case) is still taken until it runs out. The page says to paste it into
   Polis, or to scan the QR code with Manubrium on a phone, which passes
   the link on to the hall PC.
2. Polis on the hall PC posts to that link and gets a key (32 random bytes,
   base64url). Only the key's SHA-256 is stored. Joining the same tournament
   again from the same device replaces the key and undoes a removal.
3. Polis opens `wss://<host>/p/polis/link`, says `hello` with the key, and
   gets `welcome`, its `settings`, and the latest published round - its
   share of it - if there is one.
4. The socket listens to the core's tournament topic
   (`PairingsEngine.Tournaments.tournament_topic/1`). Any change is a nudge:
   300 ms later it recomputes the latest published round's payload and
   sends it when its `rev` differs from the last one it sent. That covers
   pairing with the automation on, publishing by hand and a delayed publish
   running out (the last needs the core commit that broadcasts it, see
   below). A round taken back is never sent; an older round is ignored.
5. The page's "Print round N again" (pairings, place cards or both) goes to
   every connected station of the tournament as `print`. Remove marks the
   station revoked: a connected one is told `leave`, and the next `hello`
   from it is answered `refused revoked`.

### Name, room and share

Each station row has a room and two filters,
`filter_categories` (category names, a JSON list like the core's
`players.categories`) and `filter_boards` (board numbers as text,
`1-20, 35`), added by `priv/migrations/20261018000102_add_polis_station_settings.exs`.
Empty is everything.

The room is one of the tournament's own rooms (OpenPairings' Settings,
Rooms; `PairingsEngine.Rooms`), kept by id in `room_id`
(`priv/migrations/20261018000103_add_polis_station_room_id.exs`), with
`room` holding its name as last seen. A rename in OpenPairings follows the
station; a room removed leaves it in no room. The page picks a room by id
(`"room_id"`, `"keep"` for unchanged); the station sends a name (`"room"`,
matched without regard to case or spaces). A name that is no room of the
tournament is refused, `{:error, {:room, :unknown}}`, which the socket
answers with the `settings` frame plus `"error": "room"`. The `settings`
frame carries `rooms_available`, the rooms' names.

Rooms typed before the core had them are not converted: they were free
text in tournaments without rooms, so they name none. Such a `room` stays
as a label (`Stations.legacy_room?/2`), shown and sent as it is, and
restricts nothing - as before. A station that sends the same text back is
not refused for it; picking a real room replaces it. `OpenPairingsPolis.Stations.update_settings/2` is the
only writer, called by the page and by the socket when the station sends
`settings`; it broadcasts `{:polis_settings_changed, id}`, and the socket
answers with the `settings` frame and, when the share changed, the round
again. Last save wins.

The filter is applied here, not in Polis: the round payload a station gets
holds only its boards (the board is in the station's room, its number is
in the list, and either player
carries a ticked category; a bye by its one player), and carries
`selection` (`room`, `boards`, `categories`) when it is not the whole
round, so the `rev` is per share. A category the tournament no longer has
is dropped from the filter rather than left to match nobody.

Board numbers are read by the core's `PairingsEngine.BoardRanges`, the
same reader the core's rooms use, so "1-20" means one thing to both. A room
with no boards yet holds none: a station placed in it prints nothing, and
its page says so.

The page and the sockets meet on the plugin's own PubSub topic,
`"polis:tournament:<id>"` on `PairingsEngine.PubSub`. The plugin starts no
process of its own: each socket is its own process, and nothing else runs.

Online, on the page, means a socket is up and was heard from (a ping, a
status) in the last 90 seconds. Wrong or spent join codes are counted per
client address in the core's `:board_link_auth` rate-limit bucket (under
keys of the plugin's own), 30 per 10 minutes.

### The round payload

Built by `OpenPairingsPolis.RoundPayload` from the same public functions
the core's printed pairing list uses
(`PairingsEngineWeb.PrintController.pairing_list/2`): hidden pairings left
out, `PairingsEngine.PairingDisplay.with_display_boards/1` for the board
labels and their order, `PairingsEngine.Standings.player_scores_before_round/2`
for the score in brackets, `Player.rating/2` with the tournament's rating
method. `rating` is an integer, `0` for an unrated player, as the core
reports it. `locale` is the tournament owner's account language (`nl` or
`en`); OpenPairings has no per-tournament language.

Team tournaments send their board pairings as the core lists them, with
`team: true`. Polis prints individual tournaments well and team ones
adequately; a team-shaped sheet is not in this version.

## Tables

`priv/migrations/20261018000101_create_polis_stations.exs`, run with the
core's (`migrations_path/0`; the hosted `ecto.migrate` alias adds the
directory):

- `polis_join_codes`: `tournament_id` (cascade), `code_hash` (unique),
  `expires_at`, `used_at`, `created_by_id`.
- `polis_stations`: `tournament_id` (cascade), `device_id` (unique per
  tournament), `name`, `software`, `key_hash`, `status` (what the station
  last reported: `printer`, `last_printed_round`), `last_seen_at`,
  `connected`, `connection_ref` (so an old socket closing late cannot mark a
  reconnected station offline), `revoked_at`; and, from the later
  migrations, `room`, `room_id`, `filter_categories`, `filter_boards`.

Deleting a tournament for good removes its rows; one in the recycle bin
answers `refused revoked`.

## Building OpenPairings with the plugin

OpenPairings compiles plugins only with `PAIRINGS_EDITION=hosted`. Each
plugin is a directory with an `openpairings_plugin.exs` manifest; its `lib/`
is compiled into `:pairings_engine` itself, and the directory is a path
dependency with `compile: false, app: false`. This plugin has a `mix.exs`
with no dependencies: everything it uses (Phoenix, Ecto, Jason, EQRCode,
WebSockAdapter, Bandit) OpenPairings has already. No `mix.lock` change.

It needs a core with `http_routes/0` and the delayed-publish broadcast
(OpenPairings commit "Plug-ins can answer hall devices", branch
`hall-plugins` at the time of writing). On an older core the build fails
loudly, which is the right way round.

```sh
cd openpairings   # or, better, a throwaway worktree of it
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<polis>/plugins" \
PAIRINGS_PLUGINS=openpairings_polis \
  mix deps.get && mix compile && mix ecto.migrate
```

| Variable               | Meaning                                                                 |
|------------------------|-------------------------------------------------------------------------|
| `PAIRINGS_EDITION`     | `hosted`, at build AND run time (`mix phx.server` reads `mix.exs` again) |
| `PAIRINGS_PLUGINS_DIR` | the directory the plugin names are relative to                          |
| `PAIRINGS_PLUGINS`     | comma-separated plugin directories, relative to `PAIRINGS_PLUGINS_DIR`  |

The plugin has no settings of its own: no environment variables, no
`config`.

### Both hall plugins at once

Polis and Nunki live in two repositories, so their plugins sit in two
different `plugins/` directories. Either point `PAIRINGS_PLUGINS_DIR` at
their common parent and name both with relative paths:

```sh
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<VPS projects>" \
PAIRINGS_PLUGINS=polis/plugins/openpairings_polis,nunki/plugins/openpairings_nunki \
  mix compile
```

or copy (or link) both directories under one `plugins/` directory and name
them plainly, `PAIRINGS_PLUGINS=openpairings_polis,openpairings_nunki`,
which is what the server ends up with anyway. Their migrations do not
collide (`202610180001xx` here, `202610180002xx` for Nunki) and neither
plugin knows the other exists.

## On the server

`openpairings-deploy/deploy_openpairings.py` uploads each plugin listed in
`OPENPAIRINGS_PLUGINS` into `<app>/plugins/<name>`, sets `PAIRINGS_EDITION`,
`PAIRINGS_PLUGINS_DIR` and `PAIRINGS_PLUGINS` at build and run time, runs
`mix deps.get` and the build on the box, and migrates. The plugin has been
on the hosted OpenPairings at pairings.cloud since 2026-10-18, as
`<app>/plugins/openpairings_polis`, through this one line (the deploy
repository is not this one's to change, so the line lives there):

```python
("openpairings_polis", os.path.join(LOCAL_PROJECTS_ROOT, "polis", "plugins", "openpairings_polis")),
```

What the server needs beyond that: nothing but HTTPS reaching it, and
WebSocket upgrades (`wss://`) let through for `/p/polis/link` by whatever
stands in front of it. The hall PC dials out; nothing dials in to the hall,
so no port forwarding anywhere. A proxy that idles WebSockets out sooner
than the station's 25-second ping is a proxy to configure, not a bug to
fix here.

## Tests

The plugin's tests need OpenPairings around them (`ConnCase`, the accounts,
the tournaments, `PairingsEngine.BoardLinkFixtures`), so they run in an
OpenPairings build. CI does exactly that on every push and pull request
(`.github/workflows/ci.yml`, job `plugin`): OpenPairings' `main` checked
out beside this repository, the hosted edition with `PAIRINGS_PLUGINS_DIR`
pointing at this `plugins/`, compiled with warnings as errors, formatted by
OpenPairings' rules, and the whole of `plugins/openpairings_polis/test`
run. `hall_link_contract_test.exs` holds the server half to the vendored
contract (`OpenPairingsPolis.Contract`). By hand:

```sh
# from a worktree of OpenPairings, never its own checkout (Git Bash)
MIX_BUILD_PATH=_build_hosted_hall_polis \
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<polis>/plugins" \
PAIRINGS_PLUGINS=openpairings_polis \
MIX_TEST_PARTITION=polis \
  mix test "<polis>/plugins/openpairings_polis/test"
```

`MIX_BUILD_PATH` drops the per-environment subdirectory, so a dev compile
into the same path leaves protocols consolidated without the test-only
`lazy_html`, and every LiveView test then dies in
`Phoenix.LiveViewTest.DOM`. Delete
`<build>/lib/pairings_engine/consolidated` and run the tests again.

The socket tests drive `LinkSocket`'s callbacks directly in the test
process; no real WebSocket, no printer, nothing printed.

## Translations

`mix gettext.extract --merge`, run the same way (hosted, plugin selected),
updates the plugin's `priv/gettext` (English and informal Dutch). It also
rewrites the core's own catalogues while it is at it: `git checkout --
priv/gettext` in the OpenPairings tree afterwards. The references come out
as absolute paths; strip the prefix up to the plugin directory.

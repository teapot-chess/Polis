# The hall link, as Polis speaks it

The wire format is not described here any more. It is OpenPairings'
contract **hall-link-v1**:
[priv/contracts/hall-link-v1](https://github.com/teapot-chess/openpairings/tree/main/priv/contracts/hall-link-v1)
in the OpenPairings repository - JSON Schemas for the join, every frame
both ways and the pairing links, with examples and a README that says how
the line runs and how a device is paired. Polis vendors a byte-for-byte
copy in `priv/contracts/vendor/openpairings/hall-link-v1/`
(`mix contracts.sync`; `mix contracts.check`, in CI daily, says when it is
stale), and both halves are tested against that copy: the station in
`test/contracts/`, the OpenPairings plugin in
`plugins/openpairings_polis/test/openpairings_polis_web/hall_link_contract_test.exs`.

The messages that are Polis's own are `device-status-polis`,
`device-settings-polis`, `server-settings-polis`, `server-print` and
`server-standings`, and the round payload's `selection` and `room`. Everything below is what Polis *does*
with them, which no schema can say.

## Joining

- The link is `https://<server>/p/polis/join/<code>`, pasted into the
  station's page, or scanned with Manubrium on a phone, which passes it on
  to the hall PC. A link for Nunki (`/p/nunki/join/...`) or for Manubrium
  (`manubrium://...`) is refused before anything is sent, saying which app
  it is for: its code stays unspent.
- `device` is made once per data folder. `key` goes into `state.json` and
  nowhere else: not onto the page, not into a log, not into a URL.
- 404 and 410 are "make a new link"; 409 is "update one of the two";
  anything else is "that address is not an OpenPairings server".

## Rounds and `rev`

The station keeps, per round, the `rev` it printed.

- A new round prints its pairings list (the copies set on the page) and its
  place cards, each behind its own switch. Once.
- A known round with another `rev` is "changed since it was printed" and
  waits for a person to press Reprint. A sheet on the wall that changes by
  itself is worse than one that is old.
- A known round with the same `rev` is a reconnect and does nothing.
- `print` is acted on only for the round the station holds, at once,
  whatever the switches say.
- With no printer chosen, jobs wait in the queue; Polis never picks one.

## A station's share

A board is in a station's share when it is in the station's room, its
number is in the station's board numbers and either player is in one of
its categories; a bye counts its one player. Each test passes when it has
nothing to test: no room, or a room that is not one of the tournament's
(legacy text), an empty board list, an empty category list. A room is a
set of board numbers kept on the server; the station only names it. A
board's number is the whole number its label starts with: `12` is 12, a
team board `3.1` is 3, a shared fixed table `1001/1002` is both.

The server cuts the round to the share before it sends it, and says so in
`selection`; Polis prints `selection` in the sheet's heading and prints
nothing for a round whose `boards` came out empty.

The station's page changes its name, room and share only while the line is
up: the server keeps them, and a change it cannot hear did not happen. The
page shows what the server's `settings` says, not what was asked; a
refusal (`error`) is said on the page. Against a server that sends no
`rooms_available`, the room is free text, as it always was; legacy text the
server still holds is shown as "not a room of this tournament".

## What Polis does not do with it

It does not print a round that was taken back (the server never sends
one), it never prints an older round than the one it holds, and it does
not keep rounds other than the latest: the queue's jobs keep their own copy
of the payload they were made from, so a Reprint prints what was printed.
`spoken` and `club` are not printed.

## The second job

Three more sheets, none printed on arrival unless the person said so.

- `print` with `what` `playerlist` or `slips` prints from the round the
  station holds: the player list is alphabetical (accents and case do not
  count) with board, colour and, when the boards carry a `room`, the room; a
  bye is listed as "bye". The slips are one per board with two players, four
  to a sheet. Both can also be switched on per tournament to print with every
  new round, like the pairings and the place cards; they are off until somebody
  turns them on, and the tournament's page has a "print now" button for each.
- `standings` is held, never printed on arrival: the server sends it only just
  before a `print` with `what` `standings`, because standings go stale with
  every result and a sheet nobody asked for is paper. The station keeps the
  last one; the page offers "Print the standings now" once it holds one, which
  prints that one. At most four tie-breaks are drawn.
- A `print` whose `what` the station does not know prints nothing; the
  protocol grows, and an old station must not print the wrong thing for a new
  word. The frames meant for Nunki (`announce`, `countdown`, `read`, `stop`)
  are ignored.

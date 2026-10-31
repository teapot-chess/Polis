# Polis

The print station of a chess hall. A small program on a computer with a
printer: it joins a tournament in [OpenPairings](https://github.com/teapot-chess/OpenPairings)
with a join link, keeps a line open to it, and prints the pairings list and
the place cards of every round the arbiter publishes - once, on its own,
and again only when somebody asks. On request it also prints the standings, an
alphabetical player list with board and room, and result slips (one per
board, four to a page); the last two can be switched on for every round.

It always dials out. Nothing in the hall's network needs to be opened.

## Install

Every push to `main` builds all of these; a release attaches them. The
addresses are the same for every release.

| What | Download |
|---|---|
| Windows installer (one click, updates itself) | [Polis-Setup.exe](https://github.com/teapot-chess/Polis/releases/latest/download/Polis-Setup.exe) |
| Windows, no install | [polis-windows-x86_64-portable.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-windows-x86_64-portable.zip) |
| Linux, PC | [polis-linux-x86_64.tar.gz](https://github.com/teapot-chess/Polis/releases/latest/download/polis-linux-x86_64.tar.gz) |
| Linux, Raspberry Pi (64-bit) and other arm64 | [polis-linux-aarch64.tar.gz](https://github.com/teapot-chess/Polis/releases/latest/download/polis-linux-aarch64.tar.gz) |
| Mac, Apple Silicon (macOS 11 and newer) | [polis-macos-aarch64.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-macos-aarch64.zip) |
| Mac, Intel (macOS 10.13 and newer) | [polis-macos-x86_64.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-macos-x86_64.zip) |
| Checksums | [SHA256SUMS](https://github.com/teapot-chess/Polis/releases/latest/download/SHA256SUMS) |

**Checking a download.** From the next release on, every file in a release, `SHA256SUMS` included, carries signed build provenance: a GitHub artifact attestation, signed keylessly through Sigstore, so there is no key of ours to lose. With the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify <file> --repo teapot-chess/Polis
sha256sum --check --ignore-missing SHA256SUMS
```

The first line says this exact file was built by this repository's release workflow. `SHA256SUMS` is attested too, so the second line is as trustworthy as the first.

**Linux**, one line, as a service that starts with the machine:

```sh
curl -fsSL https://github.com/teapot-chess/Polis/releases/latest/download/install.sh | sudo sh
```

The program lives in `/opt/polis`, the data in `/var/lib/polis`, and
neither an update nor `/opt/polis/uninstall.sh` touches the data. Printing
goes through CUPS (`lp`), which the machine must have with the printer set
up in it. The log is `journalctl -u polis`.

**Windows**: Windows says it does not know the program, as it does of any
unsigned installer: "More info", then "Run anyway". The data is in
`%LOCALAPPDATA%\PolisData`, never in the install folder. **macOS**: signed and
notarised; unzip and open `Polis.app` ([docs/macos.md](docs/macos.md)).

An installed copy looks for a newer release now and then (one small
request to GitHub, switched off by a checkbox) and offers it; it installs
nothing without a yes, and not while a sheet is printing unless the yes is
given twice. How releases are cut and what each file is:
[docs/releasing.md](docs/releasing.md).

## Using it

Start Polis (the installer and the Mac app do it for you; the Linux service
starts with the machine) and open its page at `http://localhost:4061`. In OpenPairings (on pairings.cloud): the
tournament's *Settings* → *Print station* → *Add a print station*; paste the
link it shows into the page (or, from another device, scan its QR code with
Manubrium on your phone, which passes the link on). The link works once, for
fifteen minutes. Choose the printer and the paper. That is the setup.

From then on, per tournament:

- **A new round** prints its pairings list (1 to 5 copies) and its place
  cards, each behind its own switch, both on. Once.
- **No printer chosen yet**: the jobs wait in the queue as "waiting for a
  printer" and go when one is chosen. Polis never picks a printer by
  itself.
- **A round changed after it was printed** (the arbiter moved a pairing):
  nothing prints by itself. The page says "changed since it was printed"
  and offers Reprint. A sheet on the wall that changes by itself is worse
  than one that is old.
- **"Print round N again" in OpenPairings** prints what it names, at once.
- **A share of the round.** A station can print only some categories and
  some board numbers (`1-20, 35, 40-45`), and has a name and a room. When the
  tournament has rooms in OpenPairings, the room is picked from them and a
  board prints only if it is in that room; a server without rooms gets a
  free-text label as before. All four are set on the station's page under *This station* or in
  OpenPairings, and OpenPairings keeps them: a change made in either place
  shows in the other at the next push. Nothing set is everything. A board
  prints when it is in the room, its number is in the list and either player
  is in a ticked category (a bye: its one player). A round with no board for this station
  prints nothing at all; a sheet that is printed says its room and share in
  the heading.

The queue keeps the last fifty jobs with what happened to each, a Reprint
button and the PDF. "Test print" prints a frame along the margins.

`POLIS_LISTEN=lan` opens the page to the hall's network; the default is
this machine only, because there is no PIN in this version. Either way the
station answers only to its own names: `localhost`, `127.0.0.1`, `PHX_HOST`
and, with `lan`, the machine's host name and addresses. A request that asks
for any other host (a web page that pointed its own name at this machine, or
a reverse proxy that forwards one) gets a 403.
`POLIS_PRINTER=dry-run` writes every sheet as a PDF into
`<data>/dry-run/` instead of printing it; development and the tests always
do that.

## For developers

To run Polis from a checkout instead of an installed copy:

```sh
mix deps.get
mix phx.server
```

The page is then at `http://localhost:4061` as above. Everything below this
heading is about how it is built, not how it is used.

## Why Polis lays out its own pages

OpenPairings has a printed pairing list already, as HTML for a browser.
Polis does not print that, for three reasons:

1. **Nobody is there to press Print.** Printing an HTML page without a
   person means a headless browser. On Windows that is Edge with flags that
   change between versions and a printer chosen by the system, not by
   Polis; on a Raspberry Pi it is a Chromium of a hundred megabytes for a
   sheet of names.
2. **The sheet must survive the trip.** The server sends data (the round
   payload of OpenPairings' `hall-link-v1` contract, `docs/protocol.md`),
   not a page. A page from the server would
   tie every station to the server's CSS of the day, and an old station
   would print a new server's page wrongly or not at all.
3. **Place cards are not a web page.** A tent card has its upper half
   upside down and a fold in the middle; a browser's print engine is a poor
   tool for that and a fine way to lose a margin.

So `Polis.Layout` turns a payload into a page description - text, lines
and boxes in points on A4 (595 x 842) or Letter (612 x 792) - and two
roads draw it:

- `Polis.Pdf`, a PDF 1.4 writer in a few hundred lines, with the standard
  Helvetica fonts in WinAnsi. CUPS prints it on Linux and macOS (`lp`), and
  every job's PDF is on the page behind "Open PDF". Names that WinAnsi lacks
  are transliterated; a name with no Latin letter at all comes out as
  question marks on this road.
- `priv/print/print.ps1` on Windows: Windows PowerShell 5.1, which every
  Windows 10 and 11 has, draws the same description with
  System.Drawing.Printing through the printer's own driver, in Arial, which
  has the metrics of Helvetica and the letters of most of the world.
  Windows has no way of its own to print a PDF; it borrows the installed
  PDF reader's, if there is one, and that opens a window to do it.

Text is fitted with Helvetica's own widths (Adobe's AFM files): a long name
is made smaller, then cut with an ellipsis, never run into the next column.

## Layout of the code

| | |
|---|---|
| `Polis.Join`, `Polis.Link`, `Polis.Protocol` | the hall-link protocol: join, the WebSocket, the frames |
| `Polis.Station` | what a round, a `print` and a removal do; the switches; the status |
| `Polis.Queue` | one job at a time, the last fifty, the PDFs |
| `Polis.Layout`, `Polis.Layout.Metrics`, `Polis.WinAnsi`, `Polis.Pdf` | the sheets |
| `Polis.Printer` and `.Cups`, `.Windows`, `.DryRun` | the roads to a printer |
| `Polis.State` | `state.json`: the tournaments, their keys, the settings |
| `Polis.Updates`, `Polis.Autostart`, `Polis.LauncherDetails` | the installed program |
| `PolisWeb.StationLive`, `PolisWeb.HelpLive` | the page and the help, English and Dutch |

The data folder holds `state.json` (keys included, mode 0600 where the
system has modes), `jobs/` (each job's source and PDF) and
`secret_key_base`. Keys are never put on a page or in a log.

## Tests

```sh
mix test test/polis/layout_test.exs
```

The tests never print: the printer is a recording fake, the dry run, or a
recorder standing in for `lp` and PowerShell. The server is a stand-in on
a port of its own (`test/support/fake_server.ex`).

The OpenPairings side, `plugins/openpairings_polis`, is built into
OpenPairings and tested there, and it is on the hosted OpenPairings at
pairings.cloud since 2026-10-18: [docs/openpairings-integration.md](docs/openpairings-integration.md).

## Licence

Apache-2.0. See `LICENSE` and `NOTICE`.

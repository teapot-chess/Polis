# Changelog

What changed in Polis, newest first. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and each entry is
tagged so that a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a hole closed, or judged not to be one |
| [Verified] | checked against the real thing, no code change |

## [Unreleased]

## [0.5.0] - 2026-10-30

- [Security] **phoenix_html 4.4.0.** 4.3.0 picked up an advisory overnight (EEF-CVE-2026-117645, medium), and the dependency audit stopped the build, as it should.
- [Security] **Bandit 1.14.1.** Three fresh advisories against 1.13.1 (HTTP/2 header blocks that unfold into unbounded allocations, quadratic work on blocked streams, WebSocket frames after a close) turned the dependency audit red. Updated, with `plug_crypto` 2.2.1 riding along; the audit is green. Polis never spoke HTTP/2 to anybody, but the audit does not grade on intent.

- [Change] **The page fits a 3.5 inch screen.** A Polis box with a 480x320 panel (or 320x480 upright) got a desktop page: wide margins, a footer of links 22 pixels tall, checkboxes smaller than the stylus, and buttons of 34 pixels in the queue where a finger wants 44. Under 520 pixels wide or 360 tall the margins and headings shrink, and the buttons, selects, ticks, station summaries, the queue's links and the footer links all get 44 pixel targets. A bigger screen sees the same page it always did. The sections still stack, so it scrolls, vertically, which is the one direction a small screen is good at. `PolisWeb.CompactCssTest`.

- [Feature] **"Show advanced features", off by default.** The station page is now the small page most halls need: the tournaments, the join field, the printer and the queue. Copies of the pairings, what this station prints (name, room, categories, boards), the update settings and starting with Windows wait behind one tick in "This program". Nothing is removed, and the help describes all of it. A station that already uses any of these (updates off, start with Windows on, more than one copy, a share of the round set) switches the tick on by itself, once, so nobody wakes up to a missing knob; after that the tick is yours.
- [Change] **README: the hall user reads first, the developer commands moved.** "Using it" no longer opens with `mix` commands; those sit under "For developers", ahead of the sections on how Polis is built.

## [0.4.3] - 2026-10-21

- [Change] **The Mac app is signed with a Developer ID and notarised by Apple.** Until now it was signed with nothing but good intentions, and every Mac that downloaded it asked the arbiter to override Gatekeeper by hand, which is a strange way to greet someone who just installed your software. The release workflow now signs every binary inside Polis.app, hardened runtime and BEAM entitlements included, sends the bundle to Apple, staples the ticket and checks the verdict with `spctl` before the zip exists. A fork without the secrets still builds, with a warning, ad-hoc signed. The workflow can also be started by hand with *mac_only* to test all this without publishing anything.
- [Change] **Releases carry signed build provenance.** Every file of a release, `SHA256SUMS` included, is now attested through GitHub and Sigstore, keyless, so `gh attestation verify <file> --repo teapot-chess/Polis` can say who built it and from what. Until now the checksums vouched for a download only against the release they sat in, which is a witness who was hired by the defendant.

## [0.4.2] - 2026-10-20

- [Fix] **Stopping from Ascella, an update or a logout no longer hangs on "Stopping".** On a Mac, the window waited for its server to end inside the very queue that was to bring the news, so the server ended and the window kept saying "Stopping" until somebody force-quit it. Quit from the menu never had the problem, which is how it survived this long. Any stop that hangs anyway now ends after forty seconds.

## [0.4.1] - 2026-10-19

- [Feature] **Polis for Intel Macs, from macOS 10.13.** macOS 10 exists only on Intel Macs, and they had been struck off on the 14th because their build is slow. It is back, and it is built only when there is a release to put it in (or when somebody starts the workflow by hand), so the other pushes are as quick as they were. Polis's own update notice picks the zip for the Mac it is on, and no longer says an Intel Mac has no build; an Intel Polis running under Rosetta on an Apple Silicon Mac is treated as the Apple Silicon Mac it is. Every program in the bundle is checked against the oldest macOS promised, as before. Whether a 2017 Mac and a real printer agree is for a person with both to say; see docs/macos.md.

## [0.4.0] - 2026-10-19

- [Fix] **Switching the print station off now cuts the stations off.** The feature only removed the menu entry: stations already joined kept receiving every published round, a join link made in the fifteen minutes before still worked, and the admin could not remove a station from the page because the disabled-feature guard swallowed Remove. A station of an account without the feature is now refused at `hello` (as revoked) and at joining, and Remove works with the feature off.
- [Fix] **A long printer name with an accent in it no longer makes the station flap.** The OpenPairings plug-in cut a status value at 200 bytes, which can be the middle of a UTF-8 character; the invalid string failed to encode, crashed the station's socket, and the station reconnected and sent it again, for ever. Status values are now cut by characters.
- [Security] **A web page can no longer drive the station by renaming it.** The page was open to any `Host` and any socket origin, so a page in the hall PC's browser could point its own name at 127.0.0.1, count as same-origin, and press the station's buttons. The station now answers 403 to a `Host` that is not its own (`localhost`, `127.0.0.1`, `PHX_HOST`, and with `POLIS_LISTEN=lan` the machine's host name and addresses), and the live socket checks the same list. The launcher, the in-app window and LAN mode ask for those names and carry on as before.

## [0.3.1] - 2026-10-18

- [Fix] **Stopping no longer ends in a red stack trace.** On the way out the launcher-details process tidied up its secret by asking the application controller, which at that point is busy dying and answers everyone with an exit. The secret goes with the VM anyway, so now it lets the question go unanswered and leaves quietly.

## [0.3.0] - 2026-10-18

- [Feature] **The room is a choice now, when the tournament has rooms.** OpenPairings sends the room names with the station's settings, and the station's page offers them in a picker instead of a text field that accepted "Hal", "hal" and "The big room, you know the one". A station in a room prints only the boards that room holds, on top of its board numbers and categories. Nothing picked is every room, as before.
- [Feature] **A room the server does not accept is said.** If OpenPairings turns a room down it keeps what it had, and the page says the room is not one of the tournament's, in the same tone it already used for board numbers that do not parse.
- [Change] **The plug-in keeps a station's room by the room's id**, so renaming "Hall B" to "Annexe" in OpenPairings moves nobody, and removing a room leaves its stations in no room rather than in a room that no longer exists. Board numbers are now read by OpenPairings' own reader; the plug-in's copy retired without ceremony.
- [Change] **An old free-text room survives, but filters nothing.** A label typed before the tournament had rooms stays visible as "not a room of this tournament" until somebody picks a real one. A server that predates rooms sends no list, and gets the free-text field it was always used to.
- [Change] **New address.** The repository moved to github.com/teapot-chess; old links still redirect, out of politeness rather than obligation.
## [0.2.0] - 2026-10-18

- [Change] **Print station moved out of the tournament's top bar and into its Settings**, under Publishing, with the rail beside it. A thing you set up once and then forget about does not get a tab next to Pairings. The station's page now says where to find it: Settings → Print station → Add a print station.
- [Feature] **Each printer prints its own share.** A station can be told which categories and which board numbers it prints (`1-20, 35, 40-45`, read back to you before you save, because typos are the only thing arbiters produce more of than pairings). A board prints when its number is in the list and either player is in a ticked category; a bye answers for its one player. Nothing set is everything, so nobody who ignores this feature notices it exists.
- [Feature] **Name and room, settable from both ends.** The station's page and OpenPairings edit the same settings, OpenPairings keeps them, and a change on one side shows on the other at the next push. Changing them from the hall needs the line up; a change the server cannot hear is a change that did not happen.
- [Feature] **The sheet says which part of the hall it is for.** A station printing a share puts its room, boards and categories in the heading, and a round with nothing for it prints nothing instead of a page announcing an absence.
- [Change] **Joining again keeps the name somebody gave the station**, rather than reverting to the machine's hostname, which nobody chose on purpose.
- [Fix] **Stopping Polis stops Polis, and what it started.** Every `lp`, `lpstat` and PowerShell now has a deadline (fifteen seconds to name the printers, a minute to take a job, two for Windows), past which it is killed and the job fails with a sentence instead of saying "printing" until further notice. A command whose caller is gone is killed too, and whatever is still running when the station stops goes with it: Erlang closes the port and walks away, and the `lp` on the other end used to stay behind, waiting for a printer that was not coming back.
- [Fix] **No part of a stop waits forever.** Every supervisor has a deadline, open browser connections get three seconds instead of fifteen, and on the Mac the launcher's SIGKILL after twenty seconds now reaches the whole tree under the server - the BEAM and the programs it started - rather than the BEAM alone. The app's own last resort, ten seconds later, does the same instead of killing only the script and leaving the server to launchd.

- [Change] **The Print station switch is in the Belgian pack** of OpenPairings' Features, not under "Optional tools for any federation", a heading whose main achievement was never being read.

## [0.1.0] - 2026-10-18

- [Feature] **A print station for the hall.** Polis joins a tournament in OpenPairings with a join link, keeps a line open to it, and prints the pairings list and the place cards of every newly published round on the printer of the machine it runs on. Once per round, which is the number of times anyone wants a pairings list taped to a pillar.
- [Feature] **It does not reprint behind anybody's back.** A round the arbiter changes after it came out of the printer is not printed again by itself; the page says "changed since it was printed" and offers Reprint. "Print round N again" in OpenPairings prints what it names, at once.
- [Feature] **Switches per tournament:** the pairings list and the place cards each on or off, and one to five copies of the list. Without a printer chosen, jobs wait in the queue and go when one is; Polis never guesses which printer is the hall's, because the bar's printer would be a guess too.
- [Feature] **A queue you can read.** The last fifty jobs with what happened to each - waiting for a printer, queued, printing, printed, or failed with the printer's own words - a Reprint button, and the PDF of every sheet in the browser.
- [Feature] **Its own sheets.** The pairings list (board, both players, rating and points, a bye where there is one, the header and the page number on every page) and tent-shaped place cards with the upper half upside down and a fold line, laid out on A4 or Letter. Long names are made smaller and then cut, never spilled into the next column.
- [Feature] **Two roads to paper.** CUPS on Linux and macOS, with a small PDF writer of its own; Windows PowerShell and the printer's driver on Windows, which every Windows 10 and 11 has, so nothing is installed beside it. A dry run writes PDFs instead, and development and the tests never use anything else.
- [Feature] **The page and its help in English and Dutch**, the language remembered per browser. The sheets speak the tournament's language, since the players read them and not whoever has the page open.
- [Feature] **Releases**: a Windows installer that updates itself and a portable zip, Linux archives for PCs and the Raspberry Pi with a one-line installer and a systemd service, and an Apple Silicon Mac app. An update waits for a sheet that is printing, unless it is told twice, and says so on every page including the help; a launcher's Details panel says how many jobs are waiting, which printer is chosen and how many lines are up.

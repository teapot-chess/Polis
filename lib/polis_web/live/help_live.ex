defmodule PolisWeb.HelpLive do
  @moduledoc """
  The station's short help, at `/help`, in English and Dutch: what Polis
  is, how to join a tournament, the printer, what prints by itself and what
  does not, and what to do when something is red. Nothing is read from the
  station: it is text, and it stays right when the station itself is the
  thing that is wrong.

  Written per language rather than through gettext: a manual is prose, and
  prose translated a sentence at a time reads like it.
  """

  use PolisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Polis.PubSub, Polis.Updates.topic())
    {:ok, assign(socket, notice: Polis.Updates.notice())}
  end

  # A newer version heard of, or put off: the banner follows.
  @impl true
  def handle_info(:update_changed, socket),
    do: {:noreply, assign(socket, notice: Polis.Updates.notice())}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{locale: "nl"} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:help} subtitle="Help" notice={@notice}>
      <article id="manual">
        <section id="help-what">
          <h2>Wat Polis is</h2>
          <p>
            Polis is het printstation van de zaal: een klein programma op een computer met een printer. Het sluit aan bij een toernooi in OpenPairings en drukt van elke nieuwe ronde de paringslijst en de tafelkaartjes af, zodra de arbiter de ronde publiceert. Wie tegen wie speelt, beslis je in OpenPairings, niet hier.
          </p>
          <p>
            Polis belt zelf naar de server. In het netwerk van de zaal hoeft niets open te staan.
          </p>
        </section>

        <section id="help-join">
          <h2>Aansluiten bij een toernooi</h2>
          <ol>
            <li>
              In OpenPairings: Instellingen van het toernooi → Printstation → "Printstation toevoegen". Er verschijnt een link, goed voor één station en vijftien minuten.
            </li>
            <li>Plak de link in het veld "Aansluiten bij een toernooi" op deze pagina.</li>
            <li>
              Druk op "Aansluiten". Het toernooi staat dan in de lijst, met een groen bolletje zodra de verbinding open is.
            </li>
          </ol>
          <p>
            Een sleutel hoef je nooit te zien of te typen; Polis haalt hem zelf op. Is de link verlopen of al gebruikt, maak dan een nieuwe. Een link voor een ander zaalprogramma (bijvoorbeeld de omroeper) werkt hier niet, en dat zegt de pagina ook.
          </p>
        </section>

        <section id="help-printer">
          <h2>De printer</h2>
          <p>
            Kies de printer en het papier (A4 of Letter) onder "Printer". Polis kiest nooit zelf een printer: een paringslijst op de printer van de bar is erger dan geen. Zolang er geen printer gekozen is, wachten de rondes in de wachtrij, en ze gaan zodra je er een kiest.
          </p>
          <p>
            "Testafdruk" drukt één blad af met een kader langs de rand: is het kader heel, dan kloppen de marges.
          </p>
        </section>

        <section id="help-what-prints">
          <h2>Wat vanzelf afgedrukt wordt, en wat niet</h2>
          <ul class="prose">
            <li>
              Een nieuwe ronde: de paringslijst (zoveel exemplaren als je kiest, één tot vijf; dat kiezen is geavanceerd) en de tafelkaartjes, elk met zijn eigen schakelaar. Eén keer per ronde.
            </li>
            <li>
              Een ronde die de arbiter na het afdrukken nog wijzigt: niets vanzelf. Er komt "gewijzigd sinds het afgedrukt is" bij het toernooi te staan, met een knop "Opnieuw afdrukken". Een blad aan de muur dat vanzelf verandert, is erger dan een blad dat oud is.
            </li>
            <li>
              "Ronde N opnieuw printen" in OpenPairings: wat het noemt, meteen.
            </li>
          </ul>
          <p>
            Een tafelkaartje is een tentje: vouw het blad op de stippellijn, en elke kant leest goed voor wie ervoor zit. Wie een bye heeft, krijgt geen kaartje.
          </p>
        </section>

        <section id="help-share">
          <h2>Wat dit station afdrukt (geavanceerd)</h2>
          <p>
            Een zaal met twee printers wil niet twee keer dezelfde lijst. Onder "Dit station" bij een toernooi geef je het station een naam en kies je een ruimte van het toernooi, en kies je wat het afdrukt: categorieën (vinkjes) en bordnummers, zoals <span class="mono">1-20, 35, 40-45</span>. Onder het veld staat meteen hoe Polis de nummers leest.
          </p>
          <ul class="prose">
            <li>
              Een bord wordt afgedrukt als het in de ruimte van dit station ligt, zijn nummer in de lijst staat én een van beide spelers in een aangevinkte categorie zit. Bij een bye telt de ene speler die er is.
            </li>
            <li>
              De ruimtes maakt de arbiter in OpenPairings (Instellingen, Ruimtes); hier kies je er een uit de lijst, of "Geen ruimte". Bij een server zonder ruimtes is het een vrij tekstveld, en een ruimte die niet bij het toernooi hoort, is alleen een naam: die filtert niets tot je een echte ruimte kiest.
            </li>
            <li>
              Niets aangevinkt is elke categorie; geen bordnummers is elk bord; geen ruimte is elke ruimte. Niets ingesteld is dus alles, zoals vroeger.
            </li>
            <li>
              Het nummer van een bord is het getal waarmee het begint: bord 3.1 van een teamtoernooi is 3.
            </li>
            <li>
              Een ronde zonder één bord voor dit station wordt niet afgedrukt. Een lijst die wel afgedrukt wordt, zet de ruimte en het deel in de kop.
            </li>
          </ul>
          <p>
            OpenPairings bewaart dit, niet Polis: de arbiter kan hetzelfde wijzigen bij Instellingen → Printstation, en wat de een bewaart, ziet de ander bij de volgende verbinding. Wijzigen kan dus alleen als de verbinding er is. Een filter dat na het afdrukken verandert, drukt niets opnieuw af; de ronde staat dan op "gewijzigd sinds het afgedrukt is".
          </p>
        </section>

        <section id="help-queue">
          <h2>De wachtrij</h2>
          <p>
            Elke afdruk staat in de wachtrij, de nieuwste bovenaan, met wat ermee gebeurd is: wacht op een printer, in de wachtrij, wordt afgedrukt, afgedrukt, of mislukt met de reden. "PDF openen" toont het blad zoals het afgedrukt wordt; "Opnieuw afdrukken" stuurt het nog een keer. De laatste vijftig blijven bewaard.
          </p>
        </section>

        <section id="help-update">
          <h2>Nieuwe versies</h2>
          <p>
            Polis kijkt af en toe of er een nieuwe versie is, en zegt het dan bovenaan de pagina. Installeren doe je zelf, met "Downloaden en installeren": het station is dan ongeveer een minuut weg, en wat in die minuut gepubliceerd wordt, komt daarna alsnog. Wordt er net een blad afgedrukt, dan wacht Polis tot het eruit is; "Toch installeren" is het tweede ja voor wie niet wil wachten. Wil je er niets van horen, zet dan "Af en toe naar een nieuwere versie kijken" uit.
          </p>
          <p>
            De installatie voor Windows en die voor Linux (met install.sh) werken zichzelf bij. Een draagbare kopie en de Mac-app vervang je met de hand.
          </p>
        </section>

        <section id="help-advanced">
          <h2>Geavanceerde functies</h2>
          <p>
            Onder "Dit programma" staat het vakje "Geavanceerde functies tonen". Uit (zo begint elk station) is de pagina klein: toernooien, aansluiten, printer en wachtrij. Aan komt erbij: het aantal exemplaren van de paringslijst, "Dit station" per toernooi, de instellingen voor updates en starten met Windows. Die delen zijn hieronder met "(geavanceerd)" aangeduid.
          </p>
          <p>
            Een station dat deze dingen al gebruikte (updates uit, starten met Windows aan, meer dan één exemplaar, of een deel van de ronde ingesteld) zet het vakje de eerste keer zelf aan, zodat niemand iets kwijtraakt. Daarna beslis jij.
          </p>
        </section>

        <section id="help-data">
          <h2>Waar Polis bewaart wat het weet</h2>
          <p>
            Eén map, nooit binnen het programma zelf, zodat een update of het verwijderen van Polis er niet aan komt: op Windows <span class="mono">%LOCALAPPDATA%\PolisData</span>, op een Mac <span class="mono">~/Library/Application Support/PolisData</span>, op Linux met install.sh <span class="mono">/var/lib/polis</span>, anders <span class="mono">~/.polis</span>. De omgevingsvariabele
            <span class="mono">POLIS_DATA</span>
            kiest een andere.
          </p>
          <p>
            Daarin staan de toernooien met hun sleutels, de instellingen en de laatste vijftig afdrukken. Geef die map aan niemand: met de sleutels kan een ander zich als dit station aanmelden.
          </p>
        </section>

        <section id="help-trouble">
          <h2>Als iets rood is</h2>
          <ul class="prose">
            <li>
              Een rood bolletje bij een toernooi: de verbinding met de server is weg. Polis probeert het zelf opnieuw; de reden staat erbij. Wat er intussen gepubliceerd wordt, komt als de verbinding terug is.
            </li>
            <li>
              Een toernooi dat uit de lijst verdwijnt: het station is in OpenPairings verwijderd. Sluit opnieuw aan met een nieuwe link als dat een vergissing was.
            </li>
            <li>
              Een afdruk die mislukt: de reden is wat de printer of het systeem zei. Kijk of de printer aan staat en papier heeft, en druk op "Opnieuw afdrukken".
            </li>
          </ul>
        </section>
      </article>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:help} subtitle="Help" notice={@notice}>
      <article id="manual">
        <section id="help-what">
          <h2>What Polis is</h2>
          <p>
            Polis is the hall's print station: a small program on a computer with a printer. It joins a tournament in OpenPairings and prints the pairings list and the place cards of every new round as soon as the arbiter publishes it. Who plays whom is decided in OpenPairings, not here.
          </p>
          <p>
            Polis calls the server itself. Nothing needs to be opened in the hall's network.
          </p>
        </section>

        <section id="help-join">
          <h2>Joining a tournament</h2>
          <ol>
            <li>
              In OpenPairings: the tournament's Settings → Print station → "Add a print station". A link appears, good for one station and fifteen minutes.
            </li>
            <li>Paste the link into the "Join a tournament" field on this page.</li>
            <li>
              Press "Join". The tournament is then in the list, with a green dot once the line is up.
            </li>
          </ol>
          <p>
            You never see or type a key; Polis fetches it itself. When the link is expired or used, make a new one. A link for another hall program (the announcer, say) does not work here, and the page says so.
          </p>
        </section>

        <section id="help-printer">
          <h2>The printer</h2>
          <p>
            Choose the printer and the paper (A4 or Letter) under "Printer". Polis never picks a printer by itself: a pairings list on the bar's printer is worse than none. Until a printer is chosen, rounds wait in the queue, and they go as soon as you choose one.
          </p>
          <p>
            "Test print" prints one sheet with a frame along the edge: if the frame is whole, the margins are right.
          </p>
        </section>

        <section id="help-what-prints">
          <h2>What prints by itself, and what does not</h2>
          <ul class="prose">
            <li>
              A new round: the pairings list (as many copies as you choose, one to five; choosing is advanced) and the place cards, each with its own switch. Once per round.
            </li>
            <li>
              A round the arbiter changes after it was printed: nothing by itself. The tournament shows "changed since it was printed", with a Reprint button. A sheet on the wall that changes by itself is worse than one that is old.
            </li>
            <li>
              "Print round N again" in OpenPairings: what it names, at once.
            </li>
          </ul>
          <p>
            A place card is a tent: fold the sheet on the dashed line, and each side reads the right way up for whoever sits in front of it. A player with a bye gets no card.
          </p>
        </section>

        <section id="help-share">
          <h2>What this station prints (advanced)</h2>
          <p>
            A hall with two printers does not want the same list twice. Under "This station" by a tournament you give the station a name and pick one of the tournament's rooms, and choose what it prints: categories (tick boxes) and board numbers, like <span class="mono">1-20, 35, 40-45</span>. Below the field, Polis says at once how it reads the numbers.
          </p>
          <ul class="prose">
            <li>
              A board prints when it is in this station's room, its number is in the list and either player is in a ticked category. For a bye, the one player there is counts.
            </li>
            <li>
              The rooms are made by the arbiter in OpenPairings (Settings, Rooms); here you pick one from the list, or "No room". Against a server without rooms it is a free text field, and a room that is not one of the tournament's is only a label: it filters nothing until you pick a real room.
            </li>
            <li>
              Nothing ticked is every category; no board numbers is every board; no room is every room. Nothing set is therefore everything, as before.
            </li>
            <li>
              A board's number is the number it starts with: board 3.1 of a team tournament is 3.
            </li>
            <li>
              A round without a single board for this station is not printed. A list that does print puts the room and the share in its heading.
            </li>
          </ul>
          <p>
            OpenPairings keeps these, not Polis: the arbiter can change the same things under Settings → Print station, and what one side saves, the other sees on the next push. So changing them needs the line up. A share that changes after a round was printed reprints nothing; the round shows "changed since it was printed".
          </p>
        </section>

        <section id="help-queue">
          <h2>The queue</h2>
          <p>
            Every print is in the queue, newest first, with what happened to it: waiting for a printer, queued, printing, printed, or failed with the reason. "Open PDF" shows the sheet as it prints; "Reprint" sends it once more. The last fifty are kept.
          </p>
        </section>

        <section id="help-update">
          <h2>New versions</h2>
          <p>
            Polis looks for a new version now and then and says so at the top of the page. Installing is yours to start, with "Download and install": the station is away for about a minute, and whatever is published in that minute arrives afterwards. When a sheet is printing, Polis waits until it is out; "Install anyway" is the second yes for whoever will not wait. To hear nothing of it, switch off "Look for a newer version now and then".
          </p>
          <p>
            The Windows installation and the Linux one (with install.sh) update themselves. A portable copy and the Mac app are replaced by hand.
          </p>
        </section>

        <section id="help-advanced">
          <h2>Advanced features</h2>
          <p>
            Under "This program" is the tick "Show advanced features". Off (how every station starts) the page is small: tournaments, joining, the printer and the queue. On adds the number of copies of the pairings, "This station" per tournament, and the settings for updates and starting with Windows. Those parts are marked "(advanced)" below.
          </p>
          <p>
            A station that already used these things (updates off, start with Windows on, more than one copy, or a share of the round set) ticks it by itself the first time, so nobody loses anything. After that it is yours to decide.
          </p>
        </section>

        <section id="help-data">
          <h2>Where Polis keeps what it knows</h2>
          <p>
            One folder, never inside the program itself, so that an update or removing Polis does not touch it: on Windows <span class="mono">%LOCALAPPDATA%\PolisData</span>, on a Mac <span class="mono">~/Library/Application Support/PolisData</span>, on Linux with install.sh <span class="mono">/var/lib/polis</span>, otherwise <span class="mono">~/.polis</span>. The environment variable
            <span class="mono">POLIS_DATA</span>
            picks another.
          </p>
          <p>
            In it are the tournaments with their keys, the settings and the last fifty prints. Give that folder to nobody: with the keys, someone else can sign in as this station.
          </p>
        </section>

        <section id="help-trouble">
          <h2>When something is red</h2>
          <ul class="prose">
            <li>
              A red dot by a tournament: the line to the server is down. Polis tries again by itself; the reason is beside it. Whatever is published meanwhile arrives when the line is back.
            </li>
            <li>
              A tournament that disappears from the list: the station was removed in OpenPairings. Join again with a new link if that was a mistake.
            </li>
            <li>
              A print that failed: the reason is what the printer or the system said. Check that the printer is on and has paper, and press Reprint.
            </li>
          </ul>
        </section>
      </article>
    </Layouts.app>
    """
  end
end

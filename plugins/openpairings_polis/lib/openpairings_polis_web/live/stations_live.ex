defmodule OpenPairingsPolisWeb.StationsLive do
  @moduledoc """
  The print station pages.

    * `/p/polis` (`:index`) - this account's stations across every
      tournament it can open, or a short word on what a print station is.
    * `/p/polis/tournaments/:id` (`:show`) - the tournament's stations
      (online or not, last seen, what each said about its printer), "Add a
      print station" (a one-time link and its QR code), Remove, "Print
      round N again", and per station its name, its room and what it
      prints (categories, board numbers). The room is picked from the
      tournament's own (Settings, Rooms). It sits in the tournament's
      Settings frame (`PairingsEngineWeb.SettingsSupport.settings_page/1`),
      so the rail stays beside it.

  A station's name, room and filters are also the station's own to
  change, over its link; both sides edit the same row
  (`OpenPairingsPolis.Stations.update_settings/2`). What one saves, the
  other sees on its next push - here, at once, through the topic. A draft
  being typed on this page is left alone until it is saved or dropped.

  Admin-only and signed-in by the core (`:plugins` live_session). Pages and
  stations meet on `OpenPairingsPolis.Stations.topic/1`; nothing here
  holds a socket.
  """
  use OpenPairingsPolisWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [settings_page: 1]

  alias OpenPairingsPolis.{Plugin, Stations}
  alias PairingsEngine.{BoardRanges, Features, Rooms, Tournaments}

  # Online/offline is a matter of time passing, so the page looks again
  # now and then even when nobody says anything.
  @tick_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: gettext("Print station"),
       enabled?: Features.enabled?(scope, Plugin.feature()),
       tournament: nil,
       join: nil,
       latest_round: 0,
       station_count: 0,
       note: nil,
       error: nil,
       drafts: %{},
       print_form: to_form(%{"what" => "both"}, as: :print)
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Stations.subscribe(tournament.id)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:noreply,
     socket
     |> assign(tournament: tournament, page_title: gettext("Print station"))
     |> assign_latest_round()
     |> load_stations()}
  end

  def handle_params(_params, _uri, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load_stations(socket)}
  end

  defp assign_latest_round(socket),
    do:
      assign(socket,
        latest_round: Tournaments.latest_published_round_number(socket.assigns.tournament)
      )

  defp load_stations(%{assigns: %{tournament: nil}} = socket) do
    stations = Stations.list_for_scope(socket.assigns.current_scope)

    socket
    |> assign(station_count: length(stations))
    |> stream(:stations, stations, reset: true)
  end

  defp load_stations(socket) do
    stations = Stations.list_stations(socket.assigns.tournament.id)

    socket
    |> assign(station_count: length(stations))
    |> stream(:stations, stations, reset: true)
  end

  ## ---------- events ----------

  # Removing a station is let through even with the feature off: switching it
  # off must not leave the admin unable to revoke the stations already joined.
  @impl true
  def handle_event("remove_station", %{"id" => id}, socket) do
    case Stations.revoke(socket.assigns.tournament, id) do
      {:ok, _station} ->
        {:noreply,
         socket
         |> assign(note: gettext("Print station removed."), error: nil)
         |> load_stations()}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: gettext("That print station is not there any more."))}
    end
  end

  # The buttons are not drawn without the feature; a button not drawn is
  # still an event anybody can send.
  def handle_event(_event, _params, %{assigns: %{enabled?: false}} = socket),
    do:
      {:noreply,
       assign(socket, error: gettext("The print station is switched off for your account."))}

  def handle_event("add_station", _params, socket) do
    {:ok, join} =
      Stations.create_join_code(socket.assigns.current_scope, socket.assigns.tournament)

    {:noreply,
     assign(socket,
       join: Map.put(join, :qr, PairingsEngine.Mobile.qr_svg(join.url)),
       note: nil,
       error: nil
     )}
  end

  def handle_event("close_join", _params, socket), do: {:noreply, assign(socket, join: nil)}

  def handle_event("print_again", %{"print" => %{"what" => what}}, socket)
      when what in ["pairings", "placecards", "both", "standings", "playerlist", "slips"] do
    case socket.assigns.latest_round do
      0 ->
        {:noreply, assign(socket, error: gettext("No round is published yet."), note: nil)}

      n ->
        Stations.print_again(socket.assigns.tournament.id, n, what)

        {:noreply,
         assign(socket,
           note: gettext("Sent to every print station that is online: round %{n}.", n: n),
           error: nil,
           print_form: to_form(%{"what" => what}, as: :print)
         )}
    end
  end

  def handle_event("print_again", _params, socket), do: {:noreply, socket}

  # Typing in a station's form: kept as a draft, so a status frame arriving
  # meanwhile (they do, every time a sheet comes out) does not undo it.
  def handle_event("station_change", %{"station" => %{"id" => id} = params}, socket) do
    case station_in_view(socket, id) do
      nil ->
        {:noreply, socket}

      station ->
        drafts = Map.put(socket.assigns.drafts, station.id, draft_params(params))

        {:noreply,
         socket
         |> assign(drafts: drafts)
         |> stream_insert(:stations, station)}
    end
  end

  def handle_event("station_save", %{"station" => %{"id" => id} = params}, socket) do
    attrs = draft_params(params)

    case Stations.update_settings(socket.assigns.tournament, id, attrs) do
      {:ok, station} ->
        {:noreply,
         socket
         |> assign(
           drafts: Map.delete(socket.assigns.drafts, station.id),
           note: gettext("Saved. The station hears of it at once when it is online."),
           error: nil
         )
         |> load_stations()}

      {:error, {:boards, _reason}} ->
        {:noreply,
         assign(socket,
           error:
             gettext("The board numbers do not read. Use numbers and ranges: 1-20, 35, 40-45."),
           note: nil
         )}

      # Removed in Settings, Rooms while this page still offered it.
      {:error, {:room, _reason}} ->
        {:noreply,
         assign(socket,
           error: gettext("That room is not one of this tournament's rooms any more."),
           note: nil
         )}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: gettext("That print station is not there any more."))}
    end
  end

  def handle_event("station_reset", %{"id" => id}, socket) do
    case station_in_view(socket, id) do
      nil ->
        {:noreply, socket}

      station ->
        {:noreply,
         socket
         |> assign(drafts: Map.delete(socket.assigns.drafts, station.id))
         |> stream_insert(:stations, station)}
    end
  end

  defp station_in_view(%{assigns: %{tournament: nil}}, _id), do: nil

  defp station_in_view(socket, id) do
    Enum.find(Stations.list_stations(socket.assigns.tournament.id), &(to_string(&1.id) == id))
  end

  defp draft_params(params) do
    %{
      "name" => params["name"] || "",
      "room_id" => params["room_id"] || "keep",
      "categories" => Enum.reject(List.wrap(params["categories"]), &(&1 == "")),
      "boards" => params["boards"] || ""
    }
  end

  ## ---------- messages ----------

  @impl true
  def handle_info(:polis_stations_changed, socket), do: {:noreply, load_stations(socket)}

  # A category or a room added or renamed changes what can be picked.
  def handle_info({:tournament_changed, _tid, _hint}, %{assigns: %{tournament: %{}}} = socket) do
    tournament =
      Tournaments.get_tournament(socket.assigns.tournament.id) || socket.assigns.tournament

    {:noreply,
     socket |> assign(tournament: tournament) |> assign_latest_round() |> load_stations()}
  end

  def handle_info({:tournament_changed, _tid, _hint}, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load_stations(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## ---------- view ----------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active={if @tournament, do: "settings", else: "plugin:polis"}
    >
      <.frame tournament={@tournament} current_scope={@current_scope}>
        <p id="polis-note" role="status" aria-live="polite" class={@note && "ok-note"}>{@note}</p>

        <p :if={@error} id="polis-error" role="alert" class="error-note">{@error}</p>

        <section :if={!@enabled?} id="polis-not-enabled" class="card">
          <p class="hint">
            {gettext("The print station is switched off for your account.")}
            <.link navigate="/users/features" id="polis-features-link">
              {gettext("Switch it on in your settings.")}
            </.link>
          </p>
        </section>

        <%= if @tournament do %>
          <section :if={@enabled?} id="polis-add" class="card">
            <h2>{gettext("Add a print station")}</h2>

            <p class="hint">
              {gettext(
                "Paste this link into Polis on the hall PC and press Join, or scan the code with Manubrium on your phone to pass the link on to that PC. The link works once, for %{minutes} minutes.",
                minutes: Stations.code_minutes()
              )}
            </p>

            <%= if @join do %>
              <div
                id="polis-join"
                class="polis-join"
                style="display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-start"
              >
                <div
                  id="polis-join-qr"
                  style="background: #fff; padding: 8px; border-radius: 8px; line-height: 0"
                >
                  {Phoenix.HTML.raw(@join.qr)}
                </div>

                <div style="flex: 1 1 280px; min-width: 0">
                  <label for="polis-join-url" class="hint">{gettext("Join link")}</label>
                  <div style="display: flex; gap: 8px; margin-top: 4px">
                    <input
                      id="polis-join-url"
                      type="text"
                      readonly
                      value={@join.url}
                      style="flex: 1; min-width: 0; font-family: ui-monospace, monospace"
                    />
                    <button
                      type="button"
                      id="polis-copy-link"
                      class="pe-btn"
                      phx-hook=".CopyJoinLink"
                      data-target="polis-join-url"
                      data-done={gettext("Copied")}
                    >
                      {gettext("Copy")}
                    </button>
                  </div>

                  <p class="hint" id="polis-join-expiry" style="margin-top: 8px">
                    {gettext("Valid until %{time} UTC, for one print station.",
                      time: Calendar.strftime(@join.expires_at, "%H:%M")
                    )}
                  </p>

                  <div class="actions">
                    <button type="button" class="pe-btn" id="polis-new-link" phx-click="add_station">
                      {gettext("Make a new link")}
                    </button>

                    <button type="button" class="pe-btn" id="polis-close-link" phx-click="close_join">
                      {gettext("Done")}
                    </button>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="actions">
                <button
                  type="button"
                  class="pe-btn primary"
                  id="polis-add-station"
                  phx-click="add_station"
                >
                  {gettext("Add a print station")}
                </button>
              </div>
            <% end %>
          </section>

          <section :if={@enabled? and @station_count > 0} id="polis-print-again" class="card">
            <h2>{gettext("Print again")}</h2>

            <%= if @latest_round > 0 do %>
              <.form
                for={@print_form}
                id="polis-print-form"
                phx-submit="print_again"
                class="form-grid"
              >
                <.input
                  field={@print_form[:what]}
                  type="select"
                  label={gettext("What")}
                  options={[
                    {gettext("Pairings and place cards"), "both"},
                    {gettext("Pairings"), "pairings"},
                    {gettext("Place cards"), "placecards"},
                    {gettext("Standings"), "standings"},
                    {gettext("Player list"), "playerlist"},
                    {gettext("Result slips"), "slips"}
                  ]}
                />
                <div class="actions">
                  <button type="submit" class="pe-btn" id="polis-print-button">
                    {gettext("Print round %{n} again", n: @latest_round)}
                  </button>
                </div>
              </.form>
            <% else %>
              <p class="hint" id="polis-nothing-published">
                {gettext("No round is published yet. The first one prints by itself.")}
              </p>
            <% end %>
          </section>
        <% end %>

        <section id="polis-stations-card" class="card">
          <h2>{gettext("Print stations")}</h2>

          <p :if={@station_count == 0} id="polis-no-stations" class="hint">
            {gettext("No print station has joined yet.")}
          </p>

          <div id="polis-stations" phx-update="stream">
            <article
              :for={{dom_id, s} <- @streams.stations}
              id={dom_id}
              class="polis-station"
              style="display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; border-top: 1px solid var(--pe-border, #ddd); padding: 12px 0"
            >
              <div style="min-width: 0">
                <p style="margin: 0">
                  <span
                    id={"#{dom_id}-state"}
                    class={["polis-dot", if(Stations.online?(s), do: "ok-note", else: "hint")]}
                    style="font-weight: 600"
                  >
                    {if Stations.online?(s), do: gettext("Online"), else: gettext("Offline")}
                  </span>
                  <strong>&nbsp;{s.name}</strong>
                  <span
                    :if={Stations.room_name(s, @tournament || s.tournament) != ""}
                    id={"#{dom_id}-room"}
                    class="hint"
                  >
                    &middot; {Stations.room_name(s, @tournament || s.tournament)}
                  </span>

                  <span :if={!@tournament} class="hint">
                    &middot;
                    <.link navigate={"/p/polis/tournaments/#{s.tournament_id}"}>
                      {s.tournament.name}
                    </.link>
                  </span>
                </p>

                <p class="hint" style="margin: 2px 0 0">
                  {seen_text(s.last_seen_at)}
                  <span :if={s.status["printer"]}>
                    &middot; {gettext("Printer: %{printer}", printer: s.status["printer"])}
                  </span>

                  <span :if={s.status["last_printed_round"]} id={"#{dom_id}-printed"}>
                    &middot; {gettext("Last printed: round %{n}", n: s.status["last_printed_round"])}
                  </span>
                </p>

                <p :if={@tournament} id={"#{dom_id}-share"} class="hint" style="margin: 2px 0 0">
                  {share_text(s, @tournament)}
                </p>
              </div>

              <button
                :if={@tournament}
                type="button"
                class="pe-btn"
                id={"#{dom_id}-remove"}
                phx-click="remove_station"
                phx-value-id={s.id}
                data-confirm={
                  gettext("Remove this print station? It stops printing for this tournament.")
                }
              >
                {gettext("Remove")}
              </button>

              <div :if={@tournament && @enabled?} style="flex-basis: 100%">
                <.station_settings
                  station={s}
                  draft={@drafts[s.id]}
                  tournament={@tournament}
                  dom_id={dom_id}
                />
              </div>
            </article>
          </div>
        </section>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyJoinLink">
          // Copies the join link. The clipboard API wants a secure context;
          // the fallback selects the text, which is half the job done anyway.
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const input = document.getElementById(this.el.dataset.target)
                if (!input) return
                const done = () => {
                  const label = this.el.textContent
                  this.el.textContent = this.el.dataset.done
                  setTimeout(() => { this.el.textContent = label }, 1500)
                }
                input.select()
                if (navigator.clipboard && window.isSecureContext) {
                  navigator.clipboard.writeText(input.value).then(done, () => {})
                } else if (document.execCommand && document.execCommand("copy")) {
                  done()
                }
              })
            }
          }
        </script>
      </.frame>
    </Layouts.app>
    """
  end

  # A tournament's page sits in its Settings frame, the rail beside it; the
  # overview belongs to the account and has a plain header.
  attr :tournament, :any, required: true
  attr :current_scope, :any, required: true
  slot :inner_block, required: true

  defp frame(%{tournament: nil} = assigns) do
    ~H"""
    <div class="page-header">
      <div>
        <h1>{gettext("Print station")}</h1>

        <p class="subtitle" style="margin: 0">
          {gettext(
            "A print station is a PC in the playing hall with a printer and the Polis program on it. Join it to a tournament in that tournament's Settings, under Print station, and it prints every round the moment you publish it."
          )}
        </p>
      </div>
    </div>
    {render_slot(@inner_block)}
    """
  end

  defp frame(assigns) do
    ~H"""
    <.settings_page
      tournament={@tournament}
      current_scope={@current_scope}
      active="plugin:polis"
      subtitle={gettext("Settings - Print station")}
    >
      <p class="hint" style="margin-top: 0">
        {gettext(
          "A PC in the hall with a printer. When you publish a round of %{name}, every print station below prints the pairings and the place cards - each its own share, when you give it one.",
          name: @tournament.name
        )}
      </p>
      {render_slot(@inner_block)}
    </.settings_page>
    """
  end

  # One station's name, room and share of the round. The draft, while
  # there is one, is what the form shows.
  attr :station, :any, required: true
  attr :draft, :map, default: nil
  attr :tournament, :any, required: true
  attr :dom_id, :string, required: true

  defp station_settings(assigns) do
    %{station: s, tournament: t} = assigns
    legacy = if Stations.legacy_room?(s, t), do: Stations.room_name(s, t)

    current_room =
      case Stations.room(s, t) do
        %{id: id} -> id
        nil -> if legacy, do: "keep", else: ""
      end

    params =
      assigns.draft ||
        %{
          "name" => s.name,
          "room_id" => current_room,
          "categories" => s.filter_categories || [],
          "boards" => s.filter_boards || ""
        }

    room_options =
      [{gettext("No room: the whole hall"), ""}] ++
        if(legacy,
          do: [{gettext("%{room} (not a room of this tournament)", room: legacy), "keep"}],
          else: []
        ) ++ Enum.map(Rooms.list(t), &{&1.name, &1.id})

    assigns =
      assign(assigns,
        form: to_form(Map.put(params, "id", to_string(s.id)), as: :station),
        categories: t.categories || [],
        picked: params["categories"],
        boards: BoardRanges.parse(params["boards"]),
        room_options: room_options,
        legacy: legacy,
        has_rooms: Rooms.any?(t)
      )

    ~H"""
    <details id={"#{@dom_id}-settings"} class="polis-station-settings" open={@draft != nil}>
      <summary>{gettext("Name, room and what it prints")}</summary>

      <.form
        for={@form}
        id={"#{@dom_id}-form"}
        phx-change="station_change"
        phx-submit="station_save"
        class="form-grid"
      >
        <input type="hidden" name={@form[:id].name} value={@form[:id].value} />
        <.input
          field={@form[:name]}
          id={"#{@dom_id}-name"}
          type="text"
          label={gettext("Name")}
          maxlength="60"
        />
        <.input
          field={@form[:room_id]}
          id={"#{@dom_id}-room-input"}
          type="select"
          label={gettext("Room")}
          options={@room_options}
        />
        <p :if={@legacy} id={"#{@dom_id}-room-legacy"} class="hint" style="margin: -4px 0 8px">
          {gettext(
            "Typed on the station before this tournament had rooms. It is a label only: the station prints the whole hall until you pick a room."
          )}
        </p>
        <p
          :if={!@has_rooms and !@legacy}
          id={"#{@dom_id}-room-none"}
          class="hint"
          style="margin: -4px 0 8px"
        >
          {gettext("This tournament has no rooms yet. They are made in Settings, Rooms.")}
        </p>
        <fieldset :if={@categories != []} id={"#{@dom_id}-categories"} class="fieldset mb-2">
          <legend class="label">{gettext("Categories")}</legend>
          <input type="hidden" name="station[categories][]" value="" />
          <label
            :for={{c, i} <- Enum.with_index(@categories)}
            for={"#{@dom_id}-cat-#{i}"}
            style="display: inline-flex; gap: 6px; align-items: center; margin-right: 14px"
          >
            <input
              type="checkbox"
              id={"#{@dom_id}-cat-#{i}"}
              name="station[categories][]"
              value={c}
              checked={c in @picked}
              class="checkbox checkbox-sm"
            /> {c}
          </label>

          <p class="hint" style="margin: 4px 0 0">
            {gettext(
              "None ticked: every category. A board prints when either player is in a ticked one."
            )}
          </p>
        </fieldset>

        <.input
          field={@form[:boards]}
          id={"#{@dom_id}-boards"}
          type="text"
          label={gettext("Board numbers")}
          placeholder="1-20, 35, 40-45"
        />
        <p id={"#{@dom_id}-boards-parsed"} class={boards_class(@boards)} style="margin: -4px 0 8px">
          {boards_text(@boards)}
        </p>

        <div class="actions">
          <button type="submit" class="pe-btn primary" id={"#{@dom_id}-save"}>
            {gettext("Save")}
          </button>

          <button
            :if={@draft}
            type="button"
            class="pe-btn"
            id={"#{@dom_id}-reset"}
            phx-click="station_reset"
            phx-value-id={@station.id}
          >
            {gettext("Undo changes")}
          </button>
        </div>
      </.form>
    </details>
    """
  end

  defp boards_class({:ok, _}), do: "hint"
  defp boards_class({:error, _}), do: "error-note"

  defp boards_text({:ok, []}), do: gettext("Every board.")

  defp boards_text({:ok, ranges}),
    do: gettext("Boards %{list}.", list: BoardRanges.format(ranges))

  defp boards_text({:error, {:backwards, token}}),
    do: gettext("\"%{token}\" runs backwards: put the smaller number first.", token: token)

  defp boards_text({:error, {:too_big, token}}),
    do: gettext("\"%{token}\" is past board 9999.", token: token)

  defp boards_text({:error, {_bad, token}}),
    do: gettext("\"%{token}\" is not a board number or a range like 40-45.", token: token)

  # What a station prints, in one line for the list.
  defp share_text(station, tournament) do
    %{room: room, categories: cats, boards: boards} = Stations.filter(station, tournament)

    share =
      case {cats, boards} do
        {[], []} ->
          gettext("Prints everything")

        {[], boards} ->
          gettext("Prints boards %{list}", list: BoardRanges.format(boards))

        {cats, []} ->
          gettext("Prints %{categories}", categories: Enum.join(cats, ", "))

        {cats, boards} ->
          gettext("Prints boards %{list}, %{categories}",
            list: BoardRanges.format(boards),
            categories: Enum.join(cats, ", ")
          )
      end

    case room do
      nil -> share
      %{ranges: []} -> gettext("%{room} has no boards yet, so nothing prints", room: room.name)
      %{name: name} -> gettext("In %{room}: %{share}", room: name, share: share)
    end
  end

  defp seen_text(nil), do: gettext("Never seen")

  defp seen_text(at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

    cond do
      seconds < 60 -> gettext("Seen just now")
      seconds < 3600 -> gettext("Seen %{n} min ago", n: div(seconds, 60))
      true -> gettext("Last seen %{time} UTC", time: Calendar.strftime(at, "%Y-%m-%d %H:%M"))
    end
  end
end

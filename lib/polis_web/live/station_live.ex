defmodule PolisWeb.StationLive do
  @moduledoc """
  The station's page: the tournaments it is joined to, the field that joins
  one, the printer and the paper, and the queue. In English or Dutch; the
  help is `PolisWeb.HelpLive`.

  Most of what it shows changes by itself (a round arrives, a job comes
  out, a line drops), so it listens to the queue, the state and the lines,
  and looks again every two seconds for what nobody announces (a line that
  is still trying).

  Two buttons here can make paper come out: "Test print" and "Reprint".
  Both are a person's click. Everything else that prints is the station
  doing what the switches say.

  Per tournament, "This station" shows the name, room and share of the
  round the server has for it, and changes them - through the server,
  which answers with what it kept. While the line is down the form waits:
  OpenPairings holds the truth, and a change it cannot hear is a change
  that did not happen. What is being typed is a draft, kept until saved,
  so a round arriving meanwhile does not wipe it.
  """

  use PolisWeb, :live_view

  alias Polis.{Advanced, Autostart, BoardRanges, Printer, Queue, State, Station, Updates}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        :timer.send_interval(2_000, :refresh)

        for topic <- [Queue.topic(), State.topic(), Station.links_topic(), Updates.topic()],
            do: Phoenix.PubSub.subscribe(Polis.PubSub, topic)

        start_async(socket, :printers, &list_printers/0)
      else
        socket
      end

    {:ok,
     socket
     |> assign(
       join_form: to_form(%{"link" => ""}, as: :join),
       joining?: false,
       message: nil,
       update_message: nil,
       update_busy?: false,
       checking?: false,
       printers: nil,
       printers_error: nil,
       drafts: %{},
       station_notes: %{}
     )
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(:queue_changed, socket), do: {:noreply, load(socket)}
  def handle_info(:state_changed, socket), do: {:noreply, load(socket)}
  def handle_info(:links_changed, socket), do: {:noreply, load(socket)}
  def handle_info(:update_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # --- joining ------------------------------------------------------------------------

  @impl true
  def handle_event("join", %{"join" => %{"link" => link}}, socket) do
    {:noreply,
     socket
     |> assign(joining?: true, message: nil, join_form: to_form(%{"link" => link}, as: :join))
     |> start_async(:join, fn -> Station.join(String.trim(link)) end)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    if State.tournament(id), do: Station.remove(id)
    {:noreply, load(socket)}
  end

  # --- per tournament -------------------------------------------------------------------

  def handle_event("switch", %{"id" => id, "which" => which} = params, socket)
      when which in ["print_pairings", "print_placecards", "print_playerlist", "print_slips"] do
    if State.tournament(id), do: Station.set_switch(id, which, params["on"] == "true")
    {:noreply, load(socket)}
  end

  def handle_event("copies", %{"tournament" => id, "copies" => copies}, socket) do
    with %{} <- State.tournament(id),
         {n, ""} when n in 1..5 <- Integer.parse(copies) do
      Station.set_copies(id, n)
    end

    {:noreply, load(socket)}
  end

  def handle_event("station_change", %{"tournament" => id} = params, socket) do
    if State.tournament(id) do
      {:noreply, assign(socket, drafts: Map.put(socket.assigns.drafts, id, draft(params)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("station_save", %{"tournament" => id} = params, socket) do
    note =
      case State.tournament(id) && Station.change_settings(id, draft(params)) do
        :ok ->
          {:ok, gettext("Sent. What OpenPairings keeps shows here.")}

        {:error, :down} ->
          {:error, gettext("Not connected: the server keeps these, so it has to hear them.")}

        {:error, {:boards, _}} ->
          {:error,
           gettext("The board numbers do not read. Use numbers and ranges: 1-20, 35, 40-45.")}

        _gone ->
          nil
      end

    drafts =
      if match?({:ok, _}, note),
        do: Map.delete(socket.assigns.drafts, id),
        else: socket.assigns.drafts

    {:noreply,
     socket
     |> assign(drafts: drafts, station_notes: Map.put(socket.assigns.station_notes, id, note))
     |> load()}
  end

  def handle_event("station_reset", %{"id" => id}, socket) do
    {:noreply,
     assign(socket,
       drafts: Map.delete(socket.assigns.drafts, id),
       station_notes: Map.delete(socket.assigns.station_notes, id)
     )}
  end

  def handle_event("reprint_round", %{"id" => id}, socket) do
    if State.tournament(id), do: Station.reprint_round(id)
    {:noreply, load(socket)}
  end

  # The sheets that are not printed by themselves, on request: the player
  # list, the result slips and the last standings the server sent.
  def handle_event("print_now", %{"id" => id, "what" => what}, socket)
      when what in ["playerlist", "slips", "standings"] do
    if State.tournament(id), do: Station.print_now(id, what)
    {:noreply, load(socket)}
  end

  # --- the printer ------------------------------------------------------------------------

  def handle_event("printer", params, socket) do
    known = socket.assigns.printers || []
    printer = params["printer"]

    # Only a name the list offered (or none): the page is not a way to send
    # jobs to whatever a crafted request names.
    if printer != Station.printer() and (printer == "" or printer in known),
      do: Station.choose_printer(printer)

    if params["paper"] in ["a4", "letter"], do: Station.set_paper(params["paper"])
    {:noreply, load(socket)}
  end

  def handle_event("refresh_printers", _params, socket),
    do: {:noreply, start_async(socket, :printers, &list_printers/0)}

  def handle_event("test_print", _params, socket) do
    Queue.test_print()
    {:noreply, load(socket)}
  end

  # --- the queue ------------------------------------------------------------------------------

  def handle_event("reprint_job", %{"id" => id}, socket) do
    Queue.reprint(id)
    {:noreply, load(socket)}
  end

  # --- the program ------------------------------------------------------------------------------

  # A sheet that is printing makes the first press a question; "Install
  # anyway" is the second yes, and the sheet is then on its own.
  def handle_event("update", params, socket) do
    case Updates.apply(force: params["force"] == "yes") do
      :ok ->
        {:noreply,
         assign(socket,
           update_busy?: false,
           update_message:
             {:ok, gettext("Updating. This page reconnects when the station is back.")}
         )}

      {:error, :busy} ->
        {:noreply,
         assign(socket,
           update_busy?: true,
           update_message: nil
         )}

      {:error, _reason} ->
        {:noreply, socket |> assign(update_message: nil, update_busy?: false) |> load()}
    end
  end

  def handle_event("later", %{"version" => version}, socket) do
    Updates.later(version)
    {:noreply, load(socket)}
  end

  def handle_event("update_check", params, socket) do
    Updates.put_mode(if(params["on"] == "true", do: "ask", else: "never"))
    {:noreply, load(socket)}
  end

  def handle_event("check_now", _params, socket) do
    {:noreply,
     socket
     |> assign(checking?: true, update_message: nil)
     |> start_async(:check, fn -> Updates.Checker.check_now() end)}
  end

  def handle_event("advanced", params, socket) do
    Advanced.put(params["on"] == "true")
    {:noreply, load(socket)}
  end

  def handle_event("autostart", params, socket) do
    case Autostart.set(params["on"] == "true") do
      :ok ->
        {:noreply, load(socket)}

      {:error, _words} ->
        {:noreply,
         assign(socket, update_message: {:error, gettext("Windows would not take that setting.")})}
    end
  end

  # --- what came back --------------------------------------------------------------------------

  @impl true
  def handle_async(:join, {:ok, {:ok, _id}}, socket) do
    {:noreply,
     socket
     |> assign(
       joining?: false,
       message: {:ok, gettext("Joined. The next published round prints by itself.")},
       join_form: to_form(%{"link" => ""}, as: :join)
     )
     |> load()}
  end

  def handle_async(:join, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, joining?: false, message: {:error, join_error(reason)})}

  def handle_async(:join, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, joining?: false, message: {:error, join_error(:unreachable)})}

  def handle_async(:printers, {:ok, {:ok, names}}, socket),
    do: {:noreply, assign(socket, printers: names, printers_error: nil)}

  def handle_async(:printers, {:ok, {:error, words}}, socket),
    do: {:noreply, assign(socket, printers: [], printers_error: words)}

  def handle_async(:printers, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, printers: [], printers_error: "?")}

  def handle_async(:check, {:ok, answer}, socket) do
    message =
      case answer do
        {:ok, _info} -> nil
        :current -> {:ok, gettext("This is the newest version.")}
        :error -> {:error, gettext("Could not reach the release page.")}
      end

    {:noreply, socket |> assign(checking?: false, update_message: message) |> load()}
  end

  def handle_async(:check, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         checking?: false,
         update_message: {:error, gettext("Could not reach the release page.")}
       )}

  defp list_printers do
    case Printer.printers() do
      {:ok, names} -> {:ok, names}
      {:error, words} -> {:error, words}
    end
  end

  defp join_error(:not_a_link),
    do: gettext("That is not a join link. It looks like https://server/p/polis/join/K7Q-4MD.")

  defp join_error({:wrong_product, "nunki"}),
    do:
      gettext(
        "That link is for Nunki, the hall announcer, not for a print station. Paste it into Nunki; for this station, add a print station in OpenPairings and use its link."
      )

  defp join_error({:wrong_product, "manubrium"}),
    do:
      gettext(
        "That link is for the Manubrium phone app: scan it with Manubrium. For this station, add a print station in OpenPairings (the tournament's Settings, Print station) and use its link."
      )

  defp join_error({:wrong_product, _product}),
    do:
      gettext(
        "That link is for another hall program, not for a print station. In OpenPairings, add a print station and use its link."
      )

  defp join_error(:used_or_expired),
    do: gettext("That link is used up or expired. Make a new one in OpenPairings.")

  defp join_error(:version),
    do: gettext("That server speaks another version of the link. Update one of the two.")

  defp join_error(:unreachable), do: gettext("The server in that link does not answer from here.")

  defp join_error(_other),
    do: gettext("That address answered, but not like an OpenPairings server.")

  @doc false
  def link_error(nil), do: nil
  def link_error(:nobody_answers), do: gettext("nobody answers at that address")
  def link_error(:no_such_address), do: gettext("that address does not exist")
  def link_error(:timeout), do: gettext("no answer in time")
  def link_error(:closed), do: gettext("the server closed the line")
  def link_error(:silent), do: gettext("the server went quiet")
  def link_error(:not_a_link), do: gettext("that address does not take a line")

  def link_error({:refused, "version"}),
    do: gettext("refused: another version of the link; update one of the two")

  def link_error({:refused, "key"}),
    do: gettext("refused: the server does not know this station's key; trying again in a minute")

  def link_error({:refused, _other}), do: gettext("refused; trying again in a minute")
  def link_error(_other), do: gettext("the line went down; trying again")

  defp draft(params) do
    %{
      "name" => params["name"] || "",
      "room" => params["room"] || "",
      "categories" =>
        params |> Map.get("categories", []) |> List.wrap() |> Enum.reject(&(&1 == "")),
      "boards" => params["boards"] || ""
    }
  end

  # What the form shows: the draft while there is one, the server's word
  # otherwise.
  defp station_params(t, drafts) do
    Map.get(drafts, t["id"]) ||
      Map.take(t["station"] || %{}, ~w(name room categories boards))
  end

  defp boards_text({:ok, []}), do: gettext("Every board.")

  defp boards_text({:ok, ranges}),
    do: gettext("Boards %{list}.", list: BoardRanges.format(ranges))

  defp boards_text({:error, {:backwards, token}}),
    do: gettext("\"%{token}\" runs backwards: put the smaller number first.", token: token)

  defp boards_text({:error, {:too_big, token}}),
    do: gettext("\"%{token}\" is past board 9999.", token: token)

  defp boards_text({:error, {_bad, token}}),
    do: gettext("\"%{token}\" is not a board number or a range like 40-45.", token: token)

  defp load(socket) do
    assign(socket,
      tournaments: safe(&Station.overview/0, []),
      jobs: safe(&Queue.jobs/0, []),
      printer: safe(&Station.printer/0, nil),
      paper: safe(&Station.paper/0, :a4),
      advanced?: safe(&Advanced.enabled?/0, false),
      dry_run?: Printer.dry_run?(),
      notice: Updates.notice(),
      install_kind: Updates.install_kind(),
      update_mode: Updates.mode(),
      last_update: Updates.last_result(),
      autostart?: Autostart.supported?() and Autostart.enabled?()
    )
  end

  defp safe(fun, default) do
    fun.()
  catch
    :exit, _reason -> default
  end

  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)

  defp held_round(t), do: get_in(t, ["payload", "round"])

  # What can be printed on request: the standings only when the server has
  # sent some, since a station has no standings of its own.
  defp print_now_buttons(t) do
    [
      {"playerlist", gettext("Print the player list now")},
      {"slips", gettext("Print the result slips now")}
    ] ++
      if(t["standings"],
        do: [{"standings", gettext("Print the standings now")}],
        else: []
      )
  end

  defp time(nil), do: ""
  defp time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:station}>
      <section :if={@notice} id="update">
        <h2>{gettext("Polis %{version} is out.", version: @notice.version)}</h2>

        <p :if={@notice.size} class="note">
          {gettext("The download is %{mb} MB.", mb: megabytes(@notice.size))}
        </p>

        <p :if={@install_kind != :manual} class="note">
          {gettext(
            "Nothing prints for about a minute while it installs. It waits for a sheet that is printing."
          )}
        </p>

        <p :if={@install_kind == :manual && !@notice.no_build} class="note">
          {gettext("This copy is updated by hand: download the new one and replace this.")}
        </p>

        <p :if={@notice.no_build} class="note">
          {gettext("There is no build for this machine.")}
        </p>

        <p :if={@update_busy?} id="update-busy" class="error" role="alert">
          {gettext("A sheet is printing. Try again when it is out, or install anyway.")}
        </p>

        <form id="update-form" phx-submit="update">
          <button :if={@install_kind != :manual} id="update-button" type="submit">
            {gettext("Download and install")}
          </button>

          <a
            :if={@install_kind == :manual && !@notice.no_build}
            id="update-link"
            href={@notice.url}
            rel="noopener"
          >
            {gettext("Releases")}
          </a>

          <button
            :if={@update_busy? && @install_kind != :manual}
            id="update-force"
            type="button"
            phx-click="update"
            phx-value-force="yes"
            data-confirm={
              gettext("Install now anyway? The sheet that is printing may not come out whole.")
            }
          >
            {gettext("Install anyway")}
          </button>

          <button
            id="update-later"
            type="button"
            phx-click="later"
            phx-value-version={@notice.version}
          >
            {gettext("Later")}
          </button>
        </form>
      </section>

      <p :if={match?({:failed, _, _}, @last_update)} id="update-failed" class="error">
        {gettext("The last update, to %{version}, did not work: %{why}",
          version: elem(@last_update, 1),
          why: elem(@last_update, 2)
        )}
      </p>

      <section id="tournaments">
        <h2>{gettext("Tournaments")}</h2>

        <p :if={@tournaments == []} id="no-tournaments" class="note">
          {gettext("Joined to no tournament yet. Paste a join link below.")}
        </p>

        <ul :if={@tournaments != []} id="tournament-list">
          <li :for={t <- @tournaments} id={"tournament-#{t["id"]}"} class="tournament">
            <div class="row">
              <span
                class={["dot", if(t["link"].up?, do: "up", else: "down")]}
                title={if(t["link"].up?, do: gettext("connected"), else: gettext("not connected"))}
              ></span> <strong class="tournament-name">{t["name"]}</strong>
              <span :if={!t["link"].up? && t["link"].error} class="note">
                {link_error(t["link"].error)}
              </span>

              <button
                id={"remove-#{t["id"]}"}
                type="button"
                class="danger"
                phx-click="remove"
                phx-value-id={t["id"]}
                data-confirm={gettext("Leave this tournament? Its rounds stop printing here.")}
              >
                {gettext("Remove")}
              </button>
            </div>

            <p class="note">
              <%= if held_round(t) do %>
                {gettext("Round %{n} is the latest published round.", n: held_round(t))}
              <% else %>
                {gettext("No round published yet.")}
              <% end %>
            </p>

            <p :if={t["changed"]} id={"changed-#{t["id"]}"} class="warn">
              {gettext("Round %{n} changed since it was printed.", n: held_round(t))}
              <button
                id={"reprint-round-#{t["id"]}"}
                type="button"
                phx-click="reprint_round"
                phx-value-id={t["id"]}
              >
                {gettext("Reprint")}
              </button>
            </p>

            <p :if={held_round(t)} class="print-now" id={"print-now-#{t["id"]}"}>
              <button
                :for={{what, label} <- print_now_buttons(t)}
                id={"print-now-#{what}-#{t["id"]}"}
                type="button"
                phx-click="print_now"
                phx-value-id={t["id"]}
                phx-value-what={what}
              >
                {label}
              </button>
            </p>

            <.station_form
              :if={@advanced? && t["station"]}
              t={t}
              params={station_params(t, @drafts)}
              draft?={Map.has_key?(@drafts, t["id"])}
              note={@station_notes[t["id"]]}
            />
            <div class="switches">
              <label>
                <input
                  id={"switch-pairings-#{t["id"]}"}
                  type="checkbox"
                  checked={t["print_pairings"] != false}
                  phx-click="switch"
                  phx-value-id={t["id"]}
                  phx-value-which="print_pairings"
                  phx-value-on={to_string(t["print_pairings"] == false)}
                /> {gettext("Print the pairings")}
              </label>

              <label>
                <input
                  id={"switch-placecards-#{t["id"]}"}
                  type="checkbox"
                  checked={t["print_placecards"] != false}
                  phx-click="switch"
                  phx-value-id={t["id"]}
                  phx-value-which="print_placecards"
                  phx-value-on={to_string(t["print_placecards"] == false)}
                /> {gettext("Print the place cards")}
              </label>

              <label>
                <input
                  id={"switch-playerlist-#{t["id"]}"}
                  type="checkbox"
                  checked={t["print_playerlist"] == true}
                  phx-click="switch"
                  phx-value-id={t["id"]}
                  phx-value-which="print_playerlist"
                  phx-value-on={to_string(t["print_playerlist"] != true)}
                /> {gettext("Print the player list")}
              </label>

              <label>
                <input
                  id={"switch-slips-#{t["id"]}"}
                  type="checkbox"
                  checked={t["print_slips"] == true}
                  phx-click="switch"
                  phx-value-id={t["id"]}
                  phx-value-which="print_slips"
                  phx-value-on={to_string(t["print_slips"] != true)}
                /> {gettext("Print the result slips")}
              </label>

              <form :if={@advanced?} id={"copies-form-#{t["id"]}"} phx-change="copies">
                <input type="hidden" name="tournament" value={t["id"]} />
                <label>
                  {gettext("Copies of the pairings")}
                  <select id={"copies-#{t["id"]}"} name="copies">
                    <option :for={n <- 1..5} value={n} selected={(t["copies"] || 1) == n}>
                      {n}
                    </option>
                  </select>
                </label>
              </form>
            </div>
          </li>
        </ul>
      </section>

      <section id="join">
        <h2>{gettext("Join a tournament")}</h2>

        <.form for={@join_form} id="join-form" phx-submit="join">
          <input
            id="join-link"
            type="text"
            name={@join_form[:link].name}
            value={@join_form[:link].value}
            placeholder="https://server/p/polis/join/K7Q-4MD"
            autocomplete="off"
          />
          <button id="join-button" type="submit" disabled={@joining?}>
            {if @joining?, do: gettext("Joining..."), else: gettext("Join")}
          </button>
        </.form>

        <p :if={@message} id="join-message" class={elem(@message, 0)}>{elem(@message, 1)}</p>

        <p class="note">
          {gettext(
            "In OpenPairings: the tournament's Settings → Print station → Add a print station. Paste the link it shows; that is all."
          )}
        </p>
      </section>

      <section id="printer">
        <h2>{gettext("Printer")}</h2>

        <p :if={@dry_run?} id="dry-run-note" class="note">
          {gettext(
            "Dry run: nothing goes to a printer. The sheets are written as PDF files in the data folder."
          )}
        </p>

        <form id="printer-form" phx-change="printer">
          <label>
            {gettext("Printer")}
            <select id="printer-select" name="printer" disabled={@printers == nil}>
              <option value="" selected={@printer == nil}>{gettext("(choose a printer)")}</option>

              <option :for={name <- @printers || []} value={name} selected={name == @printer}>
                {name}
              </option>

              <option
                :if={@printer && @printers && @printer not in @printers}
                value={@printer}
                selected
              >
                {gettext("%{name} (not found now)", name: @printer)}
              </option>
            </select>
          </label>

          <label>
            {gettext("Paper")}
            <select id="paper-select" name="paper">
              <option value="a4" selected={@paper == :a4}>A4</option>

              <option value="letter" selected={@paper == :letter}>Letter</option>
            </select>
          </label>
        </form>

        <p :if={@printers == nil} class="note">{gettext("Looking for printers...")}</p>

        <p :if={@printers_error} id="printers-error" class="error">
          {gettext("The printer list did not come: %{why}", why: @printers_error)}
        </p>

        <p :if={@printer == nil && @printers != nil} id="no-printer" class="warn">
          {gettext("No printer chosen. Rounds that arrive wait in the queue until one is.")}
        </p>

        <p class="buttons">
          <button id="refresh-printers" type="button" phx-click="refresh_printers">
            {gettext("Look for printers again")}
          </button>

          <button id="test-print" type="button" phx-click="test_print" disabled={@printer == nil}>
            {gettext("Test print")}
          </button>
        </p>
      </section>

      <section id="queue">
        <h2>{gettext("Queue")}</h2>

        <p :if={@jobs == []} id="no-jobs" class="note">{gettext("Nothing printed yet.")}</p>

        <ul :if={@jobs != []} id="job-list">
          <li :for={job <- @jobs} id={"job-#{job.id}"} class={"job #{job.status}"}>
            <span class="mono">{time(job.created_at)}</span>
            <span>
              <strong>{job_what(job)}</strong>
              <span :if={job.tournament_name} class="note">{job.tournament_name}</span>
              <span :if={job.copies > 1} class="note">x{job.copies}</span>
            </span>
            <span class={["status", job.status == :failed && "error"]}>{job_status(job)}</span>
            <span class="actions">
              <a id={"pdf-#{job.id}"} href={"/jobs/#{job.id}/pdf"} target="_blank" rel="noopener">
                {gettext("Open PDF")}
              </a>

              <button
                id={"reprint-#{job.id}"}
                type="button"
                phx-click="reprint_job"
                phx-value-id={job.id}
              >
                {gettext("Reprint")}
              </button>
            </span>
          </li>
        </ul>
      </section>

      <section id="program">
        <h2>{gettext("This program")}</h2>

        <p class="note">
          {gettext("Version")} <span class="mono">{Updates.current_version()}</span>
        </p>

        <p>
          <label>
            <input
              id="advanced"
              type="checkbox"
              checked={@advanced?}
              phx-click="advanced"
              phx-value-on={to_string(!@advanced?)}
            /> {gettext("Show advanced features")}
          </label>
        </p>

        <p :if={!@advanced?} id="advanced-note" class="note">
          {gettext(
            "Hidden until then: copies of the pairings, what this station prints, update settings and starting with Windows."
          )}
        </p>

        <p :if={@advanced?}>
          <label>
            <input
              id="update-check"
              type="checkbox"
              checked={@update_mode == "ask"}
              phx-click="update_check"
              phx-value-on={to_string(@update_mode != "ask")}
            /> {gettext("Look for a newer version now and then")}
          </label>
        </p>

        <p :if={@advanced? && Autostart.supported?()}>
          <label>
            <input
              id="autostart"
              type="checkbox"
              checked={@autostart?}
              phx-click="autostart"
              phx-value-on={to_string(!@autostart?)}
            /> {gettext("Start Polis when Windows starts")}
          </label>
        </p>

        <p>
          <button
            :if={@advanced?}
            id="check-now"
            type="button"
            phx-click="check_now"
            disabled={@checking?}
          >
            {if @checking?, do: gettext("Looking..."), else: gettext("Look now")}
          </button>

          <span :if={@update_message} id="update-message" class={elem(@update_message, 0)}>
            {elem(@update_message, 1)}
          </span>
        </p>
      </section>
    </Layouts.app>
    """
  end

  # The station's name, room and share of the round in one tournament.
  attr :t, :map, required: true
  attr :params, :map, required: true
  attr :draft?, :boolean, required: true
  attr :note, :any, default: nil

  defp station_form(assigns) do
    station = assigns.t["station"]

    assigns =
      assign(assigns,
        id: assigns.t["id"],
        up?: assigns.t["link"].up?,
        available: station["categories_available"] || [],
        picked: assigns.params["categories"] || [],
        boards: BoardRanges.parse(assigns.params["boards"]),
        refused?: station["error"] == "boards",
        room_refused?: station["error"] == "room",
        rooms: station["rooms_available"],
        room_stray?: stray_room?(assigns.params["room"], station["rooms_available"])
      )

    ~H"""
    <details id={"station-#{@id}"} class="station" open={@draft?}>
      <summary>
        {gettext("This station")}: <strong>{@t["station"]["name"]}</strong>
        <span :if={@t["station"]["room"] != ""} class="note">· {@t["station"]["room"]}</span>
        <span class="note">· {share_text(@t["station"])}</span>
      </summary>

      <form id={"station-form-#{@id}"} phx-change="station_change" phx-submit="station_save">
        <input type="hidden" name="tournament" value={@id} />
        <fieldset disabled={!@up?}>
          <label>
            {gettext("Name")}
            <input
              id={"station-name-#{@id}"}
              type="text"
              name="name"
              value={@params["name"]}
              maxlength="60"
            />
          </label>

          <label :if={@rooms == nil}>
            {gettext("Room")}
            <input
              id={"station-room-#{@id}"}
              type="text"
              name="room"
              value={@params["room"]}
              maxlength="60"
              placeholder={gettext("e.g. Main hall")}
            />
          </label>

          <label :if={@rooms != nil}>
            {gettext("Room")}
            <select id={"station-room-#{@id}"} name="room">
              <option value="" selected={@params["room"] in ["", nil]}>{gettext("No room")}</option>
              <option :if={@room_stray?} value={@params["room"]} selected>
                {gettext("%{room} (not a room of this tournament)", room: @params["room"])}
              </option>
              <option :for={r <- @rooms} value={r} selected={r == @params["room"]}>{r}</option>
            </select>
          </label>

          <p :if={@rooms == []} id={"station-rooms-none-#{@id}"} class="note">
            {gettext(
              "This tournament has no rooms. They are set in OpenPairings, under Settings, Rooms."
            )}
          </p>

          <p :if={@room_stray?} id={"station-room-stray-#{@id}"} class="note">
            {gettext("That room is only a label; it filters nothing until a room is picked.")}
          </p>

          <div :if={@available != []} id={"station-categories-#{@id}"} class="ticks">
            <span>{gettext("Categories")}</span> <input type="hidden" name="categories[]" value="" />
            <label :for={{c, i} <- Enum.with_index(@available)}>
              <input
                id={"station-cat-#{@id}-#{i}"}
                type="checkbox"
                name="categories[]"
                value={c}
                checked={c in @picked}
              /> {c}
            </label>
          </div>

          <label>
            {gettext("Board numbers")}
            <input
              id={"station-boards-#{@id}"}
              type="text"
              name="boards"
              value={@params["boards"]}
              placeholder="1-20, 35, 40-45"
              autocomplete="off"
            />
          </label>

          <p
            id={"station-boards-parsed-#{@id}"}
            class={if(match?({:ok, _}, @boards), do: "note", else: "error")}
          >
            {boards_text(@boards)}
          </p>

          <p class="note">
            {gettext(
              "Nothing ticked, no board numbers and no room: everything. A board prints when it is in the room, its number is in the list and either player is in a ticked category."
            )}
          </p>

          <p class="buttons">
            <button id={"station-save-#{@id}"} type="submit">{gettext("Save")}</button>
            <button
              :if={@draft?}
              id={"station-reset-#{@id}"}
              type="button"
              phx-click="station_reset"
              phx-value-id={@id}
            >
              {gettext("Undo changes")}
            </button>
          </p>
        </fieldset>
      </form>

      <p :if={!@up?} id={"station-down-#{@id}"} class="note">
        {gettext(
          "Not connected. OpenPairings keeps these; change them when the line is up, or there."
        )}
      </p>

      <p :if={@refused?} id={"station-refused-#{@id}"} class="error">
        {gettext("OpenPairings did not take those board numbers; it kept what it had.")}
      </p>

      <p :if={@room_refused?} id={"station-room-refused-#{@id}"} class="error">
        {gettext("That room is not one of this tournament's rooms.")}
      </p>

      <p :if={@note} id={"station-note-#{@id}"} class={elem(@note, 0)}>{elem(@note, 1)}</p>
    </details>
    """
  end

  defp stray_room?(room, rooms) when is_binary(room) and room != "" and is_list(rooms),
    do: room not in rooms

  defp stray_room?(_room, _rooms), do: false

  defp share_text(station) do
    cats = station["categories"] || []
    boards = station["boards"] || ""

    case {cats, boards} do
      {[], ""} ->
        gettext("prints everything")

      {[], b} ->
        gettext("prints boards %{list}", list: b)

      {c, ""} ->
        gettext("prints %{categories}", categories: Enum.join(c, ", "))

      {c, b} ->
        gettext("prints boards %{list}, %{categories}", list: b, categories: Enum.join(c, ", "))
    end
  end
end

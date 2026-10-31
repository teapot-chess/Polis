defmodule Polis.Station do
  @moduledoc """
  The print station, as the page and the links see it: join a tournament,
  leave one, what to do with a round that arrives, and what the station
  tells the servers about itself.

  ## What arrives, and what is printed

  A `round` from a server (`round_received/2`) is kept as that
  tournament's latest payload. Then:

    * a round number this station has not printed for that tournament:
      the pairings list (`copies` of it) and the place cards go into the
      queue, as the two switches say - both on unless somebody turned one
      off. With no printer chosen yet they wait, as "waiting for a
      printer", and go once one is chosen;
    * a round already printed, with a different `rev` (the arbiter changed
      a pairing after publishing): nothing is printed by itself. A sheet on
      the wall that changes by itself is worse than one that is old; the
      page says "changed since it was printed" and offers Reprint;
    * the same round with the same `rev` (a reconnect): nothing.

  A `print` from the server - "Print round N again" pressed in OpenPairings -
  queues what it names, for the round it names, when that is the round
  this station holds: the pairings, the place cards, an alphabetical
  player list, result slips, or the standings (the `standings` frame the
  server sent just before, held here until then). A word the station does
  not know prints nothing.

  ## Its name, its room, and its share of the round

  Per tournament, as the server has them (`settings_received/2`): what the
  station is called there, the room it stands in, and which categories
  and board numbers it prints. The server sends only this station's share
  of each round, so nothing is filtered here; a round with no board for
  this station is not printed at all, rather than printed as an empty
  sheet. `change_settings/2` asks the server for a change; what shows is
  what the server answers.

  ## What the station tells the servers

  `status` with `printer` (the chosen printer's name, or null) and
  `last_printed_round` (the highest round of that tournament whose
  pairings or place cards came out of the printer), after `welcome` and
  whenever either changes (`broadcast_status/0`).
  """

  alias Polis.{BoardRanges, Join, Link, Protocol, Queue, State}

  @status_topic "station:status"
  @links_topic "station:links"

  def status_topic, do: @status_topic
  def links_topic, do: @links_topic

  # --- joining and leaving ------------------------------------------------------

  @doc """
  Joins the tournament of a join link: `{:ok, id}` or `{:error, reason}`
  (`Polis.Join.redeem/3`).
  """
  def join(link, req_options \\ []) do
    identity = %{
      "v" => Protocol.version(),
      "device" => State.device_id(),
      "name" => State.device_name(),
      "software" => Protocol.software()
    }

    with {:ok, attrs} <- Join.redeem(link, identity, req_options),
         {:ok, id} <- State.add_tournament(attrs) do
      restart_link(id)
      broadcast_links()
      {:ok, id}
    end
  end

  @doc """
  Removes a tournament here: the server is told (`leave`, when the line is
  up now), the line goes, and the tournament is forgotten. Its printed jobs
  stay in the queue's history.
  """
  def remove(id) do
    Link.leave(id)
    stop_link(id)
    State.remove_tournament(id)
    broadcast_links()
    :ok
  end

  @doc "The server removed this station: forget the tournament (called by its link)."
  def forget(id) do
    State.remove_tournament(id)
    broadcast_links()
  end

  @doc "Starts a line for every joined tournament (at start-up)."
  def start_links do
    for t <- State.tournaments(), do: restart_link(t["id"])
    :ok
  end

  def restart_link(id) do
    stop_link(id)
    DynamicSupervisor.start_child(Polis.Links, {Link, tournament: id})
  end

  defp stop_link(id) do
    case Link.whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Polis.Links, pid)
    end
  end

  # --- rounds ---------------------------------------------------------------------

  @doc "A `round` frame's payload for tournament `id`. See the moduledoc."
  def round_received(id, %{"round" => round} = payload) when is_integer(round) do
    key = Integer.to_string(round)
    rev = payload["rev"]

    case State.tournament(id) do
      nil ->
        :ignored

      t ->
        handled = t["printed"] || %{}
        new? = not Map.has_key?(handled, key)

        {:ok, t} =
          State.update_tournament(id, fn t ->
            t = Map.merge(t, %{"payload" => payload, "last_round" => round})
            if new?, do: put_in(t, ["printed", key], rev), else: t
          end)

        if new?, do: enqueue_round(t, payload, [:pairings, :placecards, :playerlist, :slips])
        broadcast_links()
        if new?, do: :printing, else: :kept
    end
  end

  def round_received(_id, _payload), do: :ignored

  @doc """
  A `print` from the server: `what` is pairings, placecards, both,
  standings, playerlist or slips. A `what` this station does not know is
  `:unknown_what`, and nothing is printed: the protocol grows, and an old
  station must not print the wrong thing for a new word.
  """
  def print_command(id, round, what) do
    with %{"payload" => %{"round" => ^round} = payload} = t <- State.tournament(id),
         [_ | _] = whats <- whats(what) do
      # Asked for by name, so printed whatever the switches say - but not
      # an empty sheet for a station none of whose boards are in it.
      if for_this_station?(payload) do
        for w <- whats, job = job_attrs(t, payload, w), do: Queue.enqueue(job)
      end

      :ok
    else
      [] -> :unknown_what
      _other -> :unknown_round
    end
  end

  defp whats("pairings"), do: [:pairings]
  defp whats("placecards"), do: [:placecards]
  defp whats("both"), do: [:pairings, :placecards]
  defp whats("playerlist"), do: [:playerlist]
  defp whats("slips"), do: [:slips]
  defp whats("standings"), do: [:standings]
  defp whats(_other), do: []

  @doc """
  The standings the server sent (`standings` frame) for tournament `id`:
  held until a `print` asks for them. They are not printed on arrival -
  they go stale with every result, and a sheet nobody asked for is paper.
  """
  def standings_received(id, %{"rows" => rows} = frame) when is_list(rows) do
    case State.tournament(id) do
      nil ->
        :ignored

      _t ->
        State.update_tournament(id, &Map.put(&1, "standings", Map.delete(frame, "type")))
        broadcast_links()
        :kept
    end
  end

  def standings_received(_id, _frame), do: :ignored

  @doc """
  A page button: `what` (a string as in `print_command/3`) of the round
  held now, whatever the switches say. Standings are the last ones the
  server sent; `:nothing` when there is nothing held to print.
  """
  def print_now(id, what) do
    with %{"payload" => %{"round" => round}} <- State.tournament(id),
         :ok <- print_command(id, round, what) do
      :ok
    else
      _other -> :nothing
    end
  end

  @doc """
  Reprint of the round a tournament holds now - the pairings list and the
  place cards, whatever the switches say, since somebody asked - and the
  round counted as printed at this `rev`: the button beside "changed since
  it was printed".
  """
  def reprint_round(id) do
    with %{"payload" => %{"round" => round} = payload} = t <- State.tournament(id) do
      State.update_tournament(
        id,
        &put_in(&1, ["printed", Integer.to_string(round)], payload["rev"])
      )

      enqueue_round(t, payload, [:pairings, :placecards], force: true)
      broadcast_links()
      :ok
    else
      _other -> :nothing
    end
  end

  defp enqueue_round(t, payload, whats, opts \\ []) do
    for w <- whats,
        for_this_station?(payload),
        Keyword.get(opts, :force, false) or switch_on?(t, w) do
      Queue.enqueue(job_attrs(t, payload, w))
    end
  end

  @doc """
  Whether a round has anything for this station. A share that leaves no
  board (the station prints boards 40-60 of a 30-board round) prints
  nothing; a whole round always prints, empty or not, because that is a
  sheet saying "no boards", which somebody may want on the wall.
  """
  def for_this_station?(%{"selection" => %{}, "boards" => []}), do: false
  def for_this_station?(_payload), do: true

  # --- name, room and share ---------------------------------------------------------

  @doc """
  A `settings` frame from the server of tournament `id`: kept as the
  tournament's `"station"`, which is what the page shows.
  """
  def settings_received(id, frame) do
    settings = %{
      "name" => text(frame["name"]),
      "room" => text(frame["room"]),
      "categories" => strings(frame["categories"]),
      "boards" => text(frame["boards"]),
      "categories_available" => strings(frame["categories_available"]),
      "error" => frame["error"]
    }

    # Absent from a server that predates rooms; kept absent, so the page
    # knows to offer a free-text field instead of a picker.
    settings =
      if is_list(frame["rooms_available"]),
        do: Map.put(settings, "rooms_available", strings(frame["rooms_available"])),
        else: settings

    State.update_tournament(id, &Map.put(&1, "station", settings))
    broadcast_links()
  end

  defp text(v) when is_binary(v), do: v
  defp text(_v), do: ""

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_v), do: []

  @doc """
  Asks the server of tournament `id` to change this station's name, room,
  categories or board numbers (string keys; categories a list). Board
  numbers that do not read are `{:error, {:boards, reason}}` before
  anything is sent; a line that is down is `{:error, :down}`.
  """
  def change_settings(id, params) do
    fields = %{
      "name" => String.trim(params["name"] || ""),
      "room" => String.trim(params["room"] || ""),
      "categories" =>
        params |> Map.get("categories", []) |> List.wrap() |> Enum.reject(&(&1 == "")),
      "boards" => params["boards"] || ""
    }

    case BoardRanges.parse(fields["boards"]) do
      {:ok, ranges} -> Link.send_settings(id, %{fields | "boards" => BoardRanges.format(ranges)})
      {:error, reason} -> {:error, {:boards, reason}}
    end
  end

  defp switch_on?(t, :pairings), do: t["print_pairings"] != false
  defp switch_on?(t, :placecards), do: t["print_placecards"] != false
  # Not on until somebody says so: most halls have never wanted either.
  defp switch_on?(t, :playerlist), do: t["print_playerlist"] == true
  defp switch_on?(t, :slips), do: t["print_slips"] == true

  # The standings are a frame of their own, held apart from the round; a
  # job for them is made from that, or not at all.
  defp job_attrs(t, _payload, :standings) do
    case t["standings"] do
      %{"rows" => _} = frame ->
        %{
          tournament: t["id"],
          tournament_name: get_in(frame, ["tournament", "name"]) || t["name"],
          round: frame["round"],
          rev: frame["rev"],
          what: :standings,
          copies: 1,
          payload: frame
        }

      _none ->
        nil
    end
  end

  defp job_attrs(t, payload, what) do
    %{
      tournament: t["id"],
      tournament_name: get_in(payload, ["tournament", "name"]) || t["name"],
      round: payload["round"],
      rev: payload["rev"],
      what: what,
      copies: if(what == :pairings, do: copies(t), else: 1),
      payload: payload
    }
  end

  defp copies(t) do
    case t["copies"] do
      n when is_integer(n) and n in 1..5 -> n
      _other -> 1
    end
  end

  @doc "Whether the round a tournament holds changed after it was printed."
  def changed_since_printed?(t) do
    with %{"round" => round, "rev" => rev} <- t["payload"],
         {:ok, printed} <- Map.fetch(t["printed"] || %{}, Integer.to_string(round)) do
      printed != rev
    else
      _ -> false
    end
  end

  # --- the switches -------------------------------------------------------------------

  def set_switch(id, which, on)
      when which in ["print_pairings", "print_placecards", "print_playerlist", "print_slips"],
      do: State.update_tournament(id, &Map.put(&1, which, on == true))

  def set_copies(id, n) when is_integer(n) and n in 1..5,
    do: State.update_tournament(id, &Map.put(&1, "copies", n))

  # --- the printer ---------------------------------------------------------------------

  @doc "The chosen printer, or nil."
  def printer, do: State.setting("printer")

  @doc "Chooses the printer: what waited for one goes, and the servers hear of it."
  def choose_printer(name) do
    name = if name in [nil, ""], do: nil, else: name
    State.put_setting("printer", name)
    if name, do: Queue.printer_chosen()
    broadcast_status()
    :ok
  end

  @doc "`a4` or `letter`."
  def paper do
    case State.setting("paper") do
      "letter" -> :letter
      _a4 -> :a4
    end
  end

  def set_paper(paper) when paper in ["a4", "letter"], do: State.put_setting("paper", paper)

  @doc "What `status` says to the server of tournament `id`."
  def status_for(id) do
    t = State.tournament(id) || %{}
    %{"printer" => printer(), "last_printed_round" => t["last_printed_round"]}
  end

  @doc "A job of tournament `id` and round `round` came out of the printer."
  def printed(id, round) when is_integer(round) do
    State.update_tournament(id, fn t ->
      Map.put(t, "last_printed_round", max(t["last_printed_round"] || 0, round))
    end)

    broadcast_status()
  end

  def printed(_id, _round), do: :ok

  def broadcast_status, do: Phoenix.PubSub.broadcast(Polis.PubSub, @status_topic, :status_changed)
  def broadcast_links, do: Phoenix.PubSub.broadcast(Polis.PubSub, @links_topic, :links_changed)

  # --- what the page shows ---------------------------------------------------------------

  @doc "The joined tournaments with their line's state."
  def overview do
    for t <- State.tournaments() do
      t
      |> Map.put("link", Link.info(t["id"]))
      |> Map.put("changed", changed_since_printed?(t))
    end
  end
end

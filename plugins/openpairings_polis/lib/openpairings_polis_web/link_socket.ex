defmodule OpenPairingsPolisWeb.LinkSocket do
  @moduledoc """
  The server end of a print station's link (`WebSock`), one process per
  connected station, upgraded by `OpenPairingsPolisWeb.LinkPlug`. Frames
  are OpenPairings' `hall-link-v1` contract's (vendored in the Polis
  repository, `priv/contracts/vendor/openpairings/hall-link-v1/`).

  The first frame must be `hello` with the station's key; until then
  nothing else is listened to, and a link that says nothing for ten
  seconds is closed. After `welcome` the station gets its `settings` (name,
  room, what it prints) and then the latest published round, if there is
  one - cut down to the station's share of it
  (`OpenPairingsPolis.RoundPayload.build/3`).

  The station may send `settings` back to change its name, room or
  filters; so may the page. Either way the row changes, the topic hears
  `{:polis_settings_changed, id}`, and this socket sends the station what
  is now true - and the round again, when its share of it changed.

  It listens on two topics: the core's tournament topic, where any change
  at all is a nudge to look again (debounced, `@debounce_ms`), and the
  plugin's own (`OpenPairingsPolis.Stations.topic/1`), where the page says
  "print again" or "this one was removed". A round goes out only when its
  `rev` differs from the last one this socket sent, and never when it is
  older than that: a round taken back is simply not news.
  """
  @behaviour WebSock

  alias OpenPairingsPolis.{RoundPayload, Stations}
  alias PairingsEngine.Tournaments

  @protocol 1
  @hello_ms 10_000
  @debounce_ms 300
  @idle_check_ms 30_000
  # The station pings every 25 s; three missed is a station that is gone.
  @silence_ms 90_000
  # last_seen_at is written at most this often; "online" allows 90 s.
  @touch_ms 20_000

  @impl true
  def init(_args) do
    Process.send_after(self(), :hello_timeout, @hello_ms)
    Process.send_after(self(), :idle_check, @idle_check_ms)

    {:ok,
     %{
       station: nil,
       ref: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false),
       last_rev: nil,
       last_round: 0,
       last_settings: nil,
       timer: nil,
       heard: now_ms(),
       touched: now_ms()
     }}
  end

  ## ---------- frames in ----------

  @impl true
  def handle_in({text, _opts}, state) do
    state = %{state | heard: now_ms()}

    case Jason.decode(text) do
      {:ok, %{"type" => _} = frame} -> frame(frame, state)
      _ -> {:ok, state}
    end
  end

  defp frame(%{"type" => "hello"} = hello, %{station: nil} = state) do
    with :ok <- version(hello["v"]),
         {:ok, station} <- Stations.authenticate(hello["device"], hello["key"]) do
      welcome(station, state)
    else
      {:error, reason} -> refuse(reason, state)
    end
  end

  # Nothing but hello before hello.
  defp frame(_frame, %{station: nil} = state), do: {:ok, state}

  defp frame(%{"type" => "status"} = status, state) do
    {:ok, %{state | station: Stations.put_status(state.station, status), touched: now_ms()}}
  end

  # Removed on the station: removed here too.
  defp frame(%{"type" => "leave"}, state) do
    Stations.forget(state.station)
    {:stop, :normal, %{state | station: nil}}
  end

  defp frame(%{"type" => "ping"}, state), do: push([%{type: "pong"}], touch(state))

  # The station renaming itself, moving rooms, or choosing what it prints.
  defp frame(%{"type" => "settings"} = settings, state) do
    case Stations.update_settings(state.station, settings) do
      {:ok, station} ->
        state = %{state | station: station, touched: now_ms()}
        {settings, state} = settings_frames(state)
        {rounds, state} = round_frames(state)
        push(settings ++ rounds, state)

      # Board numbers that do not read: nothing changes, and the station is
      # told what still holds, with the reason.
      {:error, {:boards, _reason}} ->
        {[frame], state} = settings_frames(%{state | last_settings: nil})
        push([Map.put(frame, "error", "boards")], state)

      # A room the tournament does not have: the same, with that reason.
      {:error, {:room, _reason}} ->
        {[frame], state} = settings_frames(%{state | last_settings: nil})
        push([Map.put(frame, "error", "room")], state)
    end
  end

  defp frame(_other, state), do: {:ok, state}

  defp version(@protocol), do: :ok
  defp version(_v), do: {:error, :version}

  defp welcome(station, state) do
    station = Stations.connected(station, state.ref)
    tournament = Tournaments.get_tournament!(station.tournament_id)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    Stations.subscribe(tournament.id)

    welcome = %{
      type: "welcome",
      v: @protocol,
      server: Stations.server_name(),
      tournament: %{id: tournament.id, name: tournament.name}
    }

    state = %{state | station: station, touched: now_ms()}
    {settings, state} = settings_frames(state)
    {rounds, state} = round_frames(state)
    push([welcome | settings] ++ rounds, state)
  end

  defp refuse(reason, state) do
    frame = %{type: "refused", reason: to_string(reason)}
    {:stop, :normal, 1000, [encode(frame)], state}
  end

  ## ---------- control frames ----------

  @impl true
  def handle_control({_payload, _opts}, state) do
    state = %{state | heard: now_ms()}
    {:ok, if(state.station, do: touch(state), else: state)}
  end

  ## ---------- messages ----------

  @impl true
  def handle_info(:hello_timeout, %{station: nil} = state), do: {:stop, :normal, state}
  def handle_info(:hello_timeout, state), do: {:ok, state}

  def handle_info(:idle_check, state) do
    if now_ms() - state.heard > @silence_ms do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, @idle_check_ms)
      {:ok, state}
    end
  end

  def handle_info({:tournament_changed, tid, _hint}, %{station: %{tournament_id: tid}} = state) do
    timer = state.timer || Process.send_after(self(), :recompute, @debounce_ms)
    {:ok, %{state | timer: timer}}
  end

  def handle_info(:recompute, %{station: nil} = state), do: {:ok, %{state | timer: nil}}

  # Any change to the tournament may be a category or a room added or
  # renamed, so the settings are looked at again with the round.
  def handle_info(:recompute, state) do
    {settings, state} = settings_frames(%{state | timer: nil})
    {rounds, state} = round_frames(state)
    push(settings ++ rounds, state)
  end

  # The page (or this very socket) changed the row: say what is true now.
  def handle_info({:polis_settings_changed, id}, %{station: %{id: id}} = state) do
    case Stations.get_station(id) do
      %{revoked_at: nil} = station ->
        {settings, state} = settings_frames(%{state | station: station})
        {rounds, state} = round_frames(state)
        push(settings ++ rounds, state)

      _gone ->
        {:ok, state}
    end
  end

  # "Print again": make sure the station has the round as it stands now,
  # then ask for the print.
  def handle_info({:polis_print, round, what}, %{station: %{}} = state) do
    {frames, state} = round_frames(state)
    push(frames ++ [%{type: "print", round: round, what: what}], state)
  end

  def handle_info({:polis_revoked, id}, %{station: %{id: id}} = state) do
    {:stop, :normal, 1000, [encode(%{type: "leave"})], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{station: %{} = station, ref: ref}) do
    Stations.disconnected(station, ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## ---------- rounds ----------

  # The latest published round, as frames to send: none when nothing is
  # public, when it is older than what this socket already sent, or when
  # its rev is the one sent last.
  defp round_frames(state) do
    with %{} = tournament <- Tournaments.get_tournament(state.station.tournament_id),
         {:ok, number, payload} <- RoundPayload.latest(tournament, selection(state, tournament)),
         true <- number >= state.last_round,
         false <- payload["rev"] == state.last_rev do
      {[%{type: "round", round: payload}],
       %{state | last_rev: payload["rev"], last_round: number}}
    else
      _ -> {[], state}
    end
  end

  # The station's share, from the row as it is now: the page may have
  # changed it since this socket last looked.
  defp selection(state, tournament) do
    station = Stations.get_station(state.station.id) || state.station
    Stations.filter(station, tournament)
  end

  # The settings frame, when it differs from the last one sent.
  defp settings_frames(state) do
    with %{} = tournament <- Tournaments.get_tournament(state.station.tournament_id),
         settings = Stations.settings(state.station, tournament),
         false <- settings == state.last_settings do
      {[Map.put(settings, "type", "settings")], %{state | last_settings: settings}}
    else
      _ -> {[], state}
    end
  end

  ## ---------- helpers ----------

  defp push([], state), do: {:ok, state}
  defp push(frames, state), do: {:push, Enum.map(frames, &encode/1), state}

  defp encode(frame), do: {:text, Jason.encode!(frame)}

  defp touch(state) do
    if now_ms() - state.touched >= @touch_ms do
      %{state | station: Stations.touch(state.station), touched: now_ms()}
    else
      state
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

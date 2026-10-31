defmodule Polis.Link do
  @moduledoc """
  The line to one joined tournament: one outgoing WebSocket
  (`Mint.WebSocket`), kept up. The station always dials out, so a hall
  behind any router needs no port opened.

  1. Connect, say `hello` with the key (in the frame, never in the URL).
     The server says `welcome`; the station tells it its `status` (which
     printer, the last round it printed), and again whenever that changes.
  2. The server sends the latest published round (`round`) at once, and
     again whenever it changes or a newer one is published. Each goes to
     `Polis.Station.round_received/2`, which decides what to print.
  3. `print` - the arbiter pressed "Print round N again" in OpenPairings - goes to
     `Polis.Station.print_command/3`.
  4. `settings` - the station's name, room and filters as the server has
     them, after `welcome` and whenever they change - goes to
     `Polis.Station.settings_received/2`. A change made on this page goes
     the other way (`send_settings/2`), and comes back as `settings` once
     the server has kept it: the server's copy is the one that counts.
  5. The line goes: try again after a second, then two, up to thirty. A
     refusal other than `revoked` is said on the page and tried again in a
     minute: a key the server does not know today may be a server restored
     from yesterday's backup tomorrow.

  A ping every 25 seconds keeps a tunnel from deciding the line is idle,
  and a line that has said nothing for 75 is taken for dead.

  Removed in OpenPairings (`leave`, or `refused` with `revoked`), the
  tournament is forgotten here too.
  """

  use GenServer, restart: :transient

  require Logger

  alias Polis.{Protocol, State}

  @ping_ms 25_000
  @dead_ms 75_000
  @max_backoff_ms 30_000
  @refused_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:tournament]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }

  def whereis(id) do
    case Registry.lookup(Polis.LinkRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "`%{up?, error}` of a tournament's line."
  def info(id) do
    case whereis(id) do
      nil -> %{up?: false, error: nil}
      pid -> GenServer.call(pid, :info)
    end
  catch
    :exit, _reason -> %{up?: false, error: nil}
  end

  @doc "Tells the server this station is leaving the tournament, if the line is up."
  def leave(id) do
    case whereis(id) do
      nil -> :ok
      pid -> GenServer.call(pid, :leave)
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Sends a change to the station's name, room or filters to the server of
  tournament `id`: `:ok`, or `{:error, :down}` when the line is not up -
  the server keeps the truth, so a change is made while it can hear it.
  """
  def send_settings(id, fields) do
    case whereis(id) do
      nil -> {:error, :down}
      pid -> GenServer.call(pid, {:settings, fields})
    end
  catch
    :exit, _reason -> {:error, :down}
  end

  # --- the process ---------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :tournament)
    {:ok, _} = Registry.register(Polis.LinkRegistry, id, nil)
    Phoenix.PubSub.subscribe(Polis.PubSub, Polis.Station.status_topic())
    send(self(), :connect)

    {:ok,
     %{
       id: id,
       url: nil,
       conn: nil,
       ref: nil,
       websocket: nil,
       upgrade: %{},
       up?: false,
       error: nil,
       backoff: 1_000,
       heard: now(),
       sent_status: nil
     }}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, %{up?: state.up?, error: state.error}, state}

  def handle_call(:leave, _from, %{up?: true} = state) do
    state = push(state, Protocol.leave())
    {:reply, :ok, close(state)}
  end

  def handle_call(:leave, _from, state), do: {:reply, :ok, state}

  def handle_call({:settings, fields}, _from, %{up?: true} = state) do
    state = push(state, Protocol.settings(fields))
    {:reply, :ok, after_frames(state)}
  end

  def handle_call({:settings, _fields}, _from, state), do: {:reply, {:error, :down}, state}

  @impl true
  def handle_info(:connect, %{conn: nil} = state) do
    case State.tournament(state.id) do
      nil -> {:stop, :normal, state}
      t -> {:noreply, connect(%{state | url: t["socket_url"]})}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:status_changed, %{up?: true} = state),
    do: {:noreply, state |> send_status() |> after_frames()}

  def handle_info(:status_changed, state), do: {:noreply, state}

  def handle_info(:ping, %{up?: true} = state) do
    if now() - state.heard > @dead_ms do
      {:noreply, lost(state, :silent)}
    else
      Process.send_after(self(), :ping, @ping_ms)
      {:noreply, send_frame(state, {:ping, ""})}
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info(:stop, state), do: {:stop, :normal, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2) |> after_frames()}

      {:error, conn, reason, _responses} ->
        {:noreply, lost(%{state | conn: conn}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # --- the socket ------------------------------------------------------------------

  defp connect(state) do
    uri = URI.parse(state.url)
    http = if uri.scheme == "wss", do: :https, else: :http
    ws = if uri.scheme == "wss", do: :wss, else: :ws

    with {:ok, conn} <-
           Mint.HTTP.connect(http, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: [timeout: 10_000]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, uri.path || "/", []) do
      %{state | conn: conn, ref: ref, upgrade: %{}, heard: now()}
    else
      {:error, reason} -> retry(state, reason)
      {:error, conn, reason} -> retry(%{state | conn: conn}, reason)
    end
  end

  defp response({:status, ref, status}, %{ref: ref} = state),
    do: %{state | upgrade: Map.put(state.upgrade, :status, status)}

  defp response({:headers, ref, headers}, %{ref: ref} = state),
    do: %{state | upgrade: Map.put(state.upgrade, :headers, headers)}

  defp response({:done, ref}, %{ref: ref, websocket: nil} = state) do
    case Mint.WebSocket.new(
           state.conn,
           ref,
           state.upgrade[:status],
           state.upgrade[:headers] || []
         ) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}

        push(
          state,
          Protocol.hello(
            State.device_id(),
            State.key(state.id),
            State.device_name(),
            Protocol.software()
          )
        )

      {:error, conn, reason} ->
        Map.put(%{state | conn: conn}, :lost, {:upgrade, reason})
    end
  end

  defp response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket, heard: now()}, &frame/2)

      {:error, websocket, reason} ->
        Map.put(%{state | websocket: websocket}, :lost, reason)
    end
  end

  defp response(_other, state), do: state

  # What a frame decided (the line is gone, the tournament is gone) is acted
  # on once all of them are read.
  defp after_frames(%{removed: true} = state) do
    Logger.info("polis: the server removed this station from tournament #{state.id}")
    Polis.Station.forget(state.id)
    send(self(), :stop)
    close(Map.delete(state, :removed)) |> Map.put(:stopping, true)
  end

  defp after_frames(%{lost: reason} = state), do: lost(Map.delete(state, :lost), reason)
  defp after_frames(state), do: state

  defp frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:ok, message} -> message(message, state)
      {:error, _bad} -> state
    end
  end

  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp frame({:close, _code, _reason}, state), do: Map.put(state, :lost, :closed)
  defp frame(_other, state), do: state

  # --- the conversation -------------------------------------------------------------

  defp message(%{"type" => "welcome"} = frame, state) do
    Process.send_after(self(), :ping, @ping_ms)

    with %{"id" => _, "name" => name} when is_binary(name) <- frame["tournament"] do
      State.update_tournament(state.id, &Map.put(&1, "name", name))
    end

    %{state | up?: true, error: nil, backoff: 1_000, sent_status: nil}
    |> send_status()
    |> tap(fn _ -> Polis.Station.broadcast_links() end)
  end

  defp message(%{"type" => "settings"} = settings, state) do
    Polis.Station.settings_received(state.id, settings)
    state
  end

  defp message(%{"type" => "round", "round" => payload}, state) when is_map(payload) do
    Polis.Station.round_received(state.id, payload)
    state
  end

  defp message(%{"type" => "standings"} = frame, state) do
    Polis.Station.standings_received(state.id, frame)
    state
  end

  # A `what` this version does not know is ignored, as the contract says:
  # the server may ask for more than an old station can print.
  defp message(%{"type" => "print", "round" => round, "what" => what}, state)
       when is_integer(round) and is_binary(what) do
    Polis.Station.print_command(state.id, round, what)
    state
  end

  defp message(%{"type" => "leave"}, state), do: Map.put(state, :removed, true)

  defp message(%{"type" => "refused", "reason" => "revoked"}, state),
    do: Map.put(state, :removed, true)

  defp message(%{"type" => "refused", "reason" => reason}, state) do
    Map.put(
      %{state | error: {:refused, to_string(reason)}, backoff: @refused_ms},
      :lost,
      :refused
    )
  end

  defp message(_other, state), do: state

  # Sent after welcome and whenever it changes - never the same twice.
  defp send_status(state) do
    status = Polis.Station.status_for(state.id)

    if status == state.sent_status,
      do: state,
      else: %{push(state, Protocol.status(status)) | sent_status: status}
  end

  defp push(state, frame), do: send_frame(state, {:text, Protocol.encode(frame)})

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        Map.put(%{state | websocket: websocket}, :lost, reason)

      {:error, conn, reason} ->
        Map.put(%{state | conn: conn}, :lost, reason)
    end
  end

  # --- losing it ----------------------------------------------------------------------

  defp close(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    was_up? = state.up?
    state = %{state | conn: nil, websocket: nil, ref: nil, up?: false}
    if was_up?, do: Polis.Station.broadcast_links()
    state
  end

  defp lost(%{stopping: true} = state, _reason), do: state

  defp lost(state, reason) do
    state |> close() |> retry(reason)
  end

  defp retry(state, reason) do
    state = close(state)
    error = if reason == :refused, do: state.error, else: describe(reason)
    Process.send_after(self(), :connect, state.backoff)

    next =
      if state.backoff >= @refused_ms, do: 1_000, else: min(state.backoff * 2, @max_backoff_ms)

    %{state | error: error, backoff: next}
  end

  defp describe(%{reason: reason}), do: describe(reason)
  defp describe(:econnrefused), do: :nobody_answers
  defp describe(:nxdomain), do: :no_such_address
  defp describe(:timeout), do: :timeout
  defp describe(:closed), do: :closed
  defp describe(:silent), do: :silent
  defp describe({:upgrade, _}), do: :not_a_link
  defp describe(_other), do: :other

  defp now, do: System.monotonic_time(:millisecond)
end

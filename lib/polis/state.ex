defmodule Polis.State do
  @moduledoc """
  The station's file, `<data>/state.json`, and the one process that owns
  it. No database: what the station must remember is a device id, a name,
  a handful of settings and the tournaments it joined - a few kilobytes -
  and a file that is written whole is a file that cannot be half written:
  each change goes to `state.json.tmp`, is flushed, and is renamed over
  the old one. Mode 0600 where the system has modes: the keys are in it.

  What is kept:

    * `device_id` - made on the first start, random, the station's name for
      itself on every server;
    * `device_name` - what the servers call it; the machine's name unless
      somebody changes it;
    * `settings` - `printer` (a name, or nil until chosen), `paper`
      (`"a4"` or `"letter"`), `update_check`, `update_later`;
    * `tournaments` - per joined tournament: where the link goes and its
      key, the tournament's id and name, the two switches and the copies,
      the last round payload received, and which rounds were printed
      (`printed`: round number => the `rev` that was printed).

  The key of a tournament never leaves this module except to the link that
  needs it (`key/1`): `tournaments/0` and `tournament/1` leave it out, so
  no page and no log line can show it by accident.
  """

  use GenServer

  require Logger

  @topic "state"

  def topic, do: @topic

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # --- the device -----------------------------------------------------------------

  def device_id, do: call(:device_id)
  def device_name, do: call(:device_name)
  def put_device_name(name) when is_binary(name), do: call({:put_device_name, name})

  # --- settings ---------------------------------------------------------------------

  def settings, do: call(:settings)
  def setting(name, default \\ nil), do: Map.get(settings(), name, default)
  def put_setting(name, value) when is_binary(name), do: call({:put_setting, name, value})

  # --- tournaments ------------------------------------------------------------------

  @doc "The joined tournaments, oldest first, without their keys."
  def tournaments, do: call(:tournaments)

  @doc "One joined tournament, without its key, or nil."
  def tournament(id), do: Enum.find(tournaments(), &(&1["id"] == id))

  @doc "The key of a joined tournament, for its link and nothing else."
  def key(id), do: call({:key, id})

  @doc """
  Adds a tournament joined with `attrs` (`"socket_url"`, `"key"`, `"server"`,
  `"tournament_id"`, `"name"`) and returns `{:ok, id}`. The same tournament
  on the same server joined again gets the new key and keeps its switches
  and what it printed: that is a station re-joined, not a new one.
  """
  def add_tournament(attrs), do: call({:add_tournament, attrs})

  @doc "Changes a tournament with `fun` (map -> map). `{:ok, tournament}` or `:error`."
  def update_tournament(id, fun), do: call({:update_tournament, id, fun})

  def remove_tournament(id), do: call({:remove_tournament, id})

  @doc "The file as it is on disk now, for tests that look at what was written."
  def reload, do: call(:reload)

  defp call(message), do: GenServer.call(__MODULE__, message)

  # --- the process ------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &Polis.Paths.state_file/0)
    state = read(path)

    state =
      state
      |> Map.put_new_lazy("device_id", fn ->
        Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      end)
      |> Map.put_new_lazy("device_name", &hostname/0)
      |> Map.put_new("settings", %{})
      |> Map.put_new("tournaments", %{})
      |> Map.put("version", 1)

    # Written at once: the device id must be the same after a crash, and
    # the release checks look for this file.
    :ok = write(path, state)
    {:ok, %{path: path, data: state}}
  end

  @impl true
  def handle_call(:device_id, _from, s), do: {:reply, s.data["device_id"], s}
  def handle_call(:device_name, _from, s), do: {:reply, s.data["device_name"], s}

  def handle_call({:put_device_name, name}, _from, s) do
    name = name |> String.trim() |> String.slice(0, 60)
    name = if name == "", do: hostname(), else: name
    {:reply, :ok, change(s, &Map.put(&1, "device_name", name))}
  end

  def handle_call(:settings, _from, s), do: {:reply, s.data["settings"], s}

  def handle_call({:put_setting, name, value}, _from, s),
    do: {:reply, :ok, change(s, &put_in(&1, ["settings", name], value))}

  def handle_call(:tournaments, _from, s), do: {:reply, public(s.data), s}

  def handle_call({:key, id}, _from, s),
    do: {:reply, get_in(s.data, ["tournaments", id, "key"]), s}

  def handle_call({:add_tournament, attrs}, _from, s) do
    existing =
      Enum.find(s.data["tournaments"], fn {_id, t} ->
        t["socket_url"] == attrs["socket_url"] and t["tournament_id"] == attrs["tournament_id"]
      end)

    {id, base} =
      case existing do
        {id, t} ->
          {id, t}

        nil ->
          {"t" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false),
           %{
             "joined_at" => DateTime.to_iso8601(DateTime.utc_now(:second)),
             "print_pairings" => true,
             "print_placecards" => true,
             "copies" => 1,
             "printed" => %{},
             "payload" => nil
           }}
      end

    tournament =
      Map.merge(base, Map.take(attrs, ~w(socket_url key server tournament_id name)))

    s = change(s, &put_in(&1, ["tournaments", id], tournament))
    {:reply, {:ok, id}, s}
  end

  def handle_call({:update_tournament, id, fun}, _from, s) do
    case get_in(s.data, ["tournaments", id]) do
      nil ->
        {:reply, :error, s}

      t ->
        # The key is not the caller's to change.
        updated = t |> fun.() |> Map.put("key", t["key"])
        s = change(s, &put_in(&1, ["tournaments", id], updated))
        {:reply, {:ok, without_key(id, updated)}, s}
    end
  end

  def handle_call({:remove_tournament, id}, _from, s),
    do: {:reply, :ok, change(s, &update_in(&1, ["tournaments"], fn t -> Map.delete(t, id) end))}

  def handle_call(:reload, _from, s), do: {:reply, read(s.path), s}

  defp change(s, fun) do
    data = fun.(s.data)

    if data != s.data do
      case write(s.path, data) do
        :ok -> :ok
        {:error, reason} -> Logger.error("polis: could not write #{s.path}: #{inspect(reason)}")
      end

      Phoenix.PubSub.broadcast(Polis.PubSub, @topic, :state_changed)
    end

    %{s | data: data}
  end

  defp public(data) do
    data["tournaments"]
    |> Enum.map(fn {id, t} -> without_key(id, t) end)
    |> Enum.sort_by(&{&1["joined_at"] || "", &1["id"]})
  end

  defp without_key(id, t), do: t |> Map.delete("key") |> Map.put("id", id)

  # --- the file ---------------------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = data} <- Jason.decode(text) do
      data
    else
      {:error, :enoent} ->
        %{}

      _unreadable ->
        # Kept aside, not overwritten: whoever looks into it later may want
        # it. The station starts with nothing joined rather than not at all.
        aside = path <> ".unreadable-" <> Integer.to_string(System.os_time(:second))
        File.rename(path, aside)
        Logger.error("polis: #{path} could not be read; kept as #{aside}, starting afresh")
        %{}
    end
  end

  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  def write(path, data) do
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(tmp, ""),
         _ <- File.chmod(tmp, 0o600),
         {:ok, file} <- File.open(tmp, [:write, :binary]),
         :ok <- IO.binwrite(file, Jason.encode_to_iodata!(data, pretty: true)),
         :ok <- :file.sync(file),
         :ok <- File.close(file) do
      File.rename(tmp, path)
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end

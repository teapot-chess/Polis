defmodule OpenPairingsPolis.Stations do
  @moduledoc """
  Print stations and the join links that make them.

  ## Joining

  `create_join_code/2` makes a code (32 random bytes, base64url: 43
  characters, valid `@code_minutes` minutes, one use, bound to a
  tournament) and stores only its SHA-256 - the one pairing code every
  hall app uses (OpenPairings' `hall-link-v1` contract, README, "Pairing a
  device"). Codes made before that were 16 base32 characters, read in any
  case; `redeem/2` still takes them until they run out. `redeem/2` spends it and registers the
  station, handing back a key (32 random bytes, base64url) that is never
  stored either - only its SHA-256 is. A station that joins the same
  tournament again (same device id) gets its row back with a new key and
  its removal undone: joining again is the arbiter saying so.

  ## The link

  `authenticate/2` checks a station's `hello`; `connected/2`,
  `touch/1`, `put_status/2` and `disconnected/2` keep its row honest while
  the socket lives.

  ## What a station prints

  Each station has a name, a room - one of the tournament's own
  (`PairingsEngine.Rooms`), by id, so a rename follows it - and two
  filters, categories and board numbers, kept here and nowhere else
  (`update_settings/2`). A room typed as free text before the tournament
  had rooms stays as a label and restricts nothing. The station
  is told them after `welcome` and every time they change, and may change
  them itself; the page may too. One row, two editors, last save wins.

  Pages and sockets talk over `topic/1` on
  `PairingsEngine.PubSub`; there is no process of the plugin's own to talk
  through.
  """
  import Ecto.Query

  alias OpenPairingsPolis.{JoinCode, Plugin, Station}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.{BoardRanges, Features, Repo, Rooms}
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  @code_minutes 15
  @online_seconds 90
  @status_keys 12
  @status_value_bytes 200

  @doc "Minutes a join link stays good."
  def code_minutes, do: @code_minutes

  @doc "The plugin's own PubSub topic for one tournament: pages and sockets meet here."
  def topic(tournament_id), do: "polis:tournament:#{tournament_id}"

  @doc "Subscribes the calling process to `topic/1`."
  def subscribe(tournament_id),
    do: Phoenix.PubSub.subscribe(PairingsEngine.PubSub, topic(tournament_id))

  defp broadcast(tournament_id, message),
    do: Phoenix.PubSub.broadcast(PairingsEngine.PubSub, topic(tournament_id), message)

  @doc "SHA-256 of a secret, lowercase hex. Codes and keys are only ever stored like this."
  def hash(secret) when is_binary(secret),
    do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  ## ---------- join codes ----------

  @doc """
  A fresh join link for `tournament`: `%{code:, url:, expires_at:}`. The
  caller has already authorised the tournament for `scope`.
  """
  def create_join_code(%Scope{} = scope, %Tournament{} = tournament) do
    code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@code_minutes * 60, :second)
      |> DateTime.truncate(:second)

    %JoinCode{
      tournament_id: tournament.id,
      created_by_id: scope.user.id,
      code_hash: hash(code),
      expires_at: expires_at
    }
    |> Repo.insert!()

    {:ok, %{code: code, url: join_url(code), expires_at: expires_at}}
  end

  @doc "The absolute link a station is given: `<endpoint url>/p/polis/join/<code>`."
  def join_url(code) do
    PairingsEngineWeb.Endpoint.url() <> PairingsEngineWeb.Endpoint.path("/p/polis/join/#{code}")
  end

  @doc "The path of the link socket, as the station is told it on joining."
  def socket_path, do: PairingsEngineWeb.Endpoint.path("/p/polis/link")

  @doc "What a station shows as the server's name: the endpoint's host."
  def server_name, do: URI.parse(PairingsEngineWeb.Endpoint.url()).host || "OpenPairings"

  @doc """
  Spends `code` and registers the station `attrs` describes
  (`device`, `name`, `software`). `{:ok, station, key, tournament}`, or
  `{:error, :not_found}` for a code nobody made (or whose tournament is
  gone), `{:error, :used}` for one spent already, `{:error, :expired}`
  for one run out - which includes a code made before the account's print
  station was switched off.
  """
  def redeem(code, attrs) when is_binary(code) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    code = String.trim(code)

    Repo.transact(fn ->
      with {:ok, join} <- usable_code(code, now),
           %Tournament{} = tournament <-
             Tournaments.get_tournament(join.tournament_id) || {:error, :not_found},
           :ok <- if(feature_on?(tournament), do: :ok, else: {:error, :expired}),
           :ok <- spend(join, now) do
        key = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        station = register!(tournament, attrs, hash(key), now)
        {:ok, {station, key, tournament}}
      end
    end)
    |> case do
      {:ok, {station, key, tournament}} ->
        broadcast(tournament.id, :polis_stations_changed)
        {:ok, station, key, tournament}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The code as given (base64url is case-sensitive), then - for a code of
  # the old base32 kind, which was stored lowercased and might be pasted
  # in capitals - as lowercase.
  defp usable_code(code, now) do
    join =
      Repo.get_by(JoinCode, code_hash: hash(code)) ||
        Repo.get_by(JoinCode, code_hash: hash(String.downcase(code)))

    case join do
      nil ->
        {:error, :not_found}

      %JoinCode{used_at: %DateTime{}} ->
        {:error, :used}

      %JoinCode{expires_at: at} = join ->
        if expired?(at, now), do: {:error, :expired}, else: {:ok, join}
    end
  end

  defp expired?(at, now), do: DateTime.compare(at, now) != :gt

  # Conditional on `used_at` still being empty, so two stations racing for
  # one code cannot both win it.
  defp spend(join, now) do
    case Repo.update_all(
           from(j in JoinCode, where: j.id == ^join.id and is_nil(j.used_at)),
           set: [used_at: now]
         ) do
      {1, _} -> :ok
      _ -> {:error, :used}
    end
  end

  defp register!(tournament, attrs, key_hash, now) do
    device = attrs.device

    fields = [
      name: attrs.name,
      software: attrs.software,
      key_hash: key_hash,
      revoked_at: nil,
      connected: false,
      connection_ref: nil,
      updated_at: now
    ]

    case Repo.get_by(Station, tournament_id: tournament.id, device_id: device) do
      nil ->
        Repo.insert!(struct!(%Station{tournament_id: tournament.id, device_id: device}, fields))

      # Joined again: a new key, but the name somebody gave it, its room
      # and its filters stay. A machine's hostname does not outrank a person.
      station ->
        fields = if station.name != "", do: Keyword.delete(fields, :name), else: fields
        station |> Ecto.Changeset.change(fields) |> Repo.update!()
    end
  end

  ## ---------- the link ----------

  @doc """
  The station `device_id` holding `key`, or `{:error, :key}` for no such
  pair and `{:error, :revoked}` for a station removed in OpenPairings (or
  whose tournament went to the recycle bin, or whose account has switched
  the print station off - the switch is access, not just a menu entry).
  Every candidate's hash is compared in constant time.
  """
  def authenticate(device_id, key) when is_binary(device_id) and is_binary(key) do
    key_hash = hash(key)

    candidates = Repo.all(from s in Station, where: s.device_id == ^device_id)

    case Enum.find(candidates, &Plug.Crypto.secure_compare(&1.key_hash, key_hash)) do
      nil ->
        {:error, :key}

      %Station{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      station ->
        case Tournaments.get_tournament(station.tournament_id) do
          %Tournament{} = tournament ->
            if feature_on?(tournament), do: {:ok, station}, else: {:error, :revoked}

          nil ->
            {:error, :revoked}
        end
    end
  end

  def authenticate(_device_id, _key), do: {:error, :key}

  # Whether the account that owns `tournament` has the print station switched
  # on. Asked at every join and every hello: a station is a way to receive the
  # tournament's rounds, so turning the feature off has to cut it off.
  defp feature_on?(%Tournament{user_id: user_id}) do
    user = user_id && Repo.get(User, user_id)
    Features.enabled?(user, Plugin.feature())
  end

  @doc "Marks `station` connected by the socket that calls itself `ref`."
  def connected(%Station{} = station, ref) do
    station =
      station
      |> Ecto.Changeset.change(connected: true, connection_ref: ref, last_seen_at: now())
      |> Repo.update!()

    broadcast(station.tournament_id, :polis_stations_changed)
    station
  end

  @doc """
  Marks `station` disconnected - but only if `ref` is still the socket on
  record. A station that reconnected before its old socket noticed it was
  dead must not be marked offline by the corpse.
  """
  def disconnected(%Station{} = station, ref) do
    Repo.update_all(
      from(s in Station, where: s.id == ^station.id and s.connection_ref == ^ref),
      set: [connected: false, last_seen_at: now()]
    )

    broadcast(station.tournament_id, :polis_stations_changed)
    :ok
  end

  @doc "Writes down that `station` was heard from just now."
  def touch(%Station{} = station) do
    at = now()
    Repo.update_all(from(s in Station, where: s.id == ^station.id), set: [last_seen_at: at])
    %{station | last_seen_at: at}
  end

  @doc """
  Keeps what the station said about itself in its `status` frame: a small
  map of short values, trimmed to `@status_keys` keys of at most
  `@status_value_bytes` characters. It is shown on a page, not trusted.
  """
  def put_status(%Station{} = station, status) when is_map(status) do
    clean =
      status
      |> Enum.reject(fn {k, _v} -> k == "type" end)
      |> Enum.filter(fn {k, v} -> is_binary(k) and byte_size(k) <= 40 and scalar?(v) end)
      |> Enum.take(@status_keys)
      |> Map.new(fn {k, v} -> {k, trim_value(v)} end)

    station =
      station
      |> Ecto.Changeset.change(status: clean, last_seen_at: now())
      |> Repo.update!()

    broadcast(station.tournament_id, :polis_stations_changed)
    station
  end

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)

  # By characters, not bytes: half a UTF-8 character does not survive the
  # JSON column, and the station that sent it would be dropped and sent it again.
  defp trim_value(v) when is_binary(v) and byte_size(v) > @status_value_bytes,
    do: String.slice(v, 0, @status_value_bytes)

  defp trim_value(v), do: v

  @doc "Removes the station on the station's own say-so (its `leave` frame)."
  def forget(%Station{} = station) do
    Repo.delete(station)
    broadcast(station.tournament_id, :polis_stations_changed)
    :ok
  end

  ## ---------- what a station prints ----------

  @doc """
  What `station` is told about itself (the `settings` frame, less its
  type): its `name` and `room` (`room_name/2`), the `categories` and
  `boards` it prints, and the `categories_available` and
  `rooms_available` in its tournament to choose from.
  """
  def settings(%Station{} = station, %Tournament{} = tournament) do
    %{
      "name" => station.name,
      "room" => room_name(station, tournament),
      "categories" => effective_categories(station, tournament),
      "boards" => station.filter_boards || "",
      "categories_available" => tournament.categories || [],
      "rooms_available" => Rooms.names(tournament)
    }
  end

  @doc """
  The tournament room `station` stands in, as `PairingsEngine.Rooms.list/1`
  gives it, or nil: no room, a room since removed, or only a free-text
  label from before the tournament had rooms.
  """
  def room(%Station{room_id: id}, %Tournament{} = tournament), do: Rooms.get(tournament, id)

  @doc """
  The station's room as words: the room's name as it is now (renamed or
  not), the free-text label of a station from before rooms, or "".
  """
  def room_name(%Station{} = station, %Tournament{} = tournament) do
    case room(station, tournament) do
      %{name: name} -> name
      nil -> if (station.room_id || "") == "", do: station.room || "", else: ""
    end
  end

  @doc "Whether the station's room is only a label: free text that names no room of the tournament."
  def legacy_room?(%Station{} = station, %Tournament{} = tournament),
    do: room(station, tournament) == nil and room_name(station, tournament) != ""

  @doc """
  The filter `OpenPairingsPolis.RoundPayload` applies for `station`:
  `%{room: room | nil, categories: names, boards: ranges}`, nil or empty
  for "all". A
  category the tournament no longer has is dropped rather than left to
  match nobody: a station that prints too much is a nuisance, one that
  silently prints nothing is a round without pairings on the wall.
  """
  def filter(%Station{} = station, %Tournament{} = tournament) do
    boards =
      case BoardRanges.parse(station.filter_boards) do
        {:ok, ranges} -> ranges
        {:error, _} -> []
      end

    %{
      room: room(station, tournament),
      categories: effective_categories(station, tournament),
      boards: boards
    }
  end

  defp effective_categories(station, tournament) do
    available = tournament.categories || []
    Enum.filter(station.filter_categories || [], &(&1 in available))
  end

  @name_chars 60

  @doc """
  Changes what `station` is called, where it stands and what it prints,
  from string-keyed `attrs` (`"name"`, `"room"` or `"room_id"`,
  `"categories"`, `"boards"`); a key left out is left alone. Said by the station over its
  link or by an arbiter on the page, and it is the same change either way:
  whoever saves last is right, and both hear of it
  (`{:polis_settings_changed, id}` on `topic/1`).

  An empty name keeps the old one; a category the tournament does not have
  is dropped; board numbers that do not read are `{:error, {:boards,
  reason}}` and nothing changes.

  The room: `"room_id"` (the page) is a room's id, `""` for none, or
  `"keep"` for "leave it as it is"; `"room"` (a station) is a room's name,
  matched without regard to case or spaces, `""` for none. The very label
  the station already has is accepted as no change at all, so an older
  station that sends its free-text room back is not refused for it. Any
  other room is `{:error, {:room, :unknown}}` and nothing changes.
  """
  def update_settings(%Station{} = station, attrs) when is_map(attrs) do
    tournament = Tournaments.get_tournament!(station.tournament_id)

    with {:ok, changes} <- settings_changes(station, tournament, attrs) do
      station = station |> Ecto.Changeset.change(changes) |> Repo.update!()
      broadcast(station.tournament_id, {:polis_settings_changed, station.id})
      broadcast(station.tournament_id, :polis_stations_changed)
      {:ok, station}
    end
  end

  @doc "`update_settings/2` for station `id` of `tournament`, as the page asks it."
  def update_settings(%Tournament{} = tournament, id, attrs) do
    case Repo.get_by(Station, id: id, tournament_id: tournament.id) do
      %Station{revoked_at: nil} = station -> update_settings(station, attrs)
      _gone -> {:error, :not_found}
    end
  end

  defp settings_changes(station, tournament, attrs) do
    available = tournament.categories || []

    changes =
      []
      |> put_text(:name, attrs["name"], fn
        "" -> station.name
        name -> name
      end)

    with {:ok, changes} <- room_changes(changes, station, tournament, attrs) do
      other_changes(changes, available, attrs)
    end
  end

  defp room_changes(changes, station, tournament, attrs) do
    case {attrs["room_id"], attrs["room"]} do
      {"keep", _} ->
        {:ok, changes}

      {id, _} when is_binary(id) ->
        if id == "",
          do: {:ok, Keyword.merge(changes, room_id: "", room: "")},
          else: put_room(changes, Rooms.get(tournament, id))

      {_, text} when is_binary(text) ->
        text = text |> String.trim() |> String.slice(0, @name_chars)

        cond do
          text == "" -> {:ok, Keyword.merge(changes, room_id: "", room: "")}
          room = Rooms.find_by_name(tournament, text) -> put_room(changes, room)
          text == room_name(station, tournament) -> {:ok, changes}
          true -> {:error, {:room, :unknown}}
        end

      _absent ->
        {:ok, changes}
    end
  end

  defp put_room(_changes, nil), do: {:error, {:room, :unknown}}

  defp put_room(changes, room),
    do: {:ok, Keyword.merge(changes, room_id: room.id, room: room.name)}

  defp other_changes(changes, available, attrs) do
    changes =
      case attrs["categories"] do
        list when is_list(list) ->
          picked = for c <- list, is_binary(c), c in available, uniq: true, do: c
          Keyword.put(changes, :filter_categories, picked)

        _absent ->
          changes
      end

    case attrs["boards"] do
      text when is_binary(text) ->
        case BoardRanges.parse(text) do
          {:ok, ranges} -> {:ok, Keyword.put(changes, :filter_boards, BoardRanges.format(ranges))}
          {:error, reason} -> {:error, {:boards, reason}}
        end

      _absent ->
        {:ok, changes}
    end
  end

  defp put_text(changes, field, value, fun) when is_binary(value) do
    Keyword.put(changes, field, value |> String.trim() |> String.slice(0, @name_chars) |> fun.())
  end

  defp put_text(changes, _field, _value, _fun), do: changes

  @doc "Station `id`, as it is now, or nil."
  def get_station(id), do: Repo.get(Station, id)

  ## ---------- pages ----------

  @doc "The tournament's stations still joined, by name."
  def list_stations(tournament_id) do
    Repo.all(
      from s in Station,
        where: s.tournament_id == ^tournament_id and is_nil(s.revoked_at),
        order_by: [asc: s.name, asc: s.id]
    )
  end

  @doc "Every joined station of every tournament `scope` may open, with its tournament."
  def list_for_scope(%Scope{} = scope) do
    ids = Tournaments.authorized_tournament_ids(scope)

    Repo.all(
      from s in Station,
        where: s.tournament_id in subquery(ids) and is_nil(s.revoked_at),
        order_by: [desc: s.tournament_id, asc: s.name],
        preload: [:tournament]
    )
  end

  @doc """
  Removes station `id` from `tournament`: it is told `leave` if it is
  connected and `refused revoked` the next time it calls.
  """
  def revoke(%Tournament{} = tournament, id) do
    case Repo.get_by(Station, id: id, tournament_id: tournament.id) do
      nil ->
        {:error, :not_found}

      station ->
        station =
          station
          |> Ecto.Changeset.change(revoked_at: now(), connected: false)
          |> Repo.update!()

        broadcast(tournament.id, {:polis_revoked, station.id})
        broadcast(tournament.id, :polis_stations_changed)
        {:ok, station}
    end
  end

  @doc ~s(Tells every station of the tournament to print round `round` again: "pairings", "placecards" or "both".)
  def print_again(tournament_id, round, what)
      when is_integer(round) and what in ["pairings", "placecards", "both"] do
    broadcast(tournament_id, {:polis_print, round, what})
  end

  @doc "Online: a live socket that was heard from in the last #{@online_seconds} seconds."
  def online?(%Station{connected: true, last_seen_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= @online_seconds
  end

  def online?(_station), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

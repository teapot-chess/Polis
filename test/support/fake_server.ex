defmodule Polis.FakeServer do
  @moduledoc """
  An OpenPairings that is only the hall link for print stations:
  `POST /p/polis/join/:code` and the socket at `/p/polis/link`, on a port of
  its own. It remembers who joined, every `status` the station sent, and
  whether it said `leave`; it can be given a round to send after
  `welcome` and the station's `settings` to send before it (it then keeps
  what the station changes and tells it back, as OpenPairings does), told to refuse a key or to have revoked it, and made to push
  any frame down the open sockets.

  Started per test (`start/1`); `down/1` and `up/1` take its listener away
  and bring it back on the same port, with what it held.
  """

  use Agent

  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          codes: MapSet.new(Keyword.get(opts, :codes, ["K7Q-4MD"])),
          # A key as OpenPairings makes one: 32 random bytes, base64url.
          key: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
          tournament: %{"id" => 1, "name" => "Club Open"},
          identity: nil,
          statuses: [],
          received: [],
          sockets: [],
          round: nil,
          settings: nil,
          settings_sent: [],
          revoked: false,
          hellos: 0,
          left?: false
        }
      end)

    {:ok, port} = listen(agent, Keyword.get(opts, :port, 0))
    %{agent: agent, port: port}
  end

  defp listen(agent, port) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, agent},
        port: port,
        ip: :loopback,
        startup_log: false
      )

    # Not linked: taking it down is a server going away, not the test.
    Process.unlink(pid)
    Agent.update(agent, &Map.put(&1, :listener, pid))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, port}
  end

  def link(server, code \\ "K7Q-4MD", product \\ "polis"),
    do: "http://127.0.0.1:#{server.port}/p/#{product}/join/#{code}"

  @doc "Takes the listener and every open socket away."
  def down(server) do
    Supervisor.stop(get(server, :listener))
    Agent.update(server.agent, &%{&1 | sockets: []})
    server
  end

  def up(server) do
    {:ok, _port} = listen(server.agent, server.port)
    server
  end

  def get(server, key), do: Agent.get(server.agent, &Map.fetch!(&1, key))
  def set(server, key, value), do: Agent.update(server.agent, &Map.put(&1, key, value))

  @doc "The `status` frames received, oldest first."
  def statuses(server), do: server |> get(:statuses) |> Enum.reverse()

  @doc "Every text frame the station sent, decoded, oldest first."
  def received(server), do: server |> get(:received) |> Enum.reverse()

  @doc "The `settings` frames the station sent, oldest first."
  def settings_sent(server), do: server |> get(:settings_sent) |> Enum.reverse()

  @doc "What a server keeps for a station that has filtered nothing yet."
  def settings(fields \\ %{}) do
    Map.merge(
      %{
        "name" => "Hall PC",
        "room" => "",
        "categories" => [],
        "boards" => "",
        "categories_available" => ["U12", "Women"]
      },
      fields
    )
  end

  @doc "Sends a frame down every open socket."
  def push(server, frame), do: for(pid <- get(server, :sockets), do: send(pid, {:push, frame}))

  @doc "A round frame's payload: two boards and a bye, as OpenPairings publishes one."
  def payload(round, rev \\ "r1") do
    %{
      "tournament" => %{
        "id" => "t-1",
        "name" => "Club Open",
        "city" => "Gent",
        "dates" => "2026-10-17"
      },
      "round" => round,
      "rounds" => 7,
      "published_at" => "2026-10-17T19:30:00Z",
      "locale" => "en",
      "rating_label" => "Rtg",
      "team" => false,
      "rev" => rev,
      "boards" => [
        %{
          "board" => "1",
          "white" => player("Player One", 2210, "1.5"),
          "black" => player("Player Two", 2105, "1"),
          "bye" => nil
        },
        %{
          "board" => "2",
          "white" => player("Player Three", 1980, "1"),
          "black" => player("Player Four", 1890, "1"),
          "bye" => nil
        },
        %{
          "board" => "3",
          "white" => player("Player Five", 1700, "0.5"),
          "black" => nil,
          "bye" => "bye"
        }
      ]
    }
  end

  defp player(name, rating, score) do
    %{
      "name" => name,
      "spoken" => name,
      "title" => nil,
      "rating" => rating,
      "federation" => "BEL",
      "club" => "Hall Club",
      "number" => nil,
      "score" => score
    }
  end
end

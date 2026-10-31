defmodule Polis.JoinTest do
  @moduledoc """
  Redeeming a join link against a stand-in server: a good link gives a key
  and the socket; a used or expired one, a link for another hall program,
  something that is not a link and somebody else's web server each get
  their own answer.
  """

  use Polis.StationCase, async: false

  alias Polis.Join

  @identity %{"v" => 1, "device" => "d-1", "name" => "Hall PC", "software" => "polis 0.1.0"}

  setup do
    %{server: FakeServer.start()}
  end

  test "a good link: the key, the socket, the tournament", %{server: server} do
    assert {:ok, attrs} = Join.redeem(FakeServer.link(server), @identity)
    assert attrs["key"] == FakeServer.get(server, :key)
    assert attrs["socket_url"] == "ws://127.0.0.1:#{server.port}/p/polis/link"
    assert attrs["tournament_id"] == 1
    assert attrs["name"] == "Club Open"
    assert FakeServer.get(server, :identity) == @identity
  end

  test "any prefix before /p/polis/join/ is the server's", %{server: server} do
    link = "http://127.0.0.1:#{server.port}/p/polis/join/K7Q-4MD/"
    assert {:ok, _} = Join.redeem(link, @identity)
  end

  test "a used link is used up", %{server: server} do
    assert {:ok, _} = Join.redeem(FakeServer.link(server), @identity)
    assert {:error, :used_or_expired} = Join.redeem(FakeServer.link(server), @identity)
    assert {:error, :used_or_expired} = Join.redeem(FakeServer.link(server, "NOPE-1"), @identity)
  end

  test "another version of the protocol", %{server: server} do
    assert {:error, :version} = Join.redeem(FakeServer.link(server), %{@identity | "v" => 2})
  end

  test "a link for another hall program is refused before anything is sent", %{server: server} do
    assert {:error, {:wrong_product, "nunki"}} =
             Join.redeem(FakeServer.link(server, "K7Q-4MD", "nunki"), @identity)

    # The code was not spent on the wrong program.
    assert FakeServer.get(server, :identity) == nil
  end

  test "a Manubrium link is refused by name, before anything is sent", %{server: server} do
    link = "manubrium://connect?secret=abc&server=http%3A%2F%2F127.0.0.1%3A#{server.port}"
    assert {:error, {:wrong_product, "manubrium"}} = Join.redeem(link, @identity)
    assert FakeServer.get(server, :identity) == nil
  end

  test "not a link at all" do
    for bad <- [
          "",
          "hello",
          "ftp://x/p/polis/join/A",
          "https://server/join/K7Q",
          "https:///p/polis/join/A"
        ],
        do: assert({:error, :not_a_link} = Join.redeem(bad, @identity), bad)
  end

  test "somebody else's web server is not an OpenPairings server", %{server: server} do
    link = "http://127.0.0.1:#{server.port}/somebody/else/p/polis/join/K7Q-4MD"
    assert {:error, :not_a_server} = Join.redeem(link, @identity)
  end

  test "nobody at the address" do
    assert {:error, :unreachable} =
             Join.redeem("http://127.0.0.1:1/p/polis/join/K7Q-4MD", @identity)
  end

  test "joining through the station keeps the tournament and the key, and the key stays out of the list",
       %{server: server} do
    assert {:ok, id} = Station.join(FakeServer.link(server))
    assert [%{"name" => "Club Open"} = t] = State.tournaments()
    refute Map.has_key?(t, "key")
    assert State.key(id) == FakeServer.get(server, :key)
  end
end

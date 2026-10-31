defmodule OpenPairingsPolis.SecondJobTest do
  @moduledoc """
  The server half of Polis's second job: the room on each board of the
  round payload, the standings frame and when it is sent, the three new
  `print` words, and what Manubrium's Hall page can ask of the plugin
  (`hall_status/2`, `hall_command/3`). Every frame is held to the vendored
  hall-link-v1 schemas.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import OpenPairingsPolis.Fixtures

  alias OpenPairingsPolis.{Contract, Plugin, RoundPayload, StandingsPayload, Stations}
  alias OpenPairingsPolisWeb.LinkSocket
  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user
  setup :admin_with_feature

  setup %{scope: scope} do
    fx = paired(scope)
    {station, key} = joined_station!(scope, fx.tournament)
    Map.merge(fx, %{station: station, key: key})
  end

  defp rooms!(t) do
    {:ok, t} =
      Tournaments.update_tournament(t, %{
        "rooms" => [%{"name" => "Hall A", "boards" => "1"}, %{"name" => "Hall B", "boards" => "2"}]
      })

    t
  end

  defp dial(station, key) do
    {:ok, state} = LinkSocket.init(%{})
    hello = Jason.encode!(%{type: "hello", v: 1, device: station.device_id, key: key})
    {:push, frames, state} = LinkSocket.handle_in({hello, [opcode: :text]}, state)
    {Enum.map(frames, fn {:text, json} -> Jason.decode!(json) end), state}
  end

  describe "the room on a board" do
    test "a tournament without rooms sends none, so its rev is what it was", %{
      tournament: t,
      round: r
    } do
      publish!(r)
      assert {:ok, 1, payload} = RoundPayload.latest(Repo.reload!(t))
      refute Enum.any?(payload["boards"], &Map.has_key?(&1, "room"))
    end

    test "a tournament with rooms names each board's, empty for a board in none", %{
      tournament: t,
      round: r
    } do
      t = rooms!(t)
      publish!(r)
      assert {:ok, 1, payload} = RoundPayload.latest(Repo.reload!(t))
      assert Contract.assert_valid!("server-round", %{"type" => "round", "round" => payload})

      assert Enum.map(payload["boards"], & &1["room"]) == ["Hall A", "Hall B"]
    end

    test "the rev moves when a room does", %{tournament: t, round: r} do
      publish!(r)
      {:ok, 1, plain} = RoundPayload.latest(Repo.reload!(t))
      {:ok, 1, roomed} = RoundPayload.latest(Repo.reload!(rooms!(t)))
      refute plain["rev"] == roomed["rev"]
    end
  end

  describe "the standings frame" do
    test "fits the contract, carries every player and the tournament's tie-breaks", %{
      tournament: t
    } do
      assert {:ok, frame} = StandingsPayload.build(Repo.reload!(t))
      Contract.assert_valid!("server-standings", frame)

      assert frame["type"] == "standings"
      assert frame["rounds"] == 3
      assert frame["rev"] =~ ~r/^[0-9a-f]{64}$/
      assert length(frame["rows"]) == 4
      assert Enum.all?(frame["rows"], &(length(&1["tiebreaks"]) == length(frame["tiebreaks"])))
      assert Enum.all?(frame["rows"], &(&1["rank"] != ""))
    end

    test "the rev is a function of the table", %{tournament: t} do
      {:ok, a} = StandingsPayload.build(Repo.reload!(t))
      {:ok, b} = StandingsPayload.build(Repo.reload!(t))
      assert a["rev"] == b["rev"]
    end

    test "a team event has no table to send", %{tournament: t} do
      t = t |> Ecto.Changeset.change(type: "team-swiss") |> Repo.update!()
      assert StandingsPayload.build(t) == :none
    end
  end

  describe "print again" do
    test "the three new words are accepted by the page's function and fit the contract", %{
      tournament: t
    } do
      Stations.subscribe(t.id)
      for what <- ~w(standings playerlist slips) do
        Contract.assert_valid!("server-print", %{type: "print", round: 1, what: what})
        assert :ok = Stations.print_again(t.id, 1, what)
        assert_receive {:polis_print, 1, ^what}
      end

      assert_raise FunctionClauseError, fn -> Stations.print_again(t.id, 1, "certificates") end
    end

    test "standings travel just before the print that wants them", %{
      station: s,
      key: key,
      tournament: t,
      round: r
    } do
      publish!(r)
      {_frames, state} = dial(s, key)

      Stations.print_again(t.id, 1, "standings")
      assert_receive {:polis_print, 1, "standings"} = msg

      assert {:push, out, _} = LinkSocket.handle_info(msg, state)
      frames = Enum.map(out, fn {:text, json} -> Jason.decode!(json) end)

      assert Enum.map(frames, & &1["type"]) == ["standings", "print"]
      Contract.assert_valid!("server-standings", hd(frames))
      Contract.assert_valid!("server-print", List.last(frames))
    end

    test "the other words send the print alone", %{station: s, key: key, tournament: t, round: r} do
      publish!(r)
      {_frames, state} = dial(s, key)

      for what <- ~w(playerlist slips) do
        Stations.print_again(t.id, 1, what)
        assert_receive {:polis_print, 1, ^what} = msg
        assert {:push, [{:text, json}], _} = LinkSocket.handle_info(msg, state)
        assert %{"type" => "print", "what" => ^what} = Jason.decode!(json)
      end
    end
  end

  describe "Manubrium's Hall page" do
    test "hall_status lists the stations with their room and whether they are online", %{
      tournament: t,
      station: s,
      key: key,
      scope: scope
    } do
      t = rooms!(t)
      status = Plugin.hall_status(scope, t)
      assert %{app: "polis", countdown: nil, devices: [device]} = status
      assert %{id: id, name: "Hall PC", room: "", online: false} = device
      assert id == s.id

      {_frames, _state} = dial(s, key)
      assert %{devices: [%{online: true}]} = Plugin.hall_status(scope, t)
    end

    test "nothing is reported for an account with the print station off", %{
      tournament: t,
      scope: scope,
      user: user
    } do
      {:ok, _} = PairingsEngine.Features.set_enabled(user, [])
      assert Plugin.hall_status(scope, Repo.reload!(t)) == nil
      assert Plugin.hall_command(scope, Repo.reload!(t), {:print, "both"}) == :unsupported
    end

    test "hall_command print needs a published round and a word it knows", %{
      tournament: t,
      round: r,
      scope: scope
    } do
      Stations.subscribe(t.id)
      assert {:error, :no_round} = Plugin.hall_command(scope, t, {:print, "both"})

      publish!(r)
      assert {:error, :bad_what} = Plugin.hall_command(scope, t, {:print, "certificates"})
      assert {:ok, 0} = Plugin.hall_command(scope, t, {:print, "slips"})
      assert_receive {:polis_print, 1, "slips"}
    end

    test "sent_to counts the stations that are online", %{
      tournament: t,
      round: r,
      scope: scope,
      station: s,
      key: key
    } do
      publish!(r)
      {_frames, _state} = dial(s, key)
      assert {:ok, 1} = Plugin.hall_command(scope, t, {:print, "playerlist"})
    end

    test "the countdown and the announcements are Nunki's", %{tournament: t, scope: scope} do
      assert :unsupported = Plugin.hall_command(scope, t, {:countdown, 5})
      assert :unsupported = Plugin.hall_command(scope, t, :cancel_countdown)
      assert :unsupported = Plugin.hall_command(scope, t, {:announce, "silence", nil})
    end
  end
end

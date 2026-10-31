defmodule OpenPairingsPolisWeb.HallLinkContractTest do
  @moduledoc """
  The server half of OpenPairings' `hall-link-v1`, as this plugin speaks it
  to a print station, held to the copy the Polis repository vendors
  (`OpenPairingsPolis.Contract`): every join answer, every frame the link
  socket sends, the pairing code and link it makes - and the station's
  side of the contract, its example frames, taken without complaint.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import OpenPairingsPolis.Fixtures

  alias OpenPairingsPolis.{Contract, JoinCode, Stations}
  alias OpenPairingsPolisWeb.LinkSocket
  alias PairingsEngine.{RateLimit, Repo}

  setup :register_and_log_in_user
  setup :admin_with_feature

  setup %{scope: scope} do
    RateLimit.clear(:board_link_auth, "polis:127.0.0.1")
    on_exit(fn -> RateLimit.clear(:board_link_auth, "polis:127.0.0.1") end)
    fx = paired(scope)
    {:ok, %{code: code, url: url}} = Stations.create_join_code(scope, fx.tournament)
    Map.merge(fx, %{code: code, url: url})
  end

  defp join(code, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/p/polis/join/#{code}", Jason.encode!(body))
  end

  defp answer(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end

  defp request, do: Contract.example("join-request.polis")

  describe "pairing" do
    test "a new code is the contract's code, in the contract's link", %{code: code, url: url} do
      assert code =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert Stations.code_minutes() == 15

      Contract.assert_valid!("pairing-link", %{
        "app" => "polis",
        "link" => url,
        "server" => PairingsEngineWeb.Endpoint.url(),
        "code" => code
      })

      assert url == PairingsEngineWeb.Endpoint.url() <> "/p/polis/join/" <> code
    end

    test "a code of the old kind still joins until it runs out, in any case", %{
      tournament: t,
      user: user
    } do
      old = "k3m9q2x7v4w8z6y5"

      Repo.insert!(%JoinCode{
        tournament_id: t.id,
        created_by_id: user.id,
        code_hash: Stations.hash(old),
        expires_at: DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
      })

      Contract.assert_valid!("join-response", answer(join(String.upcase(old), request()), 200))
    end
  end

  describe "join answers" do
    test "200, and every refusal, fit their schemas", %{code: code} do
      Contract.assert_valid!("join-request", request())

      assert %{"error" => "version", "v" => 1} =
               Contract.assert_valid!(
                 "join-error",
                 answer(join(code, %{request() | "v" => 2}), 409)
               )

      assert %{"error" => "bad_request"} =
               Contract.assert_valid!(
                 "join-error",
                 answer(join(code, Map.delete(request(), "device")), 400)
               )

      Contract.assert_valid!("join-response", answer(join(code, request()), 200))

      assert %{"error" => "used"} =
               Contract.assert_valid!("join-error", answer(join(code, request()), 410))

      assert %{"error" => "unknown_code"} =
               Contract.assert_valid!(
                 "join-error",
                 answer(join(String.duplicate("A", 43), request()), 404)
               )
    end

    test "an expired code is 410 expired", %{code: code} do
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(JoinCode, set: [expires_at: past])

      assert %{"error" => "expired"} =
               Contract.assert_valid!("join-error", answer(join(code, request()), 410))
    end

    test "too many wrong codes is 429 too_many_attempts" do
      conn =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          conn = join(String.duplicate("B", 43), request())
          if conn.status == 429, do: {:halt, conn}, else: {:cont, conn}
        end)

      assert %{"error" => "too_many_attempts"} =
               Contract.assert_valid!("join-error", answer(conn, 429))
    end
  end

  describe "the line" do
    setup %{scope: scope, tournament: t} do
      {station, key} = joined_station!(scope, t)
      %{station: station, key: key}
    end

    @schema_of %{
      "welcome" => "server-welcome",
      "settings" => "server-settings-polis",
      "round" => "server-round",
      "print" => "server-print",
      "leave" => "server-leave",
      "refused" => "server-refused",
      "pong" => "server-pong"
    }

    # Every frame a callback pushed, checked against its schema; the decoded
    # frames and the new state.
    defp out({:push, frames, state}), do: {Enum.map(frames, &checked/1), state}
    defp out({:ok, state}), do: {[], state}
    defp out({:stop, :normal, 1000, frames, state}), do: {Enum.map(frames, &checked/1), state}
    defp out({:stop, :normal, state}), do: {[], state}

    defp checked({:text, json}) do
      frame = Jason.decode!(json)
      Contract.assert_valid!(Map.fetch!(@schema_of, frame["type"]), frame)
    end

    defp hello_frame(station, key) do
      Map.merge(Contract.example("device-hello"), %{"device" => station.device_id, "key" => key})
    end

    defp send_in(state, frame),
      do: LinkSocket.handle_in({Jason.encode!(frame), [opcode: :text]}, state)

    defp dial(station, key) do
      {:ok, state} = LinkSocket.init(%{})
      out(send_in(state, Contract.assert_valid!("device-hello", hello_frame(station, key))))
    end

    test "welcome, settings, a round with a bye, print, leave",
         %{
           station: s,
           key: key,
           round: r,
           tournament: t
         } = fx do
      add_bye!(fx)
      publish!(r)

      {frames, state} = dial(s, key)
      assert Enum.map(frames, & &1["type"]) == ~w(welcome settings round)

      Stations.print_again(t.id, r.number, "both")
      assert_receive {:polis_print, _, "both"} = msg
      {frames, state} = out(LinkSocket.handle_info(msg, state))
      assert "print" in Enum.map(frames, & &1["type"])

      sid = s.id
      {:ok, _} = Stations.revoke(t, s.id)
      assert_receive {:polis_revoked, ^sid} = msg
      assert {[%{"type" => "leave"}], _} = out(LinkSocket.handle_info(msg, state))
    end

    test "a share of the round comes with its selection", %{station: s, key: key, round: r} do
      publish!(r)
      {_frames, state} = dial(s, key)

      {frames, _state} = out(send_in(state, %{"type" => "settings", "boards" => "2"}))

      assert %{"round" => %{"selection" => %{"boards" => "2"}}} =
               Enum.find(frames, &(&1["type"] == "round"))
    end

    test "the station's example frames are taken; refusals fit too", %{station: s, key: key} do
      {_frames, state} = dial(s, key)

      for {_name, frame} <- Contract.examples("device-status-polis") do
        assert {[], _} = out(send_in(state, Contract.assert_valid!("device-status-polis", frame)))
      end

      for {_name, frame} <- Contract.examples("device-settings-polis") do
        Contract.assert_valid!("device-settings-polis", frame)
        {_frames, _state} = out(send_in(state, frame))
      end

      assert {[%{"type" => "pong"}], state} = out(send_in(state, Contract.example("device-ping")))
      assert {[], _} = out(send_in(state, Contract.example("device-leave")))

      # What a station that is no longer known hears.
      {:ok, fresh} = LinkSocket.init(%{})
      assert {[%{"type" => "refused"}], _} = out(send_in(fresh, hello_frame(s, "not the key")))
      v2 = Map.put(hello_frame(s, key), "v", 2)
      assert {[%{"reason" => "version"}], _} = out(send_in(fresh, v2))
    end
  end
end

defmodule OpenPairingsPolisWeb.JoinPlugTest do
  @moduledoc """
  `POST /p/polis/join/:code`, through the real endpoint and router: a good
  code buys a key, everything else buys a status code.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import OpenPairingsPolis.Fixtures

  alias OpenPairingsPolis.{JoinCode, Station, Stations}
  alias PairingsEngine.Repo

  setup :register_and_log_in_user
  setup :admin_with_feature

  setup %{scope: scope} do
    %{tournament: t} = paired(scope)
    {:ok, %{code: code}} = Stations.create_join_code(scope, t)
    %{tournament: t, code: code}
  end

  @body %{v: 1, device: "dev-abc", name: "Hall PC", software: "polis 0.1.0"}

  defp join(code, body \\ @body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/p/polis/join/#{code}", Jason.encode!(body))
  end

  test "a good code buys a key, the socket path and the tournament", %{tournament: t, code: code} do
    conn = join(code)

    assert %{"key" => key, "socket" => "/p/polis/link", "server" => server, "tournament" => tour} =
             json_response(conn, 200)

    assert tour == %{"id" => t.id, "name" => t.name}
    assert is_binary(server) and server != ""
    assert byte_size(key) >= 43

    station = Repo.get_by!(Station, device_id: "dev-abc")
    assert station.tournament_id == t.id
    assert station.name == "Hall PC"
    # Only the hash is kept.
    assert station.key_hash == Stations.hash(key)
    refute station.key_hash == key
    assert {:ok, _} = Stations.authenticate("dev-abc", key)
  end

  test "a used code is gone", %{code: code} do
    assert json_response(join(code), 200)
    assert json_response(join(code), 410)
  end

  test "an expired code is gone", %{code: code} do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    Repo.update_all(JoinCode, set: [expires_at: past])
    assert json_response(join(code), 410)
    refute Repo.get_by(Station, device_id: "dev-abc")
  end

  test "a version this side does not speak is a 409, and the code survives it", %{code: code} do
    assert %{"v" => 1} = json_response(join(code, %{@body | v: 2}), 409)
    assert json_response(join(code), 200)
  end

  test "a code made before the feature was switched off is gone", %{code: code, user: user} do
    {:ok, _} = PairingsEngine.Features.set_enabled(user, [])
    assert json_response(join(code), 410)
    refute Repo.get_by(Station, device_id: "dev-abc")
  end

  test "an unknown code is a 404" do
    assert json_response(join("aaaaaaaaaaaaaaaa"), 404)
  end

  test "a body without a device is refused", %{code: code} do
    assert json_response(join(code, Map.delete(@body, :device)), 400)
  end

  test "joining again from the same device gives the station back a new key", %{
    scope: scope,
    tournament: t,
    code: code
  } do
    %{"key" => old} = json_response(join(code), 200)
    station = Repo.get_by!(Station, device_id: "dev-abc")
    {:ok, _} = Stations.revoke(t, station.id)

    {:ok, %{code: code2}} = Stations.create_join_code(scope, t)
    %{"key" => new} = json_response(join(code2), 200)

    assert [%Station{revoked_at: nil}] = Repo.all(Station)
    assert {:error, :key} = Stations.authenticate("dev-abc", old)
    assert {:ok, _} = Stations.authenticate("dev-abc", new)
  end
end

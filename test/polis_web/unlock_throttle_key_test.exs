defmodule PolisWeb.UnlockThrottleKeyTest do
  @moduledoc """
  Which address the PIN throttle counts: the peer, unless `POLIS_BEHIND_PROXY=1`,
  then the last X-Forwarded-For entry, X-Real-IP, the peer.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest

  alias PolisWeb.UnlockController

  @endpoint PolisWeb.Endpoint
  @proxy {127, 0, 0, 1}

  setup do
    Polis.AccessPin.Throttle.reset()
    :ok
  end

  defp behind_proxy do
    Application.put_env(:polis, :behind_proxy, true)
    on_exit(fn -> Application.delete_env(:polis, :behind_proxy) end)
  end

  defp with_header(conn, name, value), do: Plug.Conn.put_req_header(conn, name, value)

  defp wrong(conn, n), do: for(_ <- 1..n, do: post(conn, "/unlock", %{"pin" => "wrong-pin"}))

  test "without the proxy flag the headers are ignored" do
    conn = remote_conn(@proxy) |> with_header("x-forwarded-for", "203.0.113.9")
    assert UnlockController.peer(conn) == @proxy
    conn = remote_conn(@proxy) |> with_header("x-real-ip", "203.0.113.9")
    assert UnlockController.peer(conn) == @proxy
  end

  test "behind a proxy the last X-Forwarded-For entry wins" do
    behind_proxy()

    conn =
      remote_conn(@proxy)
      |> with_header("x-forwarded-for", "6.6.6.6, 203.0.113.9 ,192.168.1.40")
      |> with_header("x-real-ip", "10.9.9.9")

    assert UnlockController.peer(conn) == {192, 168, 1, 40}
  end

  test "behind a proxy X-Real-IP comes next, IPv6 included" do
    behind_proxy()
    conn = remote_conn(@proxy) |> with_header("x-real-ip", " 192.168.1.41 ")
    assert UnlockController.peer(conn) == {192, 168, 1, 41}
    conn = remote_conn(@proxy) |> with_header("x-real-ip", "::1")
    assert UnlockController.peer(conn) == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  test "malformed headers fall back, step by step, to the peer" do
    behind_proxy()
    conn = remote_conn(@proxy) |> with_header("x-forwarded-for", "1.1.1.1, not-an-ip")
    assert UnlockController.peer(conn) == @proxy

    conn = conn |> with_header("x-real-ip", "192.168.1.42")
    assert UnlockController.peer(conn) == {192, 168, 1, 42}

    conn = remote_conn(@proxy) |> with_header("x-forwarded-for", "")
    assert UnlockController.peer(conn) == @proxy
  end

  test "behind a proxy one phone's wrong guesses do not lock the others out" do
    behind_proxy()
    phone = fn ip -> remote_conn(@proxy) |> with_header("x-forwarded-for", ip) end

    wrong(phone.("192.168.1.61"), 5)
    assert html_response(post(phone.("192.168.1.61"), "/unlock", %{"pin" => "x"}), 429)
    assert html_response(post(phone.("192.168.1.62"), "/unlock", %{"pin" => "x"}), 403)
  end
end

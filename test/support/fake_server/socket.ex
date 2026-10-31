defmodule Polis.FakeServer.Socket do
  @moduledoc false
  @behaviour WebSock

  alias Polis.Protocol

  def init(agent) do
    me = self()
    update(agent, &%{&1 | sockets: [me | &1.sockets]})
    {:ok, %{agent: agent, hello?: false}}
  end

  def handle_in({text, opcode: :text}, state) do
    {:ok, frame} = Protocol.decode(text)
    update(state.agent, &%{&1 | received: [frame | &1.received]})
    handle(frame, state)
  end

  def handle_in(_other, state), do: {:ok, state}

  def handle_info({:push, frame}, state), do: {:push, {:text, Jason.encode!(frame)}, state}
  def handle_info(_other, state), do: {:ok, state}

  defp handle(%{"type" => "hello", "key" => key, "v" => v}, state) do
    server = Agent.get_and_update(state.agent, fn s -> {s, %{s | hellos: s.hellos + 1}} end)

    cond do
      v != 1 ->
        {:push, {:text, refused("version")}, state}

      server.revoked ->
        {:push, {:text, refused("revoked")}, state}

      key != server.key ->
        {:push, {:text, refused("key")}, state}

      true ->
        welcome =
          Jason.encode!(%{
            "type" => "welcome",
            "v" => 1,
            "server" => "fake",
            "tournament" => server.tournament
          })

        settings =
          if server.settings,
            do: [{:text, Jason.encode!(Map.put(server.settings, "type", "settings"))}],
            else: []

        round =
          if server.round,
            do: [{:text, Jason.encode!(%{"type" => "round", "round" => server.round})}],
            else: []

        {:push, [{:text, welcome} | settings] ++ round, %{state | hello?: true}}
    end
  end

  defp handle(%{"type" => "status"} = frame, %{hello?: true} = state) do
    update(state.agent, &%{&1 | statuses: [Map.delete(frame, "type") | &1.statuses]})
    {:ok, state}
  end

  # Kept and told back, as OpenPairings does; "bad" board numbers are
  # turned down, so a test can watch a refusal.
  defp handle(%{"type" => "settings"} = frame, %{hello?: true} = state) do
    change = Map.take(frame, ~w(name room categories boards))

    reply =
      Agent.get_and_update(state.agent, fn s ->
        s = %{s | settings_sent: [change | s.settings_sent]}

        cond do
          change["boards"] == "bad" ->
            {Map.put(s.settings || %{}, "error", "boards"), s}

          unknown_room?(s.settings || %{}, change["room"]) ->
            {Map.put(s.settings || %{}, "error", "room"), s}

          true ->
            change = canonical_room(s.settings || %{}, change)
            kept = Map.merge(s.settings || %{}, change)
            {kept, %{s | settings: kept}}
        end
      end)

    {:push, {:text, Jason.encode!(Map.put(reply, "type", "settings"))}, state}
  end

  defp handle(%{"type" => "leave"}, state) do
    update(state.agent, &%{&1 | left?: true})
    {:ok, state}
  end

  defp handle(_frame, state), do: {:ok, state}

  # With `rooms_available` in the kept settings a room is "", one of them
  # (trimmed, any case) or the legacy text the server already holds.
  defp unknown_room?(%{"rooms_available" => rooms} = kept, room) when is_binary(room) do
    room != "" and room != kept["room"] and is_nil(match_room(rooms, room))
  end

  defp unknown_room?(_kept, _room), do: false

  defp canonical_room(%{"rooms_available" => rooms}, %{"room" => room} = change)
       when is_binary(room) do
    case match_room(rooms, room) do
      nil -> change
      name -> %{change | "room" => name}
    end
  end

  defp canonical_room(_kept, change), do: change

  defp match_room(rooms, room) do
    wanted = room |> String.trim() |> String.downcase()
    Enum.find(rooms, &(String.downcase(&1) == wanted))
  end

  # The test that started the server may be gone while a line it opened is
  # still saying something; that is not this test's failure.
  defp update(agent, fun) do
    Agent.update(agent, fun)
  catch
    :exit, _reason -> :ok
  end

  defp refused(reason), do: Jason.encode!(%{"type" => "refused", "reason" => reason})

  def terminate(_reason, state) do
    me = self()
    update(state.agent, &%{&1 | sockets: List.delete(&1.sockets, me)})
    :ok
  catch
    :exit, _reason -> :ok
  end
end

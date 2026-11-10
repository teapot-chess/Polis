defmodule Polis.AccessPin.Throttle do
  @moduledoc """
  Keeps the PIN from being guessed. Without a limit, six digits fall to a
  determined phone in a day.

  Failures are counted per address (the socket's, never a header) and for the
  box as a whole. An address has five free failures; from the fifth on it
  waits 5 seconds, then 10, 20 and so on up to 15 minutes, and even the right
  PIN is refused while it waits. Across all addresses the box takes at most 40
  failures a minute; past that everybody waits until the oldest of them is a
  minute old - except that an address that has not failed yet still gets 2
  tries of its own, so one phone guessing in a loop cannot keep the arbiter's
  laptop out of the hall's own station. An address quiet for an hour is
  forgotten. It is all in memory: a restart forgives.

  A guess is counted *before* it is compared (`claim/2`), one at a time
  through this process, so a burst of simultaneous guesses cannot outrun the
  count; a right guess takes its count back (`succeeded/1`).
  """

  use GenServer

  @free 5
  @base 5
  @cap 900
  @global_limit 40
  @reserve 2
  @window 60
  @forget 3_600

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`:ok` (the guess is counted; compare it now) or `{:wait, seconds}`."
  def claim(ip, now \\ now()) do
    GenServer.call(__MODULE__, {:claim, ip, now})
  catch
    :exit, _gone -> {:wait, @cap}
  end

  @doc "The guess was right: this address starts again and the box-wide count gives it back."
  def succeeded(ip) do
    GenServer.call(__MODULE__, {:succeeded, ip})
  catch
    :exit, _gone -> :ok
  end

  @doc "How long this address must wait, without counting a guess: 0 or seconds."
  def peek(ip, now \\ now()) do
    GenServer.call(__MODULE__, {:peek, ip, now})
  catch
    :exit, _gone -> @cap
  end

  @doc "Forgets everything (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "The clock, in seconds, that `claim/2` counts in."
  def now, do: System.monotonic_time(:second)

  @impl true
  def init(nil), do: {:ok, %{ips: %{}, global: []}}

  @impl true
  def handle_call({:claim, ip, now}, _from, state) do
    state = prune(state, now)

    case wait(state, ip, now) do
      {:reserve, 0} ->
        # The box-wide cap is reached, this address has tries of its own left.
        old = state.ips[ip] || %{fails: 0, reserved: 0}
        fails = old.fails + 1
        until = if fails >= @free, do: now + min(@base * Integer.pow(2, fails - @free), @cap)
        entry = %{fails: fails, last: now, until: until, reserved: old.reserved + 1}
        {:reply, :ok, %{state | ips: Map.put(state.ips, ip, entry)}}

      {_kind, wait} when wait > 0 ->
        {:reply, {:wait, wait}, state}

      {_kind, _free} ->
        old = state.ips[ip] || %{fails: 0, reserved: 0}
        fails = old.fails + 1
        until = if fails >= @free, do: now + min(@base * Integer.pow(2, fails - @free), @cap)
        entry = %{fails: fails, last: now, until: until, reserved: old.reserved}

        {:reply, :ok,
         %{state | ips: Map.put(state.ips, ip, entry), global: [{now, ip} | state.global]}}
    end
  end

  def handle_call({:peek, ip, now}, _from, state) do
    state = prune(state, now)
    {_kind, wait} = wait(state, ip, now)
    {:reply, wait, state}
  end

  def handle_call({:succeeded, ip}, _from, state) do
    # Gives back this address's own newest entry, never another address's.
    {mine, others} = Enum.split_with(state.global, fn {_at, who} -> who == ip end)
    global = Enum.sort_by(Enum.drop(mine, 1) ++ others, &elem(&1, 0), :desc)
    {:reply, :ok, %{state | ips: Map.delete(state.ips, ip), global: global}}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{ips: %{}, global: []}}

  defp ip_wait(state, ip, now) do
    case state.ips[ip] do
      %{until: until} when is_integer(until) -> max(until - now, 0)
      _none -> 0
    end
  end

  # {:normal | :reserve, seconds}. :reserve is an address with no failures of
  # its own (or still within its two spare tries) while the box-wide cap holds.
  defp wait(state, ip, now) do
    own = ip_wait(state, ip, now)

    case global_wait(state, now) do
      0 ->
        {:normal, own}

      global ->
        if own == 0 and reserve?(state.ips[ip]),
          do: {:reserve, 0},
          else: {:normal, max(global, own)}
    end
  end

  defp reserve?(nil), do: true
  defp reserve?(%{reserved: used}), do: used > 0 and used < @reserve
  defp reserve?(_old), do: false

  defp global_wait(%{global: times}, now) do
    if length(times) >= @global_limit do
      oldest = times |> Enum.map(&elem(&1, 0)) |> Enum.min()
      max(oldest + @window - now, 0)
    else
      0
    end
  end

  defp prune(state, now) do
    ips =
      state.ips
      |> Enum.reject(fn {_ip, %{last: last, until: until}} ->
        now - last > @forget and (until || now) <= now
      end)
      |> Map.new()

    %{state | ips: ips, global: Enum.filter(state.global, fn {at, _ip} -> at > now - @window end)}
  end
end

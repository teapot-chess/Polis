defmodule Polis.AccessPin do
  @moduledoc """
  The station's access PIN. There is always one.

  It lives in `<data>/access-pin`, in plain text, one line, mode 0600: the
  box this station runs on reads that file to show the PIN on its own screen,
  so a hash would be no use to it. The station is the only writer. The file is
  written whole (`access-pin.new`, then renamed over), and a symlink at
  either path is never followed.

  Who is asked for it: a browser that is not on this machine, and only when
  the station listens on the hall's network (`POLIS_LISTEN=lan`). Everyone on
  the machine itself is never asked, but the PIN exists all the same and the
  station page shows it there. See `PolisWeb.PinGate`.

  A grant is a *stamp* of the PIN (`stamp/0`), kept in the visitor's session,
  not a yes: change the PIN and every grant made before it stops matching.

  What a PIN may be (`validate/1`): 6 to 64 characters, no space at either end,
  nothing invisible. There is no way to remove it, and no empty PIN.

  The PIN is never logged and never put in a URL.
  """

  use Gettext, backend: PolisWeb.Gettext

  require Logger

  @file_name "access-pin"
  @request_name "pin-request"
  @key {__MODULE__, :pin}
  @min 6
  @max 64

  def min_length, do: @min
  def max_length, do: @max

  @doc "Where the PIN is kept."
  def path, do: Path.join(data_dir(), @file_name)

  @doc "Where the box leaves a request (`set` or `new`) before the station starts."
  def request_path, do: Path.join(data_dir(), @request_name)

  defp data_dir, do: Application.fetch_env!(:polis, :data_dir)

  # --- rules ---------------------------------------------------------------------------

  @doc """
  `:ok`, or `{:error, reason}` with the reason one of `:invalid`, `:too_short`,
  `:too_long`, `:edge_space`, `:control`.
  """
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(pin) when is_binary(pin) do
    cond do
      not String.valid?(pin) -> {:error, :invalid}
      String.length(pin) < @min -> {:error, :too_short}
      String.length(pin) > @max -> {:error, :too_long}
      String.trim(pin) != pin -> {:error, :edge_space}
      pin |> String.to_charlist() |> Enum.any?(&control?/1) -> {:error, :control}
      true -> :ok
    end
  end

  def validate(_other), do: {:error, :invalid}

  defp control?(c), do: c < 32 or c in 127..159

  @doc "A refusal in words, in the page's language."
  def reason_text(:too_short),
    do: gettext("The PIN needs at least 6 characters.")

  def reason_text(:too_long),
    do: gettext("The PIN may be 64 characters at most.")

  def reason_text(:edge_space),
    do: gettext("The PIN may not start or end with a space.")

  def reason_text(_control_or_invalid),
    do: gettext("The PIN may not contain invisible or control characters.")

  # --- the PIN -------------------------------------------------------------------------

  @doc "The current PIN, from memory (read from the file the first time)."
  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@key, nil) do
      nil -> boot()
      pin -> pin
    end
  end

  @doc "Whether `guess` is the PIN. Constant time."
  @spec correct?(term()) :: boolean()
  def correct?(guess) when is_binary(guess), do: Plug.Crypto.secure_compare(guess, current())
  def correct?(_other), do: false

  @doc """
  Makes sure there is a PIN: reads the file, or makes a random one and writes
  it. Returns the PIN. Called at start (`Polis.AccessPin.Boot`) and by tests.
  """
  @spec boot() :: String.t()
  def boot do
    pin =
      case read() do
        {:ok, pin} ->
          pin

        :none ->
          pin = generate()
          store_new(pin)
          pin

        :unusable ->
          # Somebody's hand-edited file: kept aside, not written over.
          path = path()

          Logger.warning(
            "polis: the access PIN file was not usable; kept as #{path}.invalid and a new random PIN made"
          )

          File.rm_rf(path <> ".invalid")
          File.rename(path, path <> ".invalid")
          pin = generate()
          store_new(pin)
          pin
      end

    :persistent_term.put(@key, pin)
    pin
  end

  # A PIN that cannot be written still holds in memory, with a word in the log,
  # rather than a station that does not start.
  defp store_new(pin) do
    with {:error, reason} <- write(pin) do
      Logger.warning(
        "polis: the access PIN could not be written (#{inspect(reason)}); it holds until Polis restarts"
      )
    end

    :ok
  end

  @doc "Forgets the PIN held in memory (tests)."
  def forget, do: :persistent_term.erase(@key)

  @doc """
  Sets the PIN: `:ok`, or `{:error, reason}` (see `validate/1`). Voids every
  grant at once, and drops the open sockets of browsers that were let in.
  """
  @spec change(term()) :: :ok | {:error, atom()}
  def change(pin) do
    with :ok <- change_quietly(pin) do
      PolisWeb.Endpoint.broadcast(socket_id(), "disconnect", %{})
      :ok
    end
  end

  @doc "A fresh random 6-digit PIN, written and returned."
  @spec renew() :: String.t()
  def renew do
    pin = generate()
    :ok = change(pin)
    pin
  end

  @doc "6 random digits, unbiased: a 64-bit random number, reduced by rejection."
  @spec generate() :: String.t()
  def generate do
    # The largest multiple of 10^6 below 2^64; a number above it is thrown away.
    limit = div(0x1_0000_0000_0000_0000, 1_000_000) * 1_000_000
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)

    if n < limit do
      n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    else
      generate()
    end
  end

  # --- grants --------------------------------------------------------------------------

  @doc "The stamp of the current PIN: what a browser that gave it carries."
  def stamp, do: stamp(current())

  @doc "The stamp of `pin`: HMAC-SHA256 keyed with the cookie secret, first 16 bytes."
  def stamp(pin) do
    key = PolisWeb.Endpoint.config(:secret_key_base)

    <<head::binary-16, _rest::binary>> =
      :crypto.mac(:hmac, :sha256, key, "access-pin:" <> pin)

    Base.encode64(head)
  end

  @doc "Whether `grant` (from a session) is the stamp of the PIN as it is now."
  def granted?(grant) when is_binary(grant), do: Plug.Crypto.secure_compare(grant, stamp())
  def granted?(_other), do: false

  @doc "The socket id of unlocked browsers' LiveViews; a change broadcasts a disconnect to it."
  def socket_id, do: "access_pin"

  # --- the file ------------------------------------------------------------------------

  # Only a regular file is read. A symlink, a folder, anything else is not a PIN.
  defp read do
    path = path()

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, text} <- File.read(path),
             # A line ending from a Windows editor is not part of the PIN.
             pin = text |> String.replace_suffix("\n", "") |> String.replace_suffix("\r", ""),
             :ok <- validate(pin) do
          {:ok, pin}
        else
          _unusable -> :unusable
        end

      {:error, :enoent} ->
        :none

      _not_a_file ->
        :none
    end
  end

  @doc false
  def write(pin) do
    path = path()
    tmp = path <> ".new"
    File.mkdir_p!(Path.dirname(path))

    # Nothing is followed: whatever sits at either name that is not a plain
    # file goes first, and a leftover temporary file with it.
    with {:ok, %File.Stat{type: type}} when type != :regular <- File.lstat(path) do
      File.rm_rf(path)
    end

    File.rm_rf(tmp)

    # Empty first, then the mode, then the PIN: the PIN is never in a file
    # that anybody else may read.
    with :ok <- File.write(tmp, "", [:exclusive]),
         _ <- File.chmod(tmp, 0o600),
         {:ok, file} <- File.open(tmp, [:write, :binary]),
         :ok <- IO.binwrite(file, pin <> "\n"),
         :ok <- :file.sync(file),
         :ok <- File.close(file) do
      File.rename(tmp, path)
    end
  end

  # At start nobody is connected, and the endpoint (the broadcast) is not up.
  defp change_quietly(pin) do
    with :ok <- validate(pin), :ok <- write(pin) do
      :persistent_term.put(@key, pin)
      :ok
    end
  end

  # --- the box's request ----------------------------------------------------------------

  @doc """
  Reads `<data>/pin-request` if it is there, applies it and deletes it
  whatever came of it. `set\\n<pin>\\n` sets the PIN if it is a valid one,
  `new\\n` makes a fresh random one; anything else (the old `remove`
  included) is refused and the PIN stays. Logs what happened, never the PIN.
  Returns `:none`, `:set`, `:new` or `{:refused, reason}`.
  """
  @spec consume_request() :: :none | :set | :new | {:refused, term()}
  def consume_request do
    path = request_path()

    case File.lstat(path) do
      {:error, _absent} ->
        :none

      {:ok, %File.Stat{type: :regular}} ->
        text = File.read(path)
        File.rm(path)
        result = apply_request(text)
        log(result)
        result

      {:ok, _not_a_regular_file} ->
        File.rm_rf(path)
        log({:refused, :not_a_file})
        {:refused, :not_a_file}
    end
  end

  defp apply_request({:ok, text}) do
    case String.split(text, "\n") do
      ["new", ""] -> answer(change_quietly(generate()), :new)
      ["set", pin, ""] -> answer(change_quietly(pin), :set)
      _anything_else -> {:refused, :unknown_request}
    end
  end

  defp apply_request({:error, reason}), do: {:refused, reason}

  defp answer(:ok, done), do: done
  defp answer({:error, reason}, _done), do: {:refused, reason}

  defp log(:none), do: :ok
  defp log(:set), do: Logger.info("polis: pin-request: set")
  defp log(:new), do: Logger.info("polis: pin-request: new")

  defp log({:refused, reason}),
    do: Logger.warning("polis: pin-request refused (#{inspect(reason)})")
end

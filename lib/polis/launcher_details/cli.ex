defmodule Polis.LauncherDetails.CLI do
  @moduledoc """
  `polis.sh details`: the launcher's *Details* panel, for a machine
  that has no launcher window - a Linux box, a terminal over SSH.

      ./polis.sh details          refreshes every 2 s; q or Ctrl-C quits
      ./polis.sh details --once   one snapshot, for pasting into a mail
      ./polis.sh details --json   the endpoint's JSON, as it came

  It runs as `bin/polis eval`, a second short-lived
  runtime beside the server, and asks the running server's
  `GET /_launcher/stats` like the launcher does. The secret and the port come
  from `<data>/run/launcher.token`, which the server writes when it starts
  without a launcher (see `Polis.LauncherDetails`); a launcher's
  secret, when there is one, can be given in `POLIS_LAUNCHER_TOKEN`
  with `PORT` beside it.
  """

  alias Polis.LauncherDetails

  @every_ms 2_000
  @log_lines 20

  @doc "Entry point for `eval`. Never returns: halts with 0, or 1 when it could not ask."
  def main(args \\ System.argv()) do
    System.halt(run(args))
  end

  @doc false
  # The whole command, returning the exit status. `opts` stand in for the
  # token file and the environment in tests: `:port`, `:token`, `:lang`.
  def run(args, opts \\ []) do
    {flags, _rest, _invalid} =
      OptionParser.parse(args, strict: [once: :boolean, json: :boolean, help: :boolean])

    {:ok, _} = Application.ensure_all_started(:req)
    lang = Keyword.get_lazy(opts, :lang, &lang/0)

    cond do
      flags[:help] ->
        IO.puts(usage())
        0

      true ->
        given =
          if Keyword.has_key?(opts, :token), do: {opts[:port], opts[:token]}, else: credentials()

        case given do
          {:error, message} ->
            IO.puts(:stderr, message)
            1

          {port, token} ->
            cond do
              flags[:json] -> json(port, token)
              flags[:once] -> once(port, token, lang)
              true -> watch(port, token, lang)
            end
        end
    end
  end

  defp usage do
    """
    polis.sh details [--once | --json]

      (nothing)  refresh every 2 seconds; q or Ctrl-C quits
      --once     print one snapshot and stop
      --json     print the raw JSON and stop
    """
  end

  # --- asking --------------------------------------------------------------------

  @doc false
  def fetch(port, token, lang) do
    Req.get("http://127.0.0.1:#{port}/_launcher/stats",
      headers: [{LauncherDetails.header(), token}],
      params: [lang: lang],
      decode_body: false,
      retry: false,
      receive_timeout: 3_000,
      connect_options: [timeout: 2_000]
    )
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, error} -> {:error, error}
    end
  end

  defp json(port, token) do
    case fetch(port, token, "en") do
      {:ok, body} ->
        IO.puts(body)
        0

      {:error, reason} ->
        IO.puts(:stderr, not_answering(reason))
        1
    end
  end

  defp once(port, token, lang) do
    case fetch(port, token, lang) do
      {:ok, body} ->
        IO.write(render(Jason.decode!(body), lang, "\n"))
        0

      {:error, reason} ->
        IO.puts(:stderr, not_answering(reason))
        1
    end
  end

  # Like `top`: the screen redrawn in place every two seconds, the keyboard
  # read raw so `q` needs no Enter. Without a terminal (piped, redirected)
  # there is nothing to redraw and it is `--once`.
  defp watch(port, token, lang) do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        parent = self()
        spawn_link(fn -> keys(parent) end)
        IO.write(IO.ANSI.clear())
        loop(port, token, lang)

      {:error, _not_a_terminal} ->
        once(port, token, lang)
    end
  end

  defp keys(parent) do
    case IO.getn("", 1) do
      key when is_binary(key) ->
        send(parent, {:key, key})
        keys(parent)

      _eof ->
        send(parent, {:key, :eof})
    end
  end

  defp loop(port, token, lang) do
    screen =
      case fetch(port, token, lang) do
        {:ok, body} -> render(Jason.decode!(body), lang, "\r\n")
        {:error, reason} -> not_answering(reason) <> "\r\n"
      end

    quit = if lang == "nl", do: "q of Ctrl-C stopt", else: "q or Ctrl-C quits"
    IO.write([IO.ANSI.home(), IO.ANSI.clear(), screen, "\r\n", quit, "\r\n"])

    receive do
      {:key, key} when key in ["q", "Q", <<3>>, :eof] ->
        IO.write("\r\n")
        0
    after
      @every_ms -> loop(port, token, lang)
    end
  end

  # --- showing ------------------------------------------------------------------

  @doc false
  def render(stats, lang, nl) do
    lines = stats["summary"] || []
    width = lines |> Enum.map(&String.length(&1["label"])) |> Enum.max(fn -> 0 end)

    summary =
      Enum.map(lines, fn %{"label" => label, "value" => value} ->
        [String.pad_trailing(label <> ":", width + 1), " ", value, nl]
      end)

    IO.iodata_to_binary([summary, nl, "-- log --", nl, log_tail(stats["log"], lang, nl)])
  end

  defp log_tail(%{"source" => "file", "path" => path}, _lang, nl) do
    case tail_file(path, @log_lines) do
      [] -> ["(", path, ")", nl]
      lines -> Enum.map(lines, &[&1, nl])
    end
  end

  defp log_tail(%{"source" => "journald"} = log, lang, nl) do
    unit = log["unit"] || "polis.service"

    case System.find_executable("journalctl") &&
           System.cmd(
             "journalctl",
             ["-u", unit, "-n", Integer.to_string(@log_lines), "-o", "cat", "--no-pager", "-q"],
             stderr_to_stdout: true
           ) do
      {output, 0} when output != "" ->
        output |> String.split("\n", trim: true) |> Enum.take(-@log_lines) |> Enum.map(&[&1, nl])

      _cannot ->
        if lang == "nl",
          do: [
            "Dit account mag het journaal niet lezen. Probeer: sudo journalctl -u ",
            unit,
            " -f",
            nl
          ],
          else: [
            "This account cannot read the journal. Try: sudo journalctl -u ",
            unit,
            " -f",
            nl
          ]
    end
  end

  defp log_tail(_stdout, lang, nl) do
    if lang == "nl",
      do: ["Het log staat in de terminal waarin Polis gestart is.", nl],
      else: ["The log is in the terminal Polis was started from.", nl]
  end

  @doc false
  # The last `n` lines of a file, reading only its end.
  # sobelow_skip ["Traversal.FileModule"]
  def tail_file(path, n) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      from = max(size - 64 * 1024, 0)

      chunk =
        case :file.pread(file, from, size - from) do
          {:ok, data} -> data
          _eof_or_error -> ""
        end

      File.close(file)

      chunk
      |> String.split(["\r\n", "\n"])
      |> then(fn lines -> if from > 0, do: tl(lines), else: lines end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(-n)
    else
      _none -> []
    end
  end

  defp not_answering({:status, 404}),
    do: "Polis answered, but not to this secret: is the token file from this start?"

  defp not_answering(_reason),
    do: "Polis is not answering on this machine. Is it running?"

  # --- where to ask -----------------------------------------------------------------

  defp credentials do
    case System.get_env(LauncherDetails.env_var()) do
      token when is_binary(token) and token != "" ->
        {port_from_env(), token}

      _none ->
        from_file()
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp from_file do
    with dir when is_binary(dir) <- data_dir(),
         file = LauncherDetails.token_file(dir),
         {:read, {:ok, text}} <- {:read, File.read(file)},
         [token, port | _] <- String.split(text, ["\r\n", "\n"], trim: true),
         {port, ""} <- Integer.parse(port) do
      {port, token}
    else
      {:read, {:error, :eacces}} ->
        {:error,
         "Not allowed to read #{LauncherDetails.token_file(data_dir())}. Run this as the user Polis runs as."}

      {:read, {:error, _}} ->
        {:error,
         "No #{LauncherDetails.token_file(data_dir() || "<data>")}: Polis is not running " <>
           "from this data folder, or a launcher started it (its window has the Details panel)."}

      _other ->
        {:error, "Could not work out where Polis keeps its data. Set POLIS_DATA."}
    end
  end

  defp data_dir do
    Application.get_env(:polis, :data_dir)
  end

  defp port_from_env do
    case Integer.parse(System.get_env("PORT", "4061")) do
      {port, ""} -> port
      _ -> 4061
    end
  end

  defp lang do
    language =
      System.get_env("LC_ALL") || System.get_env("LC_MESSAGES") || System.get_env("LANG") || ""

    if String.starts_with?(language, "nl"), do: "nl", else: "en"
  end
end

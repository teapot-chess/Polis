defmodule Mix.Tasks.I18n.Check do
  @shortdoc "Fails on fuzzy .po entries and msgid/msgstr placeholder mismatches"

  @moduledoc """
  Static check of every `.po` catalogue under `priv/gettext`.

    * any entry flagged `fuzzy` fails (a fuzzy entry is a guess nobody reviewed);
    * the `%{placeholder}` names of a non-empty msgstr must match the msgid
      (singular) or be a subset of msgid plus msgid_plural (plural forms, where
      "one file" legitimately drops the count).

      mix i18n.check [dir]

  Only needs `expo`, which `gettext` already pulls in. No network, no compile
  of the app beyond what `mix` does for any task.
  """
  use Mix.Task

  @placeholder ~r/%\{([A-Za-z0-9_]+)\}/

  @impl Mix.Task
  def run(args) do
    dir =
      case args do
        [d | _] -> d
        [] -> "priv/gettext"
      end

    files = Path.wildcard(Path.join(dir, "**/*.po"))
    if files == [], do: Mix.raise("i18n.check: no .po files under #{dir}")

    problems = Enum.flat_map(files, &check_file/1)

    case problems do
      [] ->
        Mix.shell().info(
          "i18n.check: #{length(files)} catalogues, no fuzzy entries, placeholders match."
        )

      _ ->
        Enum.each(problems, fn problem -> Mix.shell().error(problem) end)
        Mix.raise("i18n.check: #{length(problems)} problem(s) in the catalogues")
    end
  end

  defp check_file(path) do
    po = Expo.PO.parse_file!(path)
    Enum.flat_map(po.messages, &check_message(path, &1))
  end

  defp check_message(path, msg) do
    where = "#{path} (#{line(msg)})"

    fuzzy =
      if "fuzzy" in List.flatten(msg.flags),
        do: ["#{where}: fuzzy entry #{inspect(id(msg))}"],
        else: []

    fuzzy ++ placeholders(where, msg)
  end

  defp placeholders(where, %Expo.Message.Singular{} = m) do
    str = IO.iodata_to_binary(m.msgstr)

    if str == "" do
      []
    else
      want = names(m.msgid)
      got = names(m.msgstr)

      if want == got,
        do: [],
        else: [
          "#{where}: placeholders #{fmt(want)} in msgid vs #{fmt(got)} in msgstr (#{inspect(id(m))})"
        ]
    end
  end

  defp placeholders(where, %Expo.Message.Plural{} = m) do
    allowed = MapSet.union(names(m.msgid), names(m.msgid_plural))

    for {idx, str} <- m.msgstr,
        IO.iodata_to_binary(str) != "",
        extra = MapSet.difference(names(str), allowed),
        MapSet.size(extra) > 0 do
      "#{where}: plural form #{idx} has #{fmt(extra)} not present in msgid/msgid_plural (#{inspect(id(m))})"
    end
  end

  defp names(iodata) do
    @placeholder
    |> Regex.scan(IO.iodata_to_binary(iodata))
    |> Enum.map(&List.last/1)
    |> MapSet.new()
  end

  defp fmt(set),
    do: set |> Enum.sort() |> Enum.map(&"%{#{&1}}") |> Enum.join(",") |> then(&"[#{&1}]")

  defp id(m), do: m |> Map.get(:msgid) |> IO.iodata_to_binary() |> String.slice(0, 60)
  defp line(m), do: m.references |> List.flatten() |> List.first() |> ref()
  defp ref({file, line}), do: "#{file}:#{line}"
  defp ref(file) when is_binary(file), do: file
  defp ref(_), do: "?"
end

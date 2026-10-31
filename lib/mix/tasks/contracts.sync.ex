defmodule Mix.Tasks.Contracts.Sync do
  @shortdoc "Vendors the other programs' contracts from GitHub"

  @moduledoc """
  Rewrites `priv/contracts/vendor/` from the providers' `main` branches.

  The list of what is vendored lives in one place,
  `priv/contracts/vendor/contracts.json`: `[{"repo": "openpairings", "name":
  "hall-link-v1"}]`, the hall link OpenPairings defines and the plugin
  and the station both speak. For each, the provider's `index.json` is
  fetched from
  `https://raw.githubusercontent.com/teapot-chess/<repo>/main/priv/contracts/<name>/`,
  then every file it lists, and the vendored directory
  `priv/contracts/vendor/<repo, lowercase>/<name>/` becomes exactly that:
  files the index no longer lists are deleted. Bytes are kept as they come;
  a vendored file is never edited by hand.

  `mix contracts.check` fetches the same and says what differs, without
  writing anything. Both use Req.
  """

  use Mix.Task

  @base "https://raw.githubusercontent.com/teapot-chess"

  # A provider's index names files; a name that could climb out of the
  # vendored directory is a broken (or hostile) index, refused before
  # anything is written.
  @file_name ~r/\A(?:examples\/)?[A-Za-z0-9][A-Za-z0-9_.-]*\.json\z/

  @impl true
  def run(_args) do
    for {contract, files} <- fetch_all() do
      dir = dir(contract)
      File.mkdir_p!(dir)

      for old <- local_files(dir), not Map.has_key?(files, old), do: File.rm!(Path.join(dir, old))

      for {name, bytes} <- files do
        path = Path.join(dir, name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end

      Mix.shell().info("#{contract["repo"]}/#{contract["name"]}: #{map_size(files)} files")
    end

    :ok
  end

  @doc false
  def vendor_root, do: Path.expand("priv/contracts/vendor", File.cwd!())

  @doc false
  def contracts do
    vendor_root() |> Path.join("contracts.json") |> File.read!() |> Jason.decode!()
  end

  @doc false
  def dir(%{"repo" => repo, "name" => name}),
    do: Path.join([vendor_root(), String.downcase(repo), name])

  @doc false
  # Every file under `dir`, relative, sorted.
  def local_files(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  @doc false
  # `[{contract, %{relative path => bytes}}]`, the index included, as the
  # providers have them now. Raises on anything but a 200.
  def fetch_all do
    {:ok, _apps} = Application.ensure_all_started(:req)

    for contract <- contracts() do
      base = "#{@base}/#{contract["repo"]}/main/priv/contracts/#{contract["name"]}/"
      index = get!(base <> "index.json")
      listed = Jason.decode!(index)["files"]

      for name <- listed,
          not Regex.match?(@file_name, name),
          do:
            Mix.raise(
              "#{contract["repo"]}/#{contract["name"]}: index.json lists #{inspect(name)}"
            )

      files = Map.new(listed, &{&1, get!(base <> &1)})
      {contract, Map.put(files, "index.json", index)}
    end
  end

  defp get!(url) do
    # `decode_body: false`: the bytes, not Req's idea of the JSON in them.
    case Req.get(url, decode_body: false, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: body}} -> body
      {:ok, %{status: status}} -> Mix.raise("#{url} answered #{status}")
      {:error, error} -> Mix.raise("#{url}: #{Exception.message(error)}")
    end
  end
end

defmodule Mix.Tasks.Contracts.Check do
  @shortdoc "Fails when a vendored contract differs from its provider's"

  @moduledoc """
  Fetches every contract listed in `priv/contracts/vendor/contracts.json`
  from its provider, as `mix contracts.sync` would, and compares it with
  the vendored copy byte for byte. Writes nothing. Exits non-zero, with the
  files that were added, removed or changed, when they differ: the provider
  has moved, and Polis has to be checked against what it moved to (`mix
  contracts.sync`, then the tests) before it is merely told so in production.

  Needs the network, so it is not part of `mix test`; CI runs it on its own,
  on every push and once a day.
  """

  use Mix.Task

  alias Mix.Tasks.Contracts.Sync

  @impl true
  def run(_args) do
    drift =
      for {contract, remote} <- Sync.fetch_all(),
          diff = diff(contract, remote),
          diff != [] do
        {contract, diff}
      end

    if drift == [] do
      Mix.shell().info("Every vendored contract matches its provider.")
    else
      for {contract, diff} <- drift do
        Mix.shell().error("#{contract["repo"]}/#{contract["name"]} differs from the provider:")
        for line <- diff, do: Mix.shell().error("  " <> line)
      end

      Mix.raise("Contract drift. Run `mix contracts.sync`, then the tests, and see what broke.")
    end
  end

  defp diff(contract, remote) do
    dir = Sync.dir(contract)
    local = dir |> Sync.local_files() |> Map.new(&{&1, File.read!(Path.join(dir, &1))})

    names = Enum.sort(Enum.uniq(Map.keys(local) ++ Map.keys(remote)))

    for name <- names, line = compare(name, local[name], remote[name]), do: line
  end

  defp compare(name, nil, _remote), do: "added by the provider: " <> name
  defp compare(name, _local, nil), do: "removed by the provider: " <> name
  defp compare(_name, same, same), do: nil
  defp compare(name, _local, _remote), do: "changed: " <> name
end

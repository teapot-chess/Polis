defmodule OpenPairingsPolis.Contract do
  @moduledoc """
  OpenPairings' `hall-link-v1`, as the Polis repository vendors it
  (`priv/contracts/vendor/openpairings/hall-link-v1/`, `mix contracts.sync`
  there), for the plugin's tests: the server half held to the same files
  the station is held to.

  The schemas' `$ref`s are GitHub addresses. ex_json_schema's resolver is
  one global setting, which the core's `PairingsEngineWeb.ContractHelpers`
  sets too, so this module puts its own in place only while it resolves a
  schema, answers hall-link addresses from the vendored copy and hands
  every other address to the core's resolver. Tests using it are not
  async.
  """
  import ExUnit.Assertions

  @dir Path.expand("../../../../priv/contracts/vendor/openpairings/hall-link-v1", __DIR__)

  def dir, do: @dir

  def read!(file), do: @dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  @doc "An example by its name: `example(\"device-status-polis\")`."
  def example(name), do: read!("examples/#{name}.json")

  @doc "The examples of schema `schema`: `[{name, data}]`."
  def examples(schema) do
    for path <- Path.wildcard(Path.join(@dir, "examples/*.json")),
        name = Path.basename(path, ".json"),
        name == schema or String.starts_with?(name, schema <> "."),
        do: {name, read!("examples/#{name}.json")}
  end

  @doc "The schema `name`, resolved, cached for the run."
  def schema(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
        Application.put_env(:ex_json_schema, :remote_schema_resolver, {__MODULE__, :resolve})

        root =
          try do
            ExJsonSchema.Schema.resolve(read!("#{name}.schema.json"))
          after
            if previous,
              do: Application.put_env(:ex_json_schema, :remote_schema_resolver, previous),
              else: Application.delete_env(:ex_json_schema, :remote_schema_resolver)
          end

        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  @doc "Asserts `data` (put through JSON first, as the wire would) fits schema `name`."
  def assert_valid!(name, data) do
    json = data |> Jason.encode!() |> Jason.decode!()

    case ExJsonSchema.Validator.validate(schema(name), json) do
      :ok ->
        json

      {:error, errors} ->
        flunk("""
        does not fit hall-link-v1 #{name}.schema.json:
        #{Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)}
        in: #{Jason.encode!(json)}
        """)
    end
  end

  @doc false
  def resolve(url) do
    case String.split(url, "/main/priv/contracts/hall-link-v1/", parts: 2) do
      ["https://raw.githubusercontent.com/teapot-chess/openpairings", file] -> read!(file)
      _other -> PairingsEngineWeb.ContractHelpers.resolve_remote(url)
    end
  end
end

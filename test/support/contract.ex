defmodule Polis.Contract do
  @moduledoc """
  OpenPairings' `hall-link-v1`, as vendored in
  `priv/contracts/vendor/openpairings/hall-link-v1/` (`mix contracts.sync`),
  for the tests: its schemas resolved without the network, its examples,
  and a check that something fits.

  A schema's `$ref` to `common.schema.json` is a URL on GitHub once its
  `$id` is applied. `resolve/1` is ex_json_schema's remote resolver
  (`config/test.exs`) and answers every such URL from the vendored copy, so
  a test never asks GitHub what the file beside it says.
  """

  import ExUnit.Assertions

  @root Path.expand("../../priv/contracts/vendor", __DIR__)
  @dir Path.join([@root, "openpairings", "hall-link-v1"])

  def root, do: @root
  def dir, do: @dir

  @doc "Every file of the vendored copy, relative and sorted, `index.json` left out."
  def files do
    Path.wildcard(Path.join(@dir, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, @dir))
    |> Enum.reject(&(&1 == "index.json"))
    |> Enum.sort()
  end

  def read!(file), do: @dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  @doc "An example by its name: `example(\"server-round.polis-selection\")`."
  def example(name), do: read!("examples/#{name}.json")

  @doc "The names of the schemas: `\"device-hello\"` for `device-hello.schema.json`."
  def schemas do
    for file <- files(),
        String.ends_with?(file, ".schema.json"),
        file != "common.schema.json",
        do: String.replace_suffix(file, ".schema.json", "")
  end

  @doc """
  `[{schema, name, data}]` for every example. `x.json` and `x.<variant>.json`
  belong to schema `x`.
  """
  def examples do
    schemas = Enum.sort_by(schemas(), &(-String.length(&1)))

    for "examples/" <> file <- files() do
      name = String.replace_suffix(file, ".json", "")
      schema = Enum.find(schemas, &(name == &1 or String.starts_with?(name, &1 <> ".")))
      {schema, name, read!("examples/" <> file)}
    end
  end

  @doc "The examples of one schema: `[{name, data}]`."
  def examples(schema), do: for({^schema, name, data} <- examples(), do: {name, data})

  @doc "The schema `name`, resolved."
  def schema(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        root = ExJsonSchema.Schema.resolve(read!("#{name}.schema.json"))
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  @doc "`:ok`, or `{:error, [{message, path}]}`."
  def validate(name, data), do: ExJsonSchema.Validator.validate(schema(name), data)

  @doc """
  Asserts that `data` fits schema `name` and returns it as JSON would: a
  map with atom or string keys, or JSON text, is put through JSON first, as
  the wire would.
  """
  def assert_valid!(name, data) do
    json =
      if is_binary(data),
        do: Jason.decode!(data),
        else: data |> Jason.encode!() |> Jason.decode!()

    case validate(name, json) do
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
  # ex_json_schema's remote resolver: `https://raw.githubusercontent.com/
  # teapot-chess/<repo>/main/priv/contracts/<name>/<file>`, answered from the
  # vendored copy. Anything else is not ours to fetch, and is refused.
  def resolve(url) do
    case URI.parse(url) do
      %URI{host: "raw.githubusercontent.com", path: path} ->
        ["", "teapot-chess", repo, "main", "priv", "contracts", name, file] =
          String.split(path, "/")

        [@root, String.downcase(repo), name, file]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      _other ->
        raise ArgumentError, "a contract refers to #{url}, which is not vendored"
    end
  end
end

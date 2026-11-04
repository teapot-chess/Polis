defmodule Polis.AccessPin.Boot do
  @moduledoc """
  The start-up step of the access PIN, before the page is served: consume the
  box's `pin-request` if there is one, then make sure there is a PIN at all.
  It does its work in `start_link/1` and returns `:ignore`, so there is no
  process left to supervise.
  """

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(_opts) do
    File.mkdir_p!(Application.fetch_env!(:polis, :data_dir))
    Polis.AccessPin.forget()
    Polis.AccessPin.consume_request()
    Polis.AccessPin.boot()
    :ignore
  end
end

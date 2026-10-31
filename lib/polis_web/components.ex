defmodule PolisWeb.Components do
  @moduledoc "The little the two pages share: the mark, and a job's state in words."

  use Phoenix.Component
  use Gettext, backend: PolisWeb.Gettext

  @doc "The mark (`PolisWeb.Logo`): decorative, the name beside it says what it is."
  attr :class, :any, default: nil

  def logo(assigns) do
    assigns = assign(assigns, :inner, Phoenix.HTML.raw(PolisWeb.Logo.inner()))

    ~H"""
    <svg class={["logo", @class]} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {@inner}
    </svg>
    """
  end

  @doc "A job's state, in words."
  def job_status(%{status: :waiting_printer}), do: gettext("waiting for a printer")
  def job_status(%{status: :queued}), do: gettext("queued")
  def job_status(%{status: :printing}), do: gettext("printing")
  def job_status(%{status: :printed}), do: gettext("printed")

  def job_status(%{status: :failed, error: "stopped"}),
    do: gettext("failed: the station stopped while it printed")

  def job_status(%{status: :failed, error: error}),
    do: gettext("failed: %{why}", why: error || "?")

  @doc "What a job is, in words."
  def job_what(%{what: :test}), do: gettext("Test print")
  def job_what(%{what: :pairings, round: r}), do: gettext("Pairings, round %{n}", n: r)
  def job_what(%{what: :placecards, round: r}), do: gettext("Place cards, round %{n}", n: r)
  def job_what(%{what: :standings, round: r}), do: gettext("Standings after round %{n}", n: r)
  def job_what(%{what: :playerlist, round: r}), do: gettext("Player list, round %{n}", n: r)
  def job_what(%{what: :slips, round: r}), do: gettext("Result slips, round %{n}", n: r)
end

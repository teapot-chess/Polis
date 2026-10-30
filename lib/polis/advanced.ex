defmodule Polis.Advanced do
  @moduledoc """
  "Show advanced features": one setting (`advanced`, true or false) that
  decides whether the rarely used parts of the station page are on view.

  Off for a fresh station. A station that predates the setting has none
  stored, and is judged once by what it already has: if anything an
  advanced feature governs is set to something other than its default
  (updates switched off, start with Windows on, copies other than one, a
  share of the round set on a tournament), advanced is switched on and
  stored, so nobody loses a knob they turn. If nothing is set, nothing is
  stored: a share set later (it arrives from the server) is noticed the
  next time the question is asked.

  Once stored, the choice is the person's, and is never second-guessed.
  """

  alias Polis.{Autostart, State}

  @doc "Whether advanced features are shown. Settles the derivation on first use."
  def enabled? do
    case State.setting("advanced") do
      value when is_boolean(value) ->
        value

      _unset ->
        if in_use?() do
          State.put_setting("advanced", true)
          true
        else
          false
        end
    end
  end

  def put(on?) when is_boolean(on?), do: State.put_setting("advanced", on?)

  @doc "Whether something an advanced feature governs is set away from its default."
  def in_use? do
    State.setting("update_check") == "never" or
      (Autostart.supported?() and Autostart.enabled?()) or
      Enum.any?(State.tournaments(), &tournament_in_use?/1)
  end

  defp tournament_in_use?(t) do
    station = t["station"] || %{}

    (t["copies"] || 1) != 1 or
      station["categories"] not in [nil, []] or
      station["boards"] not in [nil, ""] or
      station["room"] not in [nil, ""]
  end
end

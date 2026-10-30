defmodule PolisWeb.CompactCssTest do
  use ExUnit.Case, async: true

  @css File.read!(Path.expand("../../priv/static/app.css", __DIR__))

  test "the 3.5 inch layout sits behind a media query, with 44 px targets" do
    [_, block] = String.split(@css, "==== compact-screen:", parts: 2)
    assert block =~ "@media (max-width: 520px), (max-height: 360px)"
    assert block =~ "min-height: 44px"
    assert block =~ ".foot a"
    assert block =~ "input[type=checkbox]"
    assert block =~ "details.station summary"
    # one media block, no loose rules outside it
    assert String.split(block, "@media") |> length() == 2
  end
end

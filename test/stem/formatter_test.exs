# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.FormatterTest do
  use ExUnit.Case, async: true

  test "formats expressions and helper subexpressions canonically" do
    assert Stem.Formatter.format_string("Hello {{  format   ( uppercase name )  }}") ==
             "Hello {{format (uppercase name)}}"
  end

  test "formats pipeline expressions canonically" do
    assert Stem.Formatter.format_string("{{  user.name  |> trim |> truncate( 20 )  }}") ==
             "{{user.name |> trim |> truncate(20)}}"
  end

  test "raises on invalid pipeline expressions" do
    assert_raise ArgumentError, ~r/pipeline stages must be helper names/, fn ->
      Stem.Formatter.format_string("{{name |> String.trim()}}")
    end
  end

  test "preserves whitespace trim markers while normalizing block tags" do
    assert Stem.Formatter.format_string(" {{~ #if ok ~}} yes {{~ /if ~}} ") ==
             " {{~#if ok~}} yes {{~/if~}} "
  end

  test "formats partials, comments, else, and empty tags" do
    assert Stem.Formatter.format_string("{{ > greet }}") == "{{> greet}}"
    assert Stem.Formatter.format_string("{{ else }}") == "{{else}}"
    assert Stem.Formatter.format_string("{{ ! note }}") == "{{! note}}"
    assert Stem.Formatter.format_string("{{!-- note --}}") == "{{!-- note --}}"
    assert Stem.Formatter.format_string("{{ #if }}") == "{{#if}}"
    assert Stem.Formatter.format_string("{{}}") == "{{}}"
  end
end

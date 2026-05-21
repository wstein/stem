# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.FormatterTest do
  use ExUnit.Case, async: true

  test "formats expressions and helper subexpressions canonically" do
    assert Stem.Formatter.format_string("Hello {{  format   ( uppercase name )  }}") ==
             "Hello {{format (uppercase name)}}"
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

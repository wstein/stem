# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.FormatterTest do
  use ExUnit.Case, async: true

  # ── Formatter plugin behaviour ─────────────────────────────────────────────

  test "implements Mix.Tasks.Format behaviour" do
    # function_exported?/3 is false for a not-yet-loaded module under async
    # tests, so ensure it is loaded before introspecting.
    Code.ensure_loaded!(Stem.Formatter)
    assert function_exported?(Stem.Formatter, :features, 1)
    assert function_exported?(Stem.Formatter, :format, 2)
  end

  test "features/1 declares .stem extension" do
    assert [extensions: extensions] = Stem.Formatter.features([])
    assert ".stem" in extensions
  end

  test "format/2 delegates to format_string/1" do
    source = "Hello {{ name }}"
    assert Stem.Formatter.format(source, []) == Stem.Formatter.format_string(source)
  end

  # ── format_string/1 canonicalisation ──────────────────────────────────────

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

  test "preserves one-sided whitespace trim markers" do
    assert Stem.Formatter.format_string("{{~ name }}") == "{{~name}}"
    assert Stem.Formatter.format_string("{{ name ~}}") == "{{name~}}"
  end

  test "formats partials, comments, else, and empty tags" do
    assert Stem.Formatter.format_string("{{ > greet }}") == "{{> greet}}"
    assert Stem.Formatter.format_string("{{ else }}") == "{{else}}"
    assert Stem.Formatter.format_string("{{ ! note }}") == "{{! note}}"
    assert Stem.Formatter.format_string("{{!-- note --}}") == "{{!-- note --}}"
    assert Stem.Formatter.format_string("{{ #if }}") == "{{#if}}"
    assert Stem.Formatter.format_string("{{}}") == "{{}}"
  end

  # ── Raw triple-stash tags ──────────────────────────────────────────────────

  test "normalizes raw triple-stash expressions without mangling braces" do
    assert Stem.Formatter.format_string("{{{ raw }}}") == "{{{raw}}}"
    assert Stem.Formatter.format_string("{{{  user.name  }}}") == "{{{user.name}}}"
  end

  test "formats pipelines inside raw triple-stash tags" do
    assert Stem.Formatter.format_string("{{{ name |> trim |> upcase }}}") ==
             "{{{name |> trim |> upcase}}}"
  end

  test "leaves escaped and raw tags side by side intact" do
    assert Stem.Formatter.format_string("{{ name }} and {{{ rawHtml }}}") ==
             "{{name}} and {{{rawHtml}}}"
  end
end

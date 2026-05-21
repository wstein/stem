# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.TokenizerTest do
  use ExUnit.Case, async: true

  alias Stem.Tokenizer

  defp tokens(source) do
    {:ok, tokens} = Tokenizer.tokenize(source)
    tokens
  end

  test "tilde trim markers remove adjacent whitespace" do
    assert tokens("a {{~name~}} b") == [
             {:text, "a", %{line: 1, column: 1}},
             {:expr, "name", :none, %{line: 1, column: 3}},
             {:text, "b", %{line: 1, column: 14}},
             {:eof, %{line: 1, column: 15}}
           ]
  end

  test "one-sided trim markers trim only the marked side" do
    assert tokens("a {{~name}} b") == [
             {:text, "a", %{line: 1, column: 1}},
             {:expr, "name", :none, %{line: 1, column: 3}},
             {:text, " b", %{line: 1, column: 12}},
             {:eof, %{line: 1, column: 14}}
           ]

    assert tokens("a {{name~}} b") == [
             {:text, "a ", %{line: 1, column: 1}},
             {:expr, "name", :none, %{line: 1, column: 3}},
             {:text, "b", %{line: 1, column: 13}},
             {:eof, %{line: 1, column: 14}}
           ]
  end

  test "plain text becomes a single text token" do
    assert tokens("foo bar") == [
             {:text, "foo bar", %{line: 1, column: 1}},
             {:eof, %{line: 1, column: 8}}
           ]
  end

  test "trim markers work for block tags" do
    assert [{:block_open, :if, "show", _}, {:text, "yes", _}, {:block_close, :if, _}, {:eof, _}] =
             tokens(" {{~#if show~}} yes {{~/if~}} ")
  end

  test "empty source yields only eof" do
    assert tokens("") == [{:eof, %{line: 1, column: 1}}]
  end

  test "double-brace expression" do
    assert tokens("Hi {{name}}") == [
             {:text, "Hi ", %{line: 1, column: 1}},
             {:expr, "name", :none, %{line: 1, column: 4}},
             {:eof, %{line: 1, column: 12}}
           ]
  end

  test "expression contents are trimmed" do
    assert [{:expr, "name", :none, _}, {:eof, _}] = tokens("{{  name  }}")
  end

  test "nested braces are rejected" do
    assert {:error, "nested braces are not supported in Stem expressions", _} =
             Tokenizer.tokenize("{{ {name} }}")
  end

  test "short comments are discarded and surrounding text merges" do
    assert tokens("a{{! note }}b") == [
             {:text, "ab", %{line: 1, column: 1}},
             {:eof, %{line: 1, column: 14}}
           ]
  end

  test "block comments are discarded and surrounding text merges" do
    assert [{:text, "ab", _}, {:eof, _}] = tokens("a{{!-- multi\nline --}}b")
  end

  test "block open with arguments" do
    assert [{:block_open, :if, "show", %{line: 1, column: 1}}, {:block_close, :if, _}, {:eof, _}] =
             tokens("{{#if show}}{{/if}}")
  end

  test "each, unless, and with block kinds" do
    assert [{:block_open, :each, "items", _} | _] = tokens("{{#each items}}{{/each}}")
    assert [{:block_open, :unless, "flag", _} | _] = tokens("{{#unless flag}}{{/unless}}")
    assert [{:block_open, :with, "story", _} | _] = tokens("{{#with story}}{{/with}}")
  end

  test "else token" do
    assert [{:block_open, :if, "a", _}, {:block_else, _}, {:block_close, :if, _}, {:eof, _}] =
             tokens("{{#if a}}{{else}}{{/if}}")
  end

  test "partial token captures trimmed name" do
    assert [{:partial, "greet", %{line: 1, column: 1}}, {:eof, _}] = tokens("{{>  greet }}")
  end

  test "tracks line and column across newlines" do
    assert [
             {:text, "a\n", %{line: 1, column: 1}},
             {:expr, "b", :none, %{line: 2, column: 1}},
             {:eof, %{line: 2, column: 6}}
           ] = tokens("a\n{{b}}")
  end

  test "block open with no arguments" do
    assert [{:block_open, :if, "", _}, {:block_close, :if, _}, {:eof, _}] =
             tokens("{{#if}}{{/if}}")
  end

  test "tracks lines across CRLF newlines" do
    assert [
             {:text, "a\r\n", %{line: 1, column: 1}},
             {:expr, "b", :none, %{line: 2, column: 1}},
             {:eof, _}
           ] = tokens("a\r\n{{b}}")
  end

  test "empty tag is skipped and surrounding text merges" do
    assert tokens("a{{}}b") == [
             {:text, "ab", %{line: 1, column: 1}},
             {:eof, %{line: 1, column: 7}}
           ]
  end

  describe "errors" do
    test "unterminated expression" do
      assert Tokenizer.tokenize("foo {{bar") ==
               {:error, "expected closing '}}' for Stem expression", %{line: 1, column: 5}}
    end

    test "nested braces are not supported" do
      assert {:error, "nested braces are not supported in Stem expressions", _} =
               Tokenizer.tokenize("{{ #if {bar} }}")
    end

    test "unterminated block comment" do
      assert {:error, "expected closing '--}}' for Stem comment", _} =
               Tokenizer.tokenize("{{!-- bar")
    end

    test "unterminated short comment" do
      assert {:error, "expected closing '}}' for Stem comment", _} = Tokenizer.tokenize("{{! bar")
    end

    test "unsupported block helper" do
      assert {:error, "unsupported Stem block helper '{{#each_with}}'", _} =
               Tokenizer.tokenize("{{#each_with items}}")
    end

    test "unsupported closing tag" do
      assert {:error, "unsupported Stem closing tag '{{/foo}}'", _} =
               Tokenizer.tokenize("{{/foo}}")
    end
  end
end

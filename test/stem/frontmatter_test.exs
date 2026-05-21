# SPDX-License-Identifier: Apache-2.0

defmodule Stem.FrontmatterTest do
  use ExUnit.Case, async: true

  test "parse extracts valid YAML frontmatter" do
    source = """
    ---
    escape: html
    mode: safe
    warn_on_missing_assigns: true
    ---
    Hello {{name}}
    """

    {:ok, {config, body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :html
    assert config[:mode] == :safe
    assert config[:warn_on_missing_assigns] == true
    assert String.trim(body) == "Hello {{name}}"
  end

  test "parse returns empty config when no frontmatter" do
    source = "Hello {{name}}"

    {:ok, {config, body}} = Stem.Frontmatter.parse(source)

    assert config == []
    assert body == source
  end

  test "parse handles frontmatter with only some fields" do
    source = """
    ---
    escape: json
    ---
    {{value}}
    """

    {:ok, {config, body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :json
    assert is_nil(config[:mode])
    assert is_nil(config[:warn_on_missing_assigns])
    assert String.trim(body) == "{{value}}"
  end

  test "parse normalizes escape modes" do
    source = """
    ---
    escape: none
    ---
    {{{raw}}}
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :none
  end

  test "parse normalizes boolean values" do
    source = """
    ---
    warn_on_missing_assigns: true
    ---
    template
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:warn_on_missing_assigns] == true
  end

  test "parse handles false boolean value" do
    source = """
    ---
    warn_on_missing_assigns: false
    ---
    template
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:warn_on_missing_assigns] == false
  end

  test "parse normalizes mode values" do
    source = """
    ---
    mode: safe
    ---
    template
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:mode] == :safe
  end

  test "parse ignores empty lines in frontmatter" do
    source = """
    ---
    escape: html

    mode: safe
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :html
    assert config[:mode] == :safe
  end

  test "parse ignores comments in frontmatter" do
    source = """
    ---
    # This is a comment
    escape: xml
    # Another comment
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :xml
  end

  test "parse handles invalid escape mode with fallback" do
    source = """
    ---
    escape: invalid_mode
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    # Invalid modes default to :html
    assert config[:escape] == :html
  end

  test "parse rejects unclosed frontmatter" do
    source = """
    ---
    escape: html
    body without closing ---
    """

    {:error, message} = Stem.Frontmatter.parse(source)

    assert String.contains?(message, "not closed")
  end

  test "parse trims leading/trailing whitespace" do
    source = """

    ---
    escape: html
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :html
  end

  test "parse preserves template body whitespace" do
    source = """
    ---
    mode: safe
    ---

    Line 1
    Line 2
    """

    {:ok, {_config, body}} = Stem.Frontmatter.parse(source)

    # Body should preserve leading newline and content
    assert String.starts_with?(String.trim_leading(body), "Line 1")
  end

  test "parse handles case-insensitive YAML keys" do
    source = """
    ---
    ESCAPE: html
    Mode: permissive
    WARN_ON_MISSING_ASSIGNS: yes
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :html
    assert config[:mode] == :permissive
    assert config[:warn_on_missing_assigns] == true
  end

  test "parse handles yes/no/1/0 for boolean values" do
    test_cases = [
      {"true", true},
      {"yes", true},
      {"1", true},
      {"false", false},
      {"no", false},
      {"0", false}
    ]

    Enum.each(test_cases, fn {value, expected} ->
      source = """
      ---
      warn_on_missing_assigns: #{value}
      ---
      body
      """

      {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

      assert config[:warn_on_missing_assigns] == expected,
             "Expected #{value} to parse as #{expected}"
    end)
  end

  test "parse ignores unknown keys in frontmatter" do
    source = """
    ---
    escape: html
    unknown_key: value
    mode: safe
    another_unknown: 123
    ---
    body
    """

    {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :html
    assert config[:mode] == :safe
    assert is_nil(config[:unknown_key])
    assert is_nil(config[:another_unknown])
  end

  test "parse handles all escape modes" do
    modes = ["none", "html", "xml", "json", "url"]
    expected = [:none, :html, :xml, :json, :url]

    Enum.zip(modes, expected)
    |> Enum.each(fn {mode, expected_atom} ->
      source = """
      ---
      escape: #{mode}
      ---
      body
      """

      {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == expected_atom,
             "Expected #{mode} to parse as #{expected_atom}"
    end)
  end

  test "parse handles all mode values" do
    source_safe = """
    ---
    mode: safe
    ---
    body
    """

    source_permissive = """
    ---
    mode: permissive
    ---
    body
    """

    {:ok, {config_safe, _}} = Stem.Frontmatter.parse(source_safe)
    {:ok, {config_permissive, _}} = Stem.Frontmatter.parse(source_permissive)

    assert config_safe[:mode] == :safe
    assert config_permissive[:mode] == :permissive
  end

  test "frontmatter with all valid fields" do
    source = """
    ---
    escape: json
    warn_on_missing_assigns: true
    mode: safe
    ---
    {{#if condition}}{{value}}{{/if}}
    """

    {:ok, {config, body}} = Stem.Frontmatter.parse(source)

    assert config[:escape] == :json
    assert config[:warn_on_missing_assigns] == true
    assert config[:mode] == :safe
    assert String.contains?(body, "{{#if condition}}")
  end

  test "frontmatter empty content" do
    source = """
    ---
    ---
    template
    """

    {:ok, {config, body}} = Stem.Frontmatter.parse(source)

    assert config == []
    assert String.trim(body) == "template"
  end
end

# SPDX-License-Identifier: Apache-2.0

defmodule Stem.FrontmatterCoverageTest do
  use ExUnit.Case, async: true

  describe "Frontmatter edge cases" do
    test "parse with YAML-style comments and spacing" do
      source = """
      ---
      # This is a comment
      escape: html

      # Another comment
      mode: safe
      ---
      {{content}}
      """

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :html
      assert config[:mode] == :safe
      assert String.contains?(body, "{{content}}")
    end

    test "parse with various whitespace patterns" do
      source = """
      ---
        escape: json
      warn_on_missing_assigns:   true
      mode:permissive
      ---
      body
      """

      {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :json
      assert config[:warn_on_missing_assigns] == true
      assert config[:mode] == :permissive
    end

    test "parse preserves exact body content and formatting" do
      source = """
      ---
      escape: none
      ---


      Line 1
        Indented Line
      {{expression}}


      """

      {:ok, {_config, body}} = Stem.Frontmatter.parse(source)

      # Body should preserve the structure after frontmatter
      lines = String.split(body, "\n")

      assert Enum.any?(lines, &String.contains?(&1, "Line 1"))
      assert Enum.any?(lines, &String.contains?(&1, "{{expression}}"))
    end

    test "parse handles template with --- in content" do
      source = """
      ---
      escape: html
      ---
      This is content with --- separator in it
      """

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :html
      assert String.contains?(body, "---")
    end

    test "parse returns empty config for frontmatter with no recognized fields" do
      source = """
      ---
      unknown_field: value
      another_unknown: 123
      ---
      body
      """

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      # Unknown fields are ignored, resulting in empty config
      assert config == []
      assert String.contains?(body, "body")
    end

    test "parse handles frontmatter with only whitespace between delimiters" do
      source = """
      ---


      ---
      template
      """

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      assert config == []
      assert String.contains?(body, "template")
    end

    test "parse handles no newline after opening ---" do
      source = "---\nescape: html\n---\nContent"

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :html
      assert String.contains?(body, "Content")
    end

    test "parse case insensitivity for keys" do
      source = """
      ---
      ESCAPE: xml
      Mode: permissive
      WARN_ON_MISSING_ASSIGNS: yes
      ---
      body
      """

      {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :xml
      assert config[:mode] == :permissive
      assert config[:warn_on_missing_assigns] == true
    end

    test "parse boolean value variations" do
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
               "Value #{value} should parse to #{expected}"
      end)
    end

    test "parse all escape modes" do
      modes = ["none", "html", "xml", "json", "url"]

      Enum.each(modes, fn mode ->
        source = """
        ---
        escape: #{mode}
        ---
        body
        """

        {:ok, {config, _body}} = Stem.Frontmatter.parse(source)

        assert config[:escape] == String.to_atom(mode),
               "Mode #{mode} should parse correctly"
      end)
    end

    test "parse all mode values" do
      source_safe = """
      ---
      mode: safe
      ---
      body
      """

      source_perm = """
      ---
      mode: permissive
      ---
      body
      """

      {:ok, {config_safe, _}} = Stem.Frontmatter.parse(source_safe)
      {:ok, {config_perm, _}} = Stem.Frontmatter.parse(source_perm)

      assert config_safe[:mode] == :safe
      assert config_perm[:mode] == :permissive
    end

    test "parse returns error for unclosed frontmatter" do
      source = """
      ---
      escape: html
      body without closing delimiter
      """

      result = Stem.Frontmatter.parse(source)

      assert {:error, _message} = result
    end

    test "parse handles multiline values (treated as single token)" do
      source = """
      ---
      escape: html
      ---
      body with
      multiple lines
      """

      {:ok, {config, body}} = Stem.Frontmatter.parse(source)

      assert config[:escape] == :html
      assert String.contains?(body, "multiple lines")
    end

    test "parse body with nested templates" do
      source = """
      ---
      mode: safe
      ---
      {{#each items}}
        {{this |> upcase}}
      {{/each}}
      """

      {:ok, {_config, body}} = Stem.Frontmatter.parse(source)

      assert String.contains?(body, "{{#each")
      assert String.contains?(body, "{{/each}}")
    end
  end
end

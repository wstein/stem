# SPDX-License-Identifier: Apache-2.0

defmodule Stem.ConfigTest do
  use ExUnit.Case, async: true

  setup do
    temp_dir =
      System.tmp_dir!() |> Path.join("stem_config_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "load_config parses valid JSON config file", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "html",
      "warn_on_missing_assigns": true,
      "allow_elixir_expressions": false
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :html
    assert config[:warn_on_missing_assigns] == true
    assert config[:allow_elixir_expressions] == false
  end

  test "load_config handles invalid JSON", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")
    File.write!(config_file, "invalid json {")

    {:error, message} = Stem.Config.load_config(config_file)
    assert String.contains?(message, "Failed to parse")
  end

  test "load_config handles missing file", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, "nonexistent.json")

    {:error, message} = Stem.Config.load_config(config_file)
    assert String.contains?(message, "Failed to read")
  end

  test "load_config normalizes escape modes", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "none"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)
    assert config[:escape] == :none
  end

  test "load_config ignores invalid escape mode", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "invalid_mode"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)
    assert config[:escape] == :html
  end

  test "load_config rejects malformed key value pairs", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "broken":
    }
    """)

    {:error, message} = Stem.Config.load_config(config_file)
    assert message =~ "invalid JSON"
  end

  test "load_config ignores unsupported field values", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "html",
      "warn_on_missing_assigns": "yes",
      "mode": "broken"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :html
    refute Keyword.has_key?(config, :warn_on_missing_assigns)
    refute Keyword.has_key?(config, :mode)
  end

  test "load_config expands a single transformer group", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    Stem.Transformers.Strings.all()

    File.write!(config_file, ~S"""
    {
      "transformers": "Stem.Transformers.Strings"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert is_map(config[:transformers])
    assert Map.has_key?(config[:transformers], "trim")
    refute Map.has_key?(config[:transformers], "load_config")
  end

  test "load_config ignores non-string transformers field", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "transformers": true,
      "allow_elixir_expressions": false
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    refute Keyword.has_key?(config, :transformers)
    assert config[:allow_elixir_expressions] == false
  end

  test "load_config ignores invalid allow_elixir_expressions values", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "allow_elixir_expressions": "sometimes"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    refute Keyword.has_key?(config, :allow_elixir_expressions)
  end

  test "load_config ignores transformer modules without all/0", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "transformers": "Stem.Config"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    refute Keyword.has_key?(config, :transformers)
  end

  test "load_config normalizes additional escape modes", %{temp_dir: temp_dir} do
    xml_config = Path.join(temp_dir, "xml.config.json")
    url_config = Path.join(temp_dir, "url.config.json")

    File.write!(xml_config, ~S({"escape":"xml"}))
    File.write!(url_config, ~S({"escape":"url"}))

    assert {:ok, config} = Stem.Config.load_config(xml_config)
    assert config[:escape] == :xml

    assert {:ok, config} = Stem.Config.load_config(url_config)
    assert config[:escape] == :url
  end

  test "find_config locates .stem.config.json in current directory", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")
    File.write!(config_file, "{}")

    {:ok, found_path} = Stem.Config.find_config(temp_dir)
    assert found_path == config_file
  end

  test "find_config walks up directory tree", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")
    File.write!(config_file, "{}")

    nested_dir = Path.join(temp_dir, "a/b/c")
    File.mkdir_p!(nested_dir)

    {:ok, found_path} = Stem.Config.find_config(nested_dir)
    assert found_path == config_file
  end

  test "find_config stops at project root (mix.exs)", %{temp_dir: temp_dir} do
    root_config = Path.join(temp_dir, ".stem.config.json")
    File.write!(root_config, "{}")
    File.write!(Path.join(temp_dir, "mix.exs"), "# project root")

    nested_dir = Path.join(temp_dir, "a/b/c")
    File.mkdir_p!(nested_dir)

    {:ok, found_path} = Stem.Config.find_config(nested_dir)
    assert found_path == root_config
  end

  test "find_config returns :not_found when no config exists", %{temp_dir: temp_dir} do
    nested_dir = Path.join(temp_dir, "a/b/c")
    File.mkdir_p!(nested_dir)

    result = Stem.Config.find_config(nested_dir)
    assert result == :not_found
  end

  test "merge_with_defaults prefers explicit options" do
    config = [escape: :xml, warn_on_missing_assigns: true]
    explicit_opts = [escape: :json]

    result = Stem.Config.merge_with_defaults(config, explicit_opts)

    assert result[:escape] == :json
    assert result[:warn_on_missing_assigns] == true
  end

  test "full config workflow: find, load, and merge", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "xml",
      "allow_elixir_expressions": false
    }
    """)

    {:ok, config_path} = Stem.Config.find_config(temp_dir)
    {:ok, config} = Stem.Config.load_config(config_path)

    cli_opts = [escape: :html, file: "template.stem"]
    merged = Stem.Config.merge_with_defaults(config, cli_opts)

    assert merged[:escape] == :html
    assert merged[:allow_elixir_expressions] == false
    assert merged[:file] == "template.stem"
  end

  test "config file with all supported options", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "json",
      "warn_on_missing_assigns": false,
      "allow_elixir_expressions": true
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :json
    assert config[:warn_on_missing_assigns] == false
    assert config[:allow_elixir_expressions] == true
  end

  test "config file ignores unsupported options", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "html",
      "unsupported_option": "value",
      "another_invalid": 123
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :html
    assert is_nil(config[:unsupported_option])
    assert is_nil(config[:another_invalid])
  end
end

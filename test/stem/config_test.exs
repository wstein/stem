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
      "mode": "safe"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :html
    assert config[:warn_on_missing_assigns] == true
    assert config[:mode] == :safe
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
      "mode": "safe"
    }
    """)

    {:ok, config_path} = Stem.Config.find_config(temp_dir)
    {:ok, config} = Stem.Config.load_config(config_path)

    cli_opts = [escape: :html, file: "template.stem"]
    merged = Stem.Config.merge_with_defaults(config, cli_opts)

    assert merged[:escape] == :html
    assert merged[:mode] == :safe
    assert merged[:file] == "template.stem"
  end

  test "config file with all supported options", %{temp_dir: temp_dir} do
    config_file = Path.join(temp_dir, ".stem.config.json")

    File.write!(config_file, ~S"""
    {
      "escape": "json",
      "warn_on_missing_assigns": false,
      "mode": "permissive"
    }
    """)

    {:ok, config} = Stem.Config.load_config(config_file)

    assert config[:escape] == :json
    assert config[:warn_on_missing_assigns] == false
    assert config[:mode] == :permissive
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

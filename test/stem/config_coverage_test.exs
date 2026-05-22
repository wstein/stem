# SPDX-License-Identifier: Apache-2.0

defmodule Stem.ConfigCoverageTest do
  use ExUnit.Case, async: true

  setup do
    temp_dir =
      System.tmp_dir!() |> Path.join("stem_config_cov_#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  describe "Config edge cases" do
    test "load_config with boolean variations", %{temp_dir: temp_dir} do
      config_file = Path.join(temp_dir, ".stem.config.json")

      File.write!(config_file, ~S"""
      {
        "warn_on_missing_assigns": true
      }
      """)

      {:ok, config} = Stem.Config.load_config(config_file)

      assert config[:warn_on_missing_assigns] == true
    end

    test "load_config with all escape modes", %{temp_dir: temp_dir} do
      modes = ["none", "html", "xml", "json", "url"]

      Enum.each(modes, fn mode ->
        config_file = Path.join(temp_dir, ".stem.config_#{mode}.json")

        File.write!(config_file, "{\"escape\": \"#{mode}\"}")

        {:ok, config} = Stem.Config.load_config(config_file)

        assert config[:escape] == String.to_atom(mode)
      end)
    end

    test "load_config with mixed case keys", %{temp_dir: temp_dir} do
      config_file = Path.join(temp_dir, ".stem_mixed.json")

      File.write!(config_file, ~S"""
      {
        "Escape": "html",
        "MODE": "safe"
      }
      """)

      {:ok, config} = Stem.Config.load_config(config_file)

      # Mixed case keys should be handled or ignored gracefully
      assert is_list(config)
    end

    test "find_config in deeply nested directory", %{temp_dir: temp_dir} do
      root_config = Path.join(temp_dir, ".stem.config.json")
      File.write!(root_config, "{}")
      File.write!(Path.join(temp_dir, "mix.exs"), "")

      nested = Path.join([temp_dir, "a", "b", "c", "d", "e"])
      File.mkdir_p!(nested)

      {:ok, found} = Stem.Config.find_config(nested)

      assert found == root_config
    end

    test "find_config respects project boundary", %{temp_dir: temp_dir} do
      sub_dir = Path.join(temp_dir, "subdir")
      File.mkdir_p!(sub_dir)

      # Create config in subdir
      sub_config = Path.join(sub_dir, ".stem.config.json")
      File.write!(sub_config, "{}")

      # Create mix.exs at subdir level to mark project root
      File.write!(Path.join(sub_dir, "mix.exs"), "")

      deeper_dir = Path.join(sub_dir, "deeper")
      File.mkdir_p!(deeper_dir)

      {:ok, found} = Stem.Config.find_config(deeper_dir)

      assert found == sub_config
    end

    test "merge_with_defaults preserves all config keys" do
      config = [escape: :xml, allow_elixir_expressions: false]
      opts = [warn_on_missing_assigns: true]

      result = Stem.Config.merge_with_defaults(config, opts)

      assert result[:escape] == :xml
      assert result[:allow_elixir_expressions] == false
      assert result[:warn_on_missing_assigns] == true
    end

    test "load_config gracefully handles extra fields" do
      temp_dir = System.tmp_dir!()
      config_file = Path.join(temp_dir, "extra_fields_#{System.unique_integer([:positive])}.json")

      File.write!(config_file, ~S"""
      {
        "escape": "html",
        "extra_field": "ignored",
        "another_extra": 123,
        "warn_on_missing_assigns": false
      }
      """)

      on_exit(fn -> File.rm_rf!(config_file) end)

      {:ok, config} = Stem.Config.load_config(config_file)

      assert config[:escape] == :html
      assert config[:warn_on_missing_assigns] == false
      assert is_nil(config[:extra_field])
    end

    test "load_config empty JSON object" do
      temp_dir = System.tmp_dir!()
      config_file = Path.join(temp_dir, "empty_#{System.unique_integer([:positive])}.json")

      File.write!(config_file, "{}")

      on_exit(fn -> File.rm_rf!(config_file) end)

      {:ok, config} = Stem.Config.load_config(config_file)

      assert config == []
    end
  end
end

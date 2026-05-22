# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Unsafe do
  @moduledoc """
  Runtime template evaluation with server-side template injection (SSTI) risks.

  This module provides runtime evaluation APIs for Stem templates. Runtime evaluation
  can be dangerous when templates come from untrusted sources, as users could exploit
  template syntax to execute arbitrary code.

  **When to use**:
  - Command-line tools (controlled boundary)
  - Render templates where you control all sources
  - Development/testing scenarios

  **When NOT to use**:
  - User-provided templates
  - Rendering templates from external APIs
  - Multi-tenant environments

  **Recommended alternative**:
  Use compile-time APIs (`Stem.compile_string/2`, `Stem.function_from_string/5`)
  which compile templates to static Elixir code and prevent SSTI attacks entirely.
  """

  @doc """
  Compiles and evaluates a template string at runtime using the provided bindings.

  ⚠️  **WARNING**: This function is unsafe with untrusted template input.
  Only use when templates come from a trusted source.

  For safer alternatives, see `Stem.compile_string/2` or `Stem.function_from_string/5`.
  """
  @spec eval_string(String.t(), keyword, [Stem.compile_opt()]) :: term()
  def eval_string(source, bindings \\ [], options \\ [])
      when is_binary(source) and is_list(bindings) and is_list(options) do
    bindings = normalize_runtime_bindings(bindings)
    merged_options = load_and_merge_config(options)
    quoted = Stem.__compile_string__(source, merged_options)
    {result, _} = Code.eval_quoted(quoted, bindings)
    result
  end

  @doc """
  Compiles and evaluates a template file at runtime using the provided bindings.

  ⚠️  **WARNING**: This function is unsafe with untrusted template input.
  Only use when templates come from a trusted source.

  For safer alternatives, see `Stem.compile_file/2` or `Stem.function_from_file/5`.
  """
  @spec eval_file(Path.t(), keyword, [Stem.compile_opt()]) :: String.t()
  def eval_file(filename, bindings \\ [], options \\ [])
      when is_list(bindings) and is_list(options) do
    bindings = normalize_runtime_bindings(bindings)
    merged_options = load_and_merge_config(options)
    quoted = Stem.__compile_file__(filename, merged_options)
    {result, _} = Code.eval_quoted(quoted, bindings)
    result
  end

  defp normalize_runtime_bindings(bindings) do
    bindings
    |> Keyword.put_new(:assigns, [])
    |> Keyword.put_new(:helpers, [])
  end

  defp load_and_merge_config(options) do
    cwd = System.get_env("EXBAR_CWD") || File.cwd!()

    case Stem.Config.find_config(cwd) do
      {:ok, config_path} ->
        case Stem.Config.load_config(config_path) do
          {:ok, config} ->
            Keyword.merge(config, options)

          {:error, _reason} ->
            options
        end

      :not_found ->
        options
    end
  end
end

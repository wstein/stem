# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

{line_exclude, line_include} =
  if line = System.get_env("LINE"), do: {[:test], [line: line]}, else: {[], []}

# The Elixir monorepo records coverage through a shared script. When Stem is
# checked out standalone that script is absent, so guard on its presence to keep
# `mix test --cover` working in both layouts.
cover_record = Path.expand("../../elixir/scripts/cover_record.exs", __DIR__)

if Code.ensure_loaded?(:cover) and File.exists?(cover_record) do
  Code.require_file(cover_record)
  CoverageRecorder.maybe_record("stem")
end

maybe_seed_opt = if seed = System.get_env("SEED"), do: [seed: String.to_integer(seed)], else: []

ex_unit_opts =
  [
    trace: !!System.get_env("TRACE"),
    include: line_include,
    exclude: line_exclude
  ] ++ maybe_seed_opt

ExUnit.start(ex_unit_opts)

defmodule Stem.TestTemplate do
  @moduledoc false

  @cache_key {__MODULE__, :compiled}
  @namespace Module.concat(__MODULE__, Runtime)

  def eval_string(template, bindings \\ [], options \\ [])
      when is_binary(template) and is_list(bindings) and is_list(options) do
    helper_bindings = Keyword.get(options, :helpers, [])

    bindings =
      if template_uses_helpers?(template) do
        Keyword.put_new(bindings, :helpers, helper_bindings)
      else
        bindings
      end

    args = binding_args(bindings)

    module =
      module_for({:string, template, options, args}, fn ->
        build_string_module(template, args, options)
      end)

    apply(module, :render, arg_values(args, bindings))
  end

  def eval_file(filename, bindings \\ [], options \\ [])
      when is_list(bindings) and is_list(options) do
    helper_bindings = Keyword.get(options, :helpers, [])
    filename = IO.chardata_to_string(filename)
    template = File.read!(filename)

    bindings =
      if template_uses_helpers?(template) do
        Keyword.put_new(bindings, :helpers, helper_bindings)
      else
        bindings
      end

    options = Keyword.put_new(options, :file, filename)
    args = binding_args(bindings)

    module =
      module_for({:file, filename, options, args}, fn ->
        build_file_module(filename, args, options)
      end)

    apply(module, :render, arg_values(args, bindings))
  end

  defp module_for(key, builder) do
    case :persistent_term.get(@cache_key, %{}) do
      %{^key => module} ->
        module

      cache ->
        module = builder.()
        :persistent_term.put(@cache_key, Map.put(cache, key, module))
        module
    end
  end

  defp build_string_module(template, args, options) do
    module = Module.concat(@namespace, "S" <> digest({template, args, options}))
    compiled = Stem.__compile_string__(template, options)

    create_or_get(
      module,
      render_quoted(args, compiled),
      options[:file] || "nofile",
      options[:line] || 1
    )
  end

  defp build_file_module(filename, args, options) do
    module = Module.concat(@namespace, "F" <> digest({filename, args, options}))
    compiled = Stem.__compile_file__(filename, options)
    create_or_get(module, render_quoted(args, compiled), filename, 1)
  end

  # The helper-usage heuristic can add a `:helpers` arg the compiled body never
  # references, so mark every parameter used to keep compilation warning-free.
  defp render_quoted(args, compiled) do
    params = Enum.map(args, &Macro.var(&1, nil))
    noops = Enum.map(params, fn param -> quote(do: _ = unquote(param)) end)

    quote do
      def render(unquote_splicing(params)) do
        unquote_splicing(noops)
        unquote(compiled)
      end
    end
  end

  defp create_or_get(module, quoted, file, line) do
    if Code.ensure_loaded?(module) do
      module
    else
      {:module, created, _, _} = Module.create(module, quoted, file: file, line: line)
      created
    end
  rescue
    ArgumentError ->
      module
  end

  defp binding_args(bindings) do
    bindings
    |> Keyword.keys()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp arg_values(args, bindings) do
    Enum.map(args, &Keyword.get(bindings, &1))
  end

  defp template_uses_helpers?(template) when is_binary(template) do
    Regex.scan(~r/\{\{\s*(.*?)\s*\}\}/s, template)
    |> Enum.any?(fn [_, expr] -> helper_expression?(String.trim(expr)) end)
  end

  defp helper_expression?(expr) do
    case String.trim(expr) do
      "" ->
        false

      tag ->
        cond do
          String.starts_with?(tag, "#") ->
            false

          String.starts_with?(tag, "/") ->
            false

          String.starts_with?(tag, ">") ->
            false

          String.starts_with?(tag, "!") ->
            false

          true ->
            case helper_tokens(tag) do
              [name | args] -> helper_name?(name) and args != []
              _ -> false
            end
        end
    end
  end

  defp helper_tokens(expr) when is_binary(expr) do
    Regex.scan(~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s]+/s, expr)
    |> List.flatten()
  end

  defp helper_name?(name), do: String.match?(name, ~r/^[a-z_][a-zA-Z0-9_]*$/)

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end

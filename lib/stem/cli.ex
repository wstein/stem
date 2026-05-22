# SPDX-License-Identifier: Apache-2.0

defmodule Stem.CLI do
  @moduledoc false

  @usage """
  Usage: stem [options] [DATA_FILE] TEMPLATE

  DATA_FILE must be a JSON file path. If omitted, Stem reads JSON data from standard input.

  TEMPLATE may be a file path or `-` to read from standard input.

  Options:

    -o, --output FILE                  Write the rendered output to FILE
    --strict                           Warn on missing assigns
    --allow-elixir-expressions         Allow arbitrary Elixir expressions in tags
    --transformers GROUPS             Enable helper capability groups (comma-separated)
    --escape MODE                      Escape mode: none, html (default), xml, json, url
    -h, --help                         Show this message
    -v, --version                      Show the Stem version
  """

  def run(argv) when is_list(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          output: :string,
          help: :boolean,
          version: :boolean,
          strict: :boolean,
          allow_elixir_expressions: :boolean,
          transformers: :string,
          escape: :string
        ],
        aliases: [o: :output, h: :help, v: :version]
      )

    if invalid != [] do
      raise ArgumentError, usage()
    end

    cond do
      opts[:help] ->
        {:help, usage()}

      opts[:version] ->
        {:version, "Stem #{Application.spec(:stem, :vsn)}"}

      true ->
        render_cli(args, opts)
    end
  end

  def usage, do: @usage

  def render_cli([template_path], opts) do
    template = read_template!(template_path)

    bindings =
      if template_path == "-" do
        %{}
      else
        read_assigns_from_stdin!()
      end

    compile_opts = build_compile_options(template_path, opts)

    output =
      render_template!(template, bindings, compile_opts)

    case opts[:output] do
      nil ->
        IO.write(output)

      path ->
        File.write!(path, output)
    end

    :ok
  end

  def render_cli([data_source, template_path], opts) do
    template = read_template!(template_path)
    bindings = read_assigns_file!(data_source)

    compile_opts = build_compile_options(template_path, opts)

    output =
      render_template!(template, bindings, compile_opts)

    case opts[:output] do
      nil ->
        IO.write(output)

      path ->
        File.write!(path, output)
    end

    :ok
  end

  def render_cli([], _opts), do: raise(ArgumentError, usage())
  def render_cli(_, _opts), do: raise(ArgumentError, usage())

  def render_template!(template, bindings, options \\ [])
      when is_binary(template) and is_map(bindings) do
    args = template_binding_args(template)
    module = build_renderer_module(template, args, options)
    apply(module, :render, runtime_binding_values(args, bindings, options))
  end

  defp template_binding_args(template) when is_binary(template) do
    []
    |> maybe_add_binding(template, :assigns, &template_uses_assigns?/1)
    |> maybe_add_binding(template, :transformers, &template_uses_helpers?/1)
  end

  defp maybe_add_binding(args, template, binding, predicate) do
    if predicate.(template) do
      args ++ [binding]
    else
      args
    end
  end

  defp runtime_binding_values(args, bindings, options) do
    Enum.map(args, fn
      :assigns -> bindings
      :transformers -> Keyword.get(options, :transformers, %{})
    end)
  end

  defp template_uses_assigns?(template) when is_binary(template) do
    Regex.scan(~r/\{\{\{?\s*(.*?)\s*\}\}\}?/s, template)
    |> Enum.any?(fn [_, expr] -> expression_uses_assigns?(normalize_expression(expr)) end)
  end

  defp template_uses_helpers?(template) when is_binary(template) do
    Regex.scan(~r/\{\{\{?\s*(.*?)\s*\}\}\}?/s, template)
    |> Enum.any?(fn [_, expr] -> helper_expression?(normalize_expression(expr)) end)
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

  defp normalize_expression(expr) do
    expr
    |> String.trim()
    |> String.trim_leading("~")
    |> String.trim_trailing("~")
    |> String.trim()
  end

  defp expression_uses_assigns?(expr) do
    case String.split(expr) do
      [] ->
        false

      [token | rest] ->
        cond do
          String.starts_with?(token, "#") ->
            expression_uses_assigns?(Enum.join(rest, " "))

          String.starts_with?(token, "/") ->
            false

          String.starts_with?(token, ">") ->
            false

          String.starts_with?(token, "!") ->
            false

          true ->
            Enum.any?([token | rest], &identifier_uses_assigns?/1)
        end
    end
  end

  defp identifier_uses_assigns?(token) do
    cond do
      token in ["true", "false", "nil", "this", "@index", "@index1", "@key"] ->
        false

      String.starts_with?(token, "../") ->
        true

      String.starts_with?(token, "@") ->
        true

      String.match?(token, ~r/^[a-z_][a-zA-Z0-9_]*$/) ->
        true

      true ->
        false
    end
  end

  defp build_renderer_module(template, args, options) do
    file = options[:file] || "nofile"
    module = Module.concat([__MODULE__, "Renderer", "M#{System.unique_integer([:positive])}"])

    quoted =
      quote do
        require Stem
        @compile {:nowarn_unused_vars, true}

        Stem.function_from_string(:def, :render, unquote(template), unquote(args),
          file: unquote(file),
          warn_on_missing_assigns: unquote(options[:warn_on_missing_assigns] || false),
          escape: unquote(options[:escape] || :html),
          allow_elixir_expressions: unquote(options[:allow_elixir_expressions] || false)
        )
      end

    {:module, created, _, _} = Module.create(module, quoted, file: file, line: 1)
    created
  end

  defp read_template!("-"), do: read_stdin()

  defp read_template!(path) do
    path
    |> resolve_path()
    |> File.read!()
  end

  defp read_assigns_from_stdin! do
    case read_stdin() do
      "" -> %{}
      source -> decode_assigns!(source)
    end
  end

  defp read_assigns_file!("-") do
    read_assigns_from_stdin!()
  end

  defp read_assigns_file!(data_source) do
    data_source
    |> resolve_path()
    |> File.read!()
    |> decode_assigns!()
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      :eof -> ""
      data -> IO.iodata_to_binary(data)
    end
  end

  defp decode_assigns!(source) when is_binary(source) do
    source
    |> JSON.decode!()
    |> atomize_keys()
  rescue
    exception ->
      raise ArgumentError, "invalid JSON data: #{Exception.message(exception)}"
  end

  defp atomize_keys(value) when is_map(value) do
    for {key, nested_value} <- value, into: %{} do
      {atomize_key(key), atomize_keys(nested_value)}
    end
  end

  defp atomize_keys(value) when is_list(value) do
    Enum.map(value, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  # JSON object keys are always strings, so only the binary case can occur.
  defp atomize_key(key) when is_binary(key), do: String.to_atom(key)

  defp resolve_path(path) when is_binary(path) do
    base_cwd = System.get_env("EXBAR_CWD") || File.cwd!()
    Path.expand(path, base_cwd)
  end

  defp parse_escape_mode(nil), do: :html

  defp parse_escape_mode(mode_string) when is_binary(mode_string) do
    case String.downcase(mode_string) do
      "none" -> :none
      "html" -> :html
      "xml" -> :xml
      "json" -> :json
      "url" -> :url
      other -> raise ArgumentError, "unknown escape mode: #{other}"
    end
  end

  defp build_compile_options(template_path, opts) do
    cwd = System.get_env("EXBAR_CWD") || File.cwd!()

    cli_opts = [
      file: template_path,
      warn_on_missing_assigns: !!opts[:strict],
      escape: parse_escape_mode(opts[:escape])
    ]

    cli_opts =
      if opts[:allow_elixir_expressions] do
        Keyword.put(cli_opts, :allow_elixir_expressions, true)
      else
        cli_opts
      end

    cli_opts =
      if opts[:transformers] do
        transformers = expand_groups_to_transformers(opts[:transformers])
        Keyword.put(cli_opts, :transformers, transformers)
      else
        cli_opts
      end

    case Stem.Config.find_config(cwd) do
      {:ok, config_path} ->
        case Stem.Config.load_config(config_path) do
          {:ok, config} ->
            Keyword.merge(config, cli_opts)

          {:error, _reason} ->
            cli_opts
        end

      :not_found ->
        cli_opts
    end
  end

  defp expand_groups_to_transformers(groups_string) when is_binary(groups_string) do
    groups_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_module_name/1)
    |> Enum.filter(&(!is_nil(&1)))
    |> Enum.reduce(%{}, fn mod, acc ->
      if function_exported?(mod, :all, 0), do: Map.merge(acc, mod.all()), else: acc
    end)
  end

  defp parse_module_name(module_string) when is_binary(module_string) do
    if String.match?(module_string, ~r/^[A-Z][\w\.]*$/) do
      try do
        String.to_atom("Elixir." <> module_string)
      rescue
        _ -> nil
      end
    else
      nil
    end
  end
end

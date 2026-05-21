# SPDX-License-Identifier: Apache-2.0

defmodule Stem.CLI do
  @moduledoc false

  @usage """
  Usage: stem [options] [DATA_FILE] TEMPLATE

  DATA_FILE must be a JSON file path. If omitted, Stem reads JSON data from standard input.

  TEMPLATE may be a file path or `-` to read from standard input.

  Options:

    -o, --output FILE   Write the rendered output to FILE
    --strict            Warn on missing assigns
    -h, --help          Show this message
    -v, --version       Show the Stem version
  """

  def run(argv) when is_list(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [output: :string, help: :boolean, version: :boolean, strict: :boolean],
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
    render_cli([template_path, nil], opts)
  end

  def render_cli([data_source, template_path], opts) do
    template = read_template!(template_path)
    bindings = read_assigns_file!(data_source)

    output =
      render_template!(template, bindings,
        file: template_path,
        warn_on_missing_assigns: !!opts[:strict]
      )

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
    apply(module, :render, runtime_binding_values(args, bindings))
  end

  defp template_binding_args(template) when is_binary(template) do
    []
    |> maybe_add_binding(template, :assigns, &template_uses_assigns?/1)
    |> maybe_add_binding(template, :helpers, &template_uses_helpers?/1)
  end

  defp maybe_add_binding(args, template, binding, predicate) do
    if predicate.(template) do
      args ++ [binding]
    else
      args
    end
  end

  defp runtime_binding_values(args, bindings) do
    Enum.map(args, fn
      :assigns -> bindings
      :helpers -> []
    end)
  end

  defp template_uses_assigns?(template) when is_binary(template) do
    Regex.scan(~r/\{\{\{?\s*(.*?)\s*\}\}\}?/s, template)
    |> Enum.any?(fn [_, expr] -> expression_uses_assigns?(String.trim(expr)) end)
  end

  defp template_uses_helpers?(template) when is_binary(template) do
    Regex.scan(~r/\{\{\{?\s*(.*?)\s*\}\}\}?/s, template)
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
      token in ["true", "false", "nil", "this", "@index", "@key"] ->
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
          warn_on_missing_assigns: unquote(options[:warn_on_missing_assigns] || false)
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

  defp file_source?(source) when is_binary(source) do
    source != "-" and File.exists?(resolve_path(source))
  end

  defp resolve_path(path) when is_binary(path) do
    base_cwd = System.get_env("EXBAR_CWD") || File.cwd!()
    Path.expand(path, base_cwd)
  end
end

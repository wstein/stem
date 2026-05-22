# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Bytecode.UnsupportedError do
  @moduledoc """
  Raised when a `Stem.AST` construct cannot be lowered to the portable bytecode
  target.

  The bytecode backend (`Stem.Bytecode`) is additive and currently covers the
  text-and-expression core of the language. Constructs outside that scope —
  block helpers (`{{#if}}`, `{{#each}}`, …), regions/yields, and arbitrary
  Elixir expressions — raise this error rather than emit a program that would
  silently diverge from the compiled backend. Render such templates with the
  default backend (`Stem.compile_string/2`).
  """

  defexception [:message]
end

defmodule Stem.Bytecode.Program do
  @moduledoc """
  A compiled, host-independent Stem template.

  A `Program` is the portable artifact produced by `Stem.Bytecode.compile/2`:
  a flat list of structured instructions plus the metadata a non-BEAM consumer
  needs to render it safely. It is a plain data structure (no closures, no
  quoted Elixir), so it can be inspected, cached, and — in a later phase —
  serialized to a wire format such as MessagePack.

  Fields:

    * `:version` — the bytecode format version (`"stem-bc/v1"`).
    * `:capabilities` — the sorted built-in transformer groups the program
      references (e.g. `[:minimum, :strings]`), for auditing and for a native
      consumer to confirm it implements them.
    * `:host_transformers` — referenced transformer names that belong to no
      built-in group. They resolve through the host's `transformers:` binding
      at render time; a non-BEAM core that cannot call host closures must
      reject a program that lists any.
    * `:instructions` — the ordered render instructions.
  """

  @type instruction ::
          {:text, binary()}
          | {:emit, Stem.Bytecode.value_op(), atom()}

  @type t :: %__MODULE__{
          version: binary(),
          capabilities: [atom()],
          host_transformers: [binary()],
          instructions: [instruction()]
        }

  @enforce_keys [:version, :capabilities, :host_transformers, :instructions]
  defstruct [:version, :capabilities, :host_transformers, :instructions]
end

defmodule Stem.Bytecode do
  @moduledoc """
  Portable bytecode backend for Stem templates.

  `Stem.Bytecode` is a second backend that sits beside `Stem.Compiler`: both
  consume the same `Stem.AST`, but where the compiler lowers the tree into
  quoted Elixir, this module lowers it into a `Stem.Bytecode.Program` — a flat,
  inspectable, host-independent instruction list. `Stem.Bytecode.VM` renders a
  program with the same semantics as the compiled backend.

  ## Scope (v1)

  The bytecode target covers the text-and-expression core: literal text, `{{ }}`
  and `{{{ }}}` expressions, assign and dotted-path resolution, parent paths
  (`{{../name}}`), transformer calls, and pipelines. Block helpers, regions,
  yields, block-scoped references (`this`, `@index`, `@key`), and arbitrary
  Elixir expressions are out of scope and raise `Stem.Bytecode.UnsupportedError`
  at compile time — the bytecode never silently diverges from the compiled
  backend.

  ## Transformers and capabilities

  Transformer resolution is identical to the compiled backend: the VM calls
  `Stem.Transformers.invoke/3`, so the secure Minimum-only default and any
  explicitly loaded groups apply unchanged, and custom transformers passed via
  the `transformers:` binding work as usual. The program records which built-in
  groups it needs (`:capabilities`) and any non-group transformer names
  (`:host_transformers`) so a future non-BEAM consumer can verify support.

  ## Example

      iex> ast = elem(Stem.Parser.parse_with_spans("Hello {{name}}"), 1)
      iex> program = Stem.Bytecode.compile(ast)
      iex> program.version
      "stem-bc/v1"
  """

  alias Stem.Bytecode.{Program, UnsupportedError}

  @version "stem-bc/v1"

  @doc "The bytecode format version this module emits."
  @spec version() :: binary()
  def version, do: @version

  @doc """
  Lowers a `Stem.AST` into a `Stem.Bytecode.Program`.

  Accepts the same `:escape` option as `Stem.compile_string/2` (default
  `:html`); the per-expression escape mode is resolved against it at compile
  time so the program is self-contained.

  Raises `Stem.Bytecode.UnsupportedError` for constructs outside the v1 scope.
  """
  @spec compile(Stem.AST.t(), keyword()) :: Program.t()
  def compile(nodes, opts \\ []) when is_list(nodes) and is_list(opts) do
    escape_default = Keyword.get(opts, :escape, :html)
    instructions = Enum.map(nodes, &compile_node(&1, escape_default))

    %Program{
      version: @version,
      capabilities: instructions |> collect_transformer_names() |> capabilities(),
      host_transformers: instructions |> collect_transformer_names() |> host_transformers(),
      instructions: instructions
    }
  end

  @doc """
  Renders a program as a human-readable disassembly, one instruction per line.

  Intended for debugging and golden tests, not for machine consumption.
  """
  @spec disasm(Program.t()) :: binary()
  def disasm(%Program{instructions: instructions, version: version}) do
    header = "; #{version}"
    body = Enum.map(instructions, &disasm_instruction/1)
    Enum.join([header | body], "\n") <> "\n"
  end

  # ── Node lowering ──────────────────────────────────────────────────────────

  defp compile_node({:text, text}, _escape_default), do: {:text, text}

  defp compile_node({:expr, expr_ast, escape_mode, _meta}, escape_default) do
    {:emit, compile_value(expr_ast), resolve_escape(escape_mode, escape_default)}
  end

  defp compile_node({node_kind, _, _, _, _, _}, _escape_default)
       when node_kind in [:each, :with] do
    unsupported_block(node_kind)
  end

  defp compile_node({node_kind, _, _, _, _}, _escape_default) when node_kind in [:if, :unless] do
    unsupported_block(node_kind)
  end

  defp compile_node({:region, _name, _body, _meta}, _escape_default) do
    unsupported_block(:region)
  end

  defp compile_node({:yield, _name, _meta}, _escape_default) do
    raise UnsupportedError,
      message:
        "{{yield}} is not supported by the bytecode target (v1 covers text and expressions); " <>
          "render this template with Stem.compile_string/2"
  end

  defp unsupported_block(kind) do
    raise UnsupportedError,
      message:
        "block helper {{##{kind}}} is not supported by the bytecode target (v1 covers " <>
          "text and expressions); render this template with Stem.compile_string/2"
  end

  # ── Expression lowering ──────────────────────────────────────────────────────

  defp compile_value({:literal, source}), do: {:lit, literal_value!(source)}

  # A bare identifier and a parent path both resolve to a top-level assign, the
  # same way `Stem.Expression.to_source/2` lowers them outside a block.
  defp compile_value({:identifier, name}), do: {:assign, String.to_atom(name)}
  defp compile_value({:parent, name}), do: {:assign, String.to_atom(name)}

  defp compile_value({:path, :implicit, [root | rest]}) do
    {:get, {:assign, String.to_atom(root)}, Enum.map(rest, &String.to_atom/1)}
  end

  defp compile_value({:transformer, name, args}) do
    {positional, keyword} = split_args(args)
    {:call, name, positional, keyword}
  end

  defp compile_value({:pipeline, lhs, stages}) do
    Enum.reduce(stages, compile_value(lhs), fn {:stage, name, args}, acc ->
      {positional, keyword} = split_args(args)
      {:call, name, [acc | positional], keyword}
    end)
  end

  defp compile_value({:special, special}) do
    unsupported_expression(
      "block-scoped reference '#{special_source(special)}' is only valid inside a block helper"
    )
  end

  defp compile_value({:path, :this, _segments}) do
    unsupported_expression("'this' paths are only valid inside a block helper")
  end

  defp compile_value({:elixir, raw}) do
    unsupported_expression("arbitrary Elixir expression #{inspect(String.trim(raw))}")
  end

  defp unsupported_expression(detail) do
    raise UnsupportedError,
      message:
        "#{detail} is not supported by the bytecode target (v1 covers text and expressions); " <>
          "render this template with Stem.compile_string/2"
  end

  defp special_source(:index), do: "@index"
  defp special_source(:key), do: "@key"
  defp special_source(:this), do: "this"

  defp split_args(args) do
    {positional, keyword} =
      Enum.reduce(args, {[], []}, fn
        {:kw, key, value}, {positional, keyword} ->
          {positional, [{String.to_atom(key), compile_value(value)} | keyword]}

        value, {positional, keyword} ->
          {[compile_value(value) | positional], keyword}
      end)

    {Enum.reverse(positional), Enum.reverse(keyword)}
  end

  # Resolve a literal's source to its value via the same parse Elixir uses, then
  # confirm it really is a literal term. Interpolation and any non-literal form
  # (which the parser's permissive literal check can still admit) is rejected so
  # the program never carries an unevaluated AST fragment.
  defp literal_value!(source) do
    quoted = Code.string_to_quoted!(source)

    if literal_term?(quoted) do
      {value, _binding} = Code.eval_quoted(quoted)
      value
    else
      unsupported_expression("non-literal expression #{inspect(source)} in argument position")
    end
  end

  defp literal_term?(term)
       when is_number(term) or is_binary(term) or is_boolean(term) or is_nil(term),
       do: true

  # Charlist literal, e.g. 'abc'.
  defp literal_term?(term) when is_list(term), do: Enum.all?(term, &is_integer/1)
  # Negated numeric literal, e.g. -5.
  defp literal_term?({:-, _meta, [number]}) when is_number(number), do: true
  defp literal_term?(_term), do: false

  # `{{ }}` resolves its escape mode against the configured default at compile
  # time, mirroring `Stem.Compiler`. `{{{ }}}` (`:none`) and any explicit mode
  # pass through unchanged.
  defp resolve_escape(:default, escape_default), do: escape_default
  defp resolve_escape(escape_mode, _escape_default), do: escape_mode

  # ── Capability metadata ──────────────────────────────────────────────────────

  @group_modules %{
    minimum: Stem.Transformers.Minimum,
    strings: Stem.Transformers.Strings,
    collections: Stem.Transformers.Collections,
    predicates: Stem.Transformers.Predicates,
    i18n: Stem.Transformers.I18n
  }

  defp collect_transformer_names(instructions) do
    instructions
    |> Enum.flat_map(&value_ops/1)
    |> Enum.flat_map(fn
      {:call, name, _positional, _keyword} -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp value_ops({:emit, value_op, _escape}), do: walk_value_op(value_op)
  defp value_ops(_instruction), do: []

  defp walk_value_op({:call, _name, positional, keyword} = op) do
    nested =
      Enum.flat_map(positional, &walk_value_op/1) ++
        Enum.flat_map(keyword, fn {_key, value} -> walk_value_op(value) end)

    [op | nested]
  end

  defp walk_value_op({:get, base, _segments}), do: walk_value_op(base)
  defp walk_value_op(op), do: [op]

  defp capabilities(transformer_names) do
    group_membership = group_membership()

    @group_modules
    |> Map.keys()
    |> Enum.filter(fn group ->
      Enum.any?(transformer_names, &(&1 in Map.get(group_membership, group, [])))
    end)
    |> Enum.sort()
  end

  defp host_transformers(transformer_names) do
    known = group_membership() |> Map.values() |> Enum.concat() |> MapSet.new()
    transformer_names |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()
  end

  defp group_membership do
    Map.new(@group_modules, fn {group, module} -> {group, Map.keys(module.all())} end)
  end

  # ── Disassembly ──────────────────────────────────────────────────────────────

  defp disasm_instruction({:text, text}), do: "EMIT_TEXT #{inspect(text)}"

  defp disasm_instruction({:emit, value_op, escape}) do
    "EMIT #{disasm_value(value_op)} ESCAPE=#{escape}"
  end

  defp disasm_value({:lit, value}), do: "LIT #{inspect(value)}"
  defp disasm_value({:assign, name}), do: "ASSIGN #{name}"

  defp disasm_value({:get, base, segments}) do
    "GET #{disasm_value(base)} #{Enum.map_join(segments, ".", &to_string/1)}"
  end

  defp disasm_value({:call, name, positional, keyword}) do
    args =
      Enum.map_join(positional, ", ", &disasm_value/1) <>
        Enum.map_join(keyword, "", fn {key, value} -> ", #{key}=#{disasm_value(value)}" end)

    "CALL #{name}(#{args})"
  end
end

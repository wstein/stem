# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Bytecode.UnsupportedError do
  @moduledoc """
  Raised when a `Stem.AST` construct cannot be lowered to the portable bytecode
  target.

  The bytecode backend (`Stem.Bytecode`) covers the structured Stem language —
  text, expressions, block helpers, regions, and yields — which is the whole
  language. This error is reserved for constructs a future backend has not yet
  lowered; render such templates with the default backend
  (`Stem.compile_string/2`).
  """

  defexception [:message]
end

defmodule Stem.Bytecode.Program do
  @moduledoc """
  A compiled, host-independent Stem template.

  A `Program` is the portable artifact produced by `Stem.Bytecode.compile/2`:
  a list of structured instructions plus the metadata a non-BEAM consumer needs
  to render it safely. It is a plain data structure (no closures, no quoted
  Elixir), so it can be inspected, cached, and — in a later phase — serialized
  to a wire format such as MessagePack.

  Fields:

    * `:version` — the bytecode format version (`"stem-bc/v1"`).
    * `:capabilities` — the sorted built-in transformer groups the program
      references (e.g. `[:minimum, :strings]`), for auditing and for a native
      consumer to confirm it implements them.
    * `:host_transformers` — referenced transformer names that belong to no
      built-in group. They resolve through the host's `transformers:` binding
      at render time; a non-BEAM core that cannot call host closures must
      reject a program that lists any.
    * `:instructions` — the ordered render instructions. Block instructions
      (`:if`, `:each`, `:with`) carry their bodies as nested instruction lists.
  """

  @type t :: %__MODULE__{
          version: binary(),
          capabilities: [atom()],
          host_transformers: [binary()],
          instructions: [Stem.Bytecode.instruction()]
        }

  @enforce_keys [:version, :capabilities, :host_transformers, :instructions]
  defstruct [:version, :capabilities, :host_transformers, :instructions]
end

defmodule Stem.Bytecode do
  @moduledoc """
  Portable bytecode backend for Stem templates.

  `Stem.Bytecode` is a second backend that sits beside `Stem.Compiler`: both
  consume the same `Stem.AST`, but where the compiler lowers the tree into
  quoted Elixir, this module lowers it into a `Stem.Bytecode.Program` — a
  structured, inspectable, host-independent instruction list. `Stem.Bytecode.VM`
  renders a program with the same semantics as the compiled backend.

  ## Scope

  The bytecode target covers the structured Stem language: literal text, `{{ }}`
  and `{{{ }}}` expressions, assign/dotted-path/parent-path resolution, block
  helpers (`{{#if}}`, `{{#unless}}`, `{{#each}}`, `{{#with}}`) with block
  parameters and `{{else}}`, block-scoped references (`this`, `@index`, `@key`),
  regions, and `{{yield}}` — the whole structured language. A top-level `this`
  reference (which the compiled backend rejects as unbound) raises
  `Stem.Bytecode.UnsupportedError`.

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

  @typedoc "An expression evaluation plan within an instruction."
  @type value_op ::
          {:lit, term()}
          | {:assign, atom()}
          | {:assigns}
          | {:local, atom()}
          | {:this}
          | {:index}
          | {:index1}
          | {:key}
          | {:get, value_op(), [atom()]}
          | {:call, binary(), [value_op()], [{atom(), value_op()}]}

  @type instruction ::
          {:text, binary()}
          | {:emit, value_op(), atom()}
          | {:if, value_op(), [instruction()], [instruction()]}
          | {:each, value_op(), [atom()], [instruction()], [instruction()]}
          | {:with, value_op(), [atom()], [instruction()], [instruction()]}
          | {:scope, value_op(), [{atom(), value_op()}], [instruction()]}

  @doc "The bytecode format version this module emits."
  @spec version() :: binary()
  def version, do: @version

  @doc """
  Lowers a `Stem.AST` into a `Stem.Bytecode.Program`.

  Accepts the same `:escape` option as `Stem.compile_string/2` (default
  `:html`); the per-expression escape mode is resolved against it at compile
  time so the program is self-contained.

  Raises `Stem.Bytecode.UnsupportedError` for constructs outside the bytecode
  scope (arbitrary Elixir expressions, top-level `this`).
  """
  @spec compile(Stem.AST.t(), keyword()) :: Program.t()
  def compile(nodes, opts \\ []) when is_list(nodes) and is_list(opts) do
    escape_default = Keyword.get(opts, :escape, :html)
    scope = %{in_each: false, has_this: false, locals: MapSet.new()}
    instructions = compile_nodes(nodes, scope, %{}, [], escape_default)
    names = transformer_names(instructions)

    %Program{
      version: @version,
      capabilities: capabilities(names),
      host_transformers: host_transformers(names),
      instructions: instructions
    }
  end

  @doc """
  Renders a program as a human-readable disassembly, one instruction per line.

  Intended for debugging and golden tests, not for machine consumption.
  """
  @spec disasm(Program.t()) :: binary()
  def disasm(%Program{instructions: instructions, version: version}) do
    lines = ["; #{version}" | Enum.flat_map(instructions, &disasm_instruction(&1, 0))]
    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Serializes a program to a JSON-encodable map — the portable wire form.

  Instructions and expression ops become tagged maps (`%{"t" => kind, ...}`) so a
  non-BEAM consumer (e.g. the Rust/WASM core) can deserialize and render them.
  Atoms (assign names, escape modes, block params, path segments) become strings,
  since assign resolution is by name across the boundary.
  """
  @spec to_wire(Program.t()) :: map()
  def to_wire(%Program{version: version, instructions: instructions}) do
    %{"version" => version, "instructions" => Enum.map(instructions, &wire_instruction/1)}
  end

  defp wire_instruction({:text, text}), do: %{"t" => "text", "text" => text}

  defp wire_instruction({:emit, value_op, escape}) do
    %{"t" => "emit", "value" => wire_value(value_op), "escape" => Atom.to_string(escape)}
  end

  defp wire_instruction({:if, cond_op, then_branch, else_branch}) do
    %{
      "t" => "if",
      "cond" => wire_value(cond_op),
      "then" => Enum.map(then_branch, &wire_instruction/1),
      "else" => Enum.map(else_branch, &wire_instruction/1)
    }
  end

  defp wire_instruction({block, value_op, params, body, else_branch})
       when block in [:each, :with] do
    %{
      "t" => Atom.to_string(block),
      "subject" => wire_value(value_op),
      "params" => Enum.map(params, &Atom.to_string/1),
      "body" => Enum.map(body, &wire_instruction/1),
      "else" => Enum.map(else_branch, &wire_instruction/1)
    }
  end

  defp wire_instruction({:scope, base, hash, body}) do
    %{
      "t" => "scope",
      "base" => wire_value(base),
      "hash" => Map.new(hash, fn {key, value} -> {Atom.to_string(key), wire_value(value)} end),
      "body" => Enum.map(body, &wire_instruction/1)
    }
  end

  defp wire_value({:lit, value}), do: %{"t" => "lit", "value" => value}
  defp wire_value({:assign, name}), do: %{"t" => "assign", "name" => Atom.to_string(name)}
  defp wire_value({:assigns}), do: %{"t" => "assigns"}
  defp wire_value({:local, name}), do: %{"t" => "local", "name" => Atom.to_string(name)}
  defp wire_value({:this}), do: %{"t" => "this"}
  defp wire_value({:index}), do: %{"t" => "index"}
  defp wire_value({:index1}), do: %{"t" => "index1"}
  defp wire_value({:key}), do: %{"t" => "key"}

  defp wire_value({:get, base, segments}) do
    %{"t" => "get", "base" => wire_value(base), "segments" => Enum.map(segments, &to_string/1)}
  end

  defp wire_value({:call, name, positional, keyword}) do
    %{
      "t" => "call",
      "name" => name,
      "args" => Enum.map(positional, &wire_value/1),
      "kwargs" =>
        Map.new(keyword, fn {key, value} -> {Atom.to_string(key), wire_value(value)} end)
    }
  end

  # ── Node lowering ────────────────────────────────────────────────────────────

  defp compile_nodes(nodes, scope, regions, region_stack, escape_default) do
    {node_regions, visible} = extract_regions(nodes)
    regions = Map.merge(regions, node_regions)
    Enum.flat_map(visible, &compile_node(&1, scope, regions, region_stack, escape_default))
  end

  defp compile_node({:text, text}, _scope, _regions, _stack, _escape_default), do: [{:text, text}]

  defp compile_node(
         {:expr, expr_ast, escape_mode, _meta},
         scope,
         _regions,
         _stack,
         escape_default
       ) do
    [{:emit, compile_value(expr_ast, scope), resolve_escape(escape_mode, escape_default)}]
  end

  defp compile_node({:if, expr, body, else_body, _meta}, scope, regions, stack, escape_default) do
    [
      {:if, compile_value(expr, scope),
       compile_nodes(body, scope, regions, stack, escape_default),
       compile_nodes(else_body, scope, regions, stack, escape_default)}
    ]
  end

  # `unless` is `if` with the branches swapped — the same lowering the compiled
  # backend uses — so the VM needs only one conditional instruction.
  defp compile_node(
         {:unless, expr, body, else_body, _meta},
         scope,
         regions,
         stack,
         escape_default
       ) do
    [
      {:if, compile_value(expr, scope),
       compile_nodes(else_body, scope, regions, stack, escape_default),
       compile_nodes(body, scope, regions, stack, escape_default)}
    ]
  end

  defp compile_node(
         {:each, expr, params, body, else_body, _meta},
         scope,
         regions,
         stack,
         escape_default
       ) do
    body_scope = %{
      scope
      | in_each: true,
        has_this: true,
        locals: MapSet.union(scope.locals, MapSet.new(params))
    }

    [
      {:each, compile_value(expr, scope), Enum.map(params, &String.to_atom/1),
       compile_nodes(body, body_scope, regions, stack, escape_default),
       compile_nodes(else_body, %{scope | in_each: false}, regions, stack, escape_default)}
    ]
  end

  defp compile_node(
         {:with, expr, params, body, else_body, _meta},
         scope,
         regions,
         stack,
         escape_default
       ) do
    body_scope = %{scope | has_this: true, locals: MapSet.union(scope.locals, MapSet.new(params))}

    [
      {:with, compile_value(expr, scope), Enum.map(params, &String.to_atom/1),
       compile_nodes(body, body_scope, regions, stack, escape_default),
       compile_nodes(else_body, scope, regions, stack, escape_default)}
    ]
  end

  # A partial invoked with arguments renders in a fresh, non-each scope: the
  # context argument (or the caller's current data context when absent) becomes
  # the assign scope and hash arguments merge on top. The body lowers under a
  # root scope so bare names resolve against the `:scope` instruction's rebound
  # assigns at render time, mirroring the compiled backend's closure rebinding.
  defp compile_node(
         {:partial_scope, context_ast, hash_kw, body, _meta},
         scope,
         regions,
         stack,
         escape_default
       ) do
    base =
      cond do
        context_ast != nil -> compile_value(context_ast, scope)
        scope.in_each -> {:this}
        true -> {:assigns}
      end

    hash = Enum.map(hash_kw, fn {key, value} -> {key, compile_value(value, scope)} end)
    body_scope = %{in_each: false, has_this: false, locals: MapSet.new()}

    [{:scope, base, hash, compile_nodes(body, body_scope, regions, stack, escape_default)}]
  end

  # Region nodes never reach compile_node: extract_regions/1 removes them from
  # every node list before its visible nodes are compiled. A yield inlines the
  # region's compiled instructions at the yield site, with a recursion guard,
  # mirroring the compiled backend.
  defp compile_node({:yield, name, _meta}, scope, regions, stack, escape_default) do
    if name in stack do
      raise UnsupportedError, message: "recursive region yield detected for '#{name}'"
    end

    regions
    |> Map.get(name, [])
    |> compile_nodes(scope, regions, [name | stack], escape_default)
  end

  defp extract_regions(nodes) do
    {regions, visible} =
      Enum.reduce(nodes, {%{}, []}, fn
        {:region, name, body, _meta}, {regions, visible} ->
          {Map.put(regions, name, body), visible}

        node, {regions, visible} ->
          {regions, [node | visible]}
      end)

    {regions, Enum.reverse(visible)}
  end

  # ── Expression lowering ──────────────────────────────────────────────────────

  defp compile_value({:literal, source}, _scope), do: {:lit, literal_value!(source)}

  defp compile_value({:identifier, name}, scope) do
    cond do
      MapSet.member?(scope.locals, name) -> {:local, String.to_atom(name)}
      scope.in_each -> {:get, {:this}, [String.to_atom(name)]}
      true -> {:assign, String.to_atom(name)}
    end
  end

  # A parent path always resolves to a top-level assign, like `to_source/2`.
  defp compile_value({:parent, name}, _scope), do: {:assign, String.to_atom(name)}

  # `@index`/`@index1` resolve to the loop index inside an each (zero- and
  # one-based), and to the like-named top-level assigns outside one, mirroring
  # `Stem.Expression.to_source/2`.
  defp compile_value({:special, :index}, %{in_each: true}), do: {:index}
  defp compile_value({:special, :index}, _scope), do: {:assign, :index0}
  defp compile_value({:special, :index1}, %{in_each: true}), do: {:index1}
  defp compile_value({:special, :index1}, _scope), do: {:assign, :index1}
  defp compile_value({:special, :key}, %{in_each: true}), do: {:key}
  defp compile_value({:special, :key}, _scope), do: {:assign, :key}

  defp compile_value({:special, :this}, %{has_this: true}), do: {:this}

  defp compile_value({:special, :this}, _scope) do
    unsupported("'this' is only bound inside a block helper")
  end

  defp compile_value({:path, :this, segments}, %{has_this: true}) do
    {:get, {:this}, Enum.map(segments, &String.to_atom/1)}
  end

  defp compile_value({:path, :this, _segments}, _scope) do
    unsupported("'this' paths are only valid inside a block helper")
  end

  defp compile_value({:path, :implicit, [root | rest]}, scope) do
    rest_atoms = Enum.map(rest, &String.to_atom/1)
    root_atom = String.to_atom(root)

    cond do
      MapSet.member?(scope.locals, root) -> {:get, {:local, root_atom}, rest_atoms}
      scope.in_each -> {:get, {:this}, [root_atom | rest_atoms]}
      true -> {:get, {:assign, root_atom}, rest_atoms}
    end
  end

  defp compile_value({:transformer, name, args}, scope) do
    {positional, keyword} = split_args(args, scope)
    {:call, name, positional, keyword}
  end

  defp compile_value({:pipeline, lhs, stages}, scope) do
    Enum.reduce(stages, compile_value(lhs, scope), fn {:stage, name, args}, acc ->
      {positional, keyword} = split_args(args, scope)
      {:call, name, [acc | positional], keyword}
    end)
  end

  defp unsupported(detail) do
    raise UnsupportedError,
      message:
        "#{detail} is not supported by the bytecode target; " <>
          "render this template with Stem.compile_string/2"
  end

  defp split_args(args, scope) do
    {positional, keyword} =
      Enum.reduce(args, {[], []}, fn
        {:kw, key, value}, {positional, keyword} ->
          {positional, [{String.to_atom(key), compile_value(value, scope)} | keyword]}

        value, {positional, keyword} ->
          {[compile_value(value, scope) | positional], keyword}
      end)

    {Enum.reverse(positional), Enum.reverse(keyword)}
  end

  # `null` is Stem's canonical nil literal (the parser stores both `nil` and
  # `null` as the source "null"); map it to nil, the same value the compiled
  # backend produces via to_source/2.
  defp literal_value!("null"), do: nil

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
      unsupported("non-literal expression #{inspect(source)} in argument position")
    end
  end

  defp literal_term?(term)
       when is_number(term) or is_binary(term) or is_boolean(term) or is_nil(term),
       do: true

  defp literal_term?({:-, _meta, [number]}) when is_number(number), do: true
  defp literal_term?(_term), do: false

  defp resolve_escape(:default, escape_default), do: escape_default
  defp resolve_escape(escape_mode, _escape_default), do: escape_mode

  # ── Capability metadata ──────────────────────────────────────────────────────

  defp transformer_names(instructions) do
    instructions |> Enum.flat_map(&instruction_calls/1) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  end

  defp instruction_calls({:emit, value_op, _escape}), do: value_calls(value_op)

  defp instruction_calls({:if, cond_op, then_branch, else_branch}) do
    value_calls(cond_op) ++ branch_calls(then_branch) ++ branch_calls(else_branch)
  end

  defp instruction_calls({block, value_op, _params, body, else_branch})
       when block in [:each, :with] do
    value_calls(value_op) ++ branch_calls(body) ++ branch_calls(else_branch)
  end

  defp instruction_calls({:scope, base, hash, body}) do
    value_calls(base) ++
      Enum.flat_map(hash, fn {_key, value} -> value_calls(value) end) ++ branch_calls(body)
  end

  defp instruction_calls({:text, _text}), do: []

  defp branch_calls(instructions), do: Enum.flat_map(instructions, &instruction_calls/1)

  defp value_calls({:call, _name, positional, keyword} = op) do
    nested =
      Enum.flat_map(positional, &value_calls/1) ++
        Enum.flat_map(keyword, fn {_key, value} -> value_calls(value) end)

    [op | nested]
  end

  defp value_calls({:get, base, _segments}), do: value_calls(base)
  defp value_calls(_op), do: []

  defp capabilities(transformer_names) do
    membership = group_membership()

    membership
    |> Map.keys()
    |> Enum.filter(fn group ->
      Enum.any?(transformer_names, &(&1 in Map.get(membership, group, [])))
    end)
    |> Enum.sort()
  end

  defp host_transformers(transformer_names) do
    known = group_membership() |> Map.values() |> Enum.concat() |> MapSet.new()
    transformer_names |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()
  end

  defp group_membership do
    Map.new(Stem.Transformers.groups(), fn {group, module} -> {group, Map.keys(module.all())} end)
  end

  # ── Disassembly ──────────────────────────────────────────────────────────────

  defp disasm_instruction({:text, text}, depth),
    do: [indent(depth) <> "EMIT_TEXT #{inspect(text)}"]

  defp disasm_instruction({:emit, value_op, escape}, depth) do
    [indent(depth) <> "EMIT #{disasm_value(value_op)} ESCAPE=#{escape}"]
  end

  defp disasm_instruction({:if, cond_op, then_branch, else_branch}, depth) do
    [indent(depth) <> "IF #{disasm_value(cond_op)}"] ++
      disasm_branch("THEN", then_branch, depth) ++ disasm_branch("ELSE", else_branch, depth)
  end

  defp disasm_instruction({block, value_op, params, body, else_branch}, depth)
       when block in [:each, :with] do
    head =
      indent(depth) <>
        "#{block |> Atom.to_string() |> String.upcase()} #{disasm_value(value_op)}" <>
        params_suffix(params)

    [head] ++ disasm_branch("DO", body, depth) ++ disasm_branch("ELSE", else_branch, depth)
  end

  defp disasm_instruction({:scope, base, hash, body}, depth) do
    head = indent(depth) <> "SCOPE #{disasm_value(base)}" <> hash_suffix(hash)
    [head] ++ disasm_branch("DO", body, depth)
  end

  defp disasm_branch(_label, [], _depth), do: []

  defp disasm_branch(label, instructions, depth) do
    [indent(depth + 1) <> label] ++
      Enum.flat_map(instructions, &disasm_instruction(&1, depth + 2))
  end

  defp params_suffix([]), do: ""
  defp params_suffix(params), do: " AS |#{Enum.join(params, " ")}|"

  defp hash_suffix([]), do: ""

  defp hash_suffix(hash) do
    " {" <>
      Enum.map_join(hash, ", ", fn {key, value} -> "#{key}=#{disasm_value(value)}" end) <> "}"
  end

  defp indent(depth), do: String.duplicate("  ", depth)

  defp disasm_value({:lit, value}), do: "LIT #{inspect(value)}"
  defp disasm_value({:assign, name}), do: "ASSIGN #{name}"
  defp disasm_value({:assigns}), do: "ASSIGNS"
  defp disasm_value({:local, name}), do: "LOCAL #{name}"
  defp disasm_value({:this}), do: "THIS"
  defp disasm_value({:index}), do: "INDEX0"
  defp disasm_value({:index1}), do: "INDEX1"
  defp disasm_value({:key}), do: "KEY"

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

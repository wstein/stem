# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ConformanceTest do
  # async: false because transformer dispatch reads the process-wide registry
  # (a :persistent_term) other suites mutate; the setup clears it for determinism.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Stem.Conformance

  @vectors_path "conformance/vectors.json"

  setup do
    Stem.Transformers.clear()
    :ok
  end

  defp load_vectors do
    @vectors_path
    |> File.read!()
    |> JSON.decode!()
    |> Enum.map(&Conformance.vector_from_json/1)
  end

  test "the checked-in vector file is up to date (run: mix stem.conformance)" do
    assert File.read!(@vectors_path) == Conformance.to_json(),
           "conformance/vectors.json is stale; regenerate it with `mix stem.conformance`"
  end

  test "every checked-in vector renders identically on both backends" do
    vectors = load_vectors()
    assert length(vectors) == length(Conformance.corpus())

    for vector <- vectors do
      assert Conformance.render_with_compiler(vector) == vector.expected,
             "compiled backend mismatch for vector #{inspect(vector.name)}"

      assert Conformance.render_with_vm(vector) == vector.expected,
             "bytecode VM mismatch for vector #{inspect(vector.name)}"
    end
  end

  property "the VM matches the compiled backend for random string pipelines" do
    stages = StreamData.member_of(~w(trim upcase downcase capitalize reverse))

    check all(
            value <- StreamData.string(:printable, max_length: 16),
            pipeline <- StreamData.list_of(stages, max_length: 4)
          ) do
      vector = %{
        template: "{{#{Enum.join(["s" | pipeline], " |> ")}}}",
        data: %{s: value},
        transformers: [:strings],
        escape: :html
      }

      assert Conformance.render_with_vm(vector) == Conformance.render_with_compiler(vector)
    end
  end

  test "mix stem.conformance writes the corpus to the given path" do
    path =
      Path.join(System.tmp_dir!(), "stem_conformance_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm_rf!(path) end)

    # capture_io keeps the task's "Wrote N vectors" notice out of test output.
    capture_io(fn -> Mix.Tasks.Stem.Conformance.run(["--output", path]) end)

    loaded = path |> File.read!() |> JSON.decode!()
    assert length(loaded) == length(Conformance.corpus())
  end
end

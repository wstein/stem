# SPDX-License-Identifier: Apache-2.0

defmodule Stem.HTML do
  @moduledoc false

  @spec escape_to_string(term()) :: String.t()
  def escape_to_string(value) do
    value
    |> String.Chars.to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end

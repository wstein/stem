# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Helpers.Sanitize do
  @moduledoc false

  @spec html(term()) :: String.t()
  def html(value) do
    value
    |> String.Chars.to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end

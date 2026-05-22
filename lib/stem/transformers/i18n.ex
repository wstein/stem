# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.I18n do
  @moduledoc """
  Internationalization transformers: translate message ids from inside templates.

  Because `Stem.DSL.defdictionary/2` is locked to pure literals, it cannot host
  locale-aware lookups. This capability group fills that gap with a `t`
  transformer that resolves a translation at render time:

      {{t "greeting"}}
      {{t "hello_name" name=user.name}}
      {{user.title |> t}}

  ## Configuration

  Translation is delegated to a host-provided **translator** so Stem never
  hard-depends on any i18n library. Configure one of:

      # a 3-arity function (locale, msgid, bindings) -> binary
      config :stem, translator: &MyApp.I18n.translate/3

      # or a {module, function} tuple called with the same three arguments
      config :stem, translator: {MyApp.I18n, :translate}

  The optional default locale (used when a render supplies none) is:

      config :stem, default_locale: "en"

  ## Integrating Gettext

  Wire Elixir's Gettext into the translator function — the host owns the
  Gettext backend, Stem stays dependency-free:

      config :stem,
        translator: fn locale, msgid, bindings ->
          Gettext.with_locale(MyApp.Gettext, locale, fn ->
            Gettext.gettext(MyApp.Gettext, msgid, bindings)
          end)
        end

  ## Locale resolution

  The locale comes from the `:locale` assign when present, otherwise from
  `config :stem, :default_locale` (defaulting to `"en"`):

      Stem.Unsafe.eval_string("{{t \\"greeting\\"}}",
        assigns: [locale: "de"],
        transformers: Stem.Transformers.I18n.all())

  ## Security

  Translation only looks up a message id and interpolates named bindings, so it
  adds no data-manipulation gadgets. It is safe to load alongside
  `Stem.Transformers.Standard`; it is kept separate only because it requires
  host configuration.
  """

  @type transformer :: ([term()], map() -> term())

  @doc "Return the i18n transformers as a map keyed by name."
  @spec all() :: %{String.t() => transformer()}
  def all do
    %{
      "t" => &translate/2,
      "translate" => &translate/2
    }
  end

  defp translate([msgid], ctx), do: do_translate(msgid, %{}, ctx)
  defp translate([msgid, bindings], ctx), do: do_translate(msgid, bindings, ctx)

  defp translate(args, _ctx) do
    raise ArgumentError, "t expects 1 or 2 arguments, got: #{length(args)}"
  end

  defp do_translate(msgid, bindings, ctx) do
    locale = resolve_locale(ctx)
    apply_translator(translator!(), locale, to_string(msgid), normalize_bindings(bindings))
  end

  defp translator! do
    case Application.get_env(:stem, :translator) do
      nil ->
        raise ArgumentError,
              "Stem i18n: no translator configured. Set " <>
                "`config :stem, translator: &Mod.fun/3` (or `{Mod, :fun}`) where the " <>
                "function receives (locale, msgid, bindings). See Stem.Transformers.I18n " <>
                "for a Gettext example."

      translator ->
        translator
    end
  end

  defp apply_translator(fun, locale, msgid, bindings) when is_function(fun, 3) do
    to_string(fun.(locale, msgid, bindings))
  end

  defp apply_translator({mod, fun}, locale, msgid, bindings)
       when is_atom(mod) and is_atom(fun) do
    to_string(apply(mod, fun, [locale, msgid, bindings]))
  end

  defp apply_translator(other, _locale, _msgid, _bindings) do
    raise ArgumentError,
          "Stem i18n: translator must be a 3-arity function or {module, function}, " <>
            "got: #{inspect(other)}"
  end

  defp resolve_locale(%{assigns: assigns}) when is_map(assigns) do
    case Map.get(assigns, :locale) || Map.get(assigns, "locale") do
      nil -> default_locale()
      locale -> to_string(locale)
    end
  end

  defp resolve_locale(_ctx), do: default_locale()

  defp default_locale do
    :stem |> Application.get_env(:default_locale, "en") |> to_string()
  end

  defp normalize_bindings(bindings) when is_map(bindings), do: bindings
  defp normalize_bindings(bindings) when is_list(bindings), do: Map.new(bindings)
  defp normalize_bindings(_other), do: %{}
end

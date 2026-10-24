defmodule Normandy.LLM.ClientInspect do
  @moduledoc false
  # The Inspect implementation of Normandy's client structs: `api_key` is left out, and the
  # `options` that can carry credentials (`:req_options`, whose `auth:` and headers go to
  # Req, and `:headers`) are shown as "**redacted**". A `base_url` (the struct field, or
  # `options.base_url`) is shown as scheme, host, port and path only, as
  # Normandy.Resilience.CircuitBreaker keys it: its userinfo, query and fragment can carry
  # a token. A crash report or a log line that inspects a config then shows no credential.

  import Inspect.Algebra

  @redacted_options [:req_options, :headers]

  @spec inspect(struct(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(%mod{} = client, opts) do
    fields = [
      base_url: url(client.base_url),
      options: redact(client.options),
      finch: client.finch
    ]

    container_doc("#" <> Kernel.inspect(mod) <> "<", fields, ">", opts, &field/2,
      separator: ",",
      break: :strict
    )
  end

  defp field({key, value}, opts), do: concat([Atom.to_string(key), ": ", to_doc(value, opts)])

  defp redact(options) when is_map(options) do
    Map.new(options, fn
      {key, _value} when key in @redacted_options -> {key, "**redacted**"}
      {:base_url, value} -> {:base_url, url(value)}
      entry -> entry
    end)
  end

  defp redact(options), do: options

  # CircuitBreaker's sanitize_url/1 rule (scheme, host, port, path). A URL with no scheme
  # or host is not shown at all.
  defp url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        port = if port in [nil, URI.default_port(scheme)], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port}#{path}"

      _no_scheme_or_host ->
        "**redacted**"
    end
  end

  defp url(other), do: other
end

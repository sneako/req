defmodule Req do
  require Logger

  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @doc """
  Makes a GET request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  def get!(uri, options \\ []) do
    request!(:get, uri, options)
  end

  @doc """
  Makes a POST request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  def post!(uri, body, options \\ []) do
    options = Keyword.put(options, :body, body)
    request!(:post, uri, options)
  end

  @doc """
  Makes an HTTP request.

  ## Options

    * `:header` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

  The options are passed down to `add_default_steps/1`, see its documentation for more
  information.
  """
  @doc api: :high_level
  def request(method, uri, options \\ []) do
    method
    |> build(uri, options)
    |> add_default_steps(options)
    |> run()
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/3` for more information.
  """
  @doc api: :high_level
  def request!(method, uri, options \\ []) do
    method
    |> build(uri, options)
    |> add_default_steps(options)
    |> run!()
  end

  ## Low-level API

  @doc """
  Builds a request pipeline.

  ## Options

    * `:header` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

  """
  @doc api: :low_level
  def build(method, uri, options \\ []) do
    %Req.Request{
      method: method,
      uri: URI.parse(uri),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, "")
    }
  end

  @doc """
  Adds steps that should be reasonable defaults for most users.

  Request steps:

    * `normalize_headers/1`

    * `default_headers/1`

    * `encode/1`

    * [`&auth(&1, options[:auth])`](`auth/2`) (if `options[:auth]` is set)

    * [`&params(&1, options[:params])`](`params/2`) (if `options[:params]` is set)

  Response steps:

    * [`&retry(&1, &2, options[:retry])`](`retry/3`) (if `options[:retry]` is set and is a
      keywords list or an atom `true`)

    * `follow_redirects/2`

    * `decompress/2`

    * `decode/2`

  Error steps:

    * [`&retry(&1, &2, options[:retry])`](`retry/3`) (if `options[:retry]` is set and is a
      keywords list or an atom `true`)

  """
  @doc api: :low_level
  def add_default_steps(request, options \\ []) do
    request_steps =
      [
        &normalize_headers/1,
        &default_headers/1,
        &encode/1
      ] ++
        maybe_step(options[:auth], &auth(&1, options[:auth])) ++
        maybe_step(options[:params], &params(&1, options[:params]))

    retry = options[:retry]
    retry = if retry == true, do: [], else: retry

    response_steps =
      maybe_step(retry, &retry(&1, &2, retry)) ++
        [
          &follow_redirects/2,
          &decompress/2,
          &decode/2
        ]

    error_steps = maybe_step(retry, &retry(&1, &2, retry))

    request
    |> add_request_steps(request_steps)
    |> add_response_steps(response_steps)
    |> add_error_steps(error_steps)
  end

  defp maybe_step(nil, _step), do: []
  defp maybe_step(false, _step), do: []
  defp maybe_step(_, step), do: [step]

  @doc """
  Adds request steps.
  """
  @doc api: :low_level
  def add_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Adds response steps.
  """
  @doc api: :low_level
  def add_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Adds error steps.
  """
  @doc api: :low_level
  def add_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  @doc api: :low_level
  def run(request) do
    case run_request(request) do
      %Req.Request{} = request ->
        finch_request = Finch.build(request.method, request.uri, request.headers, request.body)

        case Finch.request(finch_request, Req.Finch) do
          {:ok, response} ->
            run_response(request, response)

          {:error, exception} ->
            run_error(request, exception)
        end

      result ->
        result
    end
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  @doc api: :low_level
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_request(request) do
    steps = request.request_steps

    Enum.reduce_while(steps, request, fn step, acc ->
      case step.(acc) do
        %Req.Request{} = request ->
          {:cont, request}

        {%Req.Request{halted: true}, response_or_exception} ->
          {:halt, result(response_or_exception)}

        {request, %{status: _, headers: _, body: _} = response} ->
          {:halt, run_response(request, response)}

        {request, %{__exception__: true} = exception} ->
          {:halt, run_error(request, exception)}
      end
    end)
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case step.(request, response) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{status: _, headers: _, body: _} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case step.(request, exception) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %{status: _, headers: _, body: _} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  defp result(%{status: _, headers: _, body: _} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end

  ## Request steps

  @doc """
  Sets request authentication.

  `auth` can be one of:

    * `{username, password}` - uses Basic HTTP authentication

  ## Examples

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"bad", "bad"}).status
      401
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"foo", "bar"}).status
      200

  """
  @doc api: :request
  def auth(request, auth)

  def auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    value = Base.encode64("#{username}:#{password}")
    put_new_header(request, "authorization", "Basic #{value}")
  end

  @user_agent "req/#{Mix.Project.config()[:version]}"

  @doc """
  Adds common request headers.

  Currently the following headers are added:

    * `"user-agent"` - `#{inspect(@user_agent)}`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc api: :request
  def default_headers(request) do
    request
    |> put_new_header("user-agent", @user_agent)
    |> put_new_header("accept-encoding", "gzip")
  end

  @doc """
  Normalizes request headers.

  Turns atom header names into strings, e.g.: `:user_agent` becomes `"user-agent"`. Non-atom names
  are returned as is.

  ## Examples

      iex> Req.get!("https://httpbin.org/user-agent", headers: [user_agent: "my_agent"]).body
      %{"user-agent" => "my_agent"}

  """
  @doc api: :request
  def normalize_headers(request) do
    headers =
      for {name, value} <- request.headers do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    %{request | headers: headers}
  end

  @doc """
  Encodes the request body based on its shape.

  If body is of the following shape, it's encoded and its `content-type` set
  accordingly. Otherwise it's unchanged.

  | Shape           | Encoder                     | Content-Type                          |
  | --------------- | --------------------------- | ------------------------------------- |
  | `{:form, data}` | `URI.encode_query/1`        | `"application/x-www-form-urlencoded"` |
  | `{:json, data}` | `Jason.encode_to_iodata!/1` | `"application/json"`                  |

  ## Examples

      iex> Req.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
      %{"comments" => "hello!"}

  """
  @doc api: :request
  def encode(request) do
    case request.body do
      {:form, data} ->
        request
        |> Map.put(:body, URI.encode_query(data))
        |> put_new_header("content-type", "application/x-www-form-urlencoded")

      {:json, data} ->
        request
        |> Map.put(:body, Jason.encode_to_iodata!(data))
        |> put_new_header("content-type", "application/json")

      _other ->
        request
    end
  end

  @doc """
  Adds params to request query string.

  ## Examples

      iex> Req.get!("https://httpbin.org/anything/query", params: [x: "1", y: "2"]).body["args"]
      %{"x" => "1", "y" => "2"}

  """
  @doc api: :request
  def params(request, params) do
    encoded = URI.encode_query(params)

    update_in(request.uri.query, fn
      nil -> encoded
      query -> query <> "&" <> encoded
    end)
  end

  ## Response steps

  @doc """
  Decompresses the response body based on the `content-encoding` header.
  """
  @doc api: :response
  def decompress(request, response) do
    compression_algorithms = get_content_encoding_header(response.headers)
    {request, update_in(response.body, &decompress_body(&1, compression_algorithms))}
  end

  defp decompress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm(&1, &2))
  end

  defp decompress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"] do
    :zlib.gunzip(body)
  end

  defp decompress_with_algorithm("deflate", body) do
    :zlib.unzip(body)
  end

  defp decompress_with_algorithm("identity", body) do
    body
  end

  defp decompress_with_algorithm(algorithm, _body) do
    raise("unsupported decompression algorithm: #{inspect(algorithm)}")
  end

  @doc """
  Decodes the response body based on the `content-type` header.

  Supported formats:

  | Format  | Decoder                                                          |
  | ------- | ---------------------------------------------------------------- |
  | JSON    | `Jason.decode!/1`                                                |
  | gzip    | `:zlib.gunzip/1`                                                 |
  | csv     | `NimbleCSV.RFC4180.parse_string/2` (if `NimbleCSV` is installed) |

  ## Examples

      iex> Req.get!("https://hex.pm/api/packages/finch").body["meta"]
      %{
        "description" => "An HTTP client focused on performance.",
        "licenses" => ["MIT"],
        "links" => %{"GitHub" => "https://github.com/keathley/finch"},
        ...
      }

  """
  @doc api: :response
  def decode(request, response) do
    case List.keyfind(response.headers, "content-type", 0) do
      {_, content_type} ->
        extensions = content_type |> normalize_content_type() |> MIME.extensions()

        case extensions do
          ["json" | _] ->
            {request, update_in(response.body, &Jason.decode!/1)}

          ["gz" | _] ->
            {request, update_in(response.body, &:zlib.gunzip/1)}

          ["csv" | _] ->
            if Code.ensure_loaded?(NimbleCSV) do
              options = [skip_headers: false]
              {request, update_in(response.body, &NimbleCSV.RFC4180.parse_string(&1, options))}
            else
              {request, response}
            end

          _ ->
            {request, response}
        end

      _ ->
        {request, response}
    end
  end

  defp normalize_content_type("application/x-gzip"), do: "application/gzip"
  defp normalize_content_type(other), do: other

  @doc """
  Follows redirects.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  Req.follow_redirects/2: Redirecting to https://api.github.com/
      200

  """
  @doc api: :response
  def follow_redirects(request, response)

  def follow_redirects(request, %{status: status} = response) when status in 301..302 do
    {_, location} = List.keyfind(response.headers, "location", 0)
    Logger.debug(["Req.follow_redirects/2: Redirecting to ", location])

    request =
      if String.starts_with?(location, "/") do
        uri = URI.parse(location)
        update_in(request.uri, &%{&1 | path: uri.path, query: uri.query})
      else
        uri = URI.parse(location)
        put_in(request.uri, uri)
      end

    {_, result} = run(request)
    {Req.Request.halt(request), result}
  end

  def follow_redirects(request, response) do
    {request, response}
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  ## Options

    * `:delay` - sleep this number of milliseconds before making another attempt, defaults
      to `2000`

    * `:max_attempts` - maximum number of attempts, defaults to `2`

  ## Examples

  With default options:

      iex> Req.get!("https://httpbin.org/status/500,200", retry: true)
      # 19:02:08.463 [error] Req.retry/3: Got response with status 500. Will retry in 2000ms, 2 attempts left
      # 19:02:10.710 [error] Req.retry/3: Got response with status 500. Will retry in 2000ms, 1 attempt left
      %Finch.Response{
        body: "",
        headers: [
          {"date", "Thu, 01 Apr 2021 16:39:02 GMT"},
          ...
        ],
        status: 200
      }

  With custom options:

      iex> Req.request(:get, "http://localhost:9999", retry: [delay: 100, max_attempts: 1])
      # 19:04:13.163 [error] Req.retry/3: Got exception. Will retry in 100ms, 1 attempt left
      # 19:04:13.164 [error] ** (Mint.TransportError) connection refused
      {:error, %Mint.TransportError{reason: :econnrefused}}

  """
  @doc api: :error
  def retry(request, response_or_exception, options \\ [])

  def retry(request, %{status: status} = response, _options) when status < 500 do
    {request, response}
  end

  def retry(request, response_or_exception, options) when is_list(options) do
    delay = Keyword.get(options, :delay, 2000)
    max_attempts = Keyword.get(options, :max_attempts, 2)
    attempt = Req.Request.get_private(request, :retry_attempt, 0)

    if attempt < max_attempts do
      log_retry(response_or_exception, attempt, max_attempts, delay)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :retry_attempt, attempt + 1)

      {_, result} = run(request)
      {Req.Request.halt(request), result}
    else
      {request, response_or_exception}
    end
  end

  defp log_retry(response_or_exception, attempt, max_attempts, delay) do
    attempts_left =
      case max_attempts - attempt do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["Will retry in #{delay}ms, ", attempts_left, " left"]

    case response_or_exception do
      %{__exception__: true} = exception ->
        Logger.error([
          "Req.retry/3: Got exception. ",
          message
        ])

        Logger.error([
          "** (#{inspect(exception.__struct__)}) ",
          Exception.message(exception)
        ])

      response ->
        Logger.error(["Req.retry/3: Got response with status #{response.status}. ", message])
    end
  end

  ## Utilities

  defp put_new_header(struct, name, value) do
    if Enum.any?(struct.headers, fn {key, _} -> String.downcase(key) == name end) do
      struct
    else
      update_in(struct.headers, &[{name, value} | &1])
    end
  end

  defp get_content_encoding_header(headers) do
    if value = get_header(headers, "content-encoding") do
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Stream.map(&String.trim/1)
      |> Enum.reverse()
    else
      []
    end
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
  end
end

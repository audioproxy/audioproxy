defmodule AudioProxy.RawHttp do
  @moduledoc """
  A `:gen_tcp` HTTP/1.1 client, for the tests that have to see the wire.

  Chunked framing is the thing under test in half of them — a terminating
  `0\\r\\n\\r\\n` or its absence is how a completed render is told apart from one
  torn down mid-stream — and an HTTP client that hands back a reassembled body
  hides exactly that. Timing is the other: `first_byte_at` is what shows an
  encoder streaming rather than buffering.

  No dependency, either. `:httpc` would cover the simple cases, but not these
  two, and a second client for the rest would only be a second thing to keep
  honest.
  """

  @type response :: %{
          head: String.t(),
          body: binary(),
          first_byte_at: integer(),
          closed_at: integer()
        }

  @doc """
  Opens a connection and sends `GET path`.

  `Connection: close` is sent by default, so a completed response ends in a
  closed socket the way every failure case does and one reader serves all of
  them. Pass `close: false` for the keep-alive cases, which need the connection
  — and the process behind it — to survive the first response.

  `headers: [{"if-none-match", tag}]` adds request headers, for the conditional
  cases. They are written verbatim: a test asserting on how the server parses a
  header must be able to send one this module does not understand.
  """
  @spec get(String.t(), :inet.port_number(), keyword()) :: :gen_tcp.socket()
  def get(path, port, opts \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    :ok = send_get(socket, path, opts)

    socket
  end

  @doc """
  Sends `GET path` down a socket that is already open.

  For the keep-alive cases: a second request on the connection the first one
  left behind.
  """
  @spec send_get(:gen_tcp.socket(), String.t(), keyword()) :: :ok
  def send_get(socket, path, opts \\ []) do
    close = if Keyword.get(opts, :close, true), do: "Connection: close\r\n", else: ""

    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map_join(fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nHost: localhost\r\n#{close}#{headers}\r\n")
  end

  @doc """
  Reads exactly one `Content-Length`-framed response, leaving the socket open.

  `read/2` cannot serve the keep-alive tests: it reads to close, so the first
  response would swallow the connection. Only the error responses need this,
  and those all carry a `Content-Length`.
  """
  @spec read_one(:gen_tcp.socket(), timeout()) :: %{head: String.t(), body: binary()}
  def read_one(socket, deadline \\ 5_000), do: read_one(socket, deadline, "")

  defp read_one(socket, deadline, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length = content_length(head)

        if byte_size(body) >= length do
          %{head: String.downcase(head), body: binary_slice(body, 0, length)}
        else
          read_one(socket, deadline, acc <> recv!(socket, deadline))
        end

      [_partial] ->
        read_one(socket, deadline, acc <> recv!(socket, deadline))
    end
  end

  defp content_length(head) do
    head
    |> String.downcase()
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        ["content-length", value] -> value |> String.trim() |> String.to_integer()
        _other -> nil
      end
    end)
  end

  defp recv!(socket, deadline) do
    case :gen_tcp.recv(socket, 0, deadline) do
      {:ok, data} -> data
      {:error, reason} -> raise "socket error: #{inspect(reason)}"
    end
  end

  @doc """
  Reads until the server closes, returning the response and when it arrived.

  The head is downcased — HTTP field names are case-insensitive — and the body
  is left exactly as it came off the socket, framing included. Times are
  `System.monotonic_time(:millisecond)`.
  """
  @spec read(:gen_tcp.socket(), timeout()) :: response()
  def read(socket, deadline \\ 5_000), do: read(socket, deadline, "", nil)

  defp read(socket, deadline, acc, first_byte_at) do
    case :gen_tcp.recv(socket, 0, deadline) do
      {:ok, data} ->
        read(socket, deadline, acc <> data, first_byte_at || now())

      {:error, :closed} ->
        [head, body] = String.split(acc, "\r\n\r\n", parts: 2)

        %{
          head: String.downcase(head),
          body: body,
          first_byte_at: first_byte_at,
          closed_at: now()
        }

      {:error, reason} ->
        raise "socket error: #{inspect(reason)}"
    end
  end

  @doc """
  Reassembles a chunked body.

  Enough of RFC 9112 §7.1 for what this server sends: no trailers, no chunk
  extensions. A truncated stream yields the bytes that did arrive, which is the
  point in the mid-stream-failure case.
  """
  @spec dechunk(binary()) :: binary()
  def dechunk(body), do: dechunk(body, "")

  defp dechunk(body, acc) do
    with [size_line, rest] <- String.split(body, "\r\n", parts: 2),
         {size, _} when size > 0 <- Integer.parse(size_line, 16),
         true <- byte_size(rest) >= size + 2 do
      dechunk(binary_slice(rest, (size + 2)..-1//1), acc <> binary_slice(rest, 0, size))
    else
      _done_or_truncated -> acc
    end
  end

  @doc "True when the body ends in the terminating chunk."
  @spec complete?(binary()) :: boolean()
  def complete?(body), do: String.ends_with?(body, "0\r\n\r\n")

  defp now, do: System.monotonic_time(:millisecond)
end

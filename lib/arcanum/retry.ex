defmodule Arcanum.Retry do
  @moduledoc """
  Shared retry logic for Arcanum adapters.

  Provides exponential backoff and a generic retry wrapper
  that adapters use for transient HTTP errors.
  """

  @max_attempts 3
  @max_backoff_ms :timer.seconds(30)

  @doc """
  Returns the maximum number of retry attempts.
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Sleeps for an exponentially increasing duration.

  Formula: `min(2s * 2^(attempt-1), 30s)`
  """
  @spec backoff(pos_integer()) :: :ok
  def backoff(attempt) do
    delay = min(:timer.seconds(2) * Integer.pow(2, attempt - 1), @max_backoff_ms)
    Process.sleep(delay)
  end

  @doc """
  Executes `fun` with retry on specified status codes.

  `fun` must return the standard `{:ok, response} | {:error, reason}` tuple.
  The `opts` keyword list supports:

  - `:retriable_statuses` — list of HTTP status codes to retry on (required)
  - `:on_success` — `fn response -> result` for status 200 (required)
  - `:on_error` — `fn status, body -> result` for non-retriable errors (required)
  - `:max_attempts` — override default max attempts (optional)
  """
  @spec with_retry(keyword(), (-> {:ok, map()} | {:error, term()})) :: term()
  def with_retry(opts, fun) do
    max = Keyword.get(opts, :max_attempts, @max_attempts)
    do_retry(opts, fun, 1, max)
  end

  defp do_retry(opts, fun, attempt, max) do
    retriable = Keyword.fetch!(opts, :retriable_statuses)
    on_success = Keyword.fetch!(opts, :on_success)
    on_error = Keyword.fetch!(opts, :on_error)

    case fun.() do
      {:ok, %{status: 200} = response} ->
        on_success.(response)

      {:ok, %{status: status, body: body}} ->
        handle_non_200(opts, fun, attempt, max, retriable, on_error, status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_non_200(opts, fun, attempt, max, retriable, on_error, status, body) do
    if Enum.member?(retriable, status) do
      maybe_retry(opts, fun, attempt, max)
    else
      on_error.(status, body)
    end
  end

  defp maybe_retry(_opts, _fun, attempt, max) when attempt >= max do
    {:error, {:api_error, :max_retries_exceeded}}
  end

  defp maybe_retry(opts, fun, attempt, max) do
    backoff(attempt)
    do_retry(opts, fun, attempt + 1, max)
  end
end

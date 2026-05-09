defmodule Arcanum.Auth.Copilot do
  @moduledoc """
  GitHub Copilot OAuth device code authentication.

  Implements the OAuth 2.0 Device Authorization Grant (RFC 8628) to obtain
  a GitHub access token that works directly against `api.githubcopilot.com`.

  ## Flow

      1. `start_device_flow/0`  → returns {verification_uri, user_code, device_code}
      2. User visits verification_uri and enters user_code
      3. `poll_for_token/1`     → polls GitHub until user authorizes
      4. The access_token is used directly as Bearer token against Copilot API

  No secondary token exchange is needed — the GitHub OAuth token works as-is.
  """

  require Logger

  @device_code_url "https://github.com/login/device/code"
  @access_token_url "https://github.com/login/oauth/access_token"
  @scope "read:user"
  @user_agent "Arcanum/0.1"
  @request_timeout 15_000
  @max_poll_attempts 60

  @type device_flow :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          interval: pos_integer()
        }

  @doc """
  Starts the OAuth device code flow.

  Returns a map with `device_code`, `user_code`, `verification_uri`, and `interval`.
  The caller should display `user_code` and `verification_uri` to the user,
  then call `poll_for_token/1` with the returned map.

  Accepts an optional `domain` for GitHub Enterprise (e.g. `"company.ghe.com"`).
  """
  @spec start_device_flow(String.t() | nil) :: {:ok, device_flow()} | {:error, term()}
  def start_device_flow(enterprise_domain \\ nil) do
    url = device_code_url(enterprise_domain)

    body =
      URI.encode_query(%{
        "client_id" => client_id(),
        "scope" => @scope
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    case http_client().post(url, body: body, headers: headers, receive_timeout: @request_timeout) do
      {:ok, %{status: 200, body: body}} ->
        parse_device_code_response(decode_body(body))

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_code_failed, status, body}}

      {:error, reason} ->
        {:error, {:device_code_error, reason}}
    end
  end

  @doc """
  Polls GitHub for the access token after the user has entered the device code.

  Blocks the calling process, polling every `interval + 3` seconds (per RFC 8628).
  Returns `{:ok, access_token}` when the user authorizes, or `{:error, reason}` on failure.

  Accepts an optional `enterprise_domain` for GitHub Enterprise.
  """
  @spec poll_for_token(device_flow(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def poll_for_token(device_flow, enterprise_domain \\ nil) do
    url = access_token_url(enterprise_domain)
    # Add safety margin per RFC 8628
    interval_ms = (device_flow.interval + 3) * 1_000
    do_poll(url, device_flow.device_code, interval_ms, 1)
  end

  @doc """
  Makes a single poll request to GitHub's OAuth token endpoint.

  Returns:
  - `{:ok, access_token}` — user authorized, token obtained
  - `{:pending, :authorization_pending}` — user hasn't authorized yet
  - `{:pending, :slow_down}` — polling too fast, caller should increase interval
  - `{:error, reason}` — terminal failure (expired, denied, network error)

  Intended for external polling loops (e.g. Oban jobs) that manage their
  own scheduling instead of blocking a process.
  """
  @spec poll_once(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:pending, atom()} | {:error, term()}
  def poll_once(device_code, enterprise_domain \\ nil) do
    url = access_token_url(enterprise_domain)

    body =
      URI.encode_query(%{
        "client_id" => client_id(),
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    case http_client().post(url, body: body, headers: headers, receive_timeout: @request_timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        handle_single_poll(decode_body(resp_body))

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:poll_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:poll_error, reason}}
    end
  end

  @doc """
  Returns the headers required for Copilot API requests.
  """
  @spec copilot_headers(String.t()) :: [{String.t(), String.t()}]
  def copilot_headers(access_token) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"user-agent", @user_agent},
      {"openai-intent", "conversation-edits"},
      {"accept", "application/json"}
    ]
  end

  @doc """
  Returns the Copilot API base URL.
  """
  @spec base_url(String.t() | nil) :: String.t()
  def base_url(nil), do: "https://api.githubcopilot.com"
  def base_url(domain), do: "https://copilot-api.#{domain}"

  # -------------------------------------------------------------------
  # Polling
  # -------------------------------------------------------------------

  defp do_poll(_url, _device_code, _interval_ms, attempt) when attempt > @max_poll_attempts do
    {:error, :polling_timeout}
  end

  defp do_poll(url, device_code, interval_ms, attempt) do
    body =
      URI.encode_query(%{
        "client_id" => client_id(),
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    case http_client().post(url, body: body, headers: headers, receive_timeout: @request_timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        handle_poll_response(decode_body(resp_body), url, device_code, interval_ms, attempt)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:poll_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:poll_error, reason}}
    end
  end

  defp handle_poll_response(%{"access_token" => token}, _url, _dc, _int, _att)
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp handle_poll_response(%{"error" => "authorization_pending"}, url, dc, int, att) do
    Process.sleep(int)
    do_poll(url, dc, int, att + 1)
  end

  defp handle_poll_response(%{"error" => "slow_down"}, url, dc, int, att) do
    # RFC 8628: add 5 seconds on slow_down
    new_interval = int + 5_000
    Process.sleep(new_interval)
    do_poll(url, dc, new_interval, att + 1)
  end

  defp handle_poll_response(%{"error" => "expired_token"}, _url, _dc, _int, _att) do
    {:error, :device_code_expired}
  end

  defp handle_poll_response(%{"error" => "access_denied"}, _url, _dc, _int, _att) do
    {:error, :access_denied}
  end

  defp handle_poll_response(%{"error" => error}, _url, _dc, _int, _att) do
    {:error, {:oauth_error, error}}
  end

  defp handle_poll_response(body, _url, _dc, _int, _att) do
    {:error, {:unexpected_poll_response, body}}
  end

  # Single-poll response handlers (for poll_once/2)

  defp handle_single_poll(%{"access_token" => token})
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp handle_single_poll(%{"error" => "authorization_pending"}) do
    {:pending, :authorization_pending}
  end

  defp handle_single_poll(%{"error" => "slow_down"}) do
    {:pending, :slow_down}
  end

  defp handle_single_poll(%{"error" => "expired_token"}) do
    {:error, :device_code_expired}
  end

  defp handle_single_poll(%{"error" => "access_denied"}) do
    {:error, :access_denied}
  end

  defp handle_single_poll(%{"error" => error}) do
    {:error, {:oauth_error, error}}
  end

  defp handle_single_poll(body) do
    {:error, {:unexpected_poll_response, body}}
  end

  # -------------------------------------------------------------------
  # URL helpers
  # -------------------------------------------------------------------

  defp device_code_url(nil), do: @device_code_url
  defp device_code_url(domain), do: "https://#{domain}/login/device/code"

  defp access_token_url(nil), do: @access_token_url
  defp access_token_url(domain), do: "https://#{domain}/login/oauth/access_token"

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{"raw" => body}
    end
  end

  defp decode_body(body), do: %{"raw" => inspect(body)}

  defp parse_device_code_response(
         %{
           "device_code" => device_code,
           "user_code" => user_code,
           "verification_uri" => verification_uri,
           "interval" => interval
         } = _body
       ) do
    {:ok,
     %{
       device_code: device_code,
       user_code: user_code,
       verification_uri: verification_uri,
       interval: interval
     }}
  end

  defp parse_device_code_response(body) do
    {:error, {:unexpected_device_code_response, body}}
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end

  defp client_id do
    Application.fetch_env!(:arcanum, :copilot_client_id)
  end
end

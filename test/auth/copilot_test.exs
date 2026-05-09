defmodule Arcanum.Auth.CopilotTest do
  use ExUnit.Case, async: false

  alias Arcanum.Auth.Copilot

  setup do
    Application.put_env(:arcanum, :copilot_client_id, "test_client_id")
    Application.delete_env(:arcanum, :http_client)

    on_exit(fn ->
      Application.delete_env(:arcanum, :copilot_client_id)
    end)

    :ok
  end

  describe "start_device_flow/0" do
    test "returns device code info on success" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.DeviceCodeStub)

      assert {:ok, flow} = Copilot.start_device_flow()
      assert flow.device_code == "dc_test_123"
      assert flow.user_code == "ABCD-1234"
      assert flow.verification_uri == "https://github.com/login/device"
      assert flow.interval == 5
    end

    test "returns error on failure" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.ErrorStub)
      assert {:error, {:device_code_failed, 500, _}} = Copilot.start_device_flow()
    end

    test "supports enterprise domain" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.EnterpriseStub)
      assert {:ok, _flow} = Copilot.start_device_flow("company.ghe.com")
    end
  end

  describe "poll_for_token/2" do
    test "returns access token when authorized" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.AuthorizedStub)

      flow = %{
        device_code: "dc_test",
        user_code: "CODE",
        verification_uri: "https://github.com/login/device",
        interval: 0
      }

      assert {:ok, "ghu_access_token_123"} = Copilot.poll_for_token(flow)
    end

    test "returns error on access denied" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.DeniedStub)

      flow = %{
        device_code: "dc_test",
        user_code: "CODE",
        verification_uri: "https://github.com/login/device",
        interval: 0
      }

      assert {:error, :access_denied} = Copilot.poll_for_token(flow)
    end

    test "returns error on expired token" do
      Application.put_env(:arcanum, :http_client, Arcanum.Auth.CopilotTest.ExpiredStub)

      flow = %{
        device_code: "dc_test",
        user_code: "CODE",
        verification_uri: "https://github.com/login/device",
        interval: 0
      }

      assert {:error, :device_code_expired} = Copilot.poll_for_token(flow)
    end
  end

  describe "copilot_headers/1" do
    test "returns required headers with bearer token" do
      headers = Copilot.copilot_headers("test_token")

      assert {"authorization", "Bearer test_token"} in headers
      assert {"openai-intent", "conversation-edits"} in headers
    end
  end

  describe "base_url/1" do
    test "returns default URL for nil domain" do
      assert "https://api.githubcopilot.com" = Copilot.base_url(nil)
    end

    test "returns enterprise URL for custom domain" do
      assert "https://copilot-api.company.ghe.com" = Copilot.base_url("company.ghe.com")
    end
  end

  # -------------------------------------------------------------------
  # Stub modules
  # -------------------------------------------------------------------

  defmodule DeviceCodeStub do
    def post(_url, _opts) do
      {:ok,
       %{
         status: 200,
         body: %{
           "device_code" => "dc_test_123",
           "user_code" => "ABCD-1234",
           "verification_uri" => "https://github.com/login/device",
           "interval" => 5
         }
       }}
    end
  end

  defmodule ErrorStub do
    def post(_url, _opts), do: {:ok, %{status: 500, body: "Internal Server Error"}}
  end

  defmodule EnterpriseStub do
    def post(url, _opts) do
      if String.contains?(url, "company.ghe.com") do
        {:ok,
         %{
           status: 200,
           body: %{
             "device_code" => "dc_ent",
             "user_code" => "ENT-CODE",
             "verification_uri" => "https://company.ghe.com/login/device",
             "interval" => 5
           }
         }}
      else
        {:ok, %{status: 404, body: "Not Found"}}
      end
    end
  end

  defmodule AuthorizedStub do
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"access_token" => "ghu_access_token_123"}}}
    end
  end

  defmodule DeniedStub do
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"error" => "access_denied"}}}
    end
  end

  defmodule ExpiredStub do
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"error" => "expired_token"}}}
    end
  end
end

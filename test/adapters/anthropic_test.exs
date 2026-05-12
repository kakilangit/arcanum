defmodule Arcanum.Adapters.AnthropicTest do
  @moduledoc """
  Unit tests for the Anthropic adapter.

  Uses a mock HTTP client to verify request serialization and response parsing
  without hitting the real API.
  """

  use ExUnit.Case, async: false

  alias Arcanum.Adapters.Anthropic, as: AnthropicAdapter
  alias Arcanum.{Intent, ModelProfile}

  @provider %{
    base_url: "https://api.anthropic.com",
    api_key: "sk-ant-test",
    kind: "anthropic",
    api_format: :anthropic
  }

  @profile ModelProfile.capable()

  setup do
    Application.put_env(:arcanum, :http_client, __MODULE__.MockHTTP)
    on_exit(fn -> Application.delete_env(:arcanum, :http_client) end)
    :ok
  end

  # -------------------------------------------------------------------
  # System prompt extraction
  # -------------------------------------------------------------------

  describe "system prompt extraction" do
    test "extracts atom :system role to top-level system param" do
      intent = %Intent{
        messages: [
          %{role: :system, content: [%{type: :text, text: "You are helpful."}]},
          %{role: :user, content: [%{type: :text, text: "Hi"}]}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      assert body[:system] == "You are helpful."
      # Messages should NOT contain the system message
      assert Enum.all?(body[:messages], fn msg -> msg.role != "system" end)
    end

    test "extracts string system role" do
      intent = %Intent{
        messages: [
          %{role: "system", content: [%{type: :text, text: "Be concise."}]},
          %{role: :user, content: [%{type: :text, text: "Hi"}]}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      assert body[:system] == "Be concise."
    end

    test "merges multiple system messages at front" do
      intent = %Intent{
        messages: [
          %{role: :system, content: [%{type: :text, text: "First instruction."}]},
          %{role: :system, content: [%{type: :text, text: "Second instruction."}]},
          %{role: :user, content: [%{type: :text, text: "Hi"}]}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      assert body[:system] == "First instruction.\n\nSecond instruction."
    end

    test "no system param when no system messages" do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Hi"}]}],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      refute Map.has_key?(body, :system)
    end
  end

  # -------------------------------------------------------------------
  # Message formatting
  # -------------------------------------------------------------------

  describe "message formatting" do
    test "converts atom roles to strings" do
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "Hello"}]},
          %{role: :assistant, content: [%{type: :text, text: "Hi there"}]},
          %{role: :user, content: [%{type: :text, text: "How are you?"}]}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      roles = Enum.map(body[:messages], & &1.role)
      assert roles == ["user", "assistant", "user"]
    end

    test "formats tool results as user role with tool_result content blocks" do
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "What's the weather?"}]},
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "tc_1", function: %{name: "get_weather", arguments: ~s({"city":"Tokyo"})}}
            ]
          },
          %{role: :tool, content: [%{type: :text, text: "Tokyo: 22°C, sunny"}], tool_call_id: "tc_1"},
          %{role: :user, content: [%{type: :text, text: "Thanks!"}]}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}

      # Tool result (user) and "Thanks!" (user) get merged due to alternating role requirement
      tool_result_msg = Enum.at(body[:messages], 2)
      assert tool_result_msg.role == "user"
      assert is_list(tool_result_msg.content)

      # Should have tool_result block + text block merged
      assert length(tool_result_msg.content) == 2

      tool_block = Enum.find(tool_result_msg.content, &(&1.type == "tool_result"))
      assert tool_block.tool_use_id == "tc_1"
      assert tool_block.content == "Tokyo: 22°C, sunny"
    end

    test "formats assistant tool_calls as tool_use content blocks" do
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "Weather?"}]},
          %{
            role: :assistant,
            content: [%{type: :text, text: "Let me check."}],
            tool_calls: [
              %{id: "tc_1", function: %{name: "get_weather", arguments: ~s({"city":"Berlin"})}}
            ]
          },
          %{role: :tool, content: [%{type: :text, text: "Berlin: 15°C"}], tool_call_id: "tc_1"}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}

      assistant_msg = Enum.at(body[:messages], 1)
      assert assistant_msg.role == "assistant"
      assert is_list(assistant_msg.content)

      # Should have text block + tool_use block
      types = Enum.map(assistant_msg.content, & &1.type)
      assert "text" in types
      assert "tool_use" in types

      tool_use = Enum.find(assistant_msg.content, &(&1.type == "tool_use"))
      assert tool_use.id == "tc_1"
      assert tool_use.name == "get_weather"
      assert tool_use.input == %{"city" => "Berlin"}
    end

    test "merges adjacent same-role messages" do
      # When tool results follow each other, they're all "user" role
      # and must be merged for Anthropic's alternating role requirement
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "Check weather in two cities"}]},
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "tc_1", function: %{name: "get_weather", arguments: ~s({"city":"Tokyo"})}},
              %{id: "tc_2", function: %{name: "get_weather", arguments: ~s({"city":"Berlin"})}}
            ]
          },
          %{role: :tool, content: [%{type: :text, text: "Tokyo: 22°C"}], tool_call_id: "tc_1"},
          %{role: :tool, content: [%{type: :text, text: "Berlin: 15°C"}], tool_call_id: "tc_2"}
        ],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}

      # The two tool results (both "user" role) should be merged into one message
      roles = Enum.map(body[:messages], & &1.role)
      assert roles == ["user", "assistant", "user"]

      # The merged user message should have both tool_result blocks
      merged = List.last(body[:messages])
      assert length(merged.content) == 2
      assert Enum.all?(merged.content, &(&1.type == "tool_result"))
    end
  end

  # -------------------------------------------------------------------
  # Tool definition conversion
  # -------------------------------------------------------------------

  describe "tool definitions" do
    test "converts OpenAI function format to Anthropic input_schema format" do
      tool = %{
        type: "function",
        function: %{
          name: "get_weather",
          description: "Get weather",
          parameters: %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      }

      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Weather?"}]}],
        model: "claude-sonnet-4-20250514",
        tools: [tool]
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:request, body}
      [anthropic_tool] = body[:tools]
      assert anthropic_tool.name == "get_weather"
      assert anthropic_tool.description == "Get weather"
      assert anthropic_tool.input_schema["type"] == "object"
    end
  end

  # -------------------------------------------------------------------
  # Response parsing
  # -------------------------------------------------------------------

  describe "response parsing" do
    test "parses text response" do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Hi"}]}],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert resp.content == "Hello!"
      assert resp.usage.prompt_tokens == 10
      assert resp.usage.completion_tokens == 5
      assert resp.finish_reason == "stop"
    end

    test "parses tool_use response" do
      Process.put(:mock_response, :tool_use)

      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Weather?"}]}],
        model: "claude-sonnet-4-20250514",
        tools: [
          %{
            type: "function",
            function: %{name: "get_weather", description: "Get weather", parameters: %{}}
          }
        ]
      }

      {:ok, resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert resp.finish_reason == "tool_calls"
      assert [call] = resp.tool_calls
      assert call.function.name == "get_weather"
      args = Jason.decode!(call.function.arguments)
      assert args["city"] == "Tokyo"
    end
  end

  # -------------------------------------------------------------------
  # Headers
  # -------------------------------------------------------------------

  describe "headers" do
    test "includes x-api-key and anthropic-version" do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Hi"}]}],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(@provider, intent, @profile)

      assert_received {:headers, headers}
      assert {"x-api-key", "sk-ant-test"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "omits x-api-key when nil" do
      provider = %{@provider | api_key: nil}

      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Hi"}]}],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(provider, intent, @profile)

      assert_received {:headers, headers}
      refute Enum.any?(headers, fn {k, _v} -> k == "x-api-key" end)
    end
  end

  # -------------------------------------------------------------------
  # URL construction
  # -------------------------------------------------------------------

  describe "base_url" do
    test "strips trailing /v1 before appending path" do
      provider = %{@provider | base_url: "https://api.anthropic.com/v1"}

      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Hi"}]}],
        model: "claude-sonnet-4-20250514"
      }

      {:ok, _resp} =
        AnthropicAdapter.chat(provider, intent, @profile)

      assert_received {:url, url}
      assert url == "https://api.anthropic.com/v1/messages"
      # Not doubled: /v1/v1/messages
    end
  end

  # -------------------------------------------------------------------
  # Mock HTTP client
  # -------------------------------------------------------------------

  defmodule MockHTTP do
    def post(url, opts) do
      body = Keyword.get(opts, :json)
      headers = Keyword.get(opts, :headers, [])

      send(self(), {:request, body})
      send(self(), {:headers, headers})
      send(self(), {:url, url})

      response_body =
        case Process.get(:mock_response) do
          :tool_use ->
            %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_123",
                  "name" => "get_weather",
                  "input" => %{"city" => "Tokyo"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            }

          _ ->
            %{
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            }
        end

      {:ok, %{status: 200, body: response_body}}
    end

    def get(_url, _opts) do
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "claude-sonnet-4-20250514"},
             %{"id" => "claude-haiku-4-20250514"}
           ]
         }
       }}
    end
  end
end

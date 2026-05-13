defmodule Arcanum.ModelProfile.ResolverTest do
  use ExUnit.Case, async: false

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.{Registry, Resolver}

  defmodule StubHttp do
    @moduledoc false
    def get(_url, _opts) do
      {:ok,
       %{
         status: 200,
         body: %{
           "openai" => %{
             "models" => %{
               "gpt-4o" => %{
                 "id" => "gpt-4o",
                 "tool_call" => true,
                 "reasoning" => false,
                 "limit" => %{"context" => 128_000}
               }
             }
           },
           "zai" => %{
             "models" => %{
               "glm-4.7" => %{
                 "id" => "glm-4.7",
                 "tool_call" => true,
                 "reasoning" => true,
                 "interleaved" => %{"field" => "reasoning_content"},
                 "limit" => %{"context" => 204_800}
               },
               "glm-4.5-flash" => %{
                 "id" => "glm-4.5-flash",
                 "tool_call" => true,
                 "reasoning" => false,
                 "limit" => %{"context" => 131_072}
               }
             }
           },
           "deepseek" => %{
             "models" => %{
               "deepseek-chat" => %{
                 "id" => "deepseek-chat",
                 "tool_call" => true,
                 "reasoning" => true,
                 "limit" => %{"context" => 64_000}
               }
             }
           },
           "github-copilot" => %{
             "models" => %{
               "claude-opus-4.6" => %{
                 "id" => "claude-opus-4.6",
                 "tool_call" => true,
                 "reasoning" => true,
                 "limit" => %{"context" => 144_000}
               }
             }
           }
         }
       }}
    end
  end

  setup do
    Application.put_env(:arcanum, :http_client, StubHttp)

    # Clean up any leftover ETS table / GenServer from a previous test
    if Process.whereis(Registry), do: GenServer.stop(Registry, :normal, 1_000)

    try do
      :ets.delete(:model_profile_registry)
    rescue
      ArgumentError -> :ok
    end

    {:ok, pid} =
      Registry.start_link(providers: ["openai", "zai", "deepseek", "github-copilot"])

    :sys.get_state(pid)
    Process.sleep(50)

    on_exit(fn ->
      Application.delete_env(:arcanum, :http_client)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)
  end

  describe "resolve/2" do
    test "returns registry profile for known provider and model" do
      profile = Resolver.resolve("openai", "gpt-4o")
      assert profile.supports_tools == true
      assert profile.supports_system_role == true
      assert profile.max_context == 128_000
    end

    test "returns registry profile for deepseek" do
      profile = Resolver.resolve("deepseek", "deepseek-chat")
      assert profile.reasoning_field == :reasoning_content
      assert profile.supports_tools == true
    end

    test "returns registry profile for github-copilot" do
      profile = Resolver.resolve("github-copilot", "claude-opus-4.6")
      assert profile.supports_tools == true
      assert profile.max_context == 144_000
    end

    test "applies overlay for zai thinking models" do
      profile = Resolver.resolve("zai", "glm-4.7")
      assert profile.thinking_param == %{"type" => "enabled"}
      assert profile.preserve_reasoning == true
      assert profile.reasoning_field == :reasoning_content
    end

    test "no overlay for non-thinking zai models" do
      profile = Resolver.resolve("zai", "glm-4.5-flash")
      assert profile.thinking_param == nil
      assert profile.preserve_reasoning == false
      assert profile.reasoning_field == nil
    end

    test "returns provider default for local providers" do
      profile = Resolver.resolve("ollama", "llama3")
      assert profile.supports_tools == false
      assert profile.tool_call_format == :xml_text
      assert profile.max_context == 32_768
    end

    test "returns global default for unknown provider" do
      profile = Resolver.resolve("unknown", "some-model")
      assert %ModelProfile{} = profile
      assert profile.supports_system_role == false
      assert profile.supports_tools == false
    end

    test "returns provider default for uncached model" do
      # openai provider is cached but this specific model isn't
      profile = Resolver.resolve("ollama", "uncached-model")
      assert profile.supports_tools == false
    end
  end

  describe "resolve/3 with user overrides" do
    test "user overrides take highest priority" do
      profile =
        Resolver.resolve("openai", "gpt-4o", %{supports_vision: true, max_context: 64_000})

      assert profile.supports_vision == true
      assert profile.max_context == 64_000
      # Original fields preserved
      assert profile.supports_tools == true
    end

    test "nil overrides returns normal profile" do
      profile = Resolver.resolve("openai", "gpt-4o", nil)
      assert profile.max_context == 128_000
    end

    test "empty map overrides returns normal profile" do
      profile = Resolver.resolve("openai", "gpt-4o", %{})
      assert profile.max_context == 128_000
    end

    test "overrides invalid keys are ignored" do
      profile = Resolver.resolve("openai", "gpt-4o", %{bogus_field: true})
      assert %ModelProfile{} = profile
    end

    test "overrides applied on top of overlay" do
      profile = Resolver.resolve("zai", "glm-4.7", %{supports_vision: true})
      # Overlay still applied
      assert profile.thinking_param == %{"type" => "enabled"}
      assert profile.preserve_reasoning == true
      # User override applied
      assert profile.supports_vision == true
    end

    test "user override can override overlay values" do
      profile = Resolver.resolve("zai", "glm-4.7", %{preserve_reasoning: false})
      assert profile.preserve_reasoning == false
      # Other overlay fields untouched
      assert profile.thinking_param == %{"type" => "enabled"}
    end
  end
end

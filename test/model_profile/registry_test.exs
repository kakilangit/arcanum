defmodule Arcanum.ModelProfile.RegistryTest do
  use ExUnit.Case, async: false

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.Registry

  @table :model_profile_registry

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
               },
               "o3" => %{
                 "id" => "o3",
                 "tool_call" => true,
                 "reasoning" => true,
                 "limit" => %{"context" => 200_000}
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

  defmodule FailHttp do
    @moduledoc false
    def get(_url, _opts), do: {:error, :timeout}
  end

  setup do
    Application.put_env(:arcanum, :http_client, StubHttp)

    # Clean up any leftover named process / ETS table
    if Process.whereis(Registry), do: GenServer.stop(Registry, :normal, 1_000)

    try do
      :ets.delete(@table)
    rescue
      ArgumentError -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:arcanum, :http_client)
      if Process.whereis(Registry), do: GenServer.stop(Registry, :normal, 1_000)

      try do
        :ets.delete(@table)
      rescue
        ArgumentError -> :ok
      end
    end)
  end

  describe "start_link + refresh" do
    test "caches models from configured providers" do
      {:ok, pid} =
        Registry.start_link(providers: ["openai", "zai", "github-copilot"])

      # Give async refresh time to complete
      :sys.get_state(pid)
      Process.sleep(50)

      assert %ModelProfile{supports_tools: true, max_context: 128_000} =
               Registry.lookup("openai", "gpt-4o")

      assert %ModelProfile{reasoning_field: :reasoning_content, max_context: 204_800} =
               Registry.lookup("zai", "glm-4.7")

      assert %ModelProfile{supports_tools: true, max_context: 144_000} =
               Registry.lookup("github-copilot", "claude-opus-4.6")

      GenServer.stop(pid)
    end

    test "returns nil for uncached models" do
      {:ok, pid} = Registry.start_link(providers: ["openai"])
      :sys.get_state(pid)
      Process.sleep(50)

      assert nil == Registry.lookup("openai", "nonexistent-model")
      assert nil == Registry.lookup("unknown-provider", "gpt-4o")

      GenServer.stop(pid)
    end

    test "cached_providers returns available providers" do
      {:ok, pid} =
        Registry.start_link(providers: ["openai", "zai", "missing-provider"])

      :sys.get_state(pid)
      Process.sleep(50)

      providers = Registry.cached_providers()
      assert "openai" in providers
      assert "zai" in providers
      refute "missing-provider" in providers

      GenServer.stop(pid)
    end

    test "handles fetch failure gracefully" do
      Application.put_env(:arcanum, :http_client, FailHttp)

      {:ok, pid} = Registry.start_link(providers: ["openai"])
      :sys.get_state(pid)
      Process.sleep(50)

      assert nil == Registry.lookup("openai", "gpt-4o")

      GenServer.stop(pid)
    end
  end

  describe "build_profile/1" do
    test "model with tool_call=true gets native format" do
      profile = Registry.build_profile(%{"tool_call" => true, "reasoning" => false})
      assert profile.supports_tools == true
      assert profile.tool_call_format == :native
      assert profile.reasoning_field == nil
    end

    test "model with tool_call=false gets xml_text format" do
      profile = Registry.build_profile(%{"tool_call" => false})
      assert profile.supports_tools == false
      assert profile.tool_call_format == :xml_text
    end

    test "model with reasoning=true gets reasoning_content field" do
      profile = Registry.build_profile(%{"reasoning" => true})
      assert profile.reasoning_field == :reasoning_content
    end

    test "model with interleaved field extracts atom" do
      profile =
        Registry.build_profile(%{
          "interleaved" => %{"field" => "reasoning_content"},
          "reasoning" => true
        })

      assert profile.reasoning_field == :reasoning_content
    end

    test "extracts context limit" do
      profile = Registry.build_profile(%{"limit" => %{"context" => 200_000}})
      assert profile.max_context == 200_000
    end

    test "defaults context limit to 131_072" do
      profile = Registry.build_profile(%{})
      assert profile.max_context == 131_072
    end
  end
end

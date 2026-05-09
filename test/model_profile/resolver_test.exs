defmodule Arcanum.ModelProfile.ResolverTest do
  use ExUnit.Case, async: true

  alias Arcanum.ModelProfile.Resolver

  describe "resolve/2" do
    test "returns profile for known provider" do
      profile = Resolver.resolve("openai", "gpt-4o")
      assert profile.supports_tools == true
      assert profile.supports_system_role == true
    end

    test "returns profile for deepseek provider" do
      profile = Resolver.resolve("deepseek", "deepseek-chat")
      assert profile.reasoning_field == :reasoning_content
    end

    test "returns default profile for unknown provider" do
      profile = Resolver.resolve("unknown", "some-model")
      assert %Arcanum.ModelProfile{} = profile
    end

    test "model override takes precedence over provider default" do
      profile = Resolver.resolve("zai", "glm-4.5-flash")
      assert profile.reasoning_field == nil
    end
  end
end

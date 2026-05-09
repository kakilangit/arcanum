defmodule Arcanum.ModelProfile do
  @moduledoc """
  Declares model capabilities upfront so adapters serialize correctly
  on the first attempt — no runtime detection, no retry-on-error branching.

  Every model gets a profile. Unknown models get `default/0` which assumes
  the weakest common denominator (no system role, XML text tool calls).
  """

  @type tool_call_format :: :native | :xml_text

  @type t :: %__MODULE__{
          supports_system_role: boolean(),
          supports_tools: boolean(),
          tool_call_format: tool_call_format(),
          reasoning_field: atom() | nil,
          thinking_param: map() | nil,
          preserve_reasoning: boolean(),
          max_context: pos_integer(),
          provider_routing: map() | nil
        }

  @enforce_keys []
  defstruct supports_system_role: true,
            supports_tools: true,
            tool_call_format: :native,
            reasoning_field: nil,
            thinking_param: nil,
            preserve_reasoning: false,
            max_context: 131_072,
            provider_routing: nil

  @doc """
  Default profile for unknown models. Assumes weak model capabilities.
  Safe for free-tier / community models that may reject system role
  and emit tool calls as XML text.
  """
  @spec default :: t()
  def default do
    %__MODULE__{
      supports_system_role: false,
      supports_tools: false,
      tool_call_format: :xml_text,
      reasoning_field: :reasoning_content
    }
  end

  @doc """
  Profile for models with full OpenAI-compatible capabilities.
  GPT-4o, Claude via OpenAI proxy, etc.
  """
  @spec capable :: t()
  def capable do
    %__MODULE__{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: nil
    }
  end
end

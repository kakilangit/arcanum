defmodule Arcanum.ModelProfile do
  @moduledoc """
  Declares model capabilities so adapters serialize correctly on the first attempt.

  Every model gets a profile. Unknown models get `default/0` which assumes
  the weakest common denominator (no system role, XML text tool calls).
  """

  @type tool_call_format :: :native | :xml_text
  @type image_response_mode :: :native_b64 | :request_b64

  @type t :: %__MODULE__{
          supports_system_role: boolean(),
          supports_tools: boolean(),
          supports_vision: boolean(),
          supports_image_generation: boolean(),
          supports_video_generation: boolean(),
          uses_max_completion_tokens: boolean(),
          temperature_not_supported: boolean(),
          tool_call_format: tool_call_format(),
          reasoning_field: atom() | nil,
          thinking_param: map() | nil,
          preserve_reasoning: boolean(),
          max_context: pos_integer(),
          max_images_per_message: pos_integer(),
          max_outputs_per_request: pos_integer(),
          supported_sizes: [String.t()],
          supported_formats: [String.t()],
          supported_qualities: [String.t()],
          supports_style: boolean(),
          image_response_mode: image_response_mode(),
          provider_routing: map() | nil
        }

  @enforce_keys []
  defstruct supports_system_role: true,
            supports_tools: true,
            supports_vision: false,
            supports_image_generation: false,
            supports_video_generation: false,
            uses_max_completion_tokens: false,
            temperature_not_supported: false,
            tool_call_format: :native,
            reasoning_field: nil,
            thinking_param: nil,
            preserve_reasoning: false,
            max_context: 131_072,
            max_images_per_message: 4,
            max_outputs_per_request: 4,
            supported_sizes: [],
            supported_formats: [],
            supported_qualities: [],
            supports_style: false,
            image_response_mode: :native_b64,
            provider_routing: nil

  @doc """
  Default profile for unknown models. Assumes weak capabilities.
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
  """
  @spec capable :: t()
  def capable do
    %__MODULE__{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native
    }
  end
end

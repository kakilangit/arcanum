defmodule Arcanum.Intent do
  @moduledoc """
  Canonical request struct for inference calls.

  Normalizes the request format across all providers so that the
  adapter layer handles provider-specific serialization.

  Content is always a list of typed blocks — no raw strings.

  ## Content Blocks

      %{role: :user, content: [
        %{type: :text, text: "What's in this image?"},
        %{type: :image_url, url: "https://..."},
        %{type: :image_base64, media_type: "image/png", data: "iVBOR..."}
      ]}
  """

  @type content_block ::
          %{type: :text, text: String.t()}
          | %{type: :image_url, url: String.t()}
          | %{type: :image_base64, media_type: String.t(), data: String.t()}

  @type message :: %{role: atom(), content: [content_block()]}

  @type tool :: %{
          type: String.t(),
          function: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
        }

  @type t :: %__MODULE__{
          messages: [message()],
          model: String.t(),
          tools: [tool()] | nil,
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          context_length: pos_integer() | nil
        }

  @enforce_keys [:messages, :model]
  defstruct [:messages, :model, :tools, :temperature, :max_tokens, :context_length]

  @doc """
  Wraps a plain string as a single text content block.
  """
  @spec text(String.t()) :: [content_block()]
  def text(str) when is_binary(str), do: [%{type: :text, text: str}]

  @doc """
  Extracts all text from content blocks, joined by newline.
  """
  @spec to_text([content_block()]) :: String.t()
  def to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("\n", & &1.text)
  end
end

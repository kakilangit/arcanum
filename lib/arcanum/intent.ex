defmodule Arcanum.Intent do
  @moduledoc """
  Canonical request struct for all inference calls: chat, streaming,
  embeddings, and media generation.

  ## Chat / Streaming

      %Intent{
        model: "gpt-4o",
        messages: [
          %{role: :user, content: [%{type: :text, text: "Hello"}]}
        ]
      }

  ## Media Generation

      %Intent{
        model: "gpt-image-1",
        prompt: "A cat wearing a wizard hat",
        size: "1024x1024",
        quality: "auto",
        n: 1,
        format: "png"
      }

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
          | %{
              type: :image,
              data: binary() | nil,
              url: String.t() | nil,
              content_type: String.t(),
              revised_prompt: String.t() | nil
            }
          | %{
              type: :video,
              data: binary() | nil,
              url: String.t() | nil,
              content_type: String.t(),
              revised_prompt: String.t() | nil
            }

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
          model: String.t(),
          messages: [message()] | nil,
          tools: [tool()] | nil,
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          context_length: pos_integer() | nil,
          prompt: String.t() | nil,
          negative_prompt: String.t() | nil,
          size: String.t(),
          quality: String.t() | nil,
          style: String.t() | nil,
          n: pos_integer(),
          format: String.t()
        }

  @enforce_keys [:model]
  defstruct [
    :model,
    :messages,
    :tools,
    :temperature,
    :max_tokens,
    :context_length,
    :prompt,
    :negative_prompt,
    quality: "auto",
    style: nil,
    size: "1024x1024",
    n: 1,
    format: "png"
  ]

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

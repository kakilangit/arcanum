defmodule Arcanum.MediaIntent do
  @moduledoc """
  Canonical request struct for media generation calls (image/video).
  """

  @type t :: %__MODULE__{
          model: String.t(),
          prompt: String.t(),
          negative_prompt: String.t() | nil,
          size: String.t(),
          quality: String.t() | nil,
          style: String.t() | nil,
          n: pos_integer(),
          format: String.t()
        }

  @enforce_keys [:model, :prompt]
  defstruct [
    :model,
    :prompt,
    negative_prompt: nil,
    size: "1024x1024",
    quality: "auto",
    style: nil,
    n: 1,
    format: "png"
  ]
end

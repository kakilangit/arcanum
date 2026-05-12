defmodule Arcanum.MediaResponse do
  @moduledoc """
  Canonical response struct from media generation calls.
  """

  @type media_item :: %{
          data: binary() | nil,
          url: String.t() | nil,
          revised_prompt: String.t() | nil,
          content_type: String.t()
        }

  @type t :: %__MODULE__{
          items: [media_item()],
          usage: map() | nil
        }

  defstruct items: [], usage: nil
end

defmodule Reencodarr.Media.VideoValidator do
  @moduledoc """
  Centralizes video validation logic for determining when to preserve bitrate,
  delete VMAFs, and handle video file updates.

  This module consolidates validation logic that was previously scattered across
  the Media module, making it more maintainable and testable.
  """

  @type video_attrs :: %{String.t() => any()} | %{atom() => any()}
  @type video_metadata :: %{
          id: integer(),
          size: integer() | nil,
          bitrate: integer() | nil,
          duration: float() | nil,
          video_codecs: [String.t()] | nil,
          audio_codecs: [String.t()] | nil
        }

  @type comparison_values :: %{
          size: integer() | nil,
          bitrate: integer() | nil,
          duration: float() | nil,
          video_codecs: [String.t()] | nil,
          audio_codecs: [String.t()] | nil
        }

  @doc """
  Extracts comparison values from video attributes for validation.

  Normalizes values to handle both string and atom keys.
  """
  @spec extract_comparison_values(video_attrs()) :: comparison_values()
  def extract_comparison_values(attrs) do
    %{
      size: get_attr_value(attrs, "size"),
      bitrate: get_attr_value(attrs, "bitrate"),
      duration: get_attr_value(attrs, "duration"),
      video_codecs: get_attr_value(attrs, "video_codecs"),
      audio_codecs: get_attr_value(attrs, "audio_codecs")
    }
  end

  @doc """
  Determines if VMAFs should be deleted based on video changes.

  Only deletes VMAFs if significant properties have changed that would affect encoding quality.
  """
  @spec should_delete_vmafs?(video_metadata() | nil, comparison_values()) :: boolean()
  def should_delete_vmafs?(nil, _new_values), do: false

  def should_delete_vmafs?(existing, new_values) do
    # Only check fields that have non-nil values in the new attributes
    # This avoids false positives when a field isn't being updated
    #
    # For bitrate: Only consider it changed if file size also changed or if bitrate is explicitly 0
    # This prevents sync from resetting analyzed bitrate when file content hasn't changed
    size_changed =
      is_integer(Map.get(new_values, :size)) and
        Map.get(new_values, :size) != Map.get(existing, :size)

    bitrate_explicitly_zero = Map.get(new_values, :bitrate) == 0
    should_check_bitrate = size_changed or bitrate_explicitly_zero

    comparison_pairs = [
      {Map.get(new_values, :size), Map.get(existing, :size)},
      # Only compare bitrate if size changed or bitrate is 0
      {should_check_bitrate && Map.get(new_values, :bitrate),
       should_check_bitrate && Map.get(existing, :bitrate)},
      {Map.get(new_values, :duration), Map.get(existing, :duration)},
      {Map.get(new_values, :video_codecs), Map.get(existing, :video_codecs)},
      {Map.get(new_values, :audio_codecs), Map.get(existing, :audio_codecs)}
    ]

    Enum.any?(comparison_pairs, fn {new_val, old_val} ->
      (is_integer(new_val) or is_list(new_val) or is_number(new_val)) and new_val != old_val
    end)
  end

  @doc """
  Determines if the existing bitrate should be preserved during an update.

  Preserves bitrate when file size hasn't changed (indicating same file content)
  but other metadata may have been updated.
  """
  @spec should_preserve_bitrate?(video_metadata() | nil, comparison_values()) :: boolean()
  def should_preserve_bitrate?(nil, _new_values), do: false

  def should_preserve_bitrate?(existing, new_values) do
    # Preserve existing analyzed bitrate when:
    # 1. File size hasn't changed (same file content)
    # 2. We have a valid existing bitrate
    # 3. New bitrate is not explicitly 0 (which indicates need for re-analysis)
    size_unchanged =
      not is_integer(Map.get(new_values, :size)) or
        Map.get(new_values, :size) == Map.get(existing, :size)

    has_valid_existing_bitrate =
      is_integer(Map.get(existing, :bitrate)) and Map.get(existing, :bitrate) > 0

    new_bitrate_not_zero = Map.get(new_values, :bitrate) != 0

    size_unchanged and has_valid_existing_bitrate and new_bitrate_not_zero
  end

  @doc """
  Helper function to get attribute values that handles both string and atom keys.
  """
  @spec get_attr_value(video_attrs(), String.t()) :: any()
  def get_attr_value(attrs, key) when is_binary(key) do
    Map.get(attrs, key) ||
      case String.to_existing_atom(key) do
        atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
        _ -> nil
      end
  rescue
    ArgumentError -> nil
  end
end

defmodule Reencodarr.Media.GlobPattern do
  @moduledoc """
  Structured representation and matching for glob patterns.

  Supports basic glob patterns:
  - `*` matches any characters except path separators
  - `**` matches any characters including path separators
  - `?` matches single character
  """

  defstruct [:pattern, :regex, :case_sensitive]

  @type t :: %__MODULE__{
          pattern: String.t(),
          regex: Regex.t() | nil,
          case_sensitive: boolean()
        }

  @doc """
  Creates a new GlobPattern struct from a string pattern.

  ## Examples

      iex> GlobPattern.new("*.mp4")
      %GlobPattern{pattern: "*.mp4", ...}
  """
  @spec new(String.t(), keyword()) :: t()
  def new(pattern, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, false)

    regex = compile_glob_to_regex(pattern, case_sensitive)

    %__MODULE__{
      pattern: pattern,
      regex: regex,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Checks if a path matches the glob pattern.
  """
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{regex: nil, pattern: pattern}, path) do
    # Fallback to simple string matching if regex compilation failed
    String.contains?(String.downcase(path), String.downcase(pattern))
  end

  def matches?(%__MODULE__{regex: regex}, path) do
    Regex.match?(regex, path)
  end

  # Convert glob pattern to regex
  defp compile_glob_to_regex(pattern, case_sensitive) do
    regex_opts = if case_sensitive, do: [], else: [:caseless]

    regex_pattern =
      pattern
      # Temporary placeholder for ** to avoid conflicts
      |> String.replace("**", "__DOUBLE_STAR__")
      |> Regex.escape()
      # ** matches any path including /
      |> String.replace("__DOUBLE_STAR__", ".*")
      # * matches any characters except /
      |> String.replace("\\*", "[^/]*")
      # ? matches single character
      |> String.replace("\\?", ".")
      # Anchor to full string
      |> then(&("^" <> &1 <> "$"))

    case Regex.compile(regex_pattern, regex_opts) do
      {:ok, regex} -> regex
      {:error, _} -> nil
    end
  end
end

defmodule Reencodarr.CrfSearchPolicy do
  @moduledoc false

  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Media.Video

  @default_range {5, 70}
  @max_retries 3

  defmodule Attempt do
    @moduledoc false

    @enforce_keys [:target_vmaf, :crf_range]
    defstruct [:target_vmaf, :crf_range]

    @type t :: %__MODULE__{
            target_vmaf: pos_integer(),
            crf_range: {integer(), integer()}
          }
  end

  @spec initial(Video.t(), pos_integer()) :: Attempt.t()
  def initial(video, target_vmaf) do
    %Attempt{
      target_vmaf: target_vmaf,
      crf_range: CrfSearchHints.crf_range(video, target_vmaf)
    }
  end

  @spec retry(Attempt.t(), atom(), non_neg_integer(), pos_integer()) ::
          {:retry, Attempt.t(), :widen_range | :lower_target | :reduce_size} | :stop
  def retry(_attempt, _category, retry_count, _min_target) when retry_count >= @max_retries,
    do: :stop

  def retry(%Attempt{crf_range: range} = attempt, _category, _retry_count, _min_target)
      when range != @default_range do
    {:retry, %Attempt{attempt | crf_range: @default_range}, :widen_range}
  end

  def retry(%Attempt{target_vmaf: target} = attempt, :size_limits, _retry_count, min_target)
      when target > min_target do
    {:retry, %Attempt{attempt | target_vmaf: max(target - 2, min_target)}, :reduce_size}
  end

  def retry(
        %Attempt{target_vmaf: target} = attempt,
        :crf_optimization,
        _retry_count,
        min_target
      )
      when target > min_target do
    {:retry, %Attempt{attempt | target_vmaf: target - 1}, :lower_target}
  end

  def retry(_attempt, _category, _retry_count, _min_target), do: :stop

  @spec from_args([String.t()]) :: {:ok, Attempt.t()} | {:error, :invalid_crf_search_args}
  def from_args(args) when is_list(args) do
    with {target, ""} <- Integer.parse(arg_value(args, "--min-vmaf")),
         {min_crf, ""} <- Integer.parse(arg_value(args, "--min-crf")),
         {max_crf, ""} <- Integer.parse(arg_value(args, "--max-crf")) do
      {:ok, %Attempt{target_vmaf: target, crf_range: {min_crf, max_crf}}}
    else
      _ -> {:error, :invalid_crf_search_args}
    end
  end

  @spec from_context(map()) :: {:ok, Attempt.t()} | {:error, :invalid_crf_search_attempt}
  def from_context(%{"target_vmaf" => target, "crf_range" => [min_crf, max_crf]})
      when is_integer(target) and is_integer(min_crf) and is_integer(max_crf) do
    {:ok, %Attempt{target_vmaf: target, crf_range: {min_crf, max_crf}}}
  end

  def from_context(_context), do: {:error, :invalid_crf_search_attempt}

  @spec to_context(Attempt.t()) :: map()
  def to_context(%Attempt{target_vmaf: target, crf_range: {min_crf, max_crf}}) do
    %{"target_vmaf" => target, "crf_range" => [min_crf, max_crf]}
  end

  defp arg_value(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value("", fn
      [^flag, value] -> value
      _ -> nil
    end)
  end
end

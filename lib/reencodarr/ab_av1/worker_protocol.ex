defmodule Reencodarr.AbAv1.WorkerProtocol do
  @moduledoc """
  Server-side helpers for the ab-av1 worker websocket protocol.
  """

  alias Reencodarr.Media.Video

  @crf_search_topic "workers:crf_search"
  @supported_protocol_versions [1]
  @default_chunk_size_bytes 1_048_576

  defmodule Announcement do
    @moduledoc false

    @enforce_keys [:worker_id, :protocol_version, :version, :capabilities]
    defstruct [:worker_id, :protocol_version, :version, :capabilities]

    @type t :: %__MODULE__{
            worker_id: String.t(),
            protocol_version: pos_integer(),
            version: String.t(),
            capabilities: map()
          }
  end

  defmodule TransferProgress do
    @moduledoc false

    @enforce_keys [:video_id, :transfer_id, :percent, :bytes_sent, :total_bytes]
    defstruct [
      :video_id,
      :transfer_id,
      :percent,
      :bytes_sent,
      :total_bytes,
      :chunk_index,
      :total_chunks
    ]

    @type t :: %__MODULE__{
            video_id: pos_integer(),
            transfer_id: String.t(),
            percent: number(),
            bytes_sent: non_neg_integer(),
            total_bytes: non_neg_integer(),
            chunk_index: non_neg_integer() | nil,
            total_chunks: non_neg_integer() | nil
          }
  end

  defmodule CrfSearchProgress do
    @moduledoc false

    @enforce_keys [:video_id, :percent]
    defstruct [:video_id, :percent, :filename, :eta, :fps]

    @type t :: %__MODULE__{
            video_id: pos_integer(),
            percent: number(),
            filename: String.t() | nil,
            eta: non_neg_integer() | nil,
            fps: number() | nil
          }
  end

  defmodule CrfSearchResult do
    @moduledoc false

    @enforce_keys [:video_id, :results]
    defstruct [:video_id, :results]

    @type t :: %__MODULE__{
            video_id: pos_integer(),
            results: [map()]
          }
  end

  defmodule FailureReport do
    @moduledoc false

    @enforce_keys [:video_id, :stage, :category, :message]
    defstruct [
      :video_id,
      :stage,
      :category,
      :message,
      :code,
      :context,
      :retriable,
      :stderr_excerpt
    ]

    @type t :: %__MODULE__{
            video_id: pos_integer(),
            stage: atom(),
            category: atom(),
            message: String.t(),
            code: String.t() | nil,
            context: map(),
            retriable: boolean() | nil,
            stderr_excerpt: String.t() | nil
          }
  end

  defmodule Completion do
    @moduledoc false

    @enforce_keys [:video_id, :result]
    defstruct [:video_id, :result, :chosen_crf]

    @type t :: %__MODULE__{
            video_id: pos_integer(),
            result: :ok | :cancelled | :shutdown | {:error, term()},
            chosen_crf: number() | nil
          }
  end

  @type video_id :: pos_integer()
  @type percentage :: number()
  @type crf_result :: %{
          required(:crf) => number(),
          required(:score) => number(),
          required(:percent) => number(),
          optional(:size) => String.t() | nil,
          optional(:time) => non_neg_integer() | nil,
          optional(:params) => [String.t()],
          optional(:target) => integer() | nil,
          optional(:chosen) => boolean()
        }
  @type completion_result :: :ok | :cancelled | :shutdown | {:error, term()}

  @spec crf_search_topic() :: String.t()
  def crf_search_topic, do: @crf_search_topic

  @spec supported_protocol_versions() :: [pos_integer()]
  def supported_protocol_versions, do: @supported_protocol_versions

  @spec chunk_size_bytes() :: pos_integer()
  def chunk_size_bytes, do: @default_chunk_size_bytes

  @spec valid_topic?(String.t()) :: boolean()
  def valid_topic?(@crf_search_topic), do: true
  def valid_topic?(_topic), do: false

  @spec supported_protocol_version?(integer()) :: boolean()
  def supported_protocol_version?(protocol_version),
    do: protocol_version in @supported_protocol_versions

  @spec parse_announcement(map()) :: {:ok, Announcement.t()} | {:error, :invalid_announcement}
  def parse_announcement(%{
        "worker_id" => worker_id,
        "protocol_version" => protocol_version,
        "version" => version,
        "capabilities" => capabilities
      })
      when is_binary(worker_id) and is_integer(protocol_version) and is_binary(version) and
             is_map(capabilities) do
    {:ok,
     %Announcement{
       worker_id: worker_id,
       protocol_version: protocol_version,
       version: version,
       capabilities: capabilities
     }}
  end

  def parse_announcement(_payload), do: {:error, :invalid_announcement}

  @spec parse_transfer_progress(map()) :: {:ok, TransferProgress.t()} | {:error, atom()}
  def parse_transfer_progress(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_transfer_progress),
         {:ok, transfer_id} <-
           required_string(payload, [:transfer_id, "transfer_id"], :invalid_transfer_progress),
         {:ok, percent} <-
           required_number(payload, [:percent, "percent"], :invalid_transfer_progress) do
      {:ok,
       %TransferProgress{
         video_id: video_id,
         transfer_id: transfer_id,
         percent: percent,
         bytes_sent:
           optional_integer(payload, [
             :bytes_sent,
             "bytes_sent",
             :transferred_bytes,
             "transferred_bytes"
           ]) || 0,
         total_bytes: optional_integer(payload, [:total_bytes, "total_bytes"]) || 0,
         chunk_index: optional_integer(payload, [:chunk_index, "chunk_index"]),
         total_chunks: optional_integer(payload, [:total_chunks, "total_chunks"])
       }}
    end
  end

  def parse_transfer_progress(_payload), do: {:error, :invalid_transfer_progress}

  @spec parse_crf_search_progress(map()) :: {:ok, CrfSearchProgress.t()} | {:error, atom()}
  def parse_crf_search_progress(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_crf_search_progress),
         {:ok, percent} <-
           required_number(payload, [:percent, "percent"], :invalid_crf_search_progress) do
      {:ok,
       %CrfSearchProgress{
         video_id: video_id,
         percent: percent,
         filename: optional_string(payload, [:filename, "filename"]),
         eta: optional_integer(payload, [:eta, "eta"]),
         fps: optional_number(payload, [:fps, "fps"])
       }}
    end
  end

  def parse_crf_search_progress(_payload), do: {:error, :invalid_crf_search_progress}

  @spec parse_crf_search_result(map()) :: {:ok, CrfSearchResult.t()} | {:error, atom()}
  def parse_crf_search_result(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_crf_search_result),
         {:ok, results} <- parse_result_batch(payload) do
      {:ok, %CrfSearchResult{video_id: video_id, results: results}}
    end
  end

  def parse_crf_search_result(_payload), do: {:error, :invalid_crf_search_result}

  @spec parse_failure_report(map()) :: {:ok, FailureReport.t()} | {:error, atom()}
  def parse_failure_report(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_failure_report),
         {:ok, stage} <- parse_failure_stage(payload),
         {:ok, category} <- parse_failure_category(payload),
         {:ok, message} <-
           required_string(payload, [:message, "message"], :invalid_failure_report) do
      {:ok,
       %FailureReport{
         video_id: video_id,
         stage: stage,
         category: category,
         message: message,
         code: optional_string(payload, [:code, "code"]),
         context: optional_map(payload, [:context, "context"]) || %{},
         retriable: optional_boolean(payload, [:retriable, "retriable"]),
         stderr_excerpt: optional_string(payload, [:stderr_excerpt, "stderr_excerpt"])
       }}
    end
  end

  def parse_failure_report(_payload), do: {:error, :invalid_failure_report}

  @spec parse_completion(map()) :: {:ok, Completion.t()} | {:error, atom()}
  def parse_completion(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_completion_result),
         {:ok, result} <- parse_completion_result(payload) do
      {:ok,
       %Completion{
         video_id: video_id,
         result: result,
         chosen_crf: optional_number(payload, [:chosen_crf, "chosen_crf"])
       }}
    end
  end

  def parse_completion(_payload), do: {:error, :invalid_completion_result}

  @spec accepted(pos_integer()) :: map()
  def accepted(protocol_version), do: %{accepted: true, protocol_version: protocol_version}

  @spec transfer_started(
          Video.t(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          map()
  def transfer_started(
        %Video{id: video_id, path: path, size: size},
        transfer_id,
        chunk_size_bytes,
        total_bytes,
        total_chunks
      )
      when is_integer(video_id) and is_binary(path) do
    %{
      status: "transfer_started",
      video_id: video_id,
      transfer_id: transfer_id,
      source_name: Path.basename(path),
      size_bytes: size || 0,
      chunk_size_bytes: chunk_size_bytes,
      total_bytes: total_bytes,
      total_chunks: total_chunks
    }
  end

  @spec transfer_chunk(
          Video.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          binary()
        ) :: map()
  def transfer_chunk(
        %Video{id: video_id},
        transfer_id,
        chunk_index,
        total_chunks,
        bytes_sent,
        total_bytes,
        chunk
      )
      when is_integer(video_id) and is_binary(transfer_id) and is_integer(chunk_index) and
             is_integer(total_chunks) and is_integer(bytes_sent) and is_integer(total_bytes) and
             is_binary(chunk) do
    %{
      status: "transfer_chunk",
      video_id: video_id,
      transfer_id: transfer_id,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      bytes_sent: bytes_sent,
      total_bytes: total_bytes,
      crc32: :erlang.crc32(chunk),
      data: Base.encode64(chunk)
    }
  end

  @spec transfer_complete(Video.t(), String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def transfer_complete(%Video{id: video_id}, transfer_id, total_bytes, total_chunks)
      when is_integer(video_id) and is_binary(transfer_id) do
    %{
      status: "transfer_complete",
      video_id: video_id,
      transfer_id: transfer_id,
      total_bytes: total_bytes,
      total_chunks: total_chunks
    }
  end

  @spec transfer_failed(Video.t(), String.t(), String.t()) :: map()
  def transfer_failed(%Video{id: video_id}, transfer_id, reason)
      when is_integer(video_id) and is_binary(transfer_id) and is_binary(reason) do
    %{
      status: "transfer_failed",
      video_id: video_id,
      transfer_id: transfer_id,
      reason: reason
    }
  end

  @spec event_ack(String.t()) :: map()
  def event_ack(event_name), do: %{accepted: true, event: event_name}

  @spec no_work() :: map()
  def no_work, do: %{status: "no_work"}

  @spec work_assigned(Video.t(), number()) :: map()
  def work_assigned(%Video{id: video_id, path: path, size: size}, target_vmaf)
      when is_integer(video_id) and is_binary(path) do
    %{
      status: "job_assigned",
      job_id: Integer.to_string(video_id),
      video_id: video_id,
      source_name: Path.basename(path),
      size_bytes: size || 0,
      chunk_size_bytes: chunk_size_bytes(),
      target_vmaf: target_vmaf
    }
  end

  @spec heartbeat_ack(DateTime.t()) :: map()
  def heartbeat_ack(last_seen_at),
    do: %{accepted: true, last_seen_at: DateTime.to_iso8601(last_seen_at)}

  @spec error(
          :duplicate_worker_id
          | :invalid_announcement
          | :invalid_session_attrs
          | :invalid_transfer_progress
          | :invalid_crf_search_progress
          | :invalid_crf_search_result
          | :invalid_failure_report
          | :invalid_completion_result
          | :unsupported_protocol_version
          | :unsupported_event
          | :unknown_worker_session
          | :unauthorized
        ) :: map()
  def error(:duplicate_worker_id), do: %{reason: "duplicate_worker_id"}

  def error(:invalid_announcement), do: %{reason: "invalid_announcement"}
  def error(:invalid_session_attrs), do: %{reason: "invalid_session_attrs"}
  def error(:invalid_transfer_progress), do: %{reason: "invalid_transfer_progress"}
  def error(:invalid_crf_search_progress), do: %{reason: "invalid_crf_search_progress"}
  def error(:invalid_crf_search_result), do: %{reason: "invalid_crf_search_result"}
  def error(:invalid_failure_report), do: %{reason: "invalid_failure_report"}
  def error(:invalid_completion_result), do: %{reason: "invalid_completion_result"}

  def error(:unsupported_protocol_version) do
    %{
      reason: "unsupported_protocol_version",
      supported_protocol_versions: @supported_protocol_versions
    }
  end

  def error(:unsupported_event), do: %{reason: "unsupported_event"}
  def error(:unknown_worker_session), do: %{reason: "unknown_worker_session"}
  def error(:unauthorized), do: %{reason: "unauthorized"}

  defp parse_single_crf_result(payload) when is_map(payload) do
    with {:ok, crf} <- required_number(payload, [:crf, "crf"], :invalid_crf_search_result),
         {:ok, score} <-
           required_number(
             payload,
             [:score, "score", :vmaf_score, "vmaf_score"],
             :invalid_crf_search_result
           ),
         {:ok, percent} <-
           required_number(
             payload,
             [:percent, "percent", :vmaf_percentile, "vmaf_percentile"],
             :invalid_crf_search_result
           ) do
      {:ok,
       %{
         crf: crf,
         score: score,
         percent: percent,
         size: optional_size(payload),
         time: optional_time(payload),
         params: optional_params(payload),
         target: optional_integer(payload, [:target, "target"]),
         chosen: optional_boolean(payload, [:chosen, "chosen"])
       }}
    end
  end

  defp parse_single_crf_result(_payload), do: {:error, :invalid_crf_search_result}

  defp parse_result_batch(payload) do
    case fetch_any(payload, [:results, "results"]) do
      nil ->
        parse_single_crf_result(payload)
        |> wrap_single_result()

      results when is_list(results) ->
        parse_result_list(results)

      _ ->
        {:error, :invalid_crf_search_result}
    end
  end

  defp parse_result_list(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case parse_single_crf_result(result) do
        {:ok, parsed_result} -> {:cont, {:ok, [parsed_result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed_results} -> {:ok, Enum.reverse(parsed_results)}
      {:error, _} = error -> error
    end
  end

  defp wrap_single_result({:ok, result}), do: {:ok, [result]}
  defp wrap_single_result({:error, _} = error), do: error

  defp parse_completion_result(payload) do
    case Map.get(payload, :result, Map.get(payload, "result")) do
      value when value in [:ok, "ok"] -> {:ok, :ok}
      value when value in [:cancelled, :canceled, "cancelled", "canceled"] -> {:ok, :cancelled}
      value when value in [:shutdown, "shutdown"] -> {:ok, :shutdown}
      value when value in [:failed, "failed"] -> {:ok, :failed}
      {:error, _} = error -> {:ok, error}
      %{"error" => reason} -> {:ok, {:error, reason}}
      %{error: reason} -> {:ok, {:error, reason}}
      _ -> {:error, :invalid_completion_result}
    end
  end

  defp parse_failure_stage(payload) do
    case normalize_stage(Map.get(payload, :stage, Map.get(payload, "stage"))) do
      {:ok, stage} -> {:ok, stage}
      :error -> {:error, :invalid_failure_report}
    end
  end

  defp parse_failure_category(payload) do
    case normalize_category(Map.get(payload, :category, Map.get(payload, "category"))) do
      {:ok, category} -> {:ok, category}
      :error -> {:error, :invalid_failure_report}
    end
  end

  defp normalize_stage(stage) when stage in [:analysis, :crf_search, :encoding, :post_process],
    do: {:ok, stage}

  defp normalize_stage("analysis"), do: {:ok, :analysis}
  defp normalize_stage("crf_search"), do: {:ok, :crf_search}
  defp normalize_stage("encoding"), do: {:ok, :encoding}
  defp normalize_stage("post_process"), do: {:ok, :post_process}
  defp normalize_stage(_), do: :error

  defp normalize_category(category)
       when category in [
              :file_access,
              :mediainfo_parsing,
              :validation,
              :vmaf_calculation,
              :crf_optimization,
              :size_limits,
              :preset_retry,
              :process_failure,
              :resource_exhaustion,
              :codec_issues,
              :timeout,
              :file_operations,
              :sync_integration,
              :cleanup,
              :configuration,
              :system_environment,
              :unknown
            ],
       do: {:ok, category}

  defp normalize_category("file_access"), do: {:ok, :file_access}
  defp normalize_category("mediainfo_parsing"), do: {:ok, :mediainfo_parsing}
  defp normalize_category("validation"), do: {:ok, :validation}
  defp normalize_category("vmaf_calculation"), do: {:ok, :vmaf_calculation}
  defp normalize_category("crf_optimization"), do: {:ok, :crf_optimization}
  defp normalize_category("size_limits"), do: {:ok, :size_limits}
  defp normalize_category("preset_retry"), do: {:ok, :preset_retry}
  defp normalize_category("process_failure"), do: {:ok, :process_failure}
  defp normalize_category("resource_exhaustion"), do: {:ok, :resource_exhaustion}
  defp normalize_category("codec_issues"), do: {:ok, :codec_issues}
  defp normalize_category("timeout"), do: {:ok, :timeout}
  defp normalize_category("file_operations"), do: {:ok, :file_operations}
  defp normalize_category("sync_integration"), do: {:ok, :sync_integration}
  defp normalize_category("cleanup"), do: {:ok, :cleanup}
  defp normalize_category("configuration"), do: {:ok, :configuration}
  defp normalize_category("system_environment"), do: {:ok, :system_environment}
  defp normalize_category("unknown"), do: {:ok, :unknown}
  defp normalize_category(_), do: :error

  defp required_integer(payload, keys, error) do
    case fetch_any(payload, keys) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp required_number(payload, keys, error) do
    case fetch_any(payload, keys) do
      value when is_number(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp required_string(payload, keys, error) do
    case fetch_any(payload, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp optional_string(payload, keys) do
    case fetch_any(payload, keys) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp optional_number(payload, keys) do
    case fetch_any(payload, keys) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp optional_integer(payload, keys) do
    case fetch_any(payload, keys) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp optional_boolean(payload, keys) do
    case fetch_any(payload, keys) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp optional_map(payload, keys) do
    case fetch_any(payload, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp optional_params(payload) do
    case fetch_any(payload, [:params, "params"]) do
      value when is_list(value) -> Enum.map(value, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp optional_size(payload) do
    case fetch_any(payload, [:size, "size"]) do
      value when is_binary(value) -> value
      value when is_number(value) -> format_size(value, payload)
      _ -> optional_predicted_size(payload)
    end
  end

  defp format_size(size, payload) do
    case optional_size_unit(payload) do
      nil -> "#{size}"
      unit -> "#{size} #{unit}"
    end
  end

  defp optional_predicted_size(payload) do
    case optional_number(payload, [:predicted_size, "predicted_size"]) do
      nil -> nil
      size -> format_size(size, payload)
    end
  end

  defp optional_size_unit(payload) do
    optional_string(payload, [:size_unit, "size_unit"]) ||
      optional_string(payload, [:unit, "unit"])
  end

  defp optional_time(payload) do
    case fetch_any(payload, [:time, "time"]) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_number(value) ->
        round(value)

      _ ->
        case {optional_number(payload, [:time_taken, "time_taken"]),
              optional_string(payload, [:time_unit, "time_unit"])} do
          {nil, _} -> nil
          {time_taken, unit} when unit in [nil, ""] -> round(time_taken)
          {time_taken, unit} -> round(Reencodarr.Core.Time.to_seconds(time_taken, unit))
        end
    end
  end

  defp fetch_any(payload, keys) do
    Enum.find_value(keys, fn key -> Map.get(payload, key) end)
  end
end

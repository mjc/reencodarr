defmodule Reencodarr.AbAv1.WorkerProtocol do
  @moduledoc """
  Server-side helpers for the ab-av1 worker websocket protocol.
  """

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.AbAv1.WorkerConfig
  alias Reencodarr.Media.Video

  @crf_search_topic "workers:crf_search"
  @supported_protocol_versions [1]
  @transfer_chunk_magic "RAV1"
  @transfer_chunk_frame_version 1
  @transfer_chunk_frame_type 1

  defmodule Announcement do
    @moduledoc false

    @enforce_keys [:worker_id, :protocol_version, :version, :capabilities]
    defstruct [:worker_id, :hostname, :protocol_version, :version, :capabilities]

    @type t :: %__MODULE__{
            worker_id: String.t(),
            hostname: String.t() | nil,
            protocol_version: pos_integer(),
            version: String.t(),
            capabilities: map()
          }
  end

  defmodule ActiveJob do
    @moduledoc false

    @enforce_keys [:job_id, :video_id, :job_type]
    defstruct [:job_id, :video_id, :job_type]

    @type t :: %__MODULE__{
            job_id: String.t(),
            video_id: pos_integer(),
            job_type: :crf_search | :encode
          }
  end

  defmodule ControlState do
    @moduledoc false

    @enforce_keys [:state]
    defstruct [:state, :active_video_id, :job_id, :command_id]

    @type t :: %__MODULE__{
            state: :running | :paused | :stopped,
            active_video_id: pos_integer() | nil,
            job_id: String.t() | nil,
            command_id: String.t() | nil
          }
  end

  defmodule TransferProgress do
    @moduledoc false

    @enforce_keys [:video_id, :transfer_id, :percent, :bytes_sent, :total_bytes]
    defstruct [
      :job_id,
      :video_id,
      :transfer_id,
      :filename,
      :percent,
      :bytes_sent,
      :total_bytes,
      :bytes_per_second,
      :eta,
      :chunk_index,
      :total_chunks
    ]

    @type t :: %__MODULE__{
            job_id: String.t() | nil,
            video_id: pos_integer(),
            transfer_id: String.t(),
            filename: String.t() | nil,
            percent: number(),
            bytes_sent: non_neg_integer(),
            total_bytes: non_neg_integer(),
            bytes_per_second: non_neg_integer() | nil,
            eta: non_neg_integer() | nil,
            chunk_index: non_neg_integer() | nil,
            total_chunks: non_neg_integer() | nil
          }
  end

  defmodule CrfSearchProgress do
    @moduledoc false

    @enforce_keys [:video_id, :percent]
    defstruct [
      :job_id,
      :video_id,
      :percent,
      :filename,
      :eta,
      :fps,
      :crf,
      :sample_num,
      :total_samples
    ]

    @type t :: %__MODULE__{
            job_id: String.t() | nil,
            video_id: pos_integer(),
            percent: number(),
            filename: String.t() | nil,
            eta: non_neg_integer() | nil,
            fps: number() | nil,
            crf: number() | nil,
            sample_num: pos_integer() | nil,
            total_samples: pos_integer() | nil
          }
  end

  defmodule CrfSearchResult do
    @moduledoc false

    @enforce_keys [:video_id, :results]
    defstruct [:job_id, :video_id, :results]

    @type t :: %__MODULE__{
            job_id: String.t() | nil,
            video_id: pos_integer(),
            results: [map()]
          }
  end

  defmodule FailureReport do
    @moduledoc false

    @enforce_keys [:video_id, :stage, :category, :message]
    defstruct [
      :job_id,
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
            job_id: String.t() | nil,
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

  defmodule EncodeProgress do
    @moduledoc false

    @enforce_keys [:job_id, :video_id, :percent, :fps, :output_bytes, :output_percent]
    defstruct [
      :job_id,
      :video_id,
      :percent,
      :fps,
      :eta,
      :output_bytes,
      :output_percent,
      :throughput
    ]

    @type t :: %__MODULE__{
            job_id: String.t(),
            video_id: pos_integer(),
            percent: number(),
            fps: number(),
            eta: non_neg_integer() | nil,
            output_bytes: non_neg_integer(),
            output_percent: number(),
            throughput: String.t() | nil
          }
  end

  defmodule EncodeCompletion do
    @moduledoc false

    @enforce_keys [:job_id, :video_id, :source_name, :output_path, :output_bytes, :output_percent]
    defstruct [:job_id, :video_id, :source_name, :output_path, :output_bytes, :output_percent]

    @type t :: %__MODULE__{
            job_id: String.t(),
            video_id: pos_integer(),
            source_name: String.t(),
            output_path: String.t(),
            output_bytes: non_neg_integer(),
            output_percent: number()
          }
  end

  defmodule Completion do
    @moduledoc false

    @enforce_keys [:video_id, :result]
    defstruct [:job_id, :video_id, :result, :chosen_crf, results: []]

    @type t :: %__MODULE__{
            job_id: String.t() | nil,
            video_id: pos_integer(),
            result: :ok | :cancelled | :shutdown | :failed | {:error, term()},
            chosen_crf: number() | nil,
            results: [map()]
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
  @type completion_result :: :ok | :cancelled | :shutdown | :failed | {:error, term()}

  @spec crf_search_topic() :: String.t()
  def crf_search_topic, do: @crf_search_topic

  @spec supported_protocol_versions() :: [pos_integer()]
  def supported_protocol_versions, do: @supported_protocol_versions

  @spec chunk_size_bytes() :: pos_integer()
  def chunk_size_bytes, do: WorkerConfig.chunk_size_bytes()

  @spec valid_topic?(String.t()) :: boolean()
  def valid_topic?(@crf_search_topic), do: true
  def valid_topic?(_topic), do: false

  @spec supported_protocol_version?(integer()) :: boolean()
  def supported_protocol_version?(protocol_version),
    do: protocol_version in @supported_protocol_versions

  @spec parse_announcement(map()) :: {:ok, Announcement.t()} | {:error, :invalid_announcement}
  def parse_announcement(
        %{
          "worker_id" => worker_id,
          "protocol_version" => protocol_version,
          "version" => version,
          "capabilities" => capabilities
        } = payload
      )
      when is_binary(worker_id) and is_integer(protocol_version) and is_binary(version) and
             is_map(capabilities) do
    {:ok,
     %Announcement{
       worker_id: worker_id,
       hostname: optional_string(payload, [:hostname, "hostname"]),
       protocol_version: protocol_version,
       version: version,
       capabilities: capabilities
     }}
  end

  def parse_announcement(_payload), do: {:error, :invalid_announcement}

  @spec parse_active_job(map()) :: {:ok, ActiveJob.t()} | {:error, :invalid_active_job}
  def parse_active_job(%{
        "job_id" => job_id,
        "video_id" => video_id,
        "job_type" => job_type
      })
      when is_binary(job_id) and job_id != "" and is_integer(video_id) and video_id > 0 and
             job_type in ["crf_search", "encode"] do
    {:ok,
     %ActiveJob{
       job_id: job_id,
       video_id: video_id,
       job_type: String.to_existing_atom(job_type)
     }}
  end

  def parse_active_job(_payload), do: {:error, :invalid_active_job}

  @spec parse_control_state(map()) :: {:ok, ControlState.t()} | {:error, :invalid_control_state}
  def parse_control_state(%{"state" => state} = payload)
      when state in ["running", "paused", "stopped"] do
    active_video_id = Map.get(payload, "active_video_id")
    job_id = Map.get(payload, "job_id")
    command_id = Map.get(payload, "command_id")

    if (is_nil(active_video_id) or (is_integer(active_video_id) and active_video_id > 0)) and
         valid_control_identity?(job_id, command_id) do
      {:ok,
       %ControlState{
         state: String.to_existing_atom(state),
         active_video_id: active_video_id,
         job_id: job_id,
         command_id: command_id
       }}
    else
      {:error, :invalid_control_state}
    end
  end

  def parse_control_state(_payload), do: {:error, :invalid_control_state}

  defp valid_control_identity?(nil, nil), do: true

  defp valid_control_identity?(job_id, command_id),
    do: is_binary(job_id) and job_id != "" and is_binary(command_id) and command_id != ""

  @spec parse_transfer_progress(map()) :: {:ok, TransferProgress.t()} | {:error, atom()}
  def parse_transfer_progress(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_transfer_progress),
         {:ok, transfer_id} <-
           required_string(
             payload,
             [:transfer_id, "transfer_id", :job_id, "job_id"],
             :invalid_transfer_progress
           ),
         {:ok, percent} <-
           required_number(payload, [:percent, "percent"], :invalid_transfer_progress) do
      {:ok,
       %TransferProgress{
         job_id: optional_string(payload, [:job_id, "job_id"]),
         video_id: video_id,
         transfer_id: transfer_id,
         filename: optional_string(payload, [:filename, "filename"]),
         percent: percent,
         bytes_sent:
           optional_integer(payload, [
             :bytes_sent,
             "bytes_sent",
             :received_bytes,
             "received_bytes",
             :transferred_bytes,
             "transferred_bytes"
           ]) || 0,
         total_bytes:
           optional_integer(payload, [
             :total_bytes,
             "total_bytes",
             :expected_bytes,
             "expected_bytes"
           ]) || 0,
         bytes_per_second:
           optional_integer(payload, [
             :bytes_per_second,
             "bytes_per_second"
           ]),
         eta: optional_integer(payload, [:eta, "eta"]),
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
         job_id: optional_string(payload, [:job_id, "job_id"]),
         video_id: video_id,
         percent: percent,
         filename: optional_string(payload, [:filename, "filename"]),
         eta: optional_integer(payload, [:eta, "eta"]),
         fps: optional_number(payload, [:fps, "fps"]),
         crf: optional_number(payload, [:crf, "crf"]),
         sample_num: optional_integer(payload, [:sample_num, "sample_num"]),
         total_samples: optional_integer(payload, [:total_samples, "total_samples"])
       }}
    end
  end

  def parse_crf_search_progress(_payload), do: {:error, :invalid_crf_search_progress}

  @spec parse_crf_search_result(map()) :: {:ok, CrfSearchResult.t()} | {:error, atom()}
  def parse_crf_search_result(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_crf_search_result),
         {:ok, results} <- parse_result_batch(payload) do
      {:ok,
       %CrfSearchResult{
         job_id: optional_string(payload, [:job_id, "job_id"]),
         video_id: video_id,
         results: results
       }}
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
         job_id: optional_string(payload, [:job_id, "job_id"]),
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

  @spec parse_encode_progress(map()) ::
          {:ok, EncodeProgress.t()} | {:error, :invalid_encode_progress}
  def parse_encode_progress(payload) when is_map(payload) do
    with {:ok, job_id} <-
           required_string(payload, [:job_id, "job_id"], :invalid_encode_progress),
         {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_encode_progress),
         {:ok, percent} <-
           required_number(payload, [:percent, "percent"], :invalid_encode_progress),
         {:ok, fps} <- required_number(payload, [:fps, "fps"], :invalid_encode_progress),
         {:ok, output_bytes} <-
           required_integer(payload, [:output_bytes, "output_bytes"], :invalid_encode_progress),
         {:ok, output_percent} <-
           required_number(
             payload,
             [:output_percent, "output_percent"],
             :invalid_encode_progress
           ) do
      {:ok,
       %EncodeProgress{
         job_id: job_id,
         video_id: video_id,
         percent: percent,
         fps: fps,
         eta: optional_integer(payload, [:eta, "eta"]),
         output_bytes: output_bytes,
         output_percent: output_percent,
         throughput: optional_string(payload, [:throughput, "throughput"])
       }}
    end
  end

  def parse_encode_progress(_payload), do: {:error, :invalid_encode_progress}

  def parse_encode_completion(payload) when is_map(payload) do
    with {:ok, job_id} <-
           required_string(payload, [:job_id, "job_id"], :invalid_encode_completion),
         {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_encode_completion),
         {:ok, source_name} <-
           required_string(payload, [:source_name, "source_name"], :invalid_encode_completion),
         {:ok, output_path} <-
           required_string(payload, [:output_path, "output_path"], :invalid_encode_completion),
         {:ok, output_bytes} <-
           required_integer(
             payload,
             [:output_bytes, "output_bytes"],
             :invalid_encode_completion
           ),
         {:ok, output_percent} <-
           required_number(
             payload,
             [:output_percent, "output_percent"],
             :invalid_encode_completion
           ) do
      {:ok,
       %EncodeCompletion{
         job_id: job_id,
         video_id: video_id,
         source_name: source_name,
         output_path: output_path,
         output_bytes: output_bytes,
         output_percent: output_percent
       }}
    end
  end

  def parse_encode_completion(_payload), do: {:error, :invalid_encode_completion}

  @spec parse_completion(map()) :: {:ok, Completion.t()} | {:error, atom()}
  def parse_completion(payload) when is_map(payload) do
    with {:ok, video_id} <-
           required_integer(payload, [:video_id, "video_id"], :invalid_completion_result),
         {:ok, result} <- parse_completion_result(payload) do
      {:ok,
       %Completion{
         job_id: optional_string(payload, [:job_id, "job_id"]),
         video_id: video_id,
         result: result,
         chosen_crf: optional_number(payload, [:chosen_crf, "chosen_crf"]),
         results: parse_optional_completion_results(payload)
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
        ) :: {:binary, binary()}
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
    {:binary,
     transfer_chunk_frame(
       video_id,
       transfer_id,
       chunk_index,
       total_chunks,
       bytes_sent,
       total_bytes,
       chunk
     )}
  end

  @spec parse_transfer_chunk_frame(binary()) :: {:ok, map()} | {:error, atom()}
  def parse_transfer_chunk_frame(
        <<@transfer_chunk_magic, @transfer_chunk_frame_version, @transfer_chunk_frame_type,
          transfer_id_size::16, video_id::64, chunk_index::64, total_chunks::64, bytes_sent::64,
          total_bytes::64, crc32::32, transfer_id::binary-size(transfer_id_size), data::binary>>
      ) do
    if :erlang.crc32(data) == crc32 do
      {:ok,
       %{
         video_id: video_id,
         transfer_id: transfer_id,
         chunk_index: chunk_index,
         total_chunks: total_chunks,
         bytes_sent: bytes_sent,
         total_bytes: total_bytes,
         crc32: crc32,
         data: data
       }}
    else
      {:error, :crc_mismatch}
    end
  end

  def parse_transfer_chunk_frame(
        <<@transfer_chunk_magic, @transfer_chunk_frame_version, _frame_type, _rest::binary>>
      ),
      do: {:error, :unsupported_transfer_chunk_frame_type}

  def parse_transfer_chunk_frame(<<@transfer_chunk_magic, _version, _rest::binary>>),
    do: {:error, :unsupported_transfer_chunk_frame_version}

  def parse_transfer_chunk_frame(_frame), do: {:error, :invalid_transfer_chunk_frame}

  defp transfer_chunk_frame(
         video_id,
         transfer_id,
         chunk_index,
         total_chunks,
         bytes_sent,
         total_bytes,
         chunk
       ) do
    transfer_id_size = byte_size(transfer_id)
    crc32 = :erlang.crc32(chunk)

    <<
      @transfer_chunk_magic,
      @transfer_chunk_frame_version,
      @transfer_chunk_frame_type,
      transfer_id_size::16,
      video_id::64,
      chunk_index::64,
      total_chunks::64,
      bytes_sent::64,
      total_bytes::64,
      crc32::32,
      transfer_id::binary,
      chunk::binary
    >>
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

  @spec event_discarded(String.t(), atom()) :: map()
  def event_discarded(event_name, reason) when is_atom(reason) do
    %{
      accepted: false,
      discarded: true,
      event: event_name,
      reason: Atom.to_string(reason)
    }
  end

  @spec no_work() :: map()
  def no_work, do: %{status: "no_work"}

  @spec work_assigned(Video.t(), number(), keyword()) :: map()
  def work_assigned(%Video{id: video_id, path: path, size: size} = video, target_vmaf, opts \\ [])
      when is_integer(video_id) and is_binary(path) do
    video
    |> maybe_put_transfer(%{
      status: "job_assigned",
      job_type: "crf_search",
      job_id: video.worker_attempt_id || Integer.to_string(video_id),
      video_id: video_id,
      source_name: Path.basename(path),
      size_bytes: size || 0,
      chunk_size_bytes: chunk_size_bytes(),
      target_vmaf: target_vmaf,
      crf_search_args: CrfSearch.build_crf_search_args(video, target_vmaf)
    })
    |> maybe_put_local_path(path, opts)
  end

  def work_in_progress(
        %Video{id: video_id, path: path, size: size} = video,
        target_vmaf,
        opts \\ []
      )
      when is_integer(video_id) and is_binary(path) do
    video
    |> maybe_put_transfer(%{
      status: "job_in_progress",
      job_type: "crf_search",
      job_id: video.worker_attempt_id || Integer.to_string(video_id),
      video_id: video_id,
      source_name: Path.basename(path),
      size_bytes: size || 0,
      target_vmaf: target_vmaf,
      crf_search_args: CrfSearch.build_crf_search_args(video, target_vmaf)
    })
    |> maybe_put_local_path(path, opts)
  end

  def encode_work_assigned(%Video{} = video, vmaf, opts \\ []) do
    payload = %{
      status: Keyword.get(opts, :status, "job_assigned"),
      job_type: "encode",
      job_id: video.worker_attempt_id || "encode-#{video.id}",
      video_id: video.id,
      source_name: Path.basename(video.path),
      size_bytes: video.size || 0,
      chunk_size_bytes: chunk_size_bytes(),
      target_vmaf: 0.0,
      encode_args: Encode.build_encode_args(%{vmaf | video: video})
    }

    video
    |> maybe_put_transfer(payload)
    |> maybe_put_local_path(video.path, opts)
    |> put_output_delivery(video, opts)
  end

  defp put_output_delivery(payload, video, opts) do
    if Keyword.get(opts, :local?, false) do
      Map.put(payload, :output_shared_path, Encode.output_file(video))
    else
      maybe_put_output_transfer(payload, video)
    end
  end

  defp maybe_put_output_transfer(%{job_id: attempt_id} = payload, %Video{id: video_id})
       when is_binary(attempt_id) do
    with base_url when is_binary(base_url) <- WorkerConfig.transfer_base_url(),
         token when is_binary(token) <- WorkerConfig.transfer_token() do
      Map.put(payload, :output_transfer, %{
        url:
          "#{String.trim_trailing(base_url, "/")}/workers/files/#{video_id}/output/#{attempt_id}",
        auth: %{scheme: "bearer", header: "authorization", value: "Bearer #{token}"}
      })
    else
      _ -> payload
    end
  end

  defp maybe_put_output_transfer(payload, %Video{}), do: payload

  defp maybe_put_local_path(payload, path, opts) do
    if Keyword.get(opts, :local?, false) do
      payload |> Map.delete(:transfer) |> Map.put(:local_path, path)
    else
      payload
    end
  end

  defp maybe_put_transfer(%Video{id: video_id}, payload) do
    with base_url when is_binary(base_url) <- WorkerConfig.transfer_base_url(),
         token when is_binary(token) <- WorkerConfig.transfer_token() do
      Map.put(payload, :transfer, %{
        url: "#{base_url}/workers/files/#{video_id}",
        auth: %{
          scheme: "bearer",
          header: "authorization",
          value: "Bearer #{token}"
        }
      })
    else
      _ -> payload
    end
  end

  @spec heartbeat_ack(DateTime.t()) :: map()
  def heartbeat_ack(last_seen_at),
    do: %{accepted: true, last_seen_at: DateTime.to_iso8601(last_seen_at)}

  @spec parse_resource_usage(map()) :: map() | nil
  def parse_resource_usage(payload) when is_map(payload) do
    [
      cpu_percent: optional_number(payload, [:cpu_percent, "cpu_percent"]),
      memory_bytes:
        optional_integer(payload, [
          :memory_bytes,
          "memory_bytes",
          :memory_rss_bytes,
          "memory_rss_bytes"
        ]),
      memory_total_bytes:
        optional_integer(payload, [
          :memory_total_bytes,
          "memory_total_bytes",
          :total_memory_bytes,
          "total_memory_bytes"
        ]),
      disk_free_bytes:
        optional_integer(payload, [
          :disk_free_bytes,
          "disk_free_bytes",
          :free_disk_bytes,
          "free_disk_bytes"
        ]),
      disk_total_bytes:
        optional_integer(payload, [
          :disk_total_bytes,
          "disk_total_bytes",
          :total_disk_bytes,
          "total_disk_bytes"
        ])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      usage when usage == %{} -> nil
      usage -> usage
    end
  end

  def parse_resource_usage(_payload), do: nil

  @spec error(
          :duplicate_worker_id
          | :invalid_announcement
          | :invalid_control_state
          | :invalid_session_attrs
          | :invalid_transfer_progress
          | :invalid_crf_search_progress
          | :invalid_crf_search_result
          | :invalid_failure_report
          | :invalid_completion_result
          | :invalid_encode_progress
          | :invalid_encode_completion
          | :source_missing
          | :stale_worker_attempt
          | :terminal_busy
          | :unsupported_protocol_version
          | :unsupported_event
          | :unknown_worker_session
          | :unauthorized
        ) :: map()
  def error(:duplicate_worker_id), do: %{reason: "duplicate_worker_id"}

  def error(:invalid_announcement), do: %{reason: "invalid_announcement"}
  def error(:invalid_active_job), do: %{reason: "invalid_active_job"}
  def error(:invalid_control_state), do: %{reason: "invalid_control_state"}
  def error(:invalid_session_attrs), do: %{reason: "invalid_session_attrs"}
  def error(:invalid_transfer_progress), do: %{reason: "invalid_transfer_progress"}
  def error(:invalid_crf_search_progress), do: %{reason: "invalid_crf_search_progress"}
  def error(:invalid_crf_search_result), do: %{reason: "invalid_crf_search_result"}
  def error(:invalid_failure_report), do: %{reason: "invalid_failure_report"}
  def error(:invalid_completion_result), do: %{reason: "invalid_completion_result"}
  def error(:invalid_encode_progress), do: %{reason: "invalid_encode_progress"}
  def error(:invalid_encode_completion), do: %{reason: "invalid_encode_completion"}
  def error(:source_missing), do: %{reason: "source_missing"}
  def error(:stale_worker_attempt), do: %{reason: "stale_worker_attempt"}
  def error(:terminal_busy), do: %{reason: "terminal_busy"}

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
             [
               :percent,
               "percent",
               :vmaf_percentile,
               "vmaf_percentile",
               :encode_percent,
               "encode_percent"
             ],
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

  defp parse_optional_completion_results(payload) do
    case parse_result_batch(payload) do
      {:ok, results} -> results
      {:error, _reason} -> []
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
    case optional_number(payload, [
           :predicted_size,
           "predicted_size",
           :predicted_encode_size,
           "predicted_encode_size"
         ]) do
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
        case {optional_number(payload, [
                :time_taken,
                "time_taken",
                :predicted_encode_time_secs,
                "predicted_encode_time_secs"
              ]), optional_string(payload, [:time_unit, "time_unit"])} do
          {nil, _} -> nil
          {time_taken, unit} when unit in [nil, ""] -> round(time_taken)
          {time_taken, unit} -> round(Reencodarr.Core.Time.to_seconds(time_taken, unit))
        end
    end
  end

  defp fetch_any(payload, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(payload, key), do: {:ok, Map.fetch!(payload, key)}
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end
end

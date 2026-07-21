defmodule Reencodarr.AbAv1.WorkerProtocolTest do
  use ExUnit.Case, async: false

  alias Reencodarr.AbAv1.WorkerProtocol
  alias Reencodarr.AbAv1.WorkerProtocol.Announcement
  alias Reencodarr.AbAv1.WorkerProtocol.Completion
  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchResult

  alias Reencodarr.AbAv1.WorkerProtocol.{
    EncodeCompletion,
    EncodeProgress,
    FailureReport,
    TransferProgress
  }

  test "rejects invalid announcement payloads" do
    assert {:error, :invalid_announcement} = WorkerProtocol.parse_announcement(%{})

    assert {:error, :invalid_announcement} =
             WorkerProtocol.parse_announcement(%{"worker_id" => "x"})
  end

  test "parses a worker announcement into a typed struct" do
    assert {:ok,
            %Announcement{
              worker_id: "abav1-dev",
              protocol_version: 1,
              version: "0.10.0",
              capabilities: %{"crf_search" => true}
            }} =
             WorkerProtocol.parse_announcement(%{
               "worker_id" => "abav1-dev",
               "protocol_version" => 1,
               "version" => "0.10.0",
               "capabilities" => %{"crf_search" => true}
             })
  end

  test "maps protocol errors to wire payloads" do
    assert WorkerProtocol.error(:unauthorized) == %{reason: "unauthorized"}
    assert WorkerProtocol.error(:unsupported_event) == %{reason: "unsupported_event"}
  end

  test "parses transfer progress into a typed payload" do
    assert {:ok,
            %TransferProgress{
              job_id: "job-1",
              video_id: 123,
              transfer_id: "job-1",
              filename: "movie.mkv",
              percent: 42.5,
              bytes_sent: 1_048_576,
              total_bytes: 2_097_152,
              bytes_per_second: 524_288,
              eta: 12,
              chunk_index: 3,
              total_chunks: 8
            }} =
             WorkerProtocol.parse_transfer_progress(%{
               "video_id" => 123,
               "job_id" => "job-1",
               "percent" => 42.5,
               "filename" => "movie.mkv",
               "received_bytes" => 1_048_576,
               "expected_bytes" => 2_097_152,
               "bytes_per_second" => 524_288,
               "eta" => 12,
               "chunk_index" => 3,
               "total_chunks" => 8
             })
  end

  test "parses CRF search progress into a typed payload" do
    assert {:ok,
            %CrfSearchProgress{
              video_id: 123,
              percent: 78.5,
              filename: "movie.mkv",
              eta: 42,
              fps: 23.97,
              crf: 24.0,
              sample_num: 2,
              total_samples: 8
            }} =
             WorkerProtocol.parse_crf_search_progress(%{
               "video_id" => 123,
               "percent" => 78.5,
               "filename" => "movie.mkv",
               "eta" => 42,
               "fps" => 23.97,
               "crf" => 24.0,
               "sample_num" => 2,
               "total_samples" => 8
             })
  end

  test "parses heartbeat resource usage" do
    assert %{
             cpu_percent: 87.5,
             memory_bytes: 1_073_741_824,
             memory_total_bytes: 4_294_967_296,
             disk_free_bytes: 536_870_912_000,
             disk_total_bytes: 1_099_511_627_776
           } =
             WorkerProtocol.parse_resource_usage(%{
               "cpu_percent" => 87.5,
               "memory_rss_bytes" => 1_073_741_824,
               "total_memory_bytes" => 4_294_967_296,
               "free_disk_bytes" => 536_870_912_000,
               "total_disk_bytes" => 1_099_511_627_776
             })

    assert is_nil(WorkerProtocol.parse_resource_usage(%{}))
  end

  test "parses structured CRF results and completion payloads" do
    assert {:ok,
            %CrfSearchResult{
              video_id: 123,
              results: [
                %{
                  crf: 28,
                  score: 95.4,
                  percent: 94,
                  size: "512 MB",
                  time: 3600,
                  params: ["--preset", "4"],
                  chosen: true
                }
              ]
            }} =
             WorkerProtocol.parse_crf_search_result(%{
               "video_id" => 123,
               "crf" => 28,
               "score" => 95.4,
               "percent" => 94,
               "size" => "512 MB",
               "time" => 3600,
               "params" => ["--preset", "4"],
               "chosen" => true
             })

    assert {:ok, %Completion{job_id: "123", video_id: 123, result: :ok, chosen_crf: 28}} =
             WorkerProtocol.parse_completion(%{
               "job_id" => "123",
               "video_id" => 123,
               "result" => "ok",
               "chosen_crf" => 28
             })

    assert {:ok,
            %CrfSearchResult{
              results: [%{chosen: false}]
            }} =
             WorkerProtocol.parse_crf_search_result(%{
               "video_id" => 123,
               "crf" => 28,
               "score" => 95.4,
               "percent" => 94,
               "chosen" => false
             })

    assert {:ok,
            %CrfSearchResult{
              video_id: 123,
              results: [
                %{
                  crf: 31.5,
                  score: 96.2,
                  percent: 42.5,
                  size: "123456",
                  time: 88
                }
              ]
            }} =
             WorkerProtocol.parse_crf_search_result(%{
               "job_id" => "job-123",
               "video_id" => 123,
               "source_name" => "movie.mkv",
               "crf" => 31.5,
               "vmaf_score" => 96.2,
               "xpsnr_score" => nil,
               "predicted_encode_size" => 123_456,
               "encode_percent" => 42.5,
               "predicted_encode_time_secs" => 87.5,
               "from_cache" => false
             })

    assert {:ok,
            %FailureReport{
              retriable: false
            }} =
             WorkerProtocol.parse_failure_report(%{
               "video_id" => 123,
               "stage" => "crf_search",
               "category" => "timeout",
               "message" => "timed out",
               "retriable" => false
             })
  end

  test "parses typed failure reports" do
    assert {:ok,
            %FailureReport{
              video_id: 123,
              stage: :crf_search,
              category: :timeout,
              message: "timed out",
              code: "EXIT_137",
              context: %{node: "worker@host"},
              retriable: true,
              stderr_excerpt: "ab-av1 timed out"
            }} =
             WorkerProtocol.parse_failure_report(%{
               "video_id" => 123,
               "stage" => "crf_search",
               "category" => "timeout",
               "message" => "timed out",
               "code" => "EXIT_137",
               "context" => %{node: "worker@host"},
               "retriable" => true,
               "stderr_excerpt" => "ab-av1 timed out"
             })
  end

  test "parses encode progress and completion with job identity" do
    assert {:ok,
            %EncodeProgress{
              job_id: "encode-123",
              video_id: 123,
              percent: 42.5,
              fps: 18.25,
              eta: 90,
              output_bytes: 456_789,
              output_percent: 31.2,
              throughput: "18.25 fps"
            }} =
             WorkerProtocol.parse_encode_progress(%{
               "job_id" => "encode-123",
               "video_id" => 123,
               "percent" => 42.5,
               "fps" => 18.25,
               "eta" => 90,
               "output_bytes" => 456_789,
               "output_percent" => 31.2,
               "throughput" => "18.25 fps"
             })

    assert {:ok,
            %EncodeCompletion{
              job_id: "encode-123",
              video_id: 123,
              source_name: "movie.mkv",
              output_path: "/shared/123.mkv",
              output_bytes: 800,
              output_percent: 40.0
            }} =
             WorkerProtocol.parse_encode_completion(%{
               "job_id" => "encode-123",
               "video_id" => 123,
               "source_name" => "movie.mkv",
               "output_path" => "/shared/123.mkv",
               "output_bytes" => 800,
               "output_percent" => 40.0
             })
  end

  test "builds a job_assigned payload from the claimed video" do
    payload =
      WorkerProtocol.work_assigned(
        %Reencodarr.Media.Video{
          id: 123,
          path: "/videos/movie.mkv",
          size: 987_654
        },
        96.5
      )

    assert %{
             status: "job_assigned",
             job_type: "crf_search",
             job_id: "123",
             video_id: 123,
             source_name: "movie.mkv",
             size_bytes: 987_654,
             chunk_size_bytes: 134_217_728,
             target_vmaf: 96.5,
             crf_search_args: crf_search_args
           } = payload

    assert [
             "crf-search",
             "--input",
             "/videos/movie.mkv",
             "--min-vmaf",
             "96.5" | _rest
           ] = crf_search_args

    assert "--temp-dir" in crf_search_args
  end

  test "builds encode assignments with exactly one output delivery mode" do
    previous_base_url = Application.get_env(:reencodarr, :worker_transfer_base_url)
    previous_token = Application.get_env(:reencodarr, :worker_transfer_token)
    Application.put_env(:reencodarr, :worker_transfer_base_url, "http://server:4000")
    Application.put_env(:reencodarr, :worker_transfer_token, "transfer-token")

    on_exit(fn ->
      restore_env(:worker_transfer_base_url, previous_base_url)
      restore_env(:worker_transfer_token, previous_token)
    end)

    video = %Reencodarr.Media.Video{id: 123, path: "/videos/movie.mkv", size: 2_000}
    vmaf = %Reencodarr.Media.Vmaf{video: video, crf: 30.0, score: 96.0, params: []}

    remote = WorkerProtocol.encode_work_assigned(video, vmaf)
    assert %{job_type: "encode", job_id: "encode-123", encode_args: ["encode" | _]} = remote
    assert %{output_transfer: %{url: "http://server:4000/workers/files/123/output"}} = remote
    refute Map.has_key?(remote, :output_shared_path)

    local = WorkerProtocol.encode_work_assigned(video, vmaf, local?: true)
    assert %{output_shared_path: output_path, local_path: "/videos/movie.mkv"} = local
    assert Path.basename(output_path) == "123.mkv"
    refute Map.has_key?(local, :output_transfer)
  end

  test "offers the source path to a local worker" do
    video = %Reencodarr.Media.Video{id: 123, path: "/videos/movie.mkv", size: 987_654}

    local_payload = WorkerProtocol.work_assigned(video, 96.5, local?: true)
    assert %{local_path: "/videos/movie.mkv"} = local_payload
    refute Map.has_key?(local_payload, :transfer)

    refute Map.has_key?(WorkerProtocol.work_assigned(video, 96.5), :local_path)
  end

  test "includes configured worker transfer URL in job payloads" do
    previous_base_url = Application.get_env(:reencodarr, :worker_transfer_base_url)
    previous_token = Application.get_env(:reencodarr, :worker_transfer_token)
    Application.put_env(:reencodarr, :worker_transfer_base_url, "http://10.0.0.10:4000/")
    Application.put_env(:reencodarr, :worker_transfer_token, "transfer-token")

    on_exit(fn ->
      restore_env(:worker_transfer_base_url, previous_base_url)
      restore_env(:worker_transfer_token, previous_token)
    end)

    video = %Reencodarr.Media.Video{id: 123, path: "/videos/movie.mkv", size: 987_654}

    assert %{transfer: transfer} = WorkerProtocol.work_assigned(video, 96.5)

    assert transfer == %{
             url: "http://10.0.0.10:4000/workers/files/123",
             auth: %{
               scheme: "bearer",
               header: "authorization",
               value: "Bearer transfer-token"
             }
           }

    assert %{transfer: ^transfer} =
             WorkerProtocol.work_assigned(video, 96.5)

    assert %{transfer: ^transfer} =
             WorkerProtocol.work_in_progress(video, 96.5)
  end

  defp restore_env(key, nil), do: Application.delete_env(:reencodarr, key)
  defp restore_env(key, value), do: Application.put_env(:reencodarr, key, value)

  test "builds binary transfer chunk frames with ordered metadata and raw data" do
    chunk = "raw video bytes"

    assert {:binary, frame} =
             WorkerProtocol.transfer_chunk(
               %Reencodarr.Media.Video{id: 123},
               "transfer-123",
               7,
               9,
               1_024,
               2_048,
               chunk
             )

    assert {:ok,
            %{
              video_id: 123,
              transfer_id: "transfer-123",
              chunk_index: 7,
              total_chunks: 9,
              bytes_sent: 1_024,
              total_bytes: 2_048,
              crc32: crc32,
              data: ^chunk
            }} = WorkerProtocol.parse_transfer_chunk_frame(frame)

    assert crc32 == :erlang.crc32(chunk)
  end

  test "reads chunk size from configuration" do
    previous = Application.get_env(:reencodarr, :worker_chunk_size_bytes)
    Application.put_env(:reencodarr, :worker_chunk_size_bytes, 2_097_152)

    try do
      assert WorkerProtocol.chunk_size_bytes() == 2_097_152
    after
      if is_nil(previous) do
        Application.delete_env(:reencodarr, :worker_chunk_size_bytes)
      else
        Application.put_env(:reencodarr, :worker_chunk_size_bytes, previous)
      end
    end
  end
end

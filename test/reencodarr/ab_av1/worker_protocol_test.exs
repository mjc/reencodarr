defmodule Reencodarr.AbAv1.WorkerProtocolTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerProtocol
  alias Reencodarr.AbAv1.WorkerProtocol.Announcement
  alias Reencodarr.AbAv1.WorkerProtocol.Completion
  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchResult
  alias Reencodarr.AbAv1.WorkerProtocol.FailureReport
  alias Reencodarr.AbAv1.WorkerProtocol.TransferProgress

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
              video_id: 123,
              transfer_id: "transfer-1",
              percent: 42.5,
              bytes_sent: 1_048_576,
              total_bytes: 2_097_152,
              chunk_index: 3,
              total_chunks: 8
            }} =
             WorkerProtocol.parse_transfer_progress(%{
               "video_id" => 123,
               "transfer_id" => "transfer-1",
               "percent" => 42.5,
               "bytes_sent" => 1_048_576,
               "total_bytes" => 2_097_152,
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
              fps: 23.97
            }} =
             WorkerProtocol.parse_crf_search_progress(%{
               "video_id" => 123,
               "percent" => 78.5,
               "filename" => "movie.mkv",
               "eta" => 42,
               "fps" => 23.97
             })
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

    assert {:ok, %Completion{video_id: 123, result: :ok, chosen_crf: 28}} =
             WorkerProtocol.parse_completion(%{
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

    assert payload == %{
             status: "job_assigned",
             job_id: "123",
             video_id: 123,
             source_name: "movie.mkv",
             size_bytes: 987_654,
             chunk_size_bytes: 134_217_728,
             target_vmaf: 96.5
           }
  end

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

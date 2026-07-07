defmodule Reencodarr.AbAv1.WorkerProtocolTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerProtocol
  alias Reencodarr.AbAv1.WorkerProtocol.Announcement

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
             chunk_size_bytes: 1_048_576,
             target_vmaf: 96.5
           }
  end
end

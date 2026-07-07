defmodule Reencodarr.AbAv1.WorkerProtocolTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerProtocol

  test "builds a job_assigned payload from the claimed video" do
    payload =
      WorkerProtocol.work_assigned(
        %{
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

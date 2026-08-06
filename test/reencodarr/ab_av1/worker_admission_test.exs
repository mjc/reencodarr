defmodule Reencodarr.AbAv1.WorkerAdmissionTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerAdmission

  @video %{size: 10_000}
  @vmaf %{percent: 40.0}

  test "remote encode capacity includes input, predicted output, and safety headroom" do
    assert WorkerAdmission.required_encode_bytes(@video, @vmaf,
             local?: false,
             safety_bytes: 1_000
           ) == 15_000
  end

  test "local encode capacity does not count a shared source copy" do
    assert WorkerAdmission.required_encode_bytes(@video, @vmaf,
             local?: true,
             safety_bytes: 1_000
           ) == 5_000
  end

  test "unknown output size conservatively reserves the source size" do
    assert WorkerAdmission.required_encode_bytes(@video, %{percent: nil},
             local?: true,
             safety_bytes: 1_000
           ) == 11_000
  end

  test "requires all calculated bytes to be available" do
    refute WorkerAdmission.encode_allowed?(14_999, @video, @vmaf,
             local?: false,
             safety_bytes: 1_000
           )

    assert WorkerAdmission.encode_allowed?(15_000, @video, @vmaf,
             local?: false,
             safety_bytes: 1_000
           )
  end
end

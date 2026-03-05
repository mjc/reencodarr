defmodule Reencodarr.TempCleanerTest do
  use Reencodarr.UnitCase, async: false

  alias Reencodarr.TempCleaner

  import ExUnit.CaptureLog

  # We control the temp dir by overriding application config in each test
  # to point to a real temporary filesystem path we own

  setup do
    tmp = System.tmp_dir!() |> Path.join("reencodarr_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    original_temp_dir = Application.get_env(:reencodarr, :temp_dir)
    Application.put_env(:reencodarr, :temp_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      if original_temp_dir do
        Application.put_env(:reencodarr, :temp_dir, original_temp_dir)
      else
        Application.delete_env(:reencodarr, :temp_dir)
      end
    end)

    {:ok, tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # cleanup_orphaned_files/0
  # ---------------------------------------------------------------------------

  describe "cleanup_orphaned_files/0" do
    test "returns 0 when temp dir is empty", %{tmp: _tmp} do
      assert TempCleaner.cleanup_orphaned_files() == 0
    end

    test "returns 0 when temp dir does not exist" do
      Application.put_env(:reencodarr, :temp_dir, "/tmp/reencodarr_nonexistent_xyzzy_abc123")
      assert TempCleaner.cleanup_orphaned_files() == 0
    end

    test "removes files older than max age", %{tmp: tmp} do
      # Create a file
      file_path = Path.join(tmp, "old_encode.mkv.tmp")
      File.write!(file_path, "data")

      # Set mtime to 25 hours ago (older than 24h threshold)
      old_mtime = System.os_time(:second) - 25 * 3600
      File.touch!(file_path, old_mtime)

      capture_log(fn ->
        assert TempCleaner.cleanup_orphaned_files() == 1
      end)

      refute File.exists?(file_path)
    end

    test "does not remove recent files", %{tmp: tmp} do
      file_path = Path.join(tmp, "recent_encode.mkv.tmp")
      File.write!(file_path, "data")
      # File was just created — mtime is now, well within 24h

      assert TempCleaner.cleanup_orphaned_files() == 0
      assert File.exists?(file_path)
    end

    test "removes only old files when mixed ages", %{tmp: tmp} do
      old_path = Path.join(tmp, "old.tmp")
      new_path = Path.join(tmp, "new.tmp")
      File.write!(old_path, "old")
      File.write!(new_path, "new")

      old_mtime = System.os_time(:second) - 48 * 3600
      File.touch!(old_path, old_mtime)

      capture_log(fn ->
        assert TempCleaner.cleanup_orphaned_files() == 1
      end)

      refute File.exists?(old_path)
      assert File.exists?(new_path)
    end

    test "skips subdirectories", %{tmp: tmp} do
      subdir = Path.join(tmp, "subdir")
      File.mkdir_p!(subdir)

      old_mtime = System.os_time(:second) - 48 * 3600
      File.touch!(subdir, old_mtime)

      assert TempCleaner.cleanup_orphaned_files() == 0
      assert File.dir?(subdir)
    end
  end

  # ---------------------------------------------------------------------------
  # check_disk_space/1
  # ---------------------------------------------------------------------------

  describe "check_disk_space/1" do
    test "returns {:ok, bytes_available} for a real path" do
      assert {:ok, bytes} = TempCleaner.check_disk_space(System.tmp_dir!())
      assert is_integer(bytes)
      assert bytes > 0
    end

    test "returns {:error, reason} for non-existent path" do
      assert {:error, _reason} = TempCleaner.check_disk_space("/nonexistent/path/xyz")
    end
  end

  # ---------------------------------------------------------------------------
  # check_disk_space/0
  # ---------------------------------------------------------------------------

  describe "check_disk_space/0" do
    test "queries the configured temp dir", %{tmp: _tmp} do
      # temp_dir is set to a real directory in setup — should return ok
      assert {:ok, bytes} = TempCleaner.check_disk_space()
      assert is_integer(bytes)
    end
  end

  # ---------------------------------------------------------------------------
  # sufficient_disk_space?/1
  # ---------------------------------------------------------------------------

  describe "sufficient_disk_space?/1" do
    test "returns true when available space exceeds min_bytes" do
      # System temp dir almost certainly has more than 1 byte free
      assert TempCleaner.sufficient_disk_space?(1) == true
    end

    test "returns false when available space is less than min_bytes" do
      # Require more than any machine could have free
      huge = 1_000_000_000_000_000_000
      assert TempCleaner.sufficient_disk_space?(huge) == false
    end

    test "returns true when check_disk_space errors (fail-open behavior)" do
      # To trigger an error, point the temp dir at an invalid path
      Application.put_env(:reencodarr, :temp_dir, "/nonexistent_drive_xyz/path")
      assert TempCleaner.sufficient_disk_space?(1) == true
    end
  end
end

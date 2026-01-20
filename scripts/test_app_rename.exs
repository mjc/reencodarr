#!/usr/bin/env elixir

# This script tests the actual application rename flow by:
# 1. Starting the application
# 2. Finding a video in the database
# 3. Renaming it on disk
# 4. Calling Sync.refresh_and_rename_from_video (the actual app code)
# 5. Verifying the rename worked

# Start the application
Application.ensure_all_started(:reencodarr)

defmodule AppRenameTest do
  require Logger
  alias Reencodarr.{Media, Sync, Repo}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("APPLICATION RENAME FLOW TEST")
    IO.puts(String.duplicate("=", 60))

    # Test both Sonarr and Radarr
    IO.puts("\n--- Testing Sonarr flow ---")
    test_service(:sonarr)

    IO.puts("\n--- Testing Radarr flow ---")
    test_service(:radarr)
  end

  defp test_service(service_type) do
    case find_test_video(service_type) do
      nil ->
        IO.puts("⚠️  No #{service_type} videos found in database")

      video ->
        IO.puts("Found video: #{video.path}")
        IO.puts("Service ID: #{video.service_id}")
        test_rename_flow(video)
    end
  end

  defp find_test_video(service_type) do
    import Ecto.Query

    Repo.one(
      from v in Media.Video,
        where: v.service_type == ^service_type and not is_nil(v.service_id),
        limit: 1
    )
  end

  defp test_rename_flow(video) do
    original_path = video.path

    # Check if file exists
    if not File.exists?(original_path) do
      IO.puts("❌ File doesn't exist at path: #{original_path}")
    else
      do_test_rename_flow(video, original_path)
    end
  end

  defp do_test_rename_flow(video, original_path) do
    mangled_path = mangle_path(original_path)
    IO.puts("\n📝 Renaming file on disk...")
    IO.puts("   Original: #{original_path}")
    IO.puts("   Mangled:  #{mangled_path}")

    case File.rename(original_path, mangled_path) do
      :ok ->
        IO.puts("   ✅ File renamed")
        run_app_rename(video, original_path, mangled_path)

      {:error, reason} ->
        IO.puts("   ❌ Failed to rename: #{inspect(reason)}")
    end
  end

  defp mangle_path(path) do
    dir = Path.dirname(path)
    ext = Path.extname(path)
    base = Path.basename(path, ext)
    Path.join(dir, "#{base}-REENCODED#{ext}")
  end

  defp run_app_rename(video, original_path, mangled_path) do
    IO.puts("\n🔧 Calling Sync.refresh_and_rename_from_video...")
    IO.puts("   This is the actual application code being tested!")

    start_time = System.monotonic_time(:millisecond)

    result = Sync.refresh_and_rename_from_video(video)

    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("   Completed in #{elapsed}ms")
    IO.puts("   Result: #{inspect(result)}")

    # Verify the result
    verify_rename(original_path, mangled_path, result)
  end

  defp verify_rename(original_path, mangled_path, app_result) do
    IO.puts("\n🔍 Verifying results...")

    # Check what the app returned
    case app_result do
      {:ok, _} ->
        IO.puts("   ✅ App reported success")

      {:error, reason} ->
        IO.puts("   ❌ App reported error: #{inspect(reason)}")
    end

    # Check if file exists at original path (or close to it - Sonarr might rename differently)
    cond do
      File.exists?(original_path) ->
        IO.puts("   ✅ File restored to original path")

      File.exists?(mangled_path) ->
        IO.puts("   ❌ File still at mangled path - rename didn't work!")
        IO.puts("   FAILURE: The rename flow did not restore the file")

      true ->
        # File might have been renamed to a different name by Sonarr's naming format
        dir = Path.dirname(original_path)
        IO.puts("   ⚠️  File not at original or mangled path")
        IO.puts("   Checking directory for similar files...")

        case File.ls(dir) do
          {:ok, files} ->
            # Look for files with similar episode/movie identifiers
            IO.puts("   Files in directory:")
            files |> Enum.take(10) |> Enum.each(&IO.puts("     - #{&1}"))

          {:error, _} ->
            IO.puts("   Could not list directory")
        end
    end
  end
end

AppRenameTest.run()

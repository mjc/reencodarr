#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.5"},
  {:exqlite, "~> 0.22"}
])

defmodule SonarrRenameTest do
  @moduledoc """
  Standalone integration test for Sonarr rename functionality.

  Usage:
    elixir test_sonarr_rename.exs

  Or with explicit config:
    SONARR_URL=http://localhost:8989 SONARR_API_KEY=your_key elixir test_sonarr_rename.exs

  This test:
    1. Picks a file from Sonarr
    2. Renames it on disk (simulating post-reencode state)
    3. Triggers a refresh so Sonarr detects the change
    4. Checks for renameable files
    5. Executes the rename command
    6. Verifies the file was renamed back
  """

  @db_path "priv/reencodarr_dev.db"

  def run do
    config = get_config()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("SONARR RENAME INTEGRATION TEST")
    IO.puts(String.duplicate("=", 60))
    IO.puts("URL: #{config.url}")

    with :ok <- test_connection(config),
         {:ok, series_id, file_id, original_path} <- pick_test_file(config),
         {:ok, mangled_path} <- mangle_filename(original_path),
         {:ok, command_id} <- test_refresh(config, series_id),
         :ok <- wait_for_command(config, command_id, "RefreshSeries"),
         {:ok, renameable} <- test_renameable_files(config, series_id),
         {:ok, _} <- test_rename(config, series_id, renameable, original_path) do
      IO.puts("\n✅ All tests passed!")
      :ok
    else
      {:skip, reason} ->
        IO.puts("\n⚠️  Test skipped: #{reason}")
        :ok

      {:error, reason} ->
        IO.puts("\n❌ Test failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_config do
    # Check environment variables first
    case {System.get_env("SONARR_URL"), System.get_env("SONARR_API_KEY")} do
      {url, api_key} when is_binary(url) and is_binary(api_key) ->
        %{url: url, api_key: api_key}

      _ ->
        # Fall back to reading from reencodarr database
        read_config_from_db()
    end
  end

  defp read_config_from_db do
    IO.puts("Reading Sonarr config from #{@db_path}...")

    {:ok, conn} = Exqlite.Sqlite3.open(@db_path)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT url, api_key FROM configs WHERE service_type = 'sonarr'")

    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [url, api_key]} ->
        Exqlite.Sqlite3.release(conn, stmt)
        Exqlite.Sqlite3.close(conn)
        %{url: url, api_key: api_key}

      :done ->
        Exqlite.Sqlite3.release(conn, stmt)
        Exqlite.Sqlite3.close(conn)
        raise "No Sonarr config found in database. Set SONARR_URL and SONARR_API_KEY environment variables."
    end
  end

  defp request(config, opts) do
    Req.request(
      Keyword.merge(opts,
        base_url: config.url,
        headers: [{"X-Api-Key", config.api_key}]
      )
    )
  end

  defp test_connection(config) do
    IO.puts("\n📡 Testing Sonarr connection...")

    case request(config, url: "/api/v3/system/status", method: :get) do
      {:ok, %{status: 200, body: body}} ->
        IO.puts("   ✅ Connected to Sonarr v#{body["version"]}")
        :ok

      {:ok, %{status: status, body: body}} ->
        IO.puts("   ❌ Connection failed: HTTP #{status} - #{inspect(body)}")
        {:error, :connection_failed}

      {:error, reason} ->
        IO.puts("   ❌ Connection failed: #{inspect(reason)}")
        {:error, :connection_failed}
    end
  end

  defp pick_test_file(config) do
    IO.puts("\n📺 Fetching series with files...")

    with {:ok, %{body: shows}} <- request(config, url: "/api/v3/series", method: :get),
         series when not is_nil(series) <- find_series_with_files(shows),
         {:ok, %{body: files}} <- request(config, url: "/api/v3/episodefile?seriesId=#{series["id"]}", method: :get),
         file when not is_nil(file) <- List.first(files) do

      IO.puts("   Selected series: #{series["title"]} (ID: #{series["id"]})")
      IO.puts("   File ID: #{file["id"]}")
      IO.puts("   Path: #{file["path"]}")

      {:ok, series["id"], file["id"], file["path"]}
    else
      nil ->
        IO.puts("   ❌ No series with files found")
        {:error, :no_files}

      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp find_series_with_files(shows) do
    shows
    |> Enum.filter(&(&1["statistics"]["episodeFileCount"] > 0))
    |> Enum.sort_by(&(-&1["statistics"]["episodeFileCount"]))
    |> List.first()
  end

  defp mangle_filename(original_path) do
    IO.puts("\n📝 Renaming file on disk to simulate post-reencode state...")
    IO.puts("   Original: #{original_path}")

    # Create a mangled name by inserting "-REENCODED" before the extension
    dir = Path.dirname(original_path)
    ext = Path.extname(original_path)
    base = Path.basename(original_path, ext)
    mangled_path = Path.join(dir, "#{base}-REENCODED#{ext}")

    IO.puts("   Mangled:  #{mangled_path}")

    case File.rename(original_path, mangled_path) do
      :ok ->
        IO.puts("   ✅ File renamed on disk")
        {:ok, mangled_path}

      {:error, reason} ->
        IO.puts("   ❌ Failed to rename file: #{inspect(reason)}")
        IO.puts("   Make sure the script has write access to the media directory")
        {:error, {:rename_failed, reason}}
    end
  end

  defp test_refresh(config, series_id) do
    IO.puts("\n🔄 Refreshing series #{series_id}...")

    payload = %{name: "RefreshSeries", seriesId: series_id}
    IO.puts("   Payload: #{inspect(payload)}")

    case request(config, url: "/api/v3/command", method: :post, json: payload) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        command_id = body["id"]
        IO.puts("   ✅ Refresh command sent, ID: #{command_id}")
        IO.puts("   Status: #{body["status"]}")
        {:ok, command_id}

      {:ok, %{status: status, body: body}} ->
        IO.puts("   ❌ Refresh failed: HTTP #{status} - #{inspect(body)}")
        {:error, :refresh_failed}

      {:error, reason} ->
        IO.puts("   ❌ Refresh failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_for_command(config, command_id, command_name, max_attempts \\ 30) do
    IO.puts("\n⏳ Waiting for #{command_name} command #{command_id}...")
    do_wait(config, command_id, command_name, max_attempts, 0)
  end

  defp do_wait(_config, _command_id, command_name, max_attempts, attempts)
       when attempts >= max_attempts do
    IO.puts("\n   ❌ Timeout waiting for #{command_name}")
    {:error, :timeout}
  end

  defp do_wait(config, command_id, command_name, max_attempts, attempts) do
    case request(config, url: "/api/v3/command/#{command_id}", method: :get) do
      {:ok, %{body: %{"status" => "completed"}}} ->
        IO.puts("\n   ✅ #{command_name} completed")
        :ok

      {:ok, %{body: %{"status" => "failed", "message" => msg}}} ->
        IO.puts("\n   ❌ #{command_name} failed: #{msg}")
        {:error, :command_failed}

      {:ok, %{body: %{"status" => status}}} ->
        IO.write("   Status: #{status} (#{attempts + 1}/#{max_attempts})   \r")
        Process.sleep(1000)
        do_wait(config, command_id, command_name, max_attempts, attempts + 1)

      {:error, reason} ->
        IO.puts("\n   ❌ Failed to get status: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp test_renameable_files(config, series_id) do
    IO.puts("\n📋 Checking renameable files for series #{series_id}...")

    case request(config, url: "/api/v3/rename?seriesId=#{series_id}", method: :get) do
      {:ok, %{status: 200, body: files}} when is_list(files) ->
        if Enum.empty?(files) do
          IO.puts("   ⚠️  No files need renaming")
          IO.puts("   This means all files already match the naming format")
          {:ok, []}
        else
          IO.puts("   Found #{length(files)} file(s) that need renaming:")

          Enum.each(files, fn file ->
            IO.puts("")
            IO.puts("   Episode File ID: #{file["episodeFileId"]}")
            IO.puts("   Current: #{file["existingPath"]}")
            IO.puts("   New:     #{file["newPath"]}")
          end)

          {:ok, files}
        end

      {:ok, %{status: status, body: body}} ->
        IO.puts("   ❌ Unexpected response: HTTP #{status} - #{inspect(body)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp test_rename(_config, _series_id, [], _original_path) do
    IO.puts("\n⚠️  No files to rename - Sonarr didn't detect the change")
    IO.puts("   This is the bug! The refresh should have detected the renamed file.")
    {:error, :no_renameable_files_detected}
  end

  defp test_rename(config, series_id, renameable_files, original_path) do
    IO.puts("\n🔧 Executing rename for series #{series_id}...")

    file_ids = Enum.map(renameable_files, & &1["episodeFileId"])

    payload = %{
      name: "RenameFiles",
      seriesId: series_id,
      files: file_ids
    }

    IO.puts("   Payload: #{inspect(payload)}")

    case request(config, url: "/api/v3/command", method: :post, json: payload) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        command_id = body["id"]
        IO.puts("   ✅ Rename command sent, ID: #{command_id}")
        IO.puts("   Response: #{inspect(body)}")

        with :ok <- wait_for_command(config, command_id, "RenameFiles") do
          verify_rename(config, series_id, renameable_files, original_path)
        end

      {:ok, %{status: status, body: body}} ->
        IO.puts("   ❌ Rename failed: HTTP #{status}")
        IO.puts("   Response: #{inspect(body)}")
        {:error, :rename_failed}

      {:error, reason} ->
        IO.puts("   ❌ Rename failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp verify_rename(config, series_id, original_renameable, original_path) do
    IO.puts("\n🔍 Verifying rename results...")

    # First check if the file exists at the original path
    file_restored = File.exists?(original_path)

    if file_restored do
      IO.puts("   ✅ File restored to original path: #{original_path}")
    else
      IO.puts("   ❌ File NOT at original path: #{original_path}")

      # Check what path Sonarr thinks the file is at now
      case request(config, url: "/api/v3/rename?seriesId=#{series_id}", method: :get) do
        {:ok, %{body: still_renameable}} when is_list(still_renameable) ->
          if Enum.empty?(still_renameable) do
            IO.puts("   ⚠️  No files need renaming anymore, but file not at expected path")
          else
            IO.puts("   Files still needing rename:")
            Enum.each(still_renameable, fn f ->
              IO.puts("     Current: #{f["existingPath"]}")
              IO.puts("     Expected: #{f["newPath"]}")
            end)
          end

        _ ->
          :ok
      end
    end

    # Also verify via API
    case request(config, url: "/api/v3/rename?seriesId=#{series_id}", method: :get) do
      {:ok, %{body: new_renameable}} when is_list(new_renameable) ->
        original_ids = MapSet.new(original_renameable, & &1["episodeFileId"])
        new_ids = MapSet.new(new_renameable, & &1["episodeFileId"])

        renamed = MapSet.difference(original_ids, new_ids) |> MapSet.to_list()
        still_pending = MapSet.intersection(original_ids, new_ids) |> MapSet.to_list()

        if length(renamed) > 0 do
          IO.puts("   ✅ API confirms #{length(renamed)} file(s) renamed")
        end

        if length(still_pending) > 0 do
          IO.puts("   ⚠️  #{length(still_pending)} file(s) still need renaming")
          IO.puts("   Still pending IDs: #{inspect(still_pending)}")
        end

        if file_restored and Enum.empty?(still_pending) do
          {:ok, %{renamed: renamed, still_pending: still_pending}}
        else
          {:error, :rename_verification_failed}
        end

      {:error, reason} ->
        IO.puts("   ❌ Verification failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

SonarrRenameTest.run()

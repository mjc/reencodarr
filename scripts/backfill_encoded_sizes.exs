#!/usr/bin/env elixir
# Backfills video.size with actual encoded file sizes for videos that have been
# encoded but whose size field still holds the original (pre-encoding) value.
#
# This enables the dashboard "Space Saved" metric to use actual savings
# (original_size - size) instead of predicted savings from CRF search.
#
# Run via: bin/rpc 'Code.eval_file("scripts/backfill_encoded_sizes.exs")'

import Ecto.Query
alias Reencodarr.{Repo, Media.Video}

defmodule BackfillEncodedSizes do
  @batch_size 200

  def run do
    IO.puts("=== Backfilling encoded video file sizes ===\n")
    IO.puts("Finding encoded videos where original_size == size (not yet updated)...\n")

    {updated, skipped, errors, total_savings} = process_batches(0, {0, 0, 0, 0})

    IO.puts("\n=== Results ===")
    IO.puts("Updated:  #{updated}")
    IO.puts("Skipped:  #{skipped} (file same size or larger)")
    IO.puts("Errors:   #{errors} (file missing or inaccessible)")
    IO.puts("New actual savings captured: #{Float.round(total_savings / 1_073_741_824.0, 2)} GiB")
  end

  defp process_batches(min_id, acc) do
    batch =
      Repo.all(
        from(v in Video,
          where:
            v.state == :encoded and
              not is_nil(v.original_size) and
              v.original_size == v.size and
              v.id > ^min_id,
          order_by: [asc: v.id],
          limit: @batch_size,
          select: %{id: v.id, size: v.size, path: v.path}
        )
      )

    if batch == [] do
      acc
    else
      new_acc =
        Enum.reduce(batch, acc, fn video, {upd, skip, err, savings} ->
          case File.stat(video.path) do
            {:ok, %File.Stat{size: file_size}} when file_size > 0 and file_size < video.size ->
              now = DateTime.utc_now()

              from(v in Video, where: v.id == ^video.id)
              |> Repo.update_all(set: [size: file_size, updated_at: now])

              {upd + 1, skip, err, savings + (video.size - file_size)}

            {:ok, _} ->
              {upd, skip + 1, err, savings}

            {:error, _} ->
              {upd, skip, err + 1, savings}
          end
        end)

      last_id = List.last(batch).id
      {upd, _, _, _} = new_acc

      if rem(upd, 500) < @batch_size do
        IO.puts("  ...processed through id #{last_id}, #{upd} updated so far")
      end

      process_batches(last_id, new_acc)
    end
  end
end

BackfillEncodedSizes.run()

# Also handle encoded videos without original_size that were encoded
# before original_size tracking was added
defmodule BackfillMissingOriginalSize do
  @batch_size 200

  def run do
    IO.puts("\n=== Backfilling videos missing original_size ===\n")

    {updated, skipped, errors, total_savings} = process_batches(0, {0, 0, 0, 0})

    IO.puts("\n=== Results ===")
    IO.puts("Updated:  #{updated}")
    IO.puts("Skipped:  #{skipped}")
    IO.puts("Errors:   #{errors}")
    IO.puts("New actual savings captured: #{Float.round(total_savings / 1_073_741_824.0, 2)} GiB")
  end

  defp process_batches(min_id, acc) do
    batch =
      Repo.all(
        from(v in Video,
          where:
            v.state == :encoded and
              is_nil(v.original_size) and
              v.id > ^min_id,
          order_by: [asc: v.id],
          limit: @batch_size,
          select: %{id: v.id, size: v.size, path: v.path}
        )
      )

    if batch == [] do
      acc
    else
      new_acc =
        Enum.reduce(batch, acc, fn video, {upd, skip, err, savings} ->
          case File.stat(video.path) do
            {:ok, %File.Stat{size: file_size}} when file_size > 0 and file_size < video.size ->
              now = DateTime.utc_now()

              from(v in Video, where: v.id == ^video.id)
              |> Repo.update_all(
                set: [original_size: video.size, size: file_size, updated_at: now]
              )

              {upd + 1, skip, err, savings + (video.size - file_size)}

            {:ok, _} ->
              {upd, skip + 1, err, savings}

            {:error, _} ->
              {upd, skip, err + 1, savings}
          end
        end)

      last_id = List.last(batch).id
      process_batches(last_id, new_acc)
    end
  end
end

BackfillMissingOriginalSize.run()
:ok

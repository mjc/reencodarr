defmodule Reencodarr.Repo.Migrations.BackfillLegacyWorkerAttemptIds do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE videos
    SET worker_attempt_id = CASE state
          WHEN 'crf_searching' THEN CAST(id AS TEXT)
          WHEN 'encoding' THEN 'encode-' || CAST(id AS TEXT)
        END,
        worker_control_desired_state = 'running',
        worker_control_acknowledged_state = 'running',
        worker_control_command_id = NULL,
        worker_terminal_claimed_at = NULL
    WHERE worker_attempt_id IS NULL
      AND (
        (state = 'crf_searching' AND crf_search_worker_id IS NOT NULL)
        OR (state = 'encoding' AND encode_worker_id IS NOT NULL)
      )
    """)
  end

  def down, do: :ok
end

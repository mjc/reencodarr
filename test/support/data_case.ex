defmodule Reencodarr.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Reencodarr.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Reencodarr.Fixtures
      alias Reencodarr.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Reencodarr.DataCase
      import Reencodarr.TestHelpers
    end
  end

  setup tags do
    Reencodarr.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Reencodarr.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Assert that a changeset has specific errors on given fields.

      assert_changeset_error(changeset, :password, "can't be blank")
      assert_changeset_error(changeset, %{password: ["can't be blank"], email: ["is invalid"]})
  """
  def assert_changeset_error(changeset, field, expected_error) when is_atom(field) do
    errors = errors_on(changeset)

    assert expected_error in Map.get(errors, field, []),
           "Expected error '#{expected_error}' on field #{field}, got: #{inspect(errors)}"
  end

  def assert_changeset_error(changeset, expected_errors) when is_map(expected_errors) do
    errors = errors_on(changeset)

    Enum.each(expected_errors, fn {field, field_errors} ->
      assert_field_errors(field, field_errors, errors)
    end)
  end

  defp assert_field_errors(field, field_errors, errors) when is_list(field_errors) do
    Enum.each(field_errors, fn error ->
      assert error in Map.get(errors, field, []),
             "Expected error '#{error}' on field #{field}, got: #{inspect(errors)}"
    end)
  end

  defp assert_field_errors(field, field_error, errors) do
    assert field_error in Map.get(errors, field, []),
           "Expected error '#{field_error}' on field #{field}, got: #{inspect(errors)}"
  end

  @doc """
  Assert that an operation returns a successful result.

      assert_ok(Media.upsert_video(attrs))
      assert_ok(Media.upsert_video(attrs), fn video ->
        assert video.path == "test.mkv"
      end)
  """
  def assert_ok({:ok, result}), do: result

  def assert_ok({:error, reason}) do
    flunk("Expected {:ok, _}, got {:error, #{inspect(reason)}}")
  end

  def assert_ok(other) do
    flunk("Expected {:ok, _}, got #{inspect(other)}")
  end

  def assert_ok({:ok, result}, validator) when is_function(validator, 1) do
    validator.(result)
    result
  end

  @doc """
  Assert that an operation returns an error result.

      assert_error(Media.upsert_video(%{}))
      assert_error(Media.upsert_video(%{}), fn changeset ->
        assert %{path: ["can't be blank"]} = errors_on(changeset)
      end)
  """
  def assert_error({:error, result}), do: result

  def assert_error({:ok, result}) do
    flunk("Expected {:error, _}, got {:ok, #{inspect(result)}}")
  end

  def assert_error(other) do
    flunk("Expected {:error, _}, got #{inspect(other)}")
  end

  def assert_error({:error, result}, validator) when is_function(validator, 1) do
    validator.(result)
    result
  end

  @doc """
  Create a temporary test file with given content.
  File is automatically cleaned up after the test.

      test_file = create_temp_file("fake video content", ".mkv")
  """
  def create_temp_file(content \\ "test content", extension \\ ".txt") do
    file_path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(10000)}#{extension}")
    File.write!(file_path, content)

    # Schedule cleanup
    ExUnit.Callbacks.on_exit(fn -> File.rm(file_path) end)

    file_path
  end

  @doc """
  Capture log output and return both the log and the result of the function.

      {log, result} = capture_log_and_result(fn ->
        SomeModule.process()
      end)
  """
  def capture_log_and_result(fun) do
    import ExUnit.CaptureLog
    log = capture_log(fun)
    {log, fun.()}
  end
end

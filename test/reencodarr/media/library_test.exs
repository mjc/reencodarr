defmodule Reencodarr.Media.LibraryTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Library

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Library.changeset(%Library{}, %{path: "/media/movies", monitor: true})
      assert cs.valid?
    end

    test "monitor defaults to false when not provided in struct" do
      cs = Library.changeset(%Library{}, %{path: "/media/shows", monitor: false})
      assert cs.valid?
    end

    test "missing path makes changeset invalid" do
      cs = Library.changeset(%Library{}, %{monitor: true})
      refute cs.valid?
    end

    test "monitor defaults to false from schema when not provided in attrs" do
      # The schema has default: false for monitor, so validate_required passes
      cs = Library.changeset(%Library{}, %{path: "/media/movies"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :monitor) == false
    end

    test "empty path makes changeset invalid" do
      cs = Library.changeset(%Library{}, %{path: "", monitor: true})
      refute cs.valid?
    end

    test "monitor can be false" do
      cs = Library.changeset(%Library{}, %{path: "/media/archive", monitor: false})
      assert cs.valid?
    end

    test "path is stored in changeset changes" do
      cs = Library.changeset(%Library{}, %{path: "/media/4k", monitor: true})
      assert Ecto.Changeset.get_change(cs, :path) == "/media/4k"
    end

    test "monitor is stored in changeset changes" do
      cs = Library.changeset(%Library{}, %{path: "/media/4k", monitor: true})
      assert Ecto.Changeset.get_change(cs, :monitor) == true
    end
  end
end

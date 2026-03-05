defmodule Reencodarr.Media.VmafTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Vmaf

  defp valid_attrs do
    %{
      score: 95.0,
      crf: 28.0,
      params: ["--preset", "4", "--svt", "av1"],
      video_id: 1
    }
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Vmaf.changeset(%Vmaf{}, valid_attrs())
      assert cs.valid?
    end

    test "missing score makes changeset invalid" do
      cs = Vmaf.changeset(%Vmaf{}, Map.delete(valid_attrs(), :score))
      refute cs.valid?
    end

    test "missing crf makes changeset invalid" do
      cs = Vmaf.changeset(%Vmaf{}, Map.delete(valid_attrs(), :crf))
      refute cs.valid?
    end

    test "missing params makes changeset invalid" do
      cs = Vmaf.changeset(%Vmaf{}, Map.delete(valid_attrs(), :params))
      refute cs.valid?
    end

    test "percent is optional" do
      attrs = Map.put(valid_attrs(), :percent, 87.5)
      cs = Vmaf.changeset(%Vmaf{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :percent) == 87.5
    end

    test "savings is optional" do
      attrs = Map.put(valid_attrs(), :savings, 500_000_000)
      cs = Vmaf.changeset(%Vmaf{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :savings) == 500_000_000
    end

    test "target is optional" do
      attrs = Map.put(valid_attrs(), :target, 95)
      cs = Vmaf.changeset(%Vmaf{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :target) == 95
    end

    test "size is optional" do
      attrs = Map.put(valid_attrs(), :size, "1.5 GiB")
      cs = Vmaf.changeset(%Vmaf{}, attrs)
      assert cs.valid?
    end

    test "time is optional" do
      attrs = Map.put(valid_attrs(), :time, 3600)
      cs = Vmaf.changeset(%Vmaf{}, attrs)
      assert cs.valid?
    end

    test "params accepts an empty list" do
      cs = Vmaf.changeset(%Vmaf{}, Map.put(valid_attrs(), :params, []))
      # Empty list satisfies required (not nil), so changeset should be valid
      assert cs.valid?
    end

    test "score can be a float below 100" do
      cs = Vmaf.changeset(%Vmaf{}, Map.put(valid_attrs(), :score, 50.5))
      assert cs.valid?
    end

    test "crf can be a float" do
      cs = Vmaf.changeset(%Vmaf{}, Map.put(valid_attrs(), :crf, 32.5))
      assert cs.valid?
    end
  end
end

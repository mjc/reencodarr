defmodule Reencodarr.Core.ParsersYearTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Core.Parsers

  describe "extract_year_from_text/1" do
    test "extracts year from parentheses format" do
      assert Parsers.extract_year_from_text("The Movie (2008) HD") == 2008
      assert Parsers.extract_year_from_text("Another Film (1995) 720p") == 1995
    end

    test "extracts year from square brackets format" do
      assert Parsers.extract_year_from_text("The Movie [2008] HD") == 2008
      assert Parsers.extract_year_from_text("Show [1999] Complete") == 1999
    end

    test "extracts year from dot-separated format" do
      assert Parsers.extract_year_from_text("Movie.Title.2008.720p") == 2008
      assert Parsers.extract_year_from_text("Show.S01.2010.Complete") == 2010
    end

    test "extracts year from space-separated format" do
      assert Parsers.extract_year_from_text("Movie Title 2008 HD") == 2008
      assert Parsers.extract_year_from_text("Another Show 2005 Complete") == 2005
    end

    test "extracts year from standalone 4-digit number" do
      assert Parsers.extract_year_from_text("Movie2008HD") == 2008
      assert Parsers.extract_year_from_text("filename1999backup") == 1999
    end

    test "prioritizes bracketed formats over standalone numbers" do
      # Should prefer (2008) over 1234
      assert Parsers.extract_year_from_text("Movie.1234.Name.(2008).mkv") == 2008
      # Should prefer [2005] over 9999
      assert Parsers.extract_year_from_text("Show.9999.[2005].Complete") == 2005
    end

    test "handles boundary years correctly" do
      assert Parsers.extract_year_from_text("Old Movie (1950)") == 1950
      assert Parsers.extract_year_from_text("Future Film (2030)") == 2030
    end

    test "rejects years outside valid range" do
      assert Parsers.extract_year_from_text("Too Old (1949)") == nil
      assert Parsers.extract_year_from_text("Too Future (2031)") == nil
      assert Parsers.extract_year_from_text("Way Old (1800)") == nil
    end

    test "handles empty and nil inputs" do
      assert Parsers.extract_year_from_text(nil) == nil
      assert Parsers.extract_year_from_text("") == nil
    end

    test "handles strings without years" do
      assert Parsers.extract_year_from_text("No numbers here") == nil
      assert Parsers.extract_year_from_text("Only three 123 digits") == nil
      assert Parsers.extract_year_from_text("Five 12345 digits") == nil
    end

    test "handles real-world examples" do
      examples = [
        {"The.Shawshank.Redemption.1994.1080p.BluRay.x264", 1994},
        {"Inception (2010) [1080p] BluRay", 2010},
        {"Breaking.Bad.S01E01.2008.HDTV.x264", 2008},
        {"Game of Thrones S01 (2011) Complete", 2011},
        {"The Matrix [1999] Remastered Edition", 1999}
      ]

      for {filename, expected_year} <- examples do
        assert Parsers.extract_year_from_text(filename) == expected_year,
               "Failed to extract #{expected_year} from: #{filename}"
      end
    end

    test "handles edge cases with non-ASCII characters" do
      assert Parsers.extract_year_from_text("Mövie (2008) HD") == 2008
      assert Parsers.extract_year_from_text("Café [2010] Film") == 2010
    end
  end
end

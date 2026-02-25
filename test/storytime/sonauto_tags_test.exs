defmodule Storytime.SonautoTagsTest do
  use ExUnit.Case, async: true

  alias Storytime.SonautoTags

  test "loads v3 tag list from bundled source" do
    tags = SonautoTags.all()

    assert is_list(tags)
    assert length(tags) > 1000
    assert "children" in tags
    assert "instrumental" in tags
  end

  test "normalize_tags keeps only known v3 tags" do
    assert ["ambient", "jazz"] == SonautoTags.normalize_tags("Ambient, JAZZ, fake-tag")
    assert [] == SonautoTags.normalize_tags("fake-tag-only")
  end
end

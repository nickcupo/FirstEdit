"""What the studio's "Where this shoot lives" panel is allowed to say.

    .venv/bin/python -m pytest tests/test_studio_panel.py -q

Every line of it is a claim about where a photograph is, and every claim pinned
below was wrong once. A glyph that over-promises is worse than no glyph, because
the glyph is what gets read at a glance and the sentence beside it is what gets
read afterwards, so the marks are pinned here as well as the words. The last two
are about the endpoint underneath: what it takes to authorise something
destructive, and what the bar over it is allowed to say while it runs.

Nothing in here reads or writes ~/photos. Every fixture is built under pytest's
own tmp_path, and the archive is pointed at a folder inside it.
"""
from __future__ import annotations

import json
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import archive  # noqa: E402
import common  # noqa: E402
import studio  # noqa: E402


def _elsewhere(tmp_path, monkeypatch) -> None:
    """Point every root at the tmp tree. studio.storage() reads library.json
    and the free space of ROOT, and archive.retention() reads library.json
    again, so without this the panel under test would be answering partly out
    of his real library."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud" / "Photo Pipeline Archive")
    monkeypatch.setattr(archive, "ICLOUD", tmp_path / "icloud")
    monkeypatch.setattr(archive, "ROOT", tmp_path)
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    (tmp_path / "icloud").mkdir(exist_ok=True)


def _shoot(base: Path, name: str = "2026-01-01-gym", flat: bool = False) -> Path:
    shoot = base / "shoots" / name
    (shoot if flat else shoot / "raw").mkdir(parents=True)
    if not flat:
        (shoot / "cull").mkdir()
    (shoot / "shoot.json").write_text(json.dumps({"finished": "2020-01-01"}))
    return shoot


def _frame(shoot: Path, name: str, up: bool, here: bool = True) -> dict:
    """One frame, and its entry as archive.json would record it."""
    raw, _ = archive.parts(shoot)
    body = name.encode() * 512
    if here:
        (raw / name).write_bytes(body)
    rec = {"bytes": len(body), "sha256": archive.sha256(raw / name) if here else "", "at": "2020-01-01T00:00:00Z"}
    if up:
        d = archive.dest_for(shoot, name)
        d.parent.mkdir(parents=True, exist_ok=True)
        d.write_bytes(body)
    return rec


def _manifest(shoot: Path, frames: dict) -> None:
    (shoot / "decisions").mkdir(parents=True, exist_ok=True)
    (shoot / "decisions" / "archive.json").write_text(json.dumps({"shoot": shoot.name, "frames": frames}))


def test_a_job_leaves_no_folder_behind_on_a_flat_shoot(tmp_path):
    """ducksAndDeadlifts is 98 loose ARWs with no raw/ and no cull folder.
    Jobs.start mkdirs the log's parent, so asking one of these buttons a
    question created `_cull` in the shoot."""
    flat = studio.Shoot(_shoot(tmp_path, "flat", flat=True))
    assert studio._job_log(flat) == flat.folder / "studio.log"
    assert studio._plan_log(flat) == flat.folder / "storage-plan.log"
    assert not flat.cull.exists()

    deep = studio.Shoot(_shoot(tmp_path, "deep"))
    assert studio._job_log(deep) == deep.cull / "studio.log"
    assert studio._plan_log(deep) == deep.cull / "storage-plan.log"


def test_a_partly_pushed_shoot_does_not_draw_two_filled_cells(tmp_path, monkeypatch):
    """Two filled cells mean bytes on both disks. Three of five pushed is not
    that, however honest the phrase beside it is."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {}
    for i in range(5):
        name = f"TSC0{i}.ARW"
        rec = _frame(shoot, name, up=i < 3)
        if i < 3:
            man[name] = rec
    _manifest(shoot, man)
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["phrase"] == "3 of 5 in iCloud"
    assert home["cells"] == ["full", "some"]


def test_a_fully_archived_shoot_still_draws_two_filled_cells(tmp_path, monkeypatch):
    """The other half of the rule: 2026-09-16 has 1,157 frames on both disks
    and must keep saying so."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(4)}
    _manifest(shoot, man)
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["full", "full"]
    assert home["phrase"] == "in iCloud too"
    assert home["bad"] is False


def test_a_shoot_row_carries_what_it_holds_on_this_disk(tmp_path, monkeypatch):
    """The library's Storage page puts this before the phrase and sorts by it,
    so the shoot to clear first is the one at the top: the same sum as the
    panel's "... here"."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(4)}
    _manifest(shoot, man)
    home = studio._stor_home(studio.Shoot(shoot))
    here = archive.summarise(archive.status(shoot))["bytes_here"]
    assert home["bytes_here"] == here == 4 * len(b"TSC00.ARW" * 512)
    assert home["bytes_here_text"] == common.human(here)


def test_a_frame_that_was_never_archived_is_not_called_missing(tmp_path, monkeypatch):
    """A name in the shoot with no blocks behind it and nothing recorded. It
    fell through to "missing", and the panel said "recorded as archived and NOT
    FOUND in iCloud" about a frame sitting in raw/ that was never pushed."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _frame(shoot, "TSC00.ARW", up=False)
    raw, _ = archive.parts(shoot)
    with open(raw / "TSC01.ARW", "wb") as fh:      # size without blocks
        fh.truncate(1 << 20)
    assert studio._state("none", "none") == "unreadable"
    rows, agg = studio._stor_rows(studio.Shoot(shoot))
    assert agg["counts"]["unreadable"] == 1 and agg["counts"]["missing"] == 0
    row = next(r for r in rows if r["name"] == "TSC01.ARW")
    assert "never archived" in row["words"] and "recorded as archived" not in row["words"]


def test_the_panel_says_which_missing_frames_can_still_be_rebuilt():
    """"Nothing here can rebuild them." was hung on the whole missing count. A
    frame missing from iCloud whose local original is still in raw/ has lost a
    spare, not a photograph."""
    sm = {"frames": 6, "here": 2, "up": 0, "up_evicted": 0, "bytes_here": 8192, "bytes_up": 0}
    counts = dict.fromkeys(studio.STOR_BAR, 0)
    counts["missing"] = 6
    line = studio._stor_line(sm, counts, lost=4)
    assert "2 still have the original in this shoot" in line
    assert "nothing here can rebuild the other 4" in line
    # And with nothing lost, it must not say it at all.
    assert "rebuild" not in studio._stor_line(sm, counts, lost=0)


def test_a_legend_line_claims_nothing_the_group_disagrees_on(tmp_path, monkeypatch):
    """A legend line stands for a group. Six frames missing from iCloud, two of
    them still in raw/, drew "and not on this Mac either" across all six."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {}
    for i in range(6):
        name = f"TSC0{i}.ARW"
        man[name] = _frame(shoot, name, up=False, here=i < 2)
    _manifest(shoot, man)
    words = studio.storage(studio.Shoot(shoot))["words"]["missing"]
    assert words == "recorded as archived and not found in iCloud"
    rows = studio._stor_rows(studio.Shoot(shoot))[0]
    assert "the original is still on this Mac" in next(r for r in rows if r["name"] == "TSC00.ARW")["words"]
    assert "not on this Mac either" in next(r for r in rows if r["name"] == "TSC05.ARW")["words"]


def test_the_bar_moves_for_a_stage_this_page_has_never_heard_of(tmp_path):
    """archive.py and reclaim.py name their own stages, and today every name
    they print is the verb of the job. A name outside that weighed 0, which
    held the bar at nothing for the whole job."""
    def frac(kind: str, text: str) -> dict:
        log = tmp_path / f"{kind}.log"
        log.write_text(text)
        j = studio.Jobs()
        j.log, j.kind, j.started = log, kind, 1.0
        return j.status()

    known = frac("stor-drop", "$ x\n@@ drop 400 1157\n")
    assert known["fraction"] == 0.346 and known["stage"] == "drop"
    unknown = frac("stor-drop", "$ x\n@@ hash 400 1157\n")
    assert unknown["fraction"] == 0.346 and unknown["stage"] == "hash"
    # And the scrape is still there for a stretch that prints no mark at all.
    scraped = frac("stor-push", "$ x\n    40/1157 copied and verified\n")
    assert scraped["stage"] == "push" and scraped["fraction"] > 0


def test_a_bare_post_to_apply_is_refused_before_anything_is_read(tmp_path, monkeypatch):
    """The endpoint is documented to answer a POST with no token with a 400.
    That check sat under read_plan, which answers "that list was drawn for
    something else" whenever there is no plan on disk - so the 400 was
    reachable only when a matching plan happened to be lying there."""
    _elsewhere(tmp_path, monkeypatch)
    _shoot(tmp_path)
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(), raising=False)
    srv = studio.Server(("127.0.0.1", 0), studio.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{srv.server_address[1]}/api/storage/apply"
        body = json.dumps({"name": "2026-01-01-gym", "what": "drop"}).encode()
        req = urllib.request.Request(url, data=body, headers={"content-type": "application/json",
                                                              "x-studio-key": srv.key})
        try:
            urllib.request.urlopen(req)
            raise AssertionError("a bare POST to apply was accepted")
        except urllib.error.HTTPError as e:
            assert e.code == 400
            assert "Nothing was confirmed" in json.loads(e.read())["error"]
    finally:
        srv.shutdown()
        srv.server_close()


def test_a_shoot_with_holes_does_not_draw_a_filled_cell_for_this_mac(tmp_path, monkeypatch):
    """The front page's left cell is the same promise as every other filled
    mark: the bytes are on that disk now. It was drawn from a count, so one
    surviving original spoke for a shoot whose others had been dropped."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {}
    for i in range(6):
        name = f"TSC0{i}.ARW"
        man[name] = _frame(shoot, name, up=False, here=i < 2)
    _manifest(shoot, man)
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["some", "gone"] and home["lost"] == 4
    # And the other half: a hole in iCloud does not empty the disk, so a shoot
    # whose originals are all still here keeps the filled mark.
    other = _shoot(tmp_path, "2026-01-02-gym")
    man = {f"TSC1{i}.ARW": _frame(other, f"TSC1{i}.ARW", up=False) for i in range(4)}
    _manifest(other, man)
    assert studio._stor_home(studio.Shoot(other))["cells"] == ["full", "gone"]


def test_a_legend_line_does_not_evict_every_icloud_copy_of_a_group(tmp_path, monkeypatch):
    """Optimise Mac Storage evicts some of a shoot's archive copies and not
    others. One evicted copy out of five made the legend say the singular
    sentence over all five; the count belongs to the panel's own line."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)}
    _manifest(shoot, man)
    evicted = archive.dest_for(shoot, "TSC00.ARW")
    real = archive.local
    monkeypatch.setattr(archive, "local", lambda p: False if Path(p) == evicted else real(p))
    j = studio.storage(studio.Shoot(shoot))
    assert j["states"]["both"] == 5
    assert j["words"]["both"] == ("two copies; some of the iCloud ones would download "
                                  "before they could be checked")
    assert "1 of the iCloud copies" in j["line"]


def _evict(monkeypatch, paths: set) -> None:
    """Make those files answer like a file macOS has evicted: the name is
    there, stat reports the real size, and there are no blocks behind it.
    archive.local is the only thing in this pipeline that can tell."""
    real = archive.local
    monkeypatch.setattr(archive, "local", lambda p: False if Path(p) in paths else real(p))


def test_the_front_page_counts_the_evicted_icloud_copies(tmp_path, monkeypatch):
    """"two copies, one evicted" was printed for any number of them, over
    `■ ▢` - the hollow right cell denying the bytes of every archive copy that
    still has them. Optimise Mac Storage has evicted 405 of the 1,847 files in
    his Drive; one is the number this is almost never."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _manifest(shoot, {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)})
    _evict(monkeypatch, {archive.dest_for(shoot, f"TSC0{i}.ARW") for i in range(2)})
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["phrase"] == "two copies; 2 of 5 evicted in iCloud"
    assert home["cells"] == ["full", "some"]
    assert home["bad"] is False


def test_a_shoot_whose_icloud_copies_are_all_evicted_still_draws_the_hollow_cell(tmp_path, monkeypatch):
    """The other half: when the group does agree, the mark that says so stays."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _manifest(shoot, {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)})
    _evict(monkeypatch, {archive.dest_for(shoot, f"TSC0{i}.ARW") for i in range(5)})
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["full", "hollow"]
    assert home["phrase"] == "two copies; 5 of 5 evicted in iCloud"


def test_one_evicted_original_does_not_empty_the_whole_shoot(tmp_path, monkeypatch):
    """`⋅ ▢` and "in iCloud, evicted" were drawn for ANY frame in an evicted
    state: one local original of five, with four whose bytes are on this disk,
    read as a shoot with nothing here at all - which argues for bringing down
    a shoot that never left."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _manifest(shoot, {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)})
    raw, _ = archive.parts(shoot)
    _evict(monkeypatch, {raw / "TSC00.ARW"})
    monkeypatch.setattr(archive, "is_dataless", lambda p: Path(p) == raw / "TSC00.ARW")
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["some", "full"]
    assert home["phrase"] == "1 of 5 evicted"


def test_a_shoot_that_was_never_archived_does_not_say_it_is_in_icloud(tmp_path, monkeypatch):
    """"in iCloud, evicted" was the phrase for a whole shoot in EITHER evicted
    state, and the two are opposite sides. Five originals macOS had evicted out
    of his Drive, never pushed anywhere, read on the front page as archived:
    over a right-hand cell saying there is no copy there, and over the shoot's
    own panel saying "nothing in iCloud"."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    for i in range(5):
        _frame(shoot, f"TSC0{i}.ARW", up=False)
    raw, _ = archive.parts(shoot)
    gone = {raw / f"TSC0{i}.ARW" for i in range(5)}
    _evict(monkeypatch, gone)
    monkeypatch.setattr(archive, "is_dataless", lambda p: Path(p) in gone)
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["hollow", "none"]
    assert home["phrase"] == "evicted on this Mac"
    assert "iCloud" not in home["phrase"]


def test_a_shoot_whose_only_copy_is_an_evicted_icloud_one_still_says_so(tmp_path, monkeypatch):
    """The other side, which is what that phrase was written for: nothing on
    this Mac, and the copy up there with no bytes behind it."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)}
    raw, _ = archive.parts(shoot)
    for i in range(5):
        (raw / f"TSC0{i}.ARW").unlink()
    _manifest(shoot, man)
    _evict(monkeypatch, {archive.dest_for(shoot, f"TSC0{i}.ARW") for i in range(5)})
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["cells"] == ["none", "hollow"]
    assert home["phrase"] == "in iCloud, evicted"


def test_a_fully_archived_shoot_says_its_local_originals_are_gone(tmp_path, monkeypatch):
    """"10 of 10 in iCloud" is true of a shoot with two whole copies of every
    frame and of a shoot four photographs down to one copy each, and it was
    printed for both. The front page is where he finds out that they went."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    man = {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(10)}
    raw, _ = archive.parts(shoot)
    for i in range(4):
        (raw / f"TSC0{i}.ARW").unlink()
    _manifest(shoot, man)
    home = studio._stor_home(studio.Shoot(shoot))
    assert home["phrase"] == "in iCloud; 4 of 10 dropped from this Mac"
    assert home["cells"] == ["some", "full"]
    assert home["bad"] is False


def test_the_drop_button_is_offered_on_what_drop_can_actually_take(tmp_path, monkeypatch):
    """"Remove the local RAWs" was offered on `up === frames`, which counts
    NAMES in iCloud. On a fully pushed shoot whose archive copies macOS has
    since evicted, the dry run then refuses every frame: "the iCloud copy is
    evicted; it must come down to be checked"."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _manifest(shoot, {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)})
    _evict(monkeypatch, {archive.dest_for(shoot, f"TSC0{i}.ARW") for i in range(5)})
    a = studio.storage(studio.Shoot(shoot))["archive"]
    assert a["up"] == a["frames"] == 5          # the old test, which offered the button
    assert a["droppable"] == 0 and a["drop_evicted"] == 5
    assert a["droppable_text"] == "0 B"


def test_the_drop_button_counts_only_the_frames_with_a_readable_copy_up_there(tmp_path, monkeypatch):
    """And the number beside it is those frames' bytes, not the whole shoot's:
    the figure on that button is what would actually come back."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    _manifest(shoot, {f"TSC0{i}.ARW": _frame(shoot, f"TSC0{i}.ARW", up=True) for i in range(5)})
    _evict(monkeypatch, {archive.dest_for(shoot, "TSC00.ARW"), archive.dest_for(shoot, "TSC01.ARW")})
    a = studio.storage(studio.Shoot(shoot))["archive"]
    assert a["droppable"] == 3 and a["drop_evicted"] == 2
    raw, _ = archive.parts(shoot)
    want = sum((raw / f"TSC0{i}.ARW").stat().st_size for i in (2, 3, 4))
    from common import human
    assert a["droppable_text"] == human(want)


def test_the_line_speaks_both_alarms_when_a_shoot_has_both():
    """The panel has one sentence and two alarms, and the second was an
    `elif`: a shoot with one hole in iCloud and five frames with no bytes
    behind their names said the first and not a word of the second."""
    sm = {"frames": 6, "here": 0, "up": 0, "up_evicted": 0, "bytes_here": 0, "bytes_up": 0}
    counts = dict.fromkeys(studio.STOR_BAR, 0)
    counts["missing"], counts["unreadable"] = 1, 5
    line = studio._stor_line(sm, counts, lost=1)
    assert "nothing here can rebuild it." in line
    assert "5 frames have no bytes behind their name and were never archived." in line
    # And on its own it is still the whole verdict, not an afterthought.
    counts["missing"] = 0
    assert studio._stor_line(sm, counts, lost=0).endswith(
        "· 5 frames have no bytes behind their name and were never archived.")


def test_the_panel_says_what_new_shoots_are_given(tmp_path, monkeypatch):
    """"Use this for new shoots too" came back unticked on every visit, even
    on a shoot whose number was the library's, because the panel was never
    told the library's number. It is told now, and only told: nothing here
    writes it."""
    _elsewhere(tmp_path, monkeypatch)
    shoot = _shoot(tmp_path)
    assert studio.storage(studio.Shoot(shoot))["retain"]["library_days"] is None
    (tmp_path / "library.json").write_text(json.dumps({"retain_days": 90}))
    r = studio.storage(studio.Shoot(shoot))["retain"]
    assert (r["library_days"], r["days"], r["source"]) == (90, 90, "library")

"""A packed burst carries its kept frame as its Finder icon, so an evicted
.roll in iCloud still shows the photograph (pipeline/rollicon.py)."""
import shutil
import struct
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline"))
import rollicon  # noqa: E402

cv2 = pytest.importorskip("cv2")
FIXTURE = ROOT / "app/Tests/PipelineKitTests/Fixtures/Roll"


def _roll(tmp_path: Path) -> Path:
    p = tmp_path / "burst-0.roll"
    shutil.copyfile(FIXTURE / "burst-0.roll", p)
    return p


def _icon_pngs(p: Path) -> dict[str, np.ndarray]:
    """The images in the icns the resource fork holds as 'icns' -16455."""
    fork = rollicon._get(p, rollicon.RESOURCE_FORK)
    data_at, map_at = struct.unpack_from(">II", fork, 0)
    type_list = map_at + struct.unpack_from(">H", fork, map_at + 24)[0]
    assert fork[type_list + 2:type_list + 6] == b"icns"
    ref = type_list + struct.unpack_from(">H", fork, type_list + 8)[0]
    rid, _, off = struct.unpack_from(">hHI", fork, ref)
    assert rid == rollicon.CUSTOM_ICON_ID
    at = data_at + (off & 0xFFFFFF)
    (n,) = struct.unpack_from(">I", fork, at)
    icns = fork[at + 4:at + 4 + n]
    assert icns[:4] == b"icns" and struct.unpack_from(">I", icns, 4)[0] == len(icns)
    out, i = {}, 8
    while i < len(icns):
        kind, size = icns[i:i + 4].decode(), struct.unpack_from(">I", icns, i + 4)[0]
        out[kind] = cv2.imdecode(np.frombuffer(icns[i + 8:i + size], np.uint8), cv2.IMREAD_UNCHANGED)
        i += size
    return out


def test_the_kept_frames_own_jpeg_and_orientation_are_read_from_the_roll():
    jpeg, orientation = rollicon.keeper_preview(FIXTURE / "burst-0.roll")
    assert jpeg == (FIXTURE / "keeper.jpg").read_bytes()
    assert orientation == 6
    assert rollicon.keeper_preview_of((FIXTURE / "burst-0.roll").read_bytes()) == (jpeg, orientation)


def test_the_icon_is_the_kept_frame_upright_and_the_file_is_unchanged(tmp_path):
    p = _roll(tmp_path)
    before = p.read_bytes()
    assert not rollicon.has_icon(p)
    assert rollicon.give_icon(p)
    assert rollicon.has_icon(p)
    assert p.read_bytes() == before, "metadata only: the bytes, and so the checksum, are as packed"
    pngs = _icon_pngs(p)
    assert sorted(pngs) == ["ic07", "ic08", "ic09"]
    for kind, side in rollicon.SIZES:
        img = pngs[kind]
        assert img.shape == (side, side, 4)
        ys, xs = np.nonzero(img[:, :, 3])
        assert np.ptp(ys) > np.ptp(xs), "Orientation 6: the picture stands upright, taller than wide"


def test_finders_other_flags_are_kept(tmp_path):
    p = _roll(tmp_path)
    info = bytearray(32)
    info[8] = 0x0E                                       # a label colour, say
    rollicon._set(p, rollicon.FINDER_INFO, bytes(info))
    assert rollicon.give_icon(p)
    flags = struct.unpack_from(">H", rollicon._get(p, rollicon.FINDER_INFO), 8)[0]
    assert flags == 0x0E00 | rollicon.HAS_CUSTOM_ICON


def test_anything_else_gets_no_icon_and_no_error(tmp_path):
    p = tmp_path / "burst-9.roll"
    p.write_bytes(b"not a packed burst")
    assert rollicon.give_icon(p) is False
    assert not rollicon.has_icon(p)
    cut = tmp_path / "burst-8.roll"
    cut.write_bytes((FIXTURE / "burst-0.roll").read_bytes()[:400])
    assert rollicon.give_icon(cut) is False


def test_a_file_that_is_not_downloaded_is_never_opened(tmp_path, monkeypatch):
    p = _roll(tmp_path)
    monkeypatch.setattr(rollicon, "dataless", lambda q: True)
    monkeypatch.setattr(rollicon, "keeper_preview", lambda q: pytest.fail("opened a dataless file"))
    assert rollicon.give_icon(p) is False
    assert rollicon.main([str(tmp_path)]) == 0


def test_the_command_gives_each_roll_in_a_folder_one_once(tmp_path, capsys):
    _roll(tmp_path)
    shutil.copyfile(FIXTURE / "burst-0.roll", tmp_path / "burst-1.roll")
    assert rollicon.main([str(tmp_path)]) == 0
    assert "2 given an icon, 0 had one" in capsys.readouterr().out
    assert rollicon.main([str(tmp_path)]) == 0
    assert "0 given an icon, 2 had one" in capsys.readouterr().out

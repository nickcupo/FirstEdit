"""Where a Base comes from, and what counts as a decision of his.

    .venv/bin/python -m pytest tests/test_base.py -q

Two gates stand between a sidecar and the learner, and they catch different
things. The echo gate (taste.decided) drops an Overrides key that merely
repeats its OWN frame's Base, which is PhotoLab materialising the active
value when a frame is opened. The paste guard (taste._written_by_pipeline)
drops a value the pipeline wrote into any Base in the folder, which is what
a PhotoLab paste carries from frame to frame. Neither subsumes the other,
and the pipeline learned its own output back for want of both.

is_hand is a third thing entirely -- the write guard that stops --force
overwriting his sidecars -- and it must not move when the other two change.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import presets  # noqa: E402
import taste  # noqa: E402


def _sidecar(base: str, overrides: str) -> str:
    return ("Sidecar = {\n\tItems = {\n\t\t{\n\t\t\tSettings = {\n"
            f"\t\t\t\tBase = {{\n{base}\t\t\t\t}},\n"
            f"\t\t\t\tOverrides = {{\n{overrides}\t\t\t\t}},\n"
            "\t\t\t},\n\t\t},\n\t},\n}\n")


def test_an_override_that_repeats_its_own_base_is_not_a_decision():
    """The finding this whole change rests on. Audited over every hand
    sidecar under the shoots tree: ColorRenderingType echoes its own Base 323
    times and differs once; ChannelMixerActive and ChannelMixerRed echo 323
    times and differ never. Those three were the action venue's entire
    learned 'look'."""
    text = _sidecar('\t\t\t\t\tColorRenderingType = "Original",\n\t\t\t\t\tChannelMixerRed = 4,\n',
                    '\t\t\t\t\tColorRenderingType = "Original",\n\t\t\t\t\tChannelMixerRed = 4,\n')
    assert taste.decided(taste.flat_block(text, "Overrides"), taste.flat_block(text, "Base")) == {}
    # and a real correction survives it: NoiseRemovalMethod differs from its
    # Base on 202 sidecars and echoes it on none
    text = _sidecar('\t\t\t\t\tNoiseRemovalMethod = "standard",\n',
                    '\t\t\t\t\tNoiseRemovalMethod = "DeepRaw2RGBv7",\n')
    assert taste.decided(taste.flat_block(text, "Overrides"), taste.flat_block(text, "Base")) == {
        "NoiseRemovalMethod": '"DeepRaw2RGBv7"'}


def test_photolab_float_reserialisation_still_counts_as_an_echo():
    """PhotoLab writes -8.292 back as -8.2919999999999998, so numbers have to
    compare as numbers or every reopened frame reads as a correction."""
    text = _sidecar("\t\t\t\t\tLightingV3BlackPoint = -8.292,\n",
                    "\t\t\t\t\tLightingV3BlackPoint = -8.2919999999999998,\n")
    assert taste.decided(taste.flat_block(text, "Overrides"), taste.flat_block(text, "Base")) == {}


def test_is_hand_is_unchanged_by_the_echo_gate():
    """is_hand guards writes (presets.write_dops, taste; gather promotes on
    the date PhotoLab wrote inside the file, and no longer asks it). A
    sidecar whose Overrides only echo its Base is still HIS file -- he opened
    it -- and --force must still refuse to replace it. Tightening this the
    way the vote was tightened would let --force overwrite his edits."""
    text = _sidecar('\t\t\t\t\tColorRenderingType = "Original",\n',
                    '\t\t\t\t\tColorRenderingType = "Original",\n')
    ov = taste._block(text, "Overrides")
    assert taste.decided(taste.flat_block(text, "Overrides"), taste.flat_block(text, "Base")) == {}
    assert taste.is_hand(ov) is True


def test_the_paste_guard_catches_what_the_echo_gate_cannot():
    """A paste copies the SOURCE frame's whole state into the receiving
    frame's Overrides while the receiving frame's Base keeps its own
    measurement, so the pasted value differs from its own Base and passes the
    echo gate. Measured on the action venue: LightingV3BlackPoint is -8.292
    in the Overrides of 322 frames and differs from its own Base on 176 of
    them. Only a folder-wide test of what the pipeline wrote catches those."""
    # differs from its own Base, so decided() keeps it
    text = _sidecar("\t\t\t\t\tLightingV3BlackPoint = -3.1,\n",
                    "\t\t\t\t\tLightingV3BlackPoint = -8.2919999999999998,\n")
    assert "LightingV3BlackPoint" in taste.decided(taste.flat_block(text, "Overrides"), taste.flat_block(text, "Base"))
    # but the pipeline wrote that value into another frame's Base in the folder
    assert taste._written_by_pipeline("-8.2919999999999998", {"-8.292"}) is True
    assert taste._written_by_pipeline("-3.1", {"-8.292"}) is False


def test_the_base_is_what_dxo_ships(tmp_path, monkeypatch):
    """Every value in a built Base is DxO's own, bar the departures that
    survive the evidence test. Twelve keys used to depart from the preset his
    sidecars name, eleven of them unsourced.

    The one departure is the noise method, and it is a departure only because
    a starting edit that has been learned from finished work says so
    (taste.travelling). With nothing learned yet - which is what a checkout
    and a fresh install now start from - there is no departure at all."""
    nat = presets.shipped(presets.NATURAL)
    assert nat["ColorRenderingType"] == "DxONatural"
    assert nat["ProfileGainMapIntensity"] == 100          # the pipeline hard-coded 0
    assert nat["LightingV3BlackPoint"] == 0               # the pipeline hard-coded -7.5
    assert nat["ColorGradingActive"] is False             # the pipeline hard-coded true

    def departures() -> dict:
        built = presets.preset_base_dict()
        assert not set(built) - set(nat) - set(presets.dxo_lens())
        return {k: (nat[k], built[k]) for k in nat if k in built and nat[k] != built[k]}

    monkeypatch.setenv("PHOTO_TASTE", str(taste.SEED))
    taste._CACHE = None
    assert departures() == {}
    learned = tmp_path / "edit.json"
    learned.write_text(json.dumps({"venues": {"shoots": {"abc": {"finals": {"NoiseRemovalMethod": "DeepRaw2RGBv7"}}}}}))
    monkeypatch.setenv("PHOTO_TASTE", str(learned))
    taste._CACHE = None
    assert set(departures()) == {"NoiseRemovalMethod"}
    taste._CACHE = None


def test_dxo_ships_neutral_color_and_the_vocabulary_admits_it():
    """DxO's own string table calls Fidelity "Neutral color" and Original
    "DxO camera profile". check_dop refused Fidelity while his folder held
    only three rendering names, which would have stopped a probe writing the
    one rendering DxO itself calls neutral.

    The vocabulary is read out of an installed PhotoLab, so on a machine
    without one this can only be skipped. It said nothing about that and
    failed instead, which reads as the rule being broken."""
    v = taste.dxo_vocab()
    if not v.get("ColorRenderingType"):
        pytest.skip("no DxO PhotoLab on this machine, so its own string table cannot be read")
    assert "Fidelity" in v["ColorRenderingType"]
    assert len(v["WhiteBalanceRawPreset"]) == 16
    assert taste.check_dop('\tColorRenderingType = "Fidelity",\n') == []
    assert taste.check_dop('\tColorRenderingType = "Splendid",\n')


@pytest.mark.parametrize("text, expect", [
    ('\tLocalWhiteBalanceRawTemperature = 2412.48,\n', "local white balance"),
    ('\tWhiteBalanceRawTemperature = 4320.0,\n', "eyedropper"),
    ('\tColorGradingParams_Master = {\n\t\tHue = 315.18,\n\t\tSat = 4.99,\n\t\tLum = 0,\n\t},\n', "measured gain"),
])
def test_check_dop_refuses_what_cannot_be_checked(text, expect):
    """A number reaches a sidecar only if DxO produced it or DxO ships it.
    A kelvin solved in camera space is neither: DxO's scale is not the
    camera's, and the one published method that solves an illuminant from
    skin is wrong by 4-12% on its own controlled test set."""
    bad = taste.check_dop(text)
    assert any(expect in b for b in bad), bad


def test_the_channel_mixer_is_remarked_on_not_refused():
    """His own finished sidecars carry the channel mixer on every frame of one
    venue. A validator that refuses those refuses his delivered work, and it
    broke the tool that carries one of his edits across a burst. Whether the
    mixer does anything on a colour frame is a remark to make, not a veto."""
    text = '\tChannelMixerActive = true,\n\tColorRenderingType = "DxOPortraitV3",\n'
    assert taste.check_dop(text) == []
    assert taste.check_structure(text) == []
    assert any("monochrome" in r for r in taste.check_remarks(text))
    # and it says nothing about a monochrome frame, where the tool belongs
    assert taste.check_remarks('\tChannelMixerActive = true,\n\tColorRenderingType = "DefaultBW",\n') == []


def test_a_temperature_he_measured_with_the_eyedropper_is_allowed():
    """His own eyedropper reading IS DxO's output, in DxO's units, so it is
    checkable and it is written. The rule bars a computed kelvin, not a
    measured one."""
    known = taste.measured_kelvins()["WhiteBalanceRawTemperature"]
    if not known:
        pytest.skip("no eyedropper reading in the model to check against")
    k = sorted(known)[0]
    assert taste.check_dop(f"\tWhiteBalanceRawTemperature = {k},\n") == []


def test_the_band_is_published_and_the_same_on_every_venue():
    """Nothing in the published work licenses a band per venue: every source
    that addresses lightness conditions it on skin type, not on the room."""
    assert presets._band(49.8, (36.4, 65.9)) == (presets.PUBLISHED.FACE_L_LO, presets.PUBLISHED.FACE_L_HI)
    assert presets._band(33.7, None) == presets._band(49.8, (36.4, 65.9))


def test_a_calibration_is_stamped_with_the_base_it_was_measured_under():
    """The venue's render gain is the lift of DxO's render under the Base the
    pipeline wrote, so a Base change invalidates it and nothing else would
    notice."""
    a = presets.base_id(presets.preset_base_dict())
    assert a == presets.base_id(presets.preset_base_dict())
    assert a != presets.base_id(presets.preset_base_dict(settings={"ColorRenderingType": "Fidelity"}))


# ------------------------------------------------- what the fixer had to fix
#
# Every test below stands for a way the pipeline was reading its own output
# back, or writing a number it could not account for, or telling him a number
# that was not the one it used.


@pytest.mark.parametrize("installed", [True, False])
def test_dxos_own_shipped_temperature_is_not_a_solved_kelvin(monkeypatch, installed):
    """The guard that stopped every build. DxO's own "1 - DxO Style -
    Natural" carries WhiteBalanceRawTemperature 5400, so every full preset the
    pipeline writes carries it, and a guard that knew only his eyedropper
    refused DxO's own default: `pl presets --dop` died on its first frame and
    all six probe arms with it. A number DxO ships is checkable by
    construction."""
    if not installed:
        import glob
        original = glob.glob
        monkeypatch.setattr(glob, "glob", lambda pattern, **kw: [] if pattern.startswith("/Applications/DXOPhotoLab")
                            else original(pattern, **kw))
        monkeypatch.setattr(presets, "_SHIPPED", {})
        monkeypatch.setattr(presets, "_DXO_LENS", None)
        monkeypatch.setattr(taste, "_DXO_KELVINS", None)
        monkeypatch.setattr(taste, "_DXO_VOCAB", None)
        monkeypatch.setattr(taste, "_CACHE", None)
        monkeypatch.setenv("PHOTO_TASTE", str(taste.SEED))
    assert 5400.0 in taste.dxo_kelvins()["WhiteBalanceRawTemperature"]
    assert taste.check_dop(presets.build_preset("x", {})) == []
    assert taste.check_dop(presets.build_preset("x", {}, base_name="1 - DxO Style - Natural")) == []
    if not installed:
        assert presets.preset_base_dict()["WhiteBalanceRawTemperature"] == 5400
        assert taste.check_dop("\tWhiteBalanceRawTemperature = 3800,\n"), "the template is not a measured neutral"
    # and a number from neither source is still refused
    bad = taste.check_dop("\tWhiteBalanceRawTemperature = 4584.4,\n")
    assert any("eyedropper" in b for b in bad), bad


def test_no_solver_is_left_to_import():
    """Three routes to a temperature have been withdrawn: a kelvin from a
    skin-hue delta, one from a camera-scale solver, and one from a grey-world
    estimate of each frame's own light rescaled by a body ratio. The last of
    them wrote 3166 to 5250 K across one room's 155 delivered frames and
    check_dop refused 152 of them, so the build stopped on the first. Nothing
    in the tree may reach for it again."""
    assert not hasattr(taste, "light_of")
    assert not hasattr(taste, "dxo_as_shot")
    assert not hasattr(taste, "DXO_KELVIN_SCALE")
    assert not (Path(taste.__file__).parent / "cct_solve.py").exists()
    src = (Path(presets.__file__)).read_text()
    assert "light_xyz" not in src


def test_the_delivered_white_balance_carried_forward_is_only_his():
    """Same loop, one function down. write_dops carried "the white balance a
    frame was delivered with" from any sidecar beside an exported frame,
    Base included -- and on his tree that Base is the pipeline's, so it
    handed itself ManualTemp with no temperature beside it. Measured on his
    155 delivered frames: 155 carried before (all AsShot, all the pipeline's
    own Base), 0 now, with his one real Cloudy decision on another venue
    surviving."""
    his = _sidecar('\t\t\t\t\tWhiteBalanceRawPreset = "Fluo",\n',
                   '\t\t\t\t\tWhiteBalanceRawPreset = "AsShot",\n')
    ours = _sidecar('\t\t\t\t\tWhiteBalanceRawPreset = "ManualTemp",\n', "")
    dec = lambda t: taste.decided(taste.flat_block(t, "Overrides"), taste.flat_block(t, "Base"))  # noqa: E731
    assert dec(his).get("WhiteBalanceRawPreset") == '"AsShot"'
    assert "WhiteBalanceRawPreset" not in dec(ours)


def test_a_base_stamp_names_a_starting_point_not_a_frame():
    """base_id hashed Exposure* and WhiteBalance*, which are per-FRAME
    decisions written into the Base: 21 distinct stamps over 200 sidecars of
    one venue, so the venue's measured render lift was discarded for want of
    a match. On TSC04583 that is the difference between a face rendering at
    L* 66.4 (inside the band, left alone) and 70.5 (above it, pulled)."""
    base = dict(presets.preset_base_dict())
    a = presets.base_id(base)
    assert a == presets.base_id({**base, "ExposureBias": -0.24, "WhiteBalanceRawPreset": "Fluo"})
    assert a != presets.base_id({**base, "ColorRenderingType": "Fidelity"})


def test_the_note_gives_the_shortfall_and_not_the_clamp():
    """The EV is clamped to one stop before it is written, and the note used
    to print the clamped figure: "+1.00 EV short" on frames that were +2.24,
    +2.23 and +2.22 short. The clamp is a guard on the slider, not a
    measurement."""
    lin = {"face_Y": 0.01, "clip_any": 0.0, "faces": []}
    _, ev, note = presets.decide_exposure(lin, 50.0, gain=1.3, prefer="Manual")
    want = presets._stops_to_band(lin["face_Y"], presets.PUBLISHED.FACE_L_LO, presets.PUBLISHED.FACE_L_HI, 1.3)
    assert want > 1.0, want
    assert f"{want:+.2f} EV short" in note
    assert ev == 0.0


LOOK = {"ColorRenderingType": "Original", "ChannelMixerRed": 4.0, "NoiseRemovalMethod": "DeepRaw2RGBv7"}


def test_a_learned_rendering_does_not_reach_a_frame(monkeypatch):
    """A rendering is elected by measuring DxO's output, never learned from
    finished edits, so a stored look's own ColorRenderingType is dropped with
    a reason and the rest of the look survives."""
    monkeypatch.setattr(taste, "load", lambda: {"venues": {}})
    keep, dropped = presets.legal_look(LOOK)
    assert keep.get("NoiseRemovalMethod") == "DeepRaw2RGBv7"
    assert any("stored look" in d for d in dropped)
    assert "ColorRenderingType" not in keep
    assert not any(k.startswith("ChannelMixer") for k in keep)


def test_an_elected_rendering_does_reach_a_frame(monkeypatch):
    """The other half, and the one that was never asserted: with no model on
    this machine carrying a render, the old test compared None with None and
    would have passed whether or not an elected rendering could reach a frame
    at all. The probe could run, announce a winner and change nothing."""
    monkeypatch.setattr(taste, "load", lambda: {"render": {"rendering": "Fidelity"}})
    keep, dropped = presets.legal_look(LOOK)
    assert keep["ColorRenderingType"] == "Fidelity"        # the probe's, not the look's
    assert any("stored look" in d for d in dropped)

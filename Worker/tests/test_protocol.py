import io
import json
import struct
from pathlib import Path

import pytest

from miri_worker.protocol import (
    Frame,
    MAX_FRAME_BYTES,
    ProtocolError,
    decode,
    encode,
    json_payload,
    make_frame,
    read_frame,
)


def test_round_trip_json_and_binary():
    json_frame = make_frame("health", "r", {"probe": True}, session_id="s")
    binary_frame = make_frame("audio.chunk", "r2", b"\0\0\0\0", session_id="s", kind="pcmFloat32")
    assert decode(encode(json_frame)) == json_frame
    assert decode(encode(binary_frame)) == binary_frame
    assert json_payload(json_frame) == {"probe": True}


def test_reads_one_framed_message_and_eof():
    frame = make_frame("health", "r")
    source = io.BytesIO(encode(frame))
    assert read_frame(source) == frame
    assert read_frame(source) is None


@pytest.mark.parametrize(
    "frame, message",
    [
        (Frame({"version": 2, "requestID": "r", "kind": "json", "messageType": "health"}), "version"),
        (Frame({"version": 1, "requestID": "", "kind": "json", "messageType": "health"}), "requestID"),
        (Frame({"version": 1, "requestID": "r", "kind": "bytes", "messageType": "health"}), "payload kind"),
    ],
)
def test_rejects_bad_headers(frame, message):
    with pytest.raises(ProtocolError, match=message):
        encode(frame)


def test_rejects_invalid_lengths_and_payloads():
    with pytest.raises(ProtocolError, match="incomplete"):
        decode(b"123")
    with pytest.raises(ProtocolError, match="header length"):
        decode(struct.pack(">II", 4, 8))
    with pytest.raises(ProtocolError, match="JSON payload"):
        json_payload(Frame({"version": 1, "requestID": "r", "kind": "json", "messageType": "x"}, b"[]"))


def test_is_compatible_with_shared_swift_health_fixture():
    fixture_path = Path(__file__).parents[2] / "Tests/MiriIPCTests/Fixtures/health.json"
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    frame = Frame(fixture["header"], json.dumps(fixture["payload"], separators=(",", ":")).encode())
    assert decode(encode(frame)).header == fixture["header"]
    assert json_payload(frame) == {"status": "ok"}

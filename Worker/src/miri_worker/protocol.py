"""Versioned, length-prefixed IPC shared with MiriIPC.

The four-byte outer length includes the four-byte header length, JSON header, and
opaque payload. PCM payloads are little-endian float32 samples.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from typing import BinaryIO, Mapping

VERSION = 1
MAX_FRAME_BYTES = 16 * 1024 * 1024
HEADER_FIELDS = ("version", "requestID", "kind", "messageType")
PAYLOAD_KINDS = frozenset(("json", "pcmFloat32"))


class ProtocolError(ValueError):
    """A malformed or unsupported IPC frame."""


@dataclass(frozen=True, slots=True)
class Frame:
    header: dict[str, object]
    payload: bytes = b""

    @property
    def request_id(self) -> str:
        return str(self.header["requestID"])

    @property
    def session_id(self) -> str | None:
        value = self.header.get("sessionID")
        return str(value) if value is not None else None


def _validate_header(header: Mapping[str, object]) -> None:
    missing = [name for name in HEADER_FIELDS if name not in header]
    if missing:
        raise ProtocolError(f"missing header field: {missing[0]}")
    if header["version"] != VERSION:
        raise ProtocolError("unsupported protocol version")
    if not isinstance(header["requestID"], str) or not header["requestID"]:
        raise ProtocolError("invalid requestID")
    if header.get("sessionID") is not None and (
        not isinstance(header["sessionID"], str) or not header["sessionID"]
    ):
        raise ProtocolError("invalid sessionID")
    if header["kind"] not in PAYLOAD_KINDS:
        raise ProtocolError("unsupported payload kind")
    if not isinstance(header["messageType"], str) or not header["messageType"]:
        raise ProtocolError("invalid messageType")


def encode(frame: Frame) -> bytes:
    _validate_header(frame.header)
    header = json.dumps(frame.header, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    body = struct.pack(">I", len(header)) + header + frame.payload
    if len(body) > MAX_FRAME_BYTES:
        raise ProtocolError("frame too large")
    return struct.pack(">I", len(body)) + body


def decode(data: bytes) -> Frame:
    if len(data) < 8:
        raise ProtocolError("incomplete frame")
    body_len, header_len = struct.unpack(">II", data[:8])
    if body_len > MAX_FRAME_BYTES:
        raise ProtocolError("frame too large")
    if len(data) != body_len + 4:
        raise ProtocolError("invalid frame length")
    if header_len == 0 or header_len > body_len - 4:
        raise ProtocolError("invalid header length")
    try:
        header = json.loads(data[8 : 8 + header_len])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError("invalid JSON header") from error
    if not isinstance(header, dict):
        raise ProtocolError("invalid JSON header")
    _validate_header(header)
    return Frame(header, data[8 + header_len :])


def json_payload(frame: Frame) -> dict[str, object]:
    if frame.header["kind"] != "json":
        raise ProtocolError("expected JSON payload")
    try:
        value = json.loads(frame.payload or b"{}")
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError("invalid JSON payload") from error
    if not isinstance(value, dict):
        raise ProtocolError("JSON payload must be an object")
    return value


def make_frame(
    message_type: str,
    request_id: str,
    payload: Mapping[str, object] | bytes | None = None,
    *,
    session_id: str | None = None,
    kind: str = "json",
) -> Frame:
    if payload is None:
        data = b"{}" if kind == "json" else b""
    elif isinstance(payload, bytes):
        data = payload
    else:
        data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    header: dict[str, object] = {
        "version": VERSION,
        "requestID": request_id,
        "kind": kind,
        "messageType": message_type,
    }
    if session_id is not None:
        header["sessionID"] = session_id
    return Frame(header, data)


def read_frame(source: BinaryIO) -> Frame | None:
    prefix = source.read(4)
    if not prefix:
        return None
    if len(prefix) != 4:
        raise ProtocolError("incomplete frame prefix")
    size = int.from_bytes(prefix, "big")
    if size > MAX_FRAME_BYTES:
        raise ProtocolError("frame too large")
    body = source.read(size)
    if len(body) != size:
        raise ProtocolError("incomplete frame body")
    return decode(prefix + body)


def write_frame(sink: BinaryIO, frame: Frame) -> None:
    sink.write(encode(frame))
    sink.flush()

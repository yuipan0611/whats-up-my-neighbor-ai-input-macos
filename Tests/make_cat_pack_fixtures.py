"""Independent ZIP fixtures for the native reader; uses Python's standard ZIP implementation."""
from __future__ import annotations

import io
import json
from pathlib import Path
import stat
import struct
import sys
import warnings
import zipfile
import zlib


def main() -> None:
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    manifest = dict(schemaVersion=1, id="custom-mochi", name="麻糬", version="1.0.0", templateId="yui-cat-v1")
    appearance = dict(preset="tuxedo", seed=42, features=dict(
        eyes=dict(left="#60B9C8", right="#DEA245"),
        nose=dict(shape="triangle", color="#C98784", freckles=True),
        collar=dict(enabled=True, color="#A45E58"),
        bow=dict(enabled=True, color="#C98784", knotColor="#9F5B60", position="neck"),
    ))

    def encoded(value: dict) -> bytes:
        return json.dumps(value, ensure_ascii=False).encode("utf-8")

    normal = [("manifest.json", encoded(manifest)), ("appearance.json", encoded(appearance))]

    def archive(name: str, entries: list, *, method=zipfile.ZIP_DEFLATED, streaming=False) -> bytes:
        class NonSeekable(io.BytesIO):
            def seekable(self):
                return False

            def seek(self, *args):
                raise io.UnsupportedOperation("streaming fixture")

        stream = NonSeekable() if streaming else io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(stream, "w", compression=method) as file:
                for filename, content in entries:
                    file.writestr(filename, content)
        result = stream.getvalue()
        (output / name).write_bytes(result)
        return result

    stored = archive("valid-stored.nekocat", normal, method=zipfile.ZIP_STORED)
    archive("valid-deflated.nekocat", normal)
    archive("valid-streaming.nekocat", normal, streaming=True)
    archive("FirstCat.nekocatsetup", normal)

    def changed_manifest(filename: str, **changes):
        archive(filename, [("manifest.json", encoded(manifest | changes)), normal[1]])

    changed_manifest("bad-template.nekocat", templateId="unknown-cat-v2")
    changed_manifest("bad-schema.nekocat", schemaVersion=2)
    changed_manifest("boolean-schema.nekocat", schemaVersion=True)
    changed_manifest("traversal-id.nekocat", id="../escape")
    changed_manifest("bad-name.nekocat", name="麻糬\n其他指令")
    changed_manifest("unknown-manifest-field.nekocat", command="echo must-never-run")
    archive("missing-appearance.nekocat", [normal[0]])
    archive("duplicate.nekocat", normal + [normal[1]])
    archive("traversal.nekocat", [normal[0], ("../appearance.json", normal[1][1])])
    archive("extra-script.nekocat", normal + [("run.sh", b"must never execute")])
    archive("invalid-feature.nekocat", [normal[0], ("appearance.json", encoded({"preset": "tuxedo", "features": {"eyes": {"left": "invalid"}}}))])
    archive("wrong-config-shape.nekocat", [normal[0], ("appearance.json", encoded({"version": 2, "appearance": appearance}))])
    archive("huge-expanded.nekocat", [normal[0], ("appearance.json", b" " * (16 * 1024 + 1))])
    symlink = zipfile.ZipInfo("appearance.json")
    symlink.create_system = 3
    symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive("symlink.nekocat", [normal[0], (symlink, b"/etc/passwd")])
    executable = zipfile.ZipInfo("appearance.json")
    executable.create_system = 3
    executable.external_attr = (stat.S_IFREG | 0o755) << 16
    archive("executable-data.nekocat", [normal[0], (executable, normal[1][1])])
    archive("invalid-preview.nekocat", normal + [("preview.png", b"not a PNG")])

    def png(width: int, height: int) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0)) + chunk(
            b"IDAT", zlib.compress((b"\0" + b"\xc9\x87\x84\xff" * width) * height)
        ) + chunk(b"IEND", b"")

    preview = png(2, 2)
    (output / "preview.png").write_bytes(preview)
    archive("valid-preview.nekocat", normal + [("preview.png", preview)])
    archive("huge-preview.nekocat", normal + [("preview.png", png(513, 1))])
    (output / "truncated.nekocat").write_bytes(stored[:-1])
    (output / "oversized.nekocat").write_bytes(b"0" * (1024 * 1024 + 1))
    altered = bytearray(stored)
    payload_offset = 30 + len("manifest.json")
    altered[payload_offset] ^= 1
    (output / "bad-crc.nekocat").write_bytes(altered)
    altered = bytearray(stored)
    altered[30] = ord("M")  # Local name must match the central directory exactly.
    (output / "local-name-mismatch.nekocat").write_bytes(altered)
    altered = bytearray(stored)
    for signature, flag_offset in [(b"PK\x03\x04", 6), (b"PK\x01\x02", 8)]:
        offset = altered.find(signature)
        altered[offset + flag_offset] |= 1
    (output / "encrypted.nekocat").write_bytes(altered)
    # ZIP compression method other than Store/Deflate is rejected before decoding.
    archive("unsupported-method.nekocat", normal, method=zipfile.ZIP_BZIP2)
    print(f"Created {len(list(output.iterdir()))} independent cat-pack fixtures")


if __name__ == "__main__":
    main()

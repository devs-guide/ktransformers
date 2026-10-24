#!/usr/bin/env python3
"""Read-only GGUF inventory. This module never performs network or write I/O."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
from urllib.parse import urlparse


class InventoryError(Exception):
    pass


def read_exact(handle, size: int) -> bytes:
    value = handle.read(size)
    if len(value) != size:
        raise InventoryError("truncated GGUF metadata")
    return value


def unpack(handle, kind: str):
    return struct.unpack("<" + kind, read_exact(handle, struct.calcsize(kind)))[0]


def read_string(handle) -> str:
    size = unpack(handle, "Q")
    if size > 64 * 1024 * 1024:
        raise InventoryError("unreasonable GGUF string length")
    return read_exact(handle, size).decode("utf-8", "replace")


SCALARS = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def read_value(handle, value_type: int, keep: bool = True):
    if value_type in SCALARS:
        value = unpack(handle, SCALARS[value_type])
        return value if keep else None
    if value_type == 8:
        value = read_string(handle)
        return value if keep else None
    if value_type == 9:
        item_type = unpack(handle, "I")
        count = unpack(handle, "Q")
        if count > 10_000_000:
            raise InventoryError("unreasonable GGUF array length")
        values = [] if keep and count <= 4096 else None
        for _ in range(count):
            value = read_value(handle, item_type, keep=values is not None)
            if values is not None:
                values.append(value)
        return values
    raise InventoryError(f"unsupported GGUF metadata type: {value_type}")


def metadata(path: Path) -> dict:
    wanted = {
        "general.architecture",
        "general.name",
        "general.file_type",
        "general.quantization_version",
        "tokenizer.ggml.model",
    }
    result = {}
    with path.open("rb") as handle:
        if read_exact(handle, 4) != b"GGUF":
            raise InventoryError("file is not GGUF")
        version = unpack(handle, "I")
        if version not in {2, 3}:
            raise InventoryError(f"unsupported GGUF version: {version}")
        tensor_count = unpack(handle, "Q")
        kv_count = unpack(handle, "Q")
        if kv_count > 1_000_000:
            raise InventoryError("unreasonable GGUF metadata count")
        for _ in range(kv_count):
            key = read_string(handle)
            value_type = unpack(handle, "I")
            keep = key in wanted or key.endswith(".block_count")
            value = read_value(handle, value_type, keep=keep)
            if keep:
                result[key] = value
    return {"gguf_version": version, "tensor_count": tensor_count, "metadata": result}


def has_symlink(path: Path) -> bool:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            return True
    return False


def inside_git_checkout(path: Path) -> bool:
    return any((parent / ".git").exists() for parent in (path, *path.parents))


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("preflight", "validate"), required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--model-root", required=True)
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--selector", required=True)
    parser.add_argument("--expected-sha256", default="")
    args = parser.parse_args()

    parsed = urlparse(args.source_url)
    if parsed.scheme != "https" or parsed.netloc != "huggingface.co":
        raise InventoryError("source must be an HTTPS huggingface.co repository URL")
    if parsed.path.strip("/") != args.model_id:
        raise InventoryError("source URL and model ID differ")

    root_input = Path(args.model_root)
    model_input = Path(args.model_path)
    if not root_input.is_absolute() or not model_input.is_absolute():
        raise InventoryError("model root and path must be absolute")
    if has_symlink(root_input) or has_symlink(model_input):
        raise InventoryError("model root/path must not traverse symlinks")
    root = root_input.resolve(strict=True)
    model = model_input.resolve(strict=True)
    if root in {Path("/"), Path("/etc"), Path("/opt"), Path("/var"), Path("/var/lib/ktransformers")}:
        raise InventoryError("model root is unsafe or project-managed")
    if inside_git_checkout(root) or inside_git_checkout(model):
        raise InventoryError("model root/path must remain outside a Git checkout")
    try:
        model.relative_to(root)
    except ValueError as error:
        raise InventoryError("model path is outside the selected model root") from error
    if model.is_dir():
        candidates = sorted(item for item in model.iterdir() if item.is_file() and not item.is_symlink() and args.selector.lower() in item.name.lower() and item.suffix.lower() == ".gguf")
        if len(candidates) != 1:
            raise InventoryError(f"selector matched {len(candidates)} GGUF files; expected one")
        model = candidates[0]
    if not model.is_file() or model.suffix.lower() != ".gguf":
        raise InventoryError("model path must select one existing GGUF file")

    before = model.stat()
    sha256 = digest(model)
    facts = metadata(model)
    after = model.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise InventoryError("model changed during read-only inventory")
    if args.expected_sha256 and sha256 != args.expected_sha256:
        raise InventoryError("model SHA-256 differs from operator expectation")

    record = {
        "schema_version": 1,
        "status": "accepted",
        "mode": args.mode,
        "model_id": args.model_id,
        "source_url": args.source_url,
        "revision": args.revision,
        "selector": args.selector,
        "canonical_path": os.fspath(model),
        "size_bytes": before.st_size,
        "sha256": sha256,
        **facts,
    }
    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InventoryError as error:
        print(f"[models][error] {error}", file=sys.stderr)
        raise SystemExit(3)

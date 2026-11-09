#!/usr/bin/env python3
"""Refresh the bundled capacity catalog from an explicitly pinned Models.dev revision."""

import argparse
import copy
import hashlib
import io
import json
import re
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

import tomllib

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
FIRST_PARTY_ENDPOINTS = {
    "openai": ["https://api.openai.com/v1"],
    "anthropic": ["https://api.anthropic.com/v1"],
    "deepseek": ["https://api.deepseek.com", "https://api.deepseek.com/v1"],
}


def positive(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def model_limits(model, bases):
    """Resolve only the upstream limit table, retaining provider overrides and omissions."""
    base_id = model.get("base_model")
    if base_id is not None and base_id not in bases:
        raise ValueError(f"Missing canonical model: {base_id}")
    limits = copy.deepcopy(bases.get(base_id, {}).get("limit", {}))
    limits.update(model.get("limit", {}))
    for omitted in model.get("base_model_omit", []):
        if omitted == "limit":
            limits = {}
        elif omitted.startswith("limit."):
            limits.pop(omitted.removeprefix("limit."), None)
    return {
        target: limits[source]
        for source, target in (
            ("context", "contextWindow"),
            ("input", "maxInputTokens"),
            ("output", "maxOutputTokens"),
        )
        if positive(limits.get(source))
    }


def catalog(files, revision):
    bases = {
        str(PurePosixPath(path).relative_to("models").with_suffix("")): tomllib.loads(text)
        for path, text in files.items()
        if path.startswith("models/") and path.endswith(".toml")
    }
    providers = {}
    for path, text in sorted(files.items()):
        parts = PurePosixPath(path).parts
        if len(parts) != 3 or parts[0] != "providers" or parts[2] != "provider.toml":
            continue
        provider_id = parts[1]
        provider = tomllib.loads(text)
        endpoints = list(FIRST_PARTY_ENDPOINTS.get(provider_id, []))
        if provider.get("api"):
            endpoints.append(provider["api"].rstrip("/"))
        usable = []
        for endpoint in endpoints:
            parsed = urllib.parse.urlsplit(endpoint)
            if (
                parsed.scheme == "https"
                and parsed.hostname
                and not parsed.query
                and not parsed.fragment
                and not parsed.username
                and not parsed.password
                and not any(c in endpoint for c in "{}$")
            ):
                usable.append(endpoint)
        endpoints = sorted(set(usable))
        if not endpoints:
            continue
        prefix = f"providers/{provider_id}/models/"
        models = {}
        for model_path, model_text in sorted(files.items()):
            if not model_path.startswith(prefix) or not model_path.endswith(".toml"):
                continue
            model = tomllib.loads(model_text)
            if model.get("schema") != 2:
                raise ValueError(f"Unsupported model schema: {model_path}")
            limits = model_limits(model, bases)
            if limits:
                models[model_path.removeprefix(prefix).removesuffix(".toml")] = limits
        if models:
            providers[provider_id] = {"endpoints": endpoints, "models": models}
    if not providers:
        raise ValueError("The upstream source contains no usable model capacities")
    return {"schemaVersion": 1, "revision": revision, "providers": providers}


def unpack(raw, revision):
    files = {}
    prefix = f"models.dev-{revision}/"
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not member.isfile() or not member.name.startswith(prefix):
                continue
            path = member.name.removeprefix(prefix)
            if path == "LICENSE" or (
                path.endswith(".toml") and path.startswith(("models/", "providers/"))
            ):
                if member.size > 1_000_000:
                    raise ValueError(f"Unexpected source file size: {path}")
                files[path] = archive.extractfile(member).read().decode()
    if "LICENSE" not in files:
        raise ValueError("The pinned source is missing its license")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--revision", required=True, help="Reviewed, full Models.dev Git commit SHA"
    )
    parser.add_argument(
        "--archive", type=Path, help="Use a local copy of that revision's source archive"
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("revision must be a full, lowercase Git commit SHA")
    url = f"https://codeload.github.com/anomalyco/models.dev/tar.gz/{args.revision}"
    if args.archive:
        raw = args.archive.read_bytes()
    else:
        request = urllib.request.Request(
            url, headers={"User-Agent": "MarkdownIt-Catalog-Maintenance/1"}
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(30_000_001)
    if len(raw) > 30_000_000:
        raise ValueError("Unexpected upstream archive size")
    files = unpack(raw, args.revision)
    output = (
        json.dumps(
            catalog(files, args.revision), ensure_ascii=False, sort_keys=True, separators=(",", ":")
        )
        + "\n"
    )
    (VENDOR / "model-capabilities.json").write_text(output)
    (VENDOR / "models.dev.LICENSE").write_text(files["LICENSE"])
    manifest = json.loads((VENDOR / "assets.json").read_text())
    manifest = [asset for asset in manifest if asset["file"] != "model-capabilities.json"]
    manifest.append(
        {
            "file": "model-capabilities.json",
            "package": "models.dev",
            "version": args.revision,
            "target": "native",
            "license": "MIT",
            "url": url,
            "sourceSha256": hashlib.sha256(raw).hexdigest(),
            "licenseFile": "models.dev.LICENSE",
            "licenseURL": f"https://raw.githubusercontent.com/anomalyco/models.dev/{args.revision}/LICENSE",
            "sha256": hashlib.sha256(output.encode()).hexdigest(),
            "licenseSha256": hashlib.sha256(files["LICENSE"].encode()).hexdigest(),
        }
    )
    (VENDOR / "assets.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Updated model capacities from Models.dev {args.revision}.")


if __name__ == "__main__":
    main()

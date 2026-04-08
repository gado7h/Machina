#!/usr/bin/env python3
"""Write release metadata and checksums for machina packages."""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Write release metadata")
    parser.add_argument("--version", required=True, help="Release version")
    parser.add_argument("--luau-archive", required=True, help="Path to luau archive")
    parser.add_argument("--roblox-archive", required=True, help="Path to roblox archive")
    parser.add_argument("--output-directory", default="", help="Output directory")
    parser.add_argument("--git-ref", default="", help="Git reference")
    return parser.parse_args()


def get_git_ref_value(args) -> str:
    if args.git_ref:
        return args.git_ref
    github_sha = os.environ.get("GITHUB_SHA")
    if github_sha:
        return github_sha
    return "unknown"


def normalize_path(path: str) -> str:
    return path.replace("\\", "/")


def get_file_hash(path: Path) -> str:
    sha256 = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    return sha256.hexdigest().lower()


def get_file_size(path: Path) -> int:
    return path.stat().st_size


def new_asset_record(package_name: str, asset_path: str) -> dict:
    path = Path(asset_path)
    return {
        "package": package_name,
        "file": path.name,
        "sizeBytes": get_file_size(path),
        "sha256": get_file_hash(path)
    }


def main():
    args = parse_args()
    
    luau_archive = Path(args.luau_archive)
    roblox_archive = Path(args.roblox_archive)
    
    if not luau_archive.exists():
        raise FileNotFoundError(f"Luau archive not found: {luau_archive}")
    if not roblox_archive.exists():
        raise FileNotFoundError(f"Roblox archive not found: {roblox_archive}")
    
    output_dir = Path(args.output_directory) if args.output_directory else luau_archive.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    
    git_ref_value = get_git_ref_value(args)
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    
    luau_record = new_asset_record("machina-luau", str(luau_archive))
    roblox_record = new_asset_record("machina-roblox", str(roblox_archive))
    
    metadata = {
        "format": "machina-release-metadata/v1",
        "package": "machina",
        "version": args.version,
        "gitRef": git_ref_value,
        "generatedAtUtc": generated_at,
        "artifacts": {
            "machina-luau": luau_record,
            "machina-roblox": roblox_record
        }
    }
    
    metadata_path = output_dir / f"machina-release-metadata-{args.version}.json"
    checksums_path = output_dir / f"machina-release-checksums-{args.version}.txt"
    
    metadata_path.write_text(json.dumps(metadata, indent="\t") + "\n")
    print(f"Written: {metadata_path}")
    
    checksums_path.write_text(
        f"{luau_record['sha256']}  {luau_record['file']}\n"
        f"{roblox_record['sha256']}  {roblox_record['file']}\n"
    )
    print(f"Written: {checksums_path}")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""Build machina-luau and machina-roblox packages from source."""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, OrderedDict


def parse_args():
    parser = argparse.ArgumentParser(description="Build machina packages")
    parser.add_argument(
        "--target",
        choices=["all", "machina-luau", "machina-roblox"],
        default="all",
        help="Target package to build"
    )
    parser.add_argument("--output-root", default="", help="Output directory (default: dist)")
    parser.add_argument("--version", default="", help="Package version")
    parser.add_argument("--git-ref", default="", help="Git reference")
    return parser.parse_args()


def get_repo_root() -> Path:
    return Path(__file__).parent.parent.resolve()


def get_source_root() -> Path:
    return get_repo_root() / "src"


def get_output_root(args) -> Path:
    if args.output_root:
        return Path(args.output_root)
    return get_repo_root() / "dist"


def get_luau_root(output_root: Path) -> Path:
    return output_root / "machina-luau"


def get_roblox_root(output_root: Path) -> Path:
    return output_root / "machina-roblox"


def normalize_path(path: str) -> str:
    return path.replace("\\", "/")


def ensure_parent_directory(file_path: Path) -> None:
    parent = file_path.parent
    if parent != Path("."):
        parent.mkdir(parents=True, exist_ok=True)


def get_generated_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_package_version(args) -> str:
    if args.version:
        return args.version
    git_ref = os.environ.get("GITHUB_REF_NAME")
    if git_ref:
        return git_ref
    return "dev-local"


def get_package_git_ref(args) -> str:
    if args.git_ref:
        return args.git_ref
    github_sha = os.environ.get("GITHUB_SHA")
    if github_sha:
        return github_sha
    try:
        result = os.popen("git rev-parse HEAD").read().strip()
        if result:
            return result
    except Exception:
        pass
    return "unknown"


def get_relative_source_path(full_path: Path, source_root: Path) -> str:
    try:
        rel = full_path.relative_to(source_root)
        return normalize_path(str(rel))
    except ValueError:
        return normalize_path(str(full_path))


def assert_public_module_id(module_id: str) -> None:
    if not re.match(r'^@src/[A-Za-z0-9_/]+$', module_id):
        raise ValueError(f"Unsupported public module id: {module_id}")


def get_canonical_module_id(full_path: Path, source_root: Path) -> str:
    relative_path = get_relative_source_path(full_path, source_root)
    module_path = relative_path.replace(".luau", "")
    module_id = f"@src/{module_path}"
    assert_public_module_id(module_id)
    return module_id


def get_package_relative_path(module_id: str) -> str:
    assert_public_module_id(module_id)
    return module_id[1:] + ".luau"


def get_shared_source_files(source_root: Path) -> list[Path]:
    files = []
    for f in source_root.rglob("*.luau"):
        rel_path = get_relative_source_path(f, source_root)
        if "/" not in rel_path or rel_path.startswith("platforms/"):
            files.append(f)
    return sorted(files)


def get_module_entries(source_root: Path) -> list[dict]:
    entries = []
    for f in get_shared_source_files(source_root):
        module_id = get_canonical_module_id(f, source_root)
        relative_path = get_relative_source_path(f, source_root)
        entries.append({
            "full_path": f,
            "module_id": module_id,
            "relative_path": relative_path
        })
    return sorted(entries, key=lambda e: e["module_id"])


def validate_shared_source(source_root: Path) -> None:
    pattern = re.compile(r'script\.Parent|game:GetService|Instance\.new|ReplicatedStorage|RemoteFunction|DataStoreService|@host/|@config/')
    violations = []
    for f in get_shared_source_files(source_root):
        for i, line in enumerate(f.read_text().splitlines(), 1):
            if pattern.search(line):
                violations.append(f"{f}:{i}: {line.strip()}")
    if violations:
        raise ValueError(f"Shared source still contains forbidden references:\n" + "\n".join(violations))


def new_entry_points() -> dict:
    return {
        "config": "@src/DefaultConfiguration",
        "machine": "@src/platforms/x86/PcSystem",
        "platformContracts": "@src/Contracts"
    }


def new_package_manifest(format_name: str, package_name: str, consumer: str, version_value: str, git_ref_value: str, generated_at: str, module_map: dict) -> dict:
    manifest = {
        "format": format_name,
        "package": package_name,
        "sourcePackage": "machina",
        "version": version_value,
        "gitRef": git_ref_value,
        "generatedAtUtc": generated_at,
        "consumer": consumer,
        "entrypoints": new_entry_points(),
        "modules": module_map
    }
    return manifest


def get_roblox_module_expression(current_module_id: str, target_module_id: str) -> str:
    assert_public_module_id(current_module_id)
    assert_public_module_id(target_module_id)
    
    current_segments = current_module_id.split("/")
    target_segments = target_module_id.split("/")
    max_common = min(len(current_segments), len(target_segments))
    common_count = 0
    
    while common_count < max_common and current_segments[common_count] == target_segments[common_count]:
        common_count += 1
    
    result = "script"
    for _ in range(len(current_segments) - common_count):
        result += ".Parent"
    
    for seg in target_segments[common_count:]:
        result += f".{seg}"
    
    return result


def convert_to_roblox_source(content: str, current_module_id: str, known_module_ids: set) -> str:
    def replace_require(match):
        target_module_id = match.group(1)
        assert_public_module_id(target_module_id)
        if target_module_id not in known_module_ids:
            raise ValueError(f"Unknown module dependency '{target_module_id}' referenced from {current_module_id}")
        return f"require({get_roblox_module_expression(current_module_id, target_module_id)})"
    
    return re.sub(r'require\("([^"]+)"\)', replace_require, content)


def get_roblox_root_expression(target_module_id: str) -> str:
    assert_public_module_id(target_module_id)
    segments = target_module_id.split("/")
    segments[0] = segments[0].lstrip("@")
    return "root." + ".".join(segments)


def new_roblox_init_source(version_value: str, module_ids: list[str]) -> str:
    lines = [
        "-- Auto-generated Machina package",
        "-- Root is script (works for both games and most tools)",
        "",
        "local root = script",
        "",
        "-- Auto-generated module registry",
        "local modules = {"
    ]
    
    for module_id in sorted(module_ids):
        instance_expression = get_roblox_root_expression(module_id)
        lines.append(f'\t["{module_id}"] = {instance_expression},')
    
    lines.extend([
        "}",
        "",
        "local Package = {",
        f'\tName = "machina-roblox",',
        f'\tVersion = "{version_value}",',
        "}",
        "",
        "-- Deep copy a table recursively",
        "local function deepCopy(original)",
        "\tlocal copy = {}",
        "\tfor key, value in pairs(original) do",
        '\t\tif type(value) == "table" then',
        "\t\t\tcopy[key] = deepCopy(value)",
        "\t\telse",
        "\t\t\tcopy[key] = value",
        "\t\tend",
        "\tend",
        "\treturn copy",
        "end",
        "",
        "-- Merge overrides into base config",
        "local function mergeConfig(base, overrides)",
        "\tif not overrides then",
        "\t\treturn deepCopy(base)",
        "\tend",
        "\tlocal config = deepCopy(base)",
        "\tfor key, value in pairs(overrides) do",
        '\t\tif type(value) == "table" then',
        "\t\t\tif config[key] == nil then",
        "\t\t\t\tconfig[key] = {}",
        "\t\t\tend",
        "\t\t\tfor k, v in pairs(value) do",
        "\t\t\t\tconfig[key][k] = v",
        "\t\t\tend",
        "\t\telse",
        "\t\t\tconfig[key] = value",
        "\t\tend",
        "\tend",
        "\treturn config",
        "end",
        "",
        "-- Get the default configuration (as function)",
        "function Package.default()",
        '\tlocal DefaultConfiguration = Package.require("@src/DefaultConfiguration")',
        "\treturn deepCopy(DefaultConfiguration)",
        "end",
        "",
        "-- Build config with overrides",
        "function Package.build(overrides)",
        '\tlocal DefaultConfiguration = Package.require("@src/DefaultConfiguration")',
        "\treturn mergeConfig(DefaultConfiguration, overrides)",
        "end",
        "",
        "-- Entry points for common dependencies",
        'Package.machine = modules["@src/platforms/x86/PcSystem"]',
        'Package.Contracts = modules["@src/Contracts"]',
        "",
        "-- Resolve a module ID to a Roblox script instance",
        "function Package.resolve(moduleId)",
        '\tlocal moduleScript = modules[moduleId]',
        '\tassert(moduleScript, "machina: unknown module " .. tostring(moduleId))',
        "\treturn moduleScript",
        "end",
        "",
        "-- Require a module by its ID",
        "function Package.require(moduleId)",
        "\treturn require(Package.resolve(moduleId))",
        "end",
        "",
        "-- Get the PcSystem machine",
        "function Package.getMachine()",
        '\treturn Package.require("@src/platforms/x86/PcSystem")',
        "end",
        "",
        "-- Get platform contracts",
        "function Package.getContracts()",
        '\treturn Package.require("@src/Contracts")',
        "end",
        "",
        "return Package"
    ])
    
    return "\n".join(lines) + "\n"


def validate_package_manifest(manifest: dict, target_root: Path, expected_module_ids: list[str]) -> None:
    actual_module_ids = sorted(manifest["modules"].keys())
    expected_sorted = sorted(expected_module_ids)
    
    if len(actual_module_ids) != len(expected_sorted):
        raise ValueError(f"Manifest module count mismatch for {manifest['package']}: expected {len(expected_sorted)}, got {len(actual_module_ids)}")
    
    for i, (actual, expected) in enumerate(zip(actual_module_ids, expected_sorted)):
        if actual != expected:
            raise ValueError(f"Manifest module id mismatch for {manifest['package']}: expected {expected}, got {actual}")
    
    seen_paths = {}
    for module_id, dest in manifest["modules"].items():
        if dest in seen_paths:
            raise ValueError(f"Manifest for {manifest['package']} contains duplicate output paths: {dest}")
        seen_paths[dest] = module_id
    
    for module_id, dest in manifest["modules"].items():
        assert_public_module_id(module_id)
        dest_path = target_root / dest
        if not dest_path.exists():
            raise ValueError(f"Manifest for {manifest['package']} points at a missing file: {dest_path}")


def validate_roblox_output(target_root: Path) -> None:
    violations = []
    for f in target_root.rglob("*.luau"):
        if f.name == "init.luau":
            continue
        content = f.read_text()
        if re.search(r'require\("src/|require\("@src/|@config/', content):
            for i, line in enumerate(content.splitlines(), 1):
                if re.search(r'require\("src/|require\("@src/|@config/', line):
                    violations.append(f"{f}:{i}: {line.strip()}")
    if violations:
        raise ValueError(f"Generated machina-roblox package still contains unresolved string-based imports:\n" + "\n".join(violations))


def export_luau_package(target_root: Path, entries: list[dict], version_value: str, git_ref_value: str, generated_at: str) -> None:
    if target_root.exists():
        import shutil
        shutil.rmtree(target_root)
    
    target_root.mkdir(parents=True, exist_ok=True)
    
    module_map = {}
    for entry in entries:
        dest_relative = get_package_relative_path(entry["module_id"])
        dest_path = target_root / dest_relative
        ensure_parent_directory(dest_path)
        import shutil
        shutil.copy2(entry["full_path"], dest_path)
        module_map[entry["module_id"]] = dest_relative
    
    manifest = new_package_manifest(
        "machina-luau-package/v1",
        "machina-luau",
        "generic-luau-runtime",
        version_value,
        git_ref_value,
        generated_at,
        module_map
    )
    
    manifest_path = target_root / "package-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent="\t") + "\n")
    validate_package_manifest(manifest, target_root, [e["module_id"] for e in entries])


def export_roblox_package(target_root: Path, entries: list[dict], version_value: str, git_ref_value: str, generated_at: str) -> None:
    if target_root.exists():
        import shutil
        shutil.rmtree(target_root)
    
    target_root.mkdir(parents=True, exist_ok=True)
    
    known_module_ids = {e["module_id"] for e in entries}
    
    module_map = {}
    for entry in entries:
        dest_relative = get_package_relative_path(entry["module_id"])
        dest_path = target_root / dest_relative
        ensure_parent_directory(dest_path)
        
        content = entry["full_path"].read_text()
        rewritten = convert_to_roblox_source(content, entry["module_id"], known_module_ids)
        dest_path.write_text(rewritten)
        module_map[entry["module_id"]] = dest_relative
    
    init_path = target_root / "init.luau"
    init_path.write_text(new_roblox_init_source(version_value, [e["module_id"] for e in entries]))
    
    manifest = new_package_manifest(
        "machina-roblox-package/v1",
        "machina-roblox",
        "roblox-host",
        version_value,
        git_ref_value,
        generated_at,
        module_map
    )
    manifest["mountLayout"] = {
        "rootName": "machina",
        "rootType": "Folder",
        "vendorPath": "vendor/machina",
        "initModule": "init.luau",
        "sourceRoot": "src"
    }
    
    manifest_path = target_root / "package-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent="\t") + "\n")
    validate_package_manifest(manifest, target_root, [e["module_id"] for e in entries])
    validate_roblox_output(target_root)


def main():
    args = parse_args()
    
    source_root = get_source_root()
    output_root = get_output_root(args)
    
    validate_shared_source(source_root)
    
    legacy_roots = [output_root / "core", output_root / "web", output_root / "roblox"]
    for legacy in legacy_roots:
        if legacy.exists():
            import shutil
            shutil.rmtree(legacy)
    
    entries = get_module_entries(source_root)
    package_version = get_package_version(args)
    package_git_ref = get_package_git_ref(args)
    generated_at = get_generated_timestamp()
    
    if args.target in ("all", "machina-luau"):
        luau_root = get_luau_root(output_root)
        print(f"Building machina-luau -> {luau_root}")
        export_luau_package(luau_root, entries, package_version, package_git_ref, generated_at)
    
    if args.target in ("all", "machina-roblox"):
        roblox_root = get_roblox_root(output_root)
        print(f"Building machina-roblox -> {roblox_root}")
        export_roblox_package(roblox_root, entries, package_version, package_git_ref, generated_at)
    
    print("Done.")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3

import argparse
import itertools
import json
import os
import shutil
import re
from pathlib import Path


def process_file(
    file_path: Path,
    conditions: set[str],
    variant_map: dict[str, list[str]] = {},
    passthrough_unknown: bool = False,
) -> None:
    """
    Process a file for conditional directives.

    Args:
        file_path: Path to the file to process
        conditions: Set of conditions to check against, e.g., {"DRIVERCENTRAL"} or {"DRIVERCENTRAL", "DRIVERCENTRAL_DEV"}
        variant_map: Dict mapping template names to generated variant names
        passthrough_unknown: If True, directives referencing conditions not in
            the conditions set are passed through unchanged (directive lines and
            content preserved). Used during variant expansion so that
            distribution-level conditions survive for the next processing pass.
    """
    # Stack to track nested conditions: (condition, parent_including, transparent)
    # transparent=True means this condition is unknown and should be passed through
    condition_stack = []
    # Whether we're currently including lines
    including = True
    # Lines to keep
    output_lines = []

    try:
        with open(file_path, "tr", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return

    # Regular expressions for different file types
    xml_ifdef_pattern = re.compile(r"^\s*<!--\s*#ifdef\s+(\w+)\s*-->\s*$")
    xml_ifndef_pattern = re.compile(r"^\s*<!--\s*#ifndef\s+(\w+)\s*-->\s*$")
    xml_else_pattern = re.compile(r"^\s*<!--\s*#else\s*-->\s*$")
    xml_endif_pattern = re.compile(r"^\s*<!--\s*#endif\s*-->\s*$")

    lua_ifdef_pattern = re.compile(r"^\s*--\s*#ifdef\s+(\w+)\s*$")
    lua_ifndef_pattern = re.compile(r"^\s*--\s*#ifndef\s+(\w+)\s*$")
    lua_else_pattern = re.compile(r"^\s*--\s*#else\s*$")
    lua_endif_pattern = re.compile(r"^\s*--\s*#endif\s*$")

    slash_ifdef_pattern = re.compile(r"^\s*//\s*#ifdef\s+(\w+)\s*$")
    slash_ifndef_pattern = re.compile(r"^\s*//\s*#ifndef\s+(\w+)\s*$")
    slash_else_pattern = re.compile(r"^\s*//\s*#else\s*$")
    slash_endif_pattern = re.compile(r"^\s*//\s*#endif\s*$")

    # Generic patterns (for other file types)
    generic_ifdef_pattern = re.compile(r"^\s*#ifdef\s+(\w+)\s*$")
    generic_ifndef_pattern = re.compile(r"^\s*#ifndef\s+(\w+)\s*$")
    generic_else_pattern = re.compile(r"^\s*#else\s*$")
    generic_endif_pattern = re.compile(r"^\s*#endif\s*$")

    # Embed changelog pattern, resolved in a pre-pass so that directives
    # inside the changelog are handled by the main processing loop.
    changelog_pattern = re.compile(r"^\s*<!--\s*#embed-changelog\s*-->\s*$")

    # Embed a generated fragment by path (relative to this file's directory),
    # e.g. `<!-- #embed generated/binding_keys.xml -->`. Resolved in the same
    # pre-pass so directives inside the fragment are handled by the main loop.
    embed_pattern = re.compile(r"^\s*<!--\s*#embed\s+(\S+)\s*-->\s*$")

    # Variant filenames pattern (Lua comment style)
    variant_filenames_pattern = re.compile(r"^(\s*)--\s*#variant-filenames\s+(\w+)\s*$")

    ifdef_patterns = [
        xml_ifdef_pattern,
        lua_ifdef_pattern,
        slash_ifdef_pattern,
        generic_ifdef_pattern,
    ]
    ifndef_patterns = [
        xml_ifndef_pattern,
        lua_ifndef_pattern,
        slash_ifndef_pattern,
        generic_ifndef_pattern,
    ]
    else_patterns = [
        xml_else_pattern,
        lua_else_pattern,
        slash_else_pattern,
        generic_else_pattern,
    ]
    endif_patterns = [
        xml_endif_pattern,
        lua_endif_pattern,
        slash_endif_pattern,
        generic_endif_pattern,
    ]

    # Pre-pass: expand #embed-changelog directives inline so that any
    # conditional directives inside the changelog are processed by the
    # main loop below (no duplicated ifdef/ifndef logic needed).
    expanded_lines = []
    for line in lines:
        embed_match = embed_pattern.match(line)
        if changelog_pattern.match(line):
            try:
                changelog_path = Path(__file__).parent.parent / "CHANGELOG.md"
                with open(changelog_path, "r", encoding="utf-8") as cf:
                    expanded_lines.extend(cf.readlines())
            except Exception as e:
                print(f"Error embedding changelog in {file_path}: {e}")
        elif embed_match:
            rel_path = embed_match.group(1)
            embed_path = file_path.parent / rel_path
            try:
                with open(embed_path, "r", encoding="utf-8") as ef:
                    expanded_lines.extend(ef.readlines())
            except Exception as e:
                raise ValueError(f"Error embedding {rel_path} in {file_path}: {e}")
        else:
            expanded_lines.append(line)
    lines = expanded_lines

    # The pre-pass doesn't recurse, so an #embed inside an embedded fragment is never
    # expanded. Raise rather than pass it through as a literal comment, matching the
    # missing-fragment raise above.
    for line in lines:
        if embed_pattern.match(line):
            raise ValueError(
                f"Nested #embed is not supported (in a fragment embedded into {file_path})"
            )

    for line in lines:
        # Check for conditional directives
        ifdef_match = next(
            (m for pattern in ifdef_patterns if (m := pattern.match(line))), None
        )
        ifndef_match = next(
            (m for pattern in ifndef_patterns if (m := pattern.match(line))), None
        )
        else_match = next(
            (m for pattern in else_patterns if (m := pattern.match(line))), None
        )
        endif_match = next(
            (m for pattern in endif_patterns if (m := pattern.match(line))), None
        )
        variant_filenames_match = variant_filenames_pattern.match(line)

        # Check for #ifdef
        if ifdef_match:
            line_condition = ifdef_match.group(1)
            transparent = passthrough_unknown and line_condition not in conditions
            condition_stack.append((line_condition, including, transparent))
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = including and line_condition in conditions
            continue

        # Check for #ifndef
        if ifndef_match:
            line_condition = ifndef_match.group(1)
            transparent = passthrough_unknown and line_condition not in conditions
            condition_stack.append((line_condition, including, transparent))
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = including and line_condition not in conditions
            continue

        # Check for #else
        if else_match:
            if not condition_stack:
                print(f"Error: #else without matching #ifdef/#ifndef in {file_path}")
                continue
            line_condition, parent_including, transparent = condition_stack[-1]
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = parent_including and not including
            continue

        # Check for #endif
        if endif_match:
            if not condition_stack:
                print(f"Error: #endif without matching #ifdef/#ifndef in {file_path}")
                continue
            _, parent_including, transparent = condition_stack.pop()
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = parent_including if condition_stack else True
            continue

        # Check for #variant-filenames <template_name>
        if variant_filenames_match and including:
            indent = variant_filenames_match.group(1)
            template_name = variant_filenames_match.group(2)
            names = variant_map.get(template_name)
            if names is None:
                raise ValueError(
                    f"Unknown variant template '{template_name}' in {file_path}. "
                    f"Known templates: {list(variant_map.keys())}"
                )
            for name in names:
                output_lines.append(f'{indent}"{name}.c4z",\n')
            continue

        # If we're including this line, add it to the output
        if including:
            output_lines.append(line)

    # Check if we have unmatched conditionals
    if condition_stack:
        print(
            f"Warning: Unmatched conditional directives in {file_path}: {condition_stack}"
        )

    # Write the processed content back to the file
    with open(file_path, "w", encoding="utf-8") as f:
        f.writelines(output_lines)


def replace_template_variables(file_path: Path, variables: dict) -> None:
    """
    Replace __VAR_NAME__ placeholders in a file with variant-specific values.

    Args:
        file_path: Path to the file to process
        variables: Dict of variable name -> value (e.g., {"FAN_SPEED_COUNT": "3"})
    """
    try:
        with open(file_path, "tr", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return

    for var_name, var_value in variables.items():
        content = content.replace(f"__{var_name}__", var_value)
        # Also replace %%VAR%% syntax (for use in markdown files where __X__
        # is interpreted as bold by markdown formatters)
        content = content.replace(f"%%{var_name}%%", var_value)

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)


def compute_cross_product(dimensions: list[list[dict]]) -> list[dict]:
    """
    Compute the cross-product of multiple variant dimensions.

    Each dimension is a list of partial variant definitions. The cross-product
    concatenates suffixes, merges variables, and unions conditions.

    Args:
        dimensions: List of dimension arrays, each containing partial variant dicts

    Returns:
        List of fully-merged variant dicts
    """
    variants = []
    for combo in itertools.product(*dimensions):
        merged = {"suffix": "", "conditions": []}
        for part in combo:
            part = dict(part)  # avoid mutating original
            merged["suffix"] += part.pop("suffix", "")
            merged["conditions"] += part.pop("conditions", [])
            merged.update(part)
        variants.append(merged)
    return variants


def expand_variants(drivers_dir: Path) -> dict[str, list[str]]:
    """
    Expand driver template directories that contain a variants.json file.

    For each variant defined in variants.json (either as a flat "variants" list
    or a "dimensions" cross-product), copies the template directory to
    {driver_name}_{suffix}/ and replaces __VAR_NAME__ placeholders with
    variant-specific values. Variant-level conditions are processed via #ifdef
    directives. The original template directory is then removed.

    If variants.json contains a "pdf" key, a .variant_pdf marker file is
    written to each variant directory for downstream PDF consolidation.

    Args:
        drivers_dir: Path to the drivers directory in the build output

    Returns:
        Dict mapping template driver names to lists of generated variant names.
        e.g., {"esphome_fan": ["esphome_fan_1_speed", "esphome_fan_2_speed", ...]}
    """
    variant_map = {}

    for driver_dir in sorted(drivers_dir.iterdir()):
        if not driver_dir.is_dir():
            continue
        variants_file = driver_dir / "variants.json"
        if not variants_file.exists():
            continue

        with open(variants_file, "r", encoding="utf-8") as f:
            variants_config = json.load(f)

        # Support "dimensions" (cross-product) or flat "variants" list
        dimensions = variants_config.get("dimensions")
        if dimensions:
            variants = compute_cross_product(dimensions)
        else:
            variants = variants_config.get("variants", [])

        if not variants:
            continue

        pdf_name = variants_config.get("pdf")
        driver_name = driver_dir.name
        generated_names = []
        print(f"Expanding {len(variants)} variants for {driver_name}")

        # Separate empty-suffix variant from the rest. Non-empty suffixes must
        # be processed first (they copy from unmodified source). An empty-suffix
        # variant is processed last, in place.
        empty_suffix_variant = None
        suffixed_variants = []
        for variant in variants:
            if variant.get("suffix"):
                suffixed_variants.append(variant)
            else:
                empty_suffix_variant = variant

        # Process non-empty suffixes first (copy from clean source)
        for variant in suffixed_variants:
            suffix = variant.pop("suffix")
            conditions = set(variant.pop("conditions", []))
            variant_name = f"{driver_name}_{suffix}"
            variant_dir = drivers_dir / variant_name
            generated_names.append(variant_name)

            # Copy the template directory to the variant directory
            shutil.copytree(driver_dir, variant_dir)

            # Remove the variants.json from the copy
            (variant_dir / "variants.json").unlink()

            # Replace template variables and process variant conditions
            for root, _, files in os.walk(variant_dir):
                for filename in files:
                    file_path = Path(root) / filename
                    replace_template_variables(file_path, variant)
                    if conditions:
                        process_file(file_path, conditions, passthrough_unknown=True)

            # Write PDF marker if configured
            if pdf_name:
                (variant_dir / ".variant_pdf").write_text(pdf_name, encoding="utf-8")

            print(f"  Generated {variant_dir.name}")

        # Process empty-suffix variant last (in place) or remove original
        if empty_suffix_variant is not None:
            empty_suffix_variant.pop("suffix")
            conditions = set(empty_suffix_variant.pop("conditions", []))
            generated_names.insert(0, driver_name)
            (driver_dir / "variants.json").unlink(missing_ok=True)

            for root, _, files in os.walk(driver_dir):
                for filename in files:
                    file_path = Path(root) / filename
                    replace_template_variables(file_path, empty_suffix_variant)
                    if conditions:
                        process_file(file_path, conditions, passthrough_unknown=True)

            if pdf_name:
                (driver_dir / ".variant_pdf").write_text(pdf_name, encoding="utf-8")

            print(f"  Generated {driver_dir.name}")
        else:
            shutil.rmtree(driver_dir)

        variant_map[driver_name] = generated_names

    return variant_map


def process_directory(
    build_dir: Path, conditions: set[str], variant_map: dict[str, list[str]] = {}
):
    """
    Copy a directory and process all files for conditional directives.

    Args:
        build_dir: Build directory
        conditions: Set of enabled conditions
        variant_map: Dict mapping template names to generated variant names
    """
    # Copy and process all files and subdirectories
    for item in os.listdir(build_dir):
        build_item_path = build_dir / item

        if build_item_path.is_dir():
            # Recursively copy and process subdirectories
            process_directory(build_item_path, conditions, variant_map)
        else:
            # Process the file for conditional directives
            process_file(build_item_path, conditions, variant_map)


def parse_env_file(path: Path) -> dict[str, str]:
    """
    Read KEY=VALUE lines from a dotenv-style file. Blank lines and # comments are
    skipped, an optional leading `export ` is dropped, and one pair of matching
    surrounding quotes is removed from the value.
    """
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            print(f"Warning: {path.name}: ignoring a line that is not KEY=VALUE")
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def resolve_build_secrets(repo_root: Path) -> dict[str, str]:
    """
    Resolve each name `.env.default` declares from the environment, then `.env`.
    A missing value resolves to "" with a warning, or exits when REQUIRE_SECRETS is
    set. Only whether each name was set is printed.
    """
    declared = list(parse_env_file(repo_root / ".env.default"))
    if not declared:
        return {}

    local = parse_env_file(repo_root / ".env")
    required = os.environ.get("REQUIRE_SECRETS", "") not in ("", "0", "false")
    secrets: dict[str, str] = {}
    missing: list[str] = []
    for name in declared:
        value = os.environ.get(name) or local.get(name) or ""
        if value:
            print(f"Build secret {name}: set")
        else:
            print(f"Warning: build secret {name} is not set; it builds as empty")
            missing.append(name)
        secrets[name] = value

    if missing and required:
        raise SystemExit(
            "Error: REQUIRE_SECRETS is set and these build secrets have no value: "
            + ", ".join(missing)
        )
    return secrets


def write_dotenv_from_secrets(repo_root: Path) -> None:
    """
    Append to `.env` each name `.env.default` declares that SECRETS_JSON (a JSON
    object, CI's `toJSON(secrets)`) gives a value. No other secret is written.
    """
    declared = parse_env_file(repo_root / ".env.default")
    if not declared:
        return
    secrets = json.loads(os.environ.get("SECRETS_JSON") or "{}")
    lines = [f"{name}={secrets[name]}\n" for name in declared if secrets.get(name)]
    with open(repo_root / ".env", "a", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"Wrote {len(lines)} of {len(declared)} build secrets to .env")


SECRETS_MARKER = ".build-secrets"


def substitute_build_secrets(build_dir: Path, secrets: dict[str, str]) -> None:
    """
    Replace __NAME__ (and %%NAME%%) for each build secret in every built file.

    Works on bytes and rewrites only a file that holds a placeholder, so binary
    files and line endings are left exactly as they are. When any file held one,
    every driver in the build is set to encrypt its Lua (see encrypt_drivers) and
    build_dir gets SECRETS_MARKER, which tells `make package` to delete the
    plain-text squished Lua it leaves in dist/<build>/source.
    """
    pairs = []
    for name, value in secrets.items():
        encoded = value.encode("utf-8")
        pairs.append((f"__{name}__".encode(), encoded))
        pairs.append((f"%%{name}%%".encode(), encoded))
    substituted = False
    for path in sorted(build_dir.rglob("*")):
        if not path.is_file():
            continue
        content = path.read_bytes()
        replaced = content
        for placeholder, encoded in pairs:
            replaced = replaced.replace(placeholder, encoded)
        if replaced != content:
            path.write_bytes(replaced)
            substituted = True
    if substituted:
        encrypt_drivers(build_dir / "drivers")
        (build_dir / SECRETS_MARKER).write_text(
            "Build secrets were substituted into this build.\n", encoding="utf-8"
        )


def encrypt_drivers(drivers_dir: Path) -> None:
    """
    Set encryption="2" on each driver.xml's <script> so the packager encrypts it.

    A secret can sit in a src/ module that any driver squishes in, so every driver
    in the build is encrypted, not only one whose own files held a placeholder.
    """
    script_tag = re.compile(rb"<script\b[^>]*?/?>")
    encryption_attr = re.compile(rb"""\sencryption\s*=\s*(["'])[^"']*\1""")
    for xml_path in sorted(drivers_dir.glob("*/driver.xml")):
        content = xml_path.read_bytes()

        def encrypted(match: "re.Match[bytes]") -> bytes:
            tag = match.group(0)
            if encryption_attr.search(tag):
                return encryption_attr.sub(b' encryption="2"', tag)
            return tag.replace(b"<script", b'<script encryption="2"', 1)

        replaced, count = script_tag.subn(encrypted, content)
        if count == 0:
            raise SystemExit(
                f"Error: {xml_path} has no <script> to encrypt, and build secrets "
                "were substituted into this build"
            )
        if replaced != content:
            xml_path.write_bytes(replaced)
        print(f"Encrypting {xml_path.parent.name}: build secrets were substituted")


def main():
    parser = argparse.ArgumentParser(
        description="Build the project with conditional directives."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--drivercentral", action="store_true", help="Enable DRIVERCENTRAL build"
    )
    group.add_argument(
        "--drivercentral-dev",
        action="store_true",
        help="Enable DRIVERCENTRAL + DRIVERCENTRAL_DEV build",
    )
    group.add_argument("--oss", action="store_true", help="Enable OSS build")
    group.add_argument(
        "--write-dotenv",
        action="store_true",
        help="Write .env.default's names from SECRETS_JSON into .env, then exit",
    )
    args = parser.parse_args()

    if args.write_dotenv:
        write_dotenv_from_secrets(Path(__file__).parent.parent)
        return

    if args.drivercentral:
        distribution = "drivercentral"
        conditions = {"DRIVERCENTRAL"}
    elif args.drivercentral_dev:
        distribution = "drivercentral-dev"
        conditions = {"DRIVERCENTRAL", "DRIVERCENTRAL_DEV"}
    elif args.oss:
        distribution = "oss"
        conditions = {"OSS"}
    else:
        distribution = None
        conditions = set()
    assert distribution, "No distribution specified"
    print(f"Building distribution: {distribution} (conditions: {conditions})")

    # Define source and build directories
    repo_root = Path(__file__).parent.parent
    src_dir = repo_root / "src"
    drivers_dir = repo_root / "drivers"
    vendor_dir = repo_root / "vendor"
    documentation_dir = repo_root / "documentation"
    build_dir = repo_root / "build" / distribution

    os.makedirs(build_dir, exist_ok=True)

    # Clean previous builds
    shutil.rmtree(build_dir / "src", ignore_errors=True)
    shutil.rmtree(build_dir / "drivers", ignore_errors=True)
    shutil.rmtree(build_dir / "vendor", ignore_errors=True)
    shutil.rmtree(build_dir / "documentation", ignore_errors=True)
    (build_dir / SECRETS_MARKER).unlink(missing_ok=True)

    shutil.copytree(src_dir, build_dir / "src")
    shutil.copytree(drivers_dir, build_dir / "drivers")
    shutil.copytree(vendor_dir, build_dir / "vendor")

    # Copy documentation if present (optional)
    if documentation_dir.is_dir():
        shutil.copytree(documentation_dir, build_dir / "documentation")

    # Expand template variants before processing conditionals
    variant_map = expand_variants(build_dir / "drivers")

    # Copy and process src directory
    process_directory(build_dir, conditions, variant_map)

    secrets = resolve_build_secrets(repo_root)
    if secrets:
        substitute_build_secrets(build_dir, secrets)

    print(f"Build completed successfully. Output in {build_dir}")


if __name__ == "__main__":
    main()

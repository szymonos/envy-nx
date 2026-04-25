"""
Transform nix path-info JSON into an SPDX 2.3 Software Bill of Materials.

Input:  nix path-info --json --recursive on stdin (dict keyed by store path)
Output: SPDX 2.3 JSON on stdout

# :example
nix path-info --json --recursive "$(nix build --print-out-paths)" | python3 -m tests.hooks.nix_closure_to_spdx > sbom.spdx.json
# :generate closure list alongside
nix path-info --recursive "$(nix build --print-out-paths)" | sort > closure.txt
"""

import json
import re
import sys
import uuid
from datetime import datetime, timezone

STORE_PATH_RE = re.compile(r"/nix/store/[a-z0-9]{32}-(.+)")


def parse_name_version(store_path: str) -> tuple[str, str]:
    m = STORE_PATH_RE.match(store_path)
    if not m:
        return store_path, ""
    full = m.group(1)
    # nix store names: <name>-<version> where version starts with a digit
    parts = full.rsplit("-", 1)
    if len(parts) == 2 and parts[1] and parts[1][0].isdigit():
        return parts[0], parts[1]
    return full, ""


def spdx_id(name: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9._-]", "-", name)
    return f"SPDXRef-{safe}"


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON input: {e}", file=sys.stderr)
        return 1

    if not isinstance(data, dict):
        print("ERROR: expected a JSON object keyed by store path", file=sys.stderr)
        return 1

    doc_namespace = f"https://spdx.org/spdxdocs/envy-nx-{uuid.uuid4()}"
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    packages = []
    relationships = []
    seen_ids: set[str] = set()

    for store_path, info in sorted(data.items()):
        name, version = parse_name_version(store_path)
        pkg_id = spdx_id(name)

        # deduplicate (same name can appear with different hashes in theory)
        if pkg_id in seen_ids:
            continue
        seen_ids.add(pkg_id)

        pkg: dict = {
            "SPDXID": pkg_id,
            "name": name,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
        }
        if version:
            pkg["versionInfo"] = version

        nar_size = info.get("narSize")
        if nar_size:
            pkg["packageVerificationCode"] = {
                "packageVerificationCodeValue": info.get("narHash", "")
            }

        packages.append(pkg)

        # dependency relationships
        for ref in info.get("references", []):
            ref_name, _ = parse_name_version(ref)
            ref_id = spdx_id(ref_name)
            if ref != store_path:
                relationships.append(
                    {
                        "spdxElementId": pkg_id,
                        "relatedSpdxElement": ref_id,
                        "relationshipType": "DEPENDS_ON",
                    }
                )

    # document describes the root environment
    relationships.append(
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relatedSpdxElement": packages[0]["SPDXID"] if packages else "NOASSERTION",
            "relationshipType": "DESCRIBES",
        }
    )

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "envy-nx-nix-closure",
        "documentNamespace": doc_namespace,
        "creationInfo": {
            "created": created,
            "creators": ["Tool: envy-nx-build_release"],
            "licenseListVersion": "3.22",
        },
        "packages": packages,
        "relationships": relationships,
    }

    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

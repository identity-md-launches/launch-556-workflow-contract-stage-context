#!/usr/bin/env python3
"""Export the compiled contract ABIs, or check that delivered ABIs match them."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if a delivered ABI is stale")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    destination = root / "docs" / "abi"
    if not args.check:
        destination.mkdir(parents=True, exist_ok=True)

    stale = []
    for contract in ("LaunchToken", "Guestbook"):
        compiled = subprocess.run(
            ["forge", "inspect", f"src/{contract}.sol:{contract}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(compiled.stdout)
        path = destination / f"{contract}.json"
        if args.check:
            if not path.exists() or json.loads(path.read_text()) != abi:
                stale.append(str(path.relative_to(root)))
        else:
            path.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {path.relative_to(root)}")
    if stale:
        parser.exit(1, "ABIs missing or stale: " + ", ".join(stale) + "\n")
    if args.check:
        print("Both delivered ABIs match the compiled contracts.")


if __name__ == "__main__":
    main()

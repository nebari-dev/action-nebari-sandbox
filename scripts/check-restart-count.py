#!/usr/bin/env python3
"""Flag containers whose restartCount exceeds a limit.

Reads `kubectl get pods -o json` on stdin, takes the restart limit as argv[1],
and prints one indented line per offending container. Extracted from
wait-platform.sh (#84) so the limit is a real argument instead of being string-
interpolated into shell, and so the logic is unit-testable offline.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-restart-count.py <max_restarts>", file=sys.stderr)
        return 2
    limit = int(sys.argv[1])

    data = json.load(sys.stdin)
    for pod in data.get("items", []):
        name = pod.get("metadata", {}).get("name", "?")
        for cs in pod.get("status", {}).get("containerStatuses", []):
            rc = cs.get("restartCount", 0)
            if rc > limit:
                print(f"  {name} / {cs.get('name', '?')}: {rc} restarts (limit {limit})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

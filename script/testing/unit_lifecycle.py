"""Entry used by the Swift test process, including direct and filtered swift test runs."""
import sys

import owned_runs
import verify

if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: unit_lifecycle.py begin|end UUID')
    owned_runs.unit(verify.BASE, sys.argv[1], sys.argv[2], verify.clear_unit_domains)

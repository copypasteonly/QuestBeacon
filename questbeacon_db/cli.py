from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from pathlib import Path


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="questbeacon-db")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build the QuestBeacon database")
    build.add_argument("--pfquest", type=Path, required=True)
    build.add_argument("--octo", type=Path, required=True)
    build.add_argument("--dbc", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--report", type=Path, required=True)

    validate = subparsers.add_parser("validate", help="validate a built database")
    validate.add_argument("--database", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    if args.command == "build":
        from questbeacon_db.builder import build_database

        build_database(args.pfquest, args.octo, args.dbc, args.output, args.report)
        return 0

    from questbeacon_db.validation import validate_database

    result = validate_database(args.database)
    print(json.dumps(result.as_dict(), indent=2, sort_keys=True))
    return 0 if result.ok else 1

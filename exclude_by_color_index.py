#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Copy a ColorNote JSON export while excluding notes by color_index."
    )
    parser.add_argument(
        "input_file",
        type=Path,
        help="Source JSON file produced by the ColorNote decrypt script.",
    )
    parser.add_argument(
        "output_file",
        type=Path,
        help="Destination JSON file.",
    )
    parser.add_argument(
        "--exclude-color-index",
        type=int,
        required=True,
        help="color_index value to exclude from the copied JSON.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    notes = json.loads(args.input_file.read_text(encoding="utf-8-sig"))

    kept = [
        note for note in notes
        if note.get("color_index") != args.exclude_color_index
    ]

    args.output_file.write_text(
        json.dumps(kept, ensure_ascii=False, indent=2),
        encoding="utf-8-sig",
    )

    removed = len(notes) - len(kept)
    print(f"Input records: {len(notes)}")
    print(f"Removed color_index={args.exclude_color_index}: {removed}")
    print(f"Output records: {len(kept)}")
    print(f"Wrote: {args.output_file}")


if __name__ == "__main__":
    main()

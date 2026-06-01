"""Download RealWonder model checkpoints with size estimates.

Two repos per the README:
  * ziyc/realwonder              -> ckpts/   (Realwonder-Distilled-AR-I2V-Flow only,
                                              skips the AR-T2V dirs you don't need
                                              for the I2V demo path)
  * alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP -> wan_models/Wan2.1-Fun-V1.1-1.3B-InP/

Usage:
    python download_models.py                       # estimate + prompt before downloading
    python download_models.py --dry-run             # estimate only, no download
    python download_models.py --yes                 # estimate + download without prompt
    python download_models.py --realwonder-only     # skip the Wan model
    python download_models.py --wan-only            # skip the RealWonder ckpt
    python download_models.py --full-realwonder     # also pull the AR-T2V variant (adds ~0.4 GB)

The Wan default-dest path matches the README's
  ``hf download alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP --local-dir wan_models/Wan2.1-Fun-V1.1-1.3B-InP``
so RealWonder's configs that reference ``wan_models/...`` resolve without edits.
"""

import argparse
import fnmatch
import os
import sys
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download

REPO_ROOT = Path(__file__).resolve().parent

REPOS = [
    {
        "key": "realwonder",
        "repo_id": "ziyc/realwonder",
        # The README only references the I2V Flow variant; the AR T2V subdir is
        # ~0.4 GB extra. Enable with --full-realwonder.
        "default_patterns": ["Realwonder-Distilled-AR-I2V-Flow/*"],
        "full_patterns": None,  # None = full snapshot
        "local_dir": REPO_ROOT / "ckpts",
    },
    {
        "key": "wan",
        "repo_id": "alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP",
        "default_patterns": None,  # full
        "full_patterns": None,
        "local_dir": REPO_ROOT / "wan_models" / "Wan2.1-Fun-V1.1-1.3B-InP",
    },
]


def _gb(n: int) -> str:
    return f"{n / 1e9:.2f} GB"


def _matched_size(siblings, patterns) -> int:
    if patterns is None:
        return sum(s.size or 0 for s in siblings)
    return sum(
        (s.size or 0)
        for s in siblings
        if any(fnmatch.fnmatch(s.rfilename, p) for p in patterns)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="Only show sizes, don't download.")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="Skip the size-confirmation prompt.")
    parser.add_argument("--realwonder-only", action="store_true")
    parser.add_argument("--wan-only", action="store_true")
    parser.add_argument("--full-realwonder", action="store_true",
                        help="Pull the full ziyc/realwonder snapshot (~19 GB) "
                             "instead of just Realwonder-Distilled-AR-I2V-Flow.")
    parser.add_argument("--max-workers", type=int, default=4,
                        help="HF parallel download workers.")
    args = parser.parse_args()

    selected = REPOS
    if args.realwonder_only:
        selected = [r for r in REPOS if r["key"] == "realwonder"]
    if args.wan_only:
        selected = [r for r in REPOS if r["key"] == "wan"]

    # hf_transfer competes with mmap on Windows + has crashed downloads here
    # before; stick with the stock backend.
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

    api = HfApi()
    print(f"{'repo':45} {'subset':>10} {'full':>10} {'->':>3} {'dest'}")
    print("-" * 100)
    plan = []
    grand_total = 0
    for r in selected:
        info = api.repo_info(r["repo_id"], files_metadata=True)
        patterns = r["full_patterns"] if args.full_realwonder and r["key"] == "realwonder" else r["default_patterns"]
        subset_size = _matched_size(info.siblings, patterns)
        full_size = sum(s.size or 0 for s in info.siblings)
        grand_total += subset_size
        plan.append({**r, "patterns": patterns, "subset_size": subset_size, "full_size": full_size})
        print(f"{r['repo_id']:45} {_gb(subset_size):>10} {_gb(full_size):>10} {'->':>3} {r['local_dir'].relative_to(REPO_ROOT)}")
    print("-" * 100)
    print(f"{'TOTAL TO DOWNLOAD':45} {_gb(grand_total):>10}")
    print()

    if args.dry_run:
        print("[dry-run] no download.")
        return 0

    if not args.yes:
        try:
            ans = input(f"Proceed downloading ~{_gb(grand_total)}? [y/N] ").strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("y", "yes"):
            print("Aborted.")
            return 1

    for r in plan:
        r["local_dir"].mkdir(parents=True, exist_ok=True)
        print(f"\n=== {r['repo_id']} ({_gb(r['subset_size'])}) -> {r['local_dir']} ===")
        snapshot_download(
            r["repo_id"],
            local_dir=str(r["local_dir"]),
            allow_patterns=r["patterns"],
            max_workers=args.max_workers,
        )
        print(f"  done.")

    print()
    print("All requested checkpoints downloaded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

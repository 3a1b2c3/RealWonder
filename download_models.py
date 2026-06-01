"""Download RealWonder model checkpoints with size estimates.

Four asset groups:
  * ziyc/realwonder              -> ckpts/   (Realwonder-Distilled-AR-I2V-Flow only,
                                              skips the AR-T2V dirs you don't need
                                              for the I2V demo path)
  * alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP -> wan_models/Wan2.1-Fun-V1.1-1.3B-InP/
  * facebook/sam-3d-objects (GATED) -> submodules/sam_3d_objects/checkpoints/hf/
                                       (download lands in checkpoints/checkpoints/
                                       and is then moved up one level to checkpoints/hf
                                       per the upstream README. Needs HF access:
                                       https://huggingface.co/facebook/sam-3d-objects)
  * sam2.1_hiera_large.pt (direct URL, ~898 MB) ->
                              submodules/sam2/checkpoints/sam2.1_hiera_large.pt

Usage:
    python download_models.py                       # estimate + prompt before downloading
    python download_models.py --dry-run             # estimate only, no download
    python download_models.py --yes                 # estimate + download without prompt
    python download_models.py --realwonder-only     # only the RealWonder ckpt
    python download_models.py --wan-only            # only the Wan model
    python download_models.py --sam3d-only          # only facebook/sam-3d-objects
    python download_models.py --sam2-only           # only the SAM2.1 .pt file
    python download_models.py --skip-gated          # skip facebook/sam-3d-objects (gated)
    python download_models.py --full-realwonder     # also pull the AR-T2V variant (adds ~0.4 GB)

The Wan default-dest path matches the README's
  ``hf download alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP --local-dir wan_models/Wan2.1-Fun-V1.1-1.3B-InP``
so RealWonder's configs that reference ``wan_models/...`` resolve without edits.
"""

import argparse
import fnmatch
import os
import shutil
import sys
import urllib.request
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download
from huggingface_hub.errors import GatedRepoError

REPO_ROOT = Path(__file__).resolve().parent

SAM2_URL = "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_large.pt"
SAM2_DEST = REPO_ROOT / "submodules" / "sam2" / "checkpoints" / "sam2.1_hiera_large.pt"
SAM2_SIZE = 898_083_611  # bytes -- known from upstream

REPOS = [
    {
        "key": "realwonder",
        "repo_id": "ziyc/realwonder",
        # The README only references the I2V Flow variant; the AR T2V subdir is
        # ~0.4 GB extra. Enable with --full-realwonder.
        "default_patterns": ["Realwonder-Distilled-AR-I2V-Flow/*"],
        "full_patterns": None,  # None = full snapshot
        "local_dir": REPO_ROOT / "ckpts",
        "gated": False,
    },
    {
        "key": "wan",
        "repo_id": "alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP",
        "default_patterns": None,  # full
        "full_patterns": None,
        "local_dir": REPO_ROOT / "wan_models" / "Wan2.1-Fun-V1.1-1.3B-InP",
        "gated": False,
    },
    {
        # GATED -- requires HF access:
        #   https://huggingface.co/facebook/sam-3d-objects
        # After download, the upstream README moves checkpoints/checkpoints/* up
        # to checkpoints/hf/* -- we do the same via post_move.
        "key": "sam3d",
        "repo_id": "facebook/sam-3d-objects",
        "default_patterns": ["checkpoints/*"],
        "full_patterns": ["checkpoints/*"],
        "local_dir": REPO_ROOT / "submodules" / "sam_3d_objects" / "checkpoints" / "_hf_download",
        "post_move": (
            REPO_ROOT / "submodules" / "sam_3d_objects" / "checkpoints" / "_hf_download" / "checkpoints",
            REPO_ROOT / "submodules" / "sam_3d_objects" / "checkpoints" / "hf",
        ),
        "gated": True,
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
    parser.add_argument("--sam3d-only", action="store_true",
                        help="Only the facebook/sam-3d-objects checkpoints (gated).")
    parser.add_argument("--sam2-only", action="store_true",
                        help="Only the SAM2.1 hiera-large .pt direct download.")
    parser.add_argument("--skip-gated", action="store_true",
                        help="Skip gated repos (currently only facebook/sam-3d-objects).")
    parser.add_argument("--skip-sam2", action="store_true",
                        help="Skip the SAM2.1 hiera-large .pt direct download.")
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
    if args.sam3d_only:
        selected = [r for r in REPOS if r["key"] == "sam3d"]
    if args.sam2_only:
        selected = []  # only SAM2 below; skip HF repos
    if args.skip_gated:
        selected = [r for r in selected if not r.get("gated")]
    do_sam2 = not (args.realwonder_only or args.wan_only or args.sam3d_only or args.skip_sam2)
    if args.sam2_only:
        do_sam2 = True

    # hf_transfer competes with mmap on Windows + has crashed downloads here
    # before; stick with the stock backend.
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

    api = HfApi()
    print(f"{'repo':45} {'subset':>10} {'full':>10} {'->':>3} {'dest'}")
    print("-" * 100)
    plan = []
    grand_total = 0
    for r in selected:
        try:
            info = api.repo_info(r["repo_id"], files_metadata=True)
        except GatedRepoError:
            print(f"{r['repo_id']:45} {'GATED':>10} {'GATED':>10} {'->':>3} "
                  f"{r['local_dir'].relative_to(REPO_ROOT)}  "
                  f"(request access: https://huggingface.co/{r['repo_id']})")
            continue
        patterns = r["full_patterns"] if args.full_realwonder and r["key"] == "realwonder" else r["default_patterns"]
        subset_size = _matched_size(info.siblings, patterns)
        full_size = sum(s.size or 0 for s in info.siblings)
        grand_total += subset_size
        plan.append({**r, "patterns": patterns, "subset_size": subset_size, "full_size": full_size})
        print(f"{r['repo_id']:45} {_gb(subset_size):>10} {_gb(full_size):>10} {'->':>3} {r['local_dir'].relative_to(REPO_ROOT)}")
    if do_sam2:
        sam2_size = SAM2_SIZE if not SAM2_DEST.exists() else 0
        grand_total += sam2_size
        sam2_status = _gb(sam2_size) if sam2_size else "cached"
        print(f"{'(direct) sam2.1_hiera_large.pt':45} {sam2_status:>10} {_gb(SAM2_SIZE):>10} {'->':>3} {SAM2_DEST.relative_to(REPO_ROOT)}")
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
        try:
            snapshot_download(
                r["repo_id"],
                local_dir=str(r["local_dir"]),
                allow_patterns=r["patterns"],
                max_workers=args.max_workers,
            )
        except GatedRepoError as e:
            print(f"  SKIPPED -- gated repo not accessible:\n    {e}")
            print(f"  Request access at: https://huggingface.co/{r['repo_id']}")
            continue
        post = r.get("post_move")
        if post:
            src, dst = post
            if src.is_dir():
                if dst.exists():
                    shutil.rmtree(dst)
                shutil.move(str(src), str(dst))
                # parent of src is the local_dir; clean leftover _hf_download
                shutil.rmtree(str(r["local_dir"]), ignore_errors=True)
                print(f"  moved -> {dst}")
        print(f"  done.")

    if do_sam2:
        SAM2_DEST.parent.mkdir(parents=True, exist_ok=True)
        if SAM2_DEST.exists() and SAM2_DEST.stat().st_size == SAM2_SIZE:
            print(f"\n=== SAM2.1 hiera-large -- already at expected size, skipping ===")
        else:
            print(f"\n=== SAM2.1 hiera-large ({_gb(SAM2_SIZE)}) -> {SAM2_DEST} ===")
            tmp = SAM2_DEST.with_suffix(SAM2_DEST.suffix + ".part")
            urllib.request.urlretrieve(SAM2_URL, tmp)
            tmp.replace(SAM2_DEST)
            print(f"  done.")

    print()
    print("All requested checkpoints downloaded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

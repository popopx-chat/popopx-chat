#!/usr/bin/env python3
"""Turns open-source pretrained YOLO weights into the compiled CoreML model the POPOPX
anti-spy camera guard loads at runtime (`POPOPXAntiSpyDetector.mlmodelc`), with no training
and no labels of our own: it downloads a small public detection weight, exports it at 320x320
with FP16 quantisation and CoreML's built-in NMS, compiles it, and verifies the artifact.

Threat model, in two sentences: the model answers exactly one question — "is a phone or camera
pointed at this screen right now?" — from the front camera feed while a secure popup is open, and
its only job is to be a *trigger* for the on-device response (mask, wipe, alert). It is never
evidence about a person: nothing is stored, nothing is shown to a user as an accusation, and no
detection is ever transmitted, so a wrong answer must cost the user an interruption, never
their trust or someone's reputation.

The honesty rule that follows from that: this detector false-positives. A phone-shaped object at
0.42 confidence in a bag, a picture of a camera on a poster, a TV displaying a newsroom, all of
them can fire. That is exactly why the Swift side latches instead of wiping immediately and why
the user can switch the guard off — and it is why this script verifies every stage out loud
instead of trusting the toolchain: an artifact that loads but reports the wrong class names, or
that silently lost its NMS layer, is a guard that never fires, which is worse than no guard at
all because it looks like safety.

Usage (run from anywhere; the repo root is taken from this file's location):
  python3 scripts/setup_pretrained_coreml.py                 # yolo11n.pt, falling back to yolov8n.pt
  python3 scripts/setup_pretrained_coreml.py --dry-run       # no ML deps needed, prints the plan
  python3 scripts/setup_pretrained_coreml.py --custom-weights ./phone_detector.pt
  python3 scripts/setup_pretrained_coreml.py --compile-only  # mlpackage already in --dest
The paths in this docstring are relative to the repo root (the directory this file's scripts/
parent lives in) so they work when pasted; this script resolves nothing from the current
directory except the literal --dest/--custom-weights/--cache-dir values you give it.
Setup: `python3 -m pip install -r scripts/requirements.txt` (a venv is cleaner than the system
python3; see scripts/requirements.txt for why the pins are ranges).

Exit codes: 0 succeeded (or a valid --dry-run), 2 bad arguments (nothing was imported or written),
1 a stage failed - missing dependency, refused export, refused compile, or a verification that did
not agree with what was asked for. Both failure classes print an "ERROR:" line and "->" hints on
stderr; a traceback here is a bug in this file, not a result.
The artifact is deterministic only in the loose sense: the digest printed at the end is the
provenance handle for the exact bytes this run produced.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import statistics
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union
from urllib import error as urlerror
from urllib import request as urlrequest

# Repo root from this file's location, so the
# script can be run from any directory. apps/ios is the iOS app; artifacts go where Xcode sees them.
ROOT = Path(__file__).resolve().parents[1]
IOS_DIR = ROOT / "apps" / "ios"
XCODEPROJ = IOS_DIR / "POPOPX.xcodeproj"
DEFAULT_DEST = IOS_DIR / "Resources" / "SecureEphemeral"

# The name the Swift side hard-codes. Changing it here without changing PopopxCameraGuardEngine
# breaks the load; the engine degrades to the glare fallback when the bundle lookup fails, so it
# fails quiet, which is precisely the kind of failure this file exists to make loud.
MODEL_NAME = "POPOPXAntiSpyDetector"
MLPACKAGE_DIRNAME = MODEL_NAME + ".mlpackage"
MLMODELC_DIRNAME = MODEL_NAME + ".mlmodelc"

DEFAULT_IMAGE_SIZE = 320
DEFAULT_PRECISION = "fp16"
PRECISIONS = ("fp16", "fp32")
MIN_IMAGE_SIZE, MAX_IMAGE_SIZE = 64, 1280
# ultralytics pads the backbone 32x, so a non-multiple-of-32 input is either rejected or quietly
# resized. Refusing here is honest; letting the exporter decide produces an artifact whose real
# input size is not the one the Swift side pre-multiplies into its crop maths.
MULTIPLE_OF = 32

# Weight fallback order. yolo11n is the requested model; yolov8n is the same architecture family
# and the same COCO label set, exported by the same code path, so a mirror/CDN outage on the first
# URL is a download problem, not a modelling problem. Both are AGPL-licensed Ultralytics assets:
# licensing has to be settled before this artifact ships, and it is not settled by this script.
DEFAULT_WEIGHTS = ("yolo11n.pt", "yolov8n.pt")
WEIGHT_URLS = {
    "yolo11n.pt": "https://github.com/ultralytics/assets/releases/download/v0.0.0/yolo11n.pt",
    "yolov8n.pt": "https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.pt",
}
MIN_PT_BYTES = 1_000_000  # a truncated or HTML-error-page "weight" is smaller than this
WEIGHTS_URL_HINT = "https://github.com/ultralytics/assets/releases"

# ---- The contract with the Swift side -------------------------------------------------------
# PopopxCameraGuardEngine maps these model labels (case-insensitive, whitespace-trimmed) and
# ignores everything else. Duplicated here on purpose: the script cannot read Swift, so this table
# is a copy that has to be kept in step by whoever changes either side.
TIER_ONE = ["cell phone", "camera", "mobile phone", "lens"]  # confidence >= 0.40
TIER_TWO = ["laptop", "tv", "remote"]  # confidence >= 0.55
MAPPED_ONLY = ["monitor", "remote control"]  # recognised by the Swift map, no threshold in it
GUARD_LABELS = TIER_ONE + TIER_TWO + MAPPED_ONLY
# COCO names the Swift table does *not* contain, and what COCO really calls them. Kept because the
# first stock-COCO export makes this visible: "tvmonitor" matches neither "tv" nor "monitor", so a
# whole class of proximity recordings is invisible until someone adds the real name to the map.
COCO_SYNONYMS = {"tvmonitor": "tv / monitor"}

# Output names ultralytics gives an NMS-enabled CoreML export (coremltools >= 8.0 composite op).
NMS_OUTPUT_MARKERS = ("coordinates", "confidence", "classes")

# The one step no script may do: see apps/ios/private-prompt.md, ".pbxproj zero-change red line".
MANUAL_STEP = (
    "drag `POPOPXAntiSpyDetector.mlpackage` into the `POPOPX (iOS)` target, "
    "untick *Copy items if needed*"
)


class ToolError(Exception):
    """A failure with an actionable next step attached; the message alone is never enough."""

    def __init__(self, message: str, *hints: str) -> None:
        super().__init__(message)
        self.message = message
        self.hints = [h for h in hints if h]
        self.code = 1  # operational failure; the parser overrides this for argument failures


class UsageError(ToolError):
    """Bad arguments: no ML dependency is imported, nothing is written, exit code 2."""

    def __init__(self, message: str, *hints: str) -> None:
        super().__init__(message, *hints)
        self.code = 2


# ---- output helpers -------------------------------------------------------------------------
# print(), not logging: every sibling script in scripts/ prints, and this tool's output is a
# report a human reads once, not a stream to aggregate. Plain prefixes, no colour, so the same
# output is legible in a CI log and in a pasted bug report.

def say(message: str = "") -> None:
    print(message, flush=True)


def step(message: str) -> None:
    say("\n==> " + message)


def note(message: str) -> None:
    say("    " + message)


def block(message: str, indent: int = 4) -> None:
    """Print a wrapped passage with every continuation line aligned under the first one's text."""
    pad = " " * indent
    say("\n".join(pad + line for line in message.splitlines()))


def warn(message: str) -> None:
    say("WARN: " + message)


def fail(exc: ToolError) -> int:
    print("ERROR: " + exc.message, file=sys.stderr, flush=True)
    for hint in exc.hints:
        print("  -> " + hint, file=sys.stderr, flush=True)
    return exc.code


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024.0 or unit == "GB":
            return "%.1f %s" % (size, unit) if unit != "B" else "%d B" % num_bytes
        size /= 1024.0
    return "%.1f GB" % size  # unreachable; keeps mypy quiet on the loop shape


def dir_size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---- argument handling ----------------------------------------------------------------------

def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="setup_pretrained_coreml.py",
        description="Export the POPOPX anti-spy detector to CoreML (FP16 + built-in NMS) and "
        "compile it for the app bundle. No training: open-source pretrained weights only.",
        epilog="Output: <dest>/%s and <dest>/%s, then one manual step in Xcode that this script "
        "refuses to automate (see apps/ios/private-prompt.md: no script may touch "
        "project.pbxproj)." % (MLPACKAGE_DIRNAME, MLMODELC_DIRNAME),
    )
    parser.add_argument(
        "--dest",
        default=str(DEFAULT_DEST),
        help="directory for the artifacts (default: %s)" % DEFAULT_DEST.relative_to(ROOT),
    )
    parser.add_argument(
        "--image-size",
        type=int,
        default=DEFAULT_IMAGE_SIZE,
        help="square model input in pixels; a multiple of %d in [%d, %d] (default: %d)"
        % (MULTIPLE_OF, MIN_IMAGE_SIZE, MAX_IMAGE_SIZE, DEFAULT_IMAGE_SIZE),
    )
    parser.add_argument(
        "--precision",
        default=DEFAULT_PRECISION,
        help="fp16 (default) or fp32; fp16 is the halved bundle size, fp32 the fallback if this "
        "coremltools build refuses fp16 + NMS together",
    )
    parser.add_argument(
        "--custom-weights",
        metavar="PATH",
        help="third-party open-source *phone detection* .pt to export instead of downloading "
        "(skips the download; its class list must contain a guard label or the guard never fires)",
    )
    parser.add_argument(
        "--skip-nms",
        action="store_true",
        help="export without the CoreML NMS op (raw (1, nc, anchors) output). Only for an engine "
        "that decodes boxes itself; the current one reads Vision labels.",
    )
    parser.add_argument(
        "--compile-only",
        action="store_true",
        help="skip ultralytics entirely and only compile the %s already in --dest" % MLPACKAGE_DIRNAME,
    )
    parser.add_argument(
        "--cache-dir",
        metavar="DIR",
        help="where downloaded .pt files are cached (default: %s)" % cache_dir_hint(),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate the arguments and print the plan plus the manual steps; imports neither "
        "ultralytics nor coremltools, so it works on a machine with no ML dependencies",
    )
    parser.add_argument("--verbose", action="store_true", help="echo toolchain and artifact details")
    return parser.parse_args(list(argv) if argv is not None else None)


def default_cache_dir() -> Path:
    """Per-user cache, never the repo: a committed 5 MB .pt is a licensing accident waiting to be."""
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Caches"
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "popopx" / "anti-spy-weights"


def cache_dir_hint() -> str:
    try:
        return str(default_cache_dir())
    except Exception:  # unresolvable home directory; the help text must not crash
        return "~/Library/Caches/popopx/anti-spy-weights"


# The validators take the parsed namespace rather than a destination path, because a failed
# destination check would otherwise have to print to stderr without knowing --verbose: --verbose
# sends the full "what would happen" report to stdout first, then still fails with exit 2.
def validate_arguments(args: argparse.Namespace) -> Path:
    """Validate every argument; raise UsageError with a one-line fix for anything hostile."""
    precision = str(args.precision).strip().lower()
    if precision not in PRECISIONS:
        raise UsageError(
            "--precision %r: this toolchain only supports %s."
            % (args.precision, " / ".join(PRECISIONS)),
            "coremltools int8 needs a post-export quantisation pass (quantize_weights / "
            "palettize_weights), which on an MLProgram model with the composite NMS op is not a "
            "one-liner and is not tested here; say --precision fp16 and take the halved size.",
            "if an fp16 export was rejected because of the NMS op, retry with --precision fp32.",
        )
    args.precision = precision

    size = args.image_size
    if size < MIN_IMAGE_SIZE or size > MAX_IMAGE_SIZE:
        raise UsageError(
            "--image-size %d is outside [%d, %d]." % (size, MIN_IMAGE_SIZE, MAX_IMAGE_SIZE),
            "smaller than %d px the head's smallest feature map has nothing to score; "
            "bigger than %d px stops being a 'low power, 10 FPS' input"
            % (MIN_IMAGE_SIZE, MAX_IMAGE_SIZE),
            "the Swift side expects the input this script prints in its summary; %d is the default"
            % DEFAULT_IMAGE_SIZE,
        )
    if size % MULTIPLE_OF:
        raise UsageError(
            "--image-size %d is not a multiple of %d." % (size, MULTIPLE_OF),
            "the YOLO backbone downsamples by 32, so %d would be silently resized to %d"
            % (size, size - size % MULTIPLE_OF),
            "valid values near it: %d, %d"
            % (size - size % MULTIPLE_OF, size - size % MULTIPLE_OF + MULTIPLE_OF),
        )

    # An empty string would otherwise be read as "flag not given" and silently start a download.
    if args.custom_weights is not None and not str(args.custom_weights).strip():
        raise UsageError(
            "--custom-weights was given an empty path.",
            "pass one .pt file, or drop the flag to let the script fetch %s"
            % " or ".join(DEFAULT_WEIGHTS),
        )

    if args.custom_weights and args.compile_only:
        raise UsageError(
            "--custom-weights and --compile-only contradict each other.",
            "--compile-only reuses the %s already in --dest and never opens a weight file; "
            "drop one of the two flags." % MLPACKAGE_DIRNAME,
        )

    if args.custom_weights:
        candidate = Path(str(args.custom_weights).strip()).expanduser()
        target = candidate if candidate.is_absolute() else Path.cwd() / candidate
        if not target.exists():
            raise UsageError(
                "--custom-weights %r does not exist." % str(args.custom_weights),
                "check the path, or drop the flag to let the script fetch %s"
                % " or ".join(DEFAULT_WEIGHTS),
            )
        if not target.is_file():
            raise UsageError(
                "--custom-weights %r is not a file." % str(args.custom_weights),
                "point it at one ultralytics .pt weight file.",
            )
        if target.suffix.lower() not in (".pt", ".pth"):
            raise UsageError(
                "--custom-weights %r is not a .pt file." % target.name,
                "the exporter loads ultralytics torch checkpoints; an onnx/tensorflow file needs "
                "a converter that this script does not drive.",
            )
        if target.stat().st_size < MIN_PT_BYTES:
            raise UsageError(
                "--custom-weights %r is %s; that is too small to be real weights."
                % (str(args.custom_weights), human_size(target.stat().st_size)),
                "this is usually a saved error page or a truncated download; re-download it "
                "and pass it verbatim rather than letting ultralytics try to guess.",
            )
        args.custom_weights = str(target.resolve())

    dest = parse_dest(args.dest)

    if dest.exists() and not dest.is_dir():
        raise UsageError(
            "--dest %s exists and is a file, not a directory." % dest,
            "pick an empty directory; this script writes %s and %s into it."
            % (MLPACKAGE_DIRNAME, MLMODELC_DIRNAME),
        )
    if not args.dry_run:
        ensure_dest(dest, args.verbose)
    return dest


def parse_dest(raw: str) -> Path:
    """Resolve --dest and refuse destinations where writing it is either useless or dangerous."""
    if not str(raw).strip():
        raise UsageError(
            "--dest is empty.",
            "give a directory; the default is %s." % DEFAULT_DEST.relative_to(ROOT),
        )
    candidate = Path(str(raw).strip()).expanduser()
    dest = candidate if candidate.is_absolute() else Path.cwd() / candidate
    resolved = Path(os.path.realpath(str(dest)))
    if str(resolved) == os.sep:
        raise UsageError(
            "--dest %r resolves to the filesystem root; refusing to write there." % raw,
            "the artifacts are a directory each; give a directory you own, e.g. "
            "--dest %s" % DEFAULT_DEST,
            "the root is also not writable without sudo, and sudo is how a build script ends up "
            "with root-owned files in a source tree.",
        )
    # Writing two multi-MB model directories into a source-tree root or a home directory is how
    # artifacts end up committed by accident; a deliberate staging directory is fine.
    forbidden = [("the repo root", str(ROOT))]
    try:
        forbidden.append(("your home directory", str(Path.home())))
    except RuntimeError:
        pass  # no resolvable home directory: nothing to refuse, and --dry-run must not crash
    for label, path in forbidden:
        if str(resolved) == os.path.realpath(path):
            raise UsageError(
                "--dest %r resolves to %s (%s); refusing to write artifacts there."
                % (raw, label, resolved),
                "give the artifact directory explicitly, e.g. --dest %s" % DEFAULT_DEST,
                "a directory holding only a .mlpackage is easy to `git add -A` by mistake, and "
                "these are AGPL-licensed build products that do not belong in the repo.",
            )
    # The red line: never write inside, or next to, the project file. A .mlpackage dropped into the
    # xcodeproj directory would look like a pbxproj edit to the next person who diffs the branch.
    try:
        if XCODEPROJ.exists() and resolved.is_relative_to(XCODEPROJ.resolve()):
            raise UsageError(
                "--dest %s is inside %s." % (dest, XCODEPROJ.relative_to(ROOT)),
                "nothing may be written into the Xcode project bundle; a script must not touch "
                "project.pbxproj, and dumping resources next to it invites exactly that.",
                "--dest apps/ios/Resources/SecureEphemeral (the default) is what the manual "
                "drag expects.",
            )
    except AttributeError:
        pass  # Path.is_relative_to is 3.9+; on an older interpreter this guard is skipped
    return dest


def ensure_dest(dest: Path, verbose: bool) -> None:
    try:
        dest.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        raise UsageError(
            "cannot create %s: permission denied." % dest,
            "run it where you have write access, or point --dest at a staging directory and "
            "copy the artifacts from there.",
        )
    except OSError as exc:
        raise UsageError("cannot create %s: %s" % (dest, exc.strerror or exc))
    probe = dest / ".popopx-write-test"
    try:
        probe.write_text("")
        probe.unlink()
    except OSError as exc:
        raise UsageError(
            "%s is not writable (%s)." % (dest, getattr(exc, "strerror", None) or exc),
            "check ownership, or pick another --dest; the default is %s." % DEFAULT_DEST,
        )
    if verbose:
        note("dest is writable: %s" % dest)


# ---- lazy imports ---------------------------------------------------------------------------

def require(module_name: str, purpose: str) -> Any:
    """Import inside the function that needs it: --dry-run must work on a bare machine."""
    try:
        return __import__(module_name)
    except ImportError as exc:
        raise ToolError(
            "%s is required for %s and is not importable (%s)." % (module_name, purpose, exc),
            "python3 -m pip install -r scripts/requirements.txt",
            "a venv is better than the system python3: the macOS system interpreter has no "
            "writable site-packages, and --dry-run is the only mode that works there.",
        )


def import_ultralytics() -> Any:
    return require("ultralytics", "loading and exporting the pretrained weights")


def import_coremltools() -> Any:
    return require("coremltools", "compiling and verifying the CoreML model")


def import_numpy() -> Any:
    return require("numpy", "building the dummy verification image")


# ---- stage 1: weights -------------------------------------------------------------------------

def ensure_cache_dir(cache_dir: Path) -> None:
    """Create the download cache, or say which flag to fix. A traceback here would be a lie:
    an unwritable --cache-dir is an argument problem, not a crash."""
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ToolError(
            "cannot create the weight cache %s: %s."
            % (cache_dir, getattr(exc, "strerror", None) or exc),
            "pass --cache-dir with a directory you own; the default is %s." % default_cache_dir(),
            "the cache is deliberately outside the repo, so do not fix this by pointing it at "
            "scripts/: a committed 5 MB .pt is a licensing accident waiting to be.",
        )


def fetch_weight(name: str, cache_dir: Path) -> Path:
    """Cached download of an ultralytics asset. Cheap, idempotent, and gives us a digest."""
    target = cache_dir / name
    if target.is_file() and target.stat().st_size >= MIN_PT_BYTES:
        say("cached weight %s (%s)" % (target.name, human_size(target.stat().st_size)))
        return target
    url = WEIGHT_URLS.get(name)
    if not url:
        raise ToolError(
            "no download URL is configured for %s." % name,
            "pass it with --custom-weights, or add its URL to WEIGHT_URLS in this file.",
        )
    say("preparing the weight cache %s" % cache_dir)
    ensure_cache_dir(cache_dir)
    tmp = target.with_suffix(target.suffix + ".part")
    say("downloading %s" % url)
    request = urlrequest.Request(url, headers={"User-Agent": "popopx-anti-spy-export/1.0"})
    try:
        with urlrequest.urlopen(request, timeout=120) as response, tmp.open("wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                out.write(chunk)
                done += len(chunk)
                if total:
                    print(
                        "\r    %3d%% %s" % (done * 100 // total, human_size(done)),
                        end="",
                        flush=True,
                    )
            print("\r    fetched %s%s" % (human_size(done), " " * 12), flush=True)
    except PermissionError as exc:
        # Checked before OSError on purpose: an unwritable --cache-dir is the one download failure
        # where retrying the network tells you nothing.
        raise ToolError(
            "cannot write %s: %s." % (tmp, getattr(exc, "strerror", None) or exc),
            "pass --cache-dir with a directory you own; the default is %s." % default_cache_dir(),
        )
    except (urlerror.URLError, urlerror.HTTPError, OSError, TimeoutError) as exc:
        tmp.unlink(missing_ok=True)
        raise ToolError("could not download %s: %s" % (name, exc), WEIGHTS_URL_HINT)
    if tmp.stat().st_size < MIN_PT_BYTES:
        tmp.unlink(missing_ok=True)
        raise ToolError(
            "%s downloaded as %s; that is not a weight file."
            % (name, human_size(tmp.stat().st_size)),
            "a proxy or captive portal usually returns a small HTML body under a 200; fetch it "
            "yourself from %s and pass it with --custom-weights." % WEIGHTS_URL_HINT,
        )
    tmp.rename(target)
    return target


def load_source_model(args: argparse.Namespace, cache_dir: Path) -> Tuple[Any, str, Optional[Path]]:
    """Return (model, description, .pt path or None) from --custom-weights or the cache/network.

    Order per candidate weight: a cache hit (no network at all), then ultralytics' own loader
    (which downloads into the working directory), then our own cached download. Each step is
    printed, because "which of these worked" is the difference between a reproducible build and a
    rumour.
    """
    ultralytics = import_ultralytics()
    if args.custom_weights:
        path = Path(args.custom_weights)
        say("loading custom weights %s (%s)" % (path.name, human_size(path.stat().st_size)))
        try:
            model = ultralytics.YOLO(str(path))
        except Exception as exc:
            raise ToolError(
                "ultralytics could not load %s: %s" % (path.name, exc),
                "the file must be an ultralytics/torch detection checkpoint; a raw torchscript "
                "or a .onnx file will not load here.",
                "its license and its training data are yours to verify - this script does not "
                "inspect either.",
            )
        return model, path.name, path

    errors = []  # type: List[str]
    for name in DEFAULT_WEIGHTS:
        cached = cache_dir / name
        attempts = []  # type: List[Tuple[str, Any]]
        if cached.is_file() and cached.stat().st_size >= MIN_PT_BYTES:
            attempts.append(("cache %s" % cached, lambda: ultralytics.YOLO(str(cached))))
        attempts.append(("ultralytics", lambda: ultralytics.YOLO(name)))
        attempts.append(("download", lambda: ultralytics.YOLO(str(fetch_weight(name, cache_dir)))))
        for label, attempt in attempts:
            try:
                say("loading %s via %s" % (name, label))
                model = attempt()
                local = next(
                    (p for p in (cache_dir / name, Path.cwd() / name) if p.is_file()), None
                )
                return model, name, local
            except ToolError:
                raise
            except Exception as exc:
                errors.append("%s via %s: %s" % (name, label, exc))
                note("%s via %s failed: %s" % (name, label, exc))
    raise ToolError(
        "no pretrained weight could be loaded: %s." % " / ".join(DEFAULT_WEIGHTS),
        "this is a network or version problem, not a model problem; the last error was: %s"
        % (errors[-1] if errors else "unknown"),
        "fix: download a weight from %s and re-run with --custom-weights PATH (no download)."
        % WEIGHTS_URL_HINT,
        "fix: python3 -m pip install -U ultralytics, in case the installed version cannot read "
        "the newer asset.",
    )


def names_from_model(model: Any) -> Dict[int, str]:
    """Class list as ultralytics reports it; this is what the exported model can name."""
    names = getattr(model, "names", None)
    if isinstance(names, dict):
        return {int(k): str(v) for k, v in names.items()}
    if isinstance(names, (list, tuple)):
        return {i: str(v) for i, v in enumerate(names)}
    return {}


# ---- stage 2: export -------------------------------------------------------------------------

def export_mlpackage(args: argparse.Namespace, model: Any, cache_dir: Path) -> Path:
    """model.export(...) -> a .mlpackage somewhere; verify it exists and return its path."""
    with_nms = not args.skip_nms
    step(
        "exporting %s to CoreML: imgsz=%d precision=%s nms=%s"
        % (args.description, args.image_size, args.precision, "on" if with_nms else "off")
    )
    options = {"format": "coreml", "imgsz": args.image_size, "precision": args.precision}  # type: Dict[str, Any]
    if with_nms:
        options["nms"] = True
    try:
        produced = model.export(**options)
    except Exception as exc:
        raise ToolError(
            "the CoreML export of %s failed: %s" % (args.description, exc),
            "the two knobs most likely to be refused by this coremltools/ultralytics pair are "
            "nms=True and precision=fp16; reproduce the smallest case first:",
            "  python3 scripts/setup_pretrained_coreml.py --skip-nms        (proves NMS is the "
            "blocker)",
            "  python3 scripts/setup_pretrained_coreml.py --precision fp32  (proves FP16 is the "
            "blocker)",
            "python3 -m pip install -U ultralytics coremltools - the composite NMS op and FP16 "
            "handling both changed across coremltools 8 -> 9.",
        )
    if not produced:
        raise ToolError(
            "ultralytics reported success but returned no path for %s." % args.description,
            "ultralytics writes the package next to the .pt or into the working directory; re-run "
            "with --verbose and check %s and %s for a stray %s."
            % (cache_dir, Path.cwd(), MLPACKAGE_DIRNAME),
        )
    source = Path(str(produced)).expanduser()
    if not source.is_absolute():
        source = Path.cwd() / source
    if not source.exists():
        raise ToolError(
            "export reported %s, which does not exist on disk." % source,
            "an antivirus or a symlinked build directory can move this; re-run with --verbose.",
        )
    if source.suffix != ".mlpackage":
        raise ToolError(
            "export produced %s, not a .mlpackage." % source.name,
            "this script compiles a package directory only; check that coremltools is installed "
            "(without it ultralytics falls back to a zip of the same weights).",
        )
    note("exported %s (%s)" % (source, human_size(dir_size(source))))
    return source


def install_package(source: Path, dest: Path) -> Path:
    """Place the artifact at <dest>/POPOPXAntiSpyDetector.mlpackage, replacing the previous one."""
    target = dest / MLPACKAGE_DIRNAME
    # Renaming a .mlpackage is safe: the package is self-contained and its name is not baked in.
    # The name *is* what the Swift side looks up, so an un-renamed yolo11n.mlpackage is a silent
    # "model not found" at runtime.
    if target.exists():
        shutil.rmtree(str(target))
        note("replaced the existing %s" % target.name)
    shutil.move(str(source), str(target))
    # A real package is a directory holding Model.mlmodel plus a Data/ payload. Anything else is a
    # truncated move or a zip that was never a package, and coremlc would only notice later.
    if not target.is_dir() or not ((target / "Model.mlmodel").exists() or (target / "Data").is_dir()):
        raise ToolError(
            "%s does not look like a CoreML package (no Model.mlmodel, no Data/)." % target,
            "re-run the export; if ultralytics wrote a .zip instead of a package, coremltools is "
            "missing from this interpreter: python3 -m pip install -r scripts/requirements.txt",
        )
    return target


# ---- stage 3: compile -------------------------------------------------------------------------

def compile_model(mlpackage: Path, dest: Path) -> Path:
    """mlpackage -> mlmodelc. Needs macOS + the CoreML framework; there is no portable path."""
    ct = import_coremltools()
    step("compiling %s" % mlpackage.name)
    if not sys.platform.startswith("darwin"):
        raise ToolError(
            "compiling a .mlpackage into .mlmodelc requires macOS with the CoreML framework, "
            "and this is %s." % sys.platform,
            "Xcode compiles the .mlpackage at app build time, so the app still gets a "
            ".mlmodelc: add the package on a Mac and skip --compile elsewhere.",
            "the digest of the .mlpackage is printed either way; the compiled digest is not.",
        )
    utils = getattr(getattr(ct, "models", None), "utils", None)
    compile_fn = getattr(utils, "compile_model", None) if utils else None
    if compile_fn is None:
        raise ToolError(
            "coremltools.models.utils.compile_model is missing in coremltools %s."
            % getattr(ct, "__version__", "?"),
            "the package still works: Xcode compiles %s when you drag it in, and the Swift "
            "engine loads the result from the bundle." % MLPACKAGE_DIRNAME,
            "python3 -m pip install -U coremltools to get the compiler helper back.",
        )
    # Compile into a staging directory and replace what is already in --dest only once the
    # compiler has written something: a failed compile must not also cost the user the artifact
    # they had. A hidden directory inside --dest keeps the move on one volume.
    staging = dest / (".%s-compile-staging" % MODEL_NAME)
    try:
        if staging.exists():
            shutil.rmtree(str(staging))
        staging.mkdir(parents=True)
        try:
            compile_fn(str(mlpackage), output_directory=str(staging))
        except TypeError:
            # Signature drift across coremltools versions (positional author/description pairs).
            compile_fn(str(mlpackage), None, str(staging))
        produced = sorted(
            staging.glob("*.mlmodelc"), key=lambda p: p.stat().st_mtime, reverse=True
        )  # type: List[Path]
        if not produced:
            raise ToolError(
                "the compile reported success but wrote no .mlmodelc into %s." % staging,
                "run the same compile by hand to see what the compiler says about %s:"
                % mlpackage.name,
                "  /usr/bin/xcrun coremlc compile %s %s" % (mlpackage, dest),
            )
        compiled = produced[0]
        if compiled.name != MLMODELC_DIRNAME:
            warn(
                "the compiled model is named %s but the Swift side loads %s; rename it or expect "
                "the graceful-degradation path to be the one that runs."
                % (compiled.name, MLMODELC_DIRNAME)
            )
        # The previous artifact goes only now, because from here on the new one exists.
        for stale in dest.glob("*.mlmodelc"):
            shutil.rmtree(str(stale))
        compiled = dest / produced[0].name
        shutil.move(str(produced[0]), str(compiled))
    except ToolError:
        raise
    except Exception as exc:
        raise ToolError(
            "coremlc refused to compile %s: %s" % (mlpackage.name, exc),
            "run the same compile by hand to see the compiler's own message:",
            "  /usr/bin/xcrun coremlc compile %s %s" % (mlpackage, dest),
            "if the package contains an op this macOS cannot compile (a too-new composite NMS on "
            "an old system), re-export with --skip-nms.",
            "the %s already in --dest is untouched, so a previous good model is still there."
            % MLMODELC_DIRNAME,
        )
    finally:
        shutil.rmtree(str(staging), ignore_errors=True)
    note("compiled %s (%s)" % (compiled.name, human_size(dir_size(compiled))))
    return compiled


# ---- stage 4: verify -------------------------------------------------------------------------

def model_io_names(mlmodel: Any) -> Tuple[List[str], List[str]]:
    """Input and output feature names, read defensively because the spec API has moved around."""
    inputs, outputs = [], []  # type: List[str], List[str]
    try:
        spec = mlmodel.get_spec()
        description = getattr(spec, "description", None)
        inputs = [f.name for f in getattr(description, "input", [])]
        outputs = [f.name for f in getattr(description, "output", [])]
    except Exception as exc:
        note("could not read the spec for io names: %s" % exc)
    if not outputs:
        try:  # a spec-less compiled model still reports its feature descriptions
            for feature in mlmodel.get_model().description.output:
                outputs.append(feature.name)
        except Exception:
            pass
    return inputs, outputs


def dummy_image(numpy: Any, size: int) -> Any:
    """A deterministic RGB image of the exact input size. No image file on disk is needed."""
    try:
        from PIL import Image  # coremltools and ultralytics both depend on Pillow
    except ImportError as exc:
        raise ToolError(
            "Pillow is not importable (%s); the verification image cannot be built." % exc,
            "python3 -m pip install -r scripts/requirements.txt",
        )

    # A mid-grey field with one hard-edged light rectangle: enough structure that a detector that
    # is genuinely wired up produces *something* different from an all-zero tensor, without
    # pretending to be a phone. Real images are the only accuracy test, and this is not one.
    pixels = numpy.full((size, size, 3), 128, dtype=numpy.uint8)
    pixels[size // 8 : size // 2, size // 3 : size - size // 3] = 240
    return Image.fromarray(pixels, "RGB")


def verify_artifact(args: argparse.Namespace, compiled: Path, class_names: Optional[Sequence[str]]) -> Dict[str, Any]:
    """Load the compiled model with coremltools, run one prediction, check what came back.

    The Swift side loads this same directory with VNCoreMLModel, so anything that fails here fails
    on the device too. A prediction that raises, or an output set that lost its NMS layer, must
    stop the script rather than ship a guard that cannot fire.
    """
    ct = import_coremltools()
    step("verifying %s with coremltools" % compiled.name)
    try:
        mlmodel = ct.models.MLModel(str(compiled))
    except Exception as exc:
        raise ToolError(
            "coremltools cannot load the compiled model %s: %s" % (compiled, exc),
            "the bundle lookup on device would fail the same way and the engine would degrade "
            "silently to the glare fallback.",
            "re-run the compile with the compiler's own output visible: "
            "/usr/bin/xcrun coremlc compile <package> %s" % args.dest,
        )
    inputs, outputs = model_io_names(mlmodel)
    note("inputs: %s" % (", ".join(inputs) or "(unreadable)"))
    note("outputs: %s" % (", ".join(outputs) or "(unreadable)"))

    if not outputs:
        raise ToolError(
            "the verified model reports no outputs at all.",
            "a package whose outputs coremltools cannot read is not loadable by Vision either; "
            "compare against the .mlpackage the export wrote.",
        )
    with_nms = not args.skip_nms
    lowered = [name.strip().lower() for name in outputs]
    if with_nms:
        markers = [m for m in NMS_OUTPUT_MARKERS if any(k == m or k.endswith("_" + m) for k in lowered)]
        if len(markers) < 2:
            raise ToolError(
                "nms=True was requested but the exported model does not carry the NMS outputs "
                "(found: %s; expected %s)." % (", ".join(outputs), " / ".join(NMS_OUTPUT_MARKERS)),
                "coremltools accepted the flag and dropped it: a model whose output is a raw "
                "(1, nc, anchors) tensor gives Vision no labels, so the guard would never fire.",
                "this artifact is not shippable; either install a coremltools whose NMS path "
                "really works (python3 -m pip install -U coremltools), or keep --skip-nms out of "
                "the picture and decode boxes in Swift deliberately.",
            )
        note("NMS outputs present: %s" % " / ".join(markers))
    elif len(outputs) > 1:
        warn(
            "--skip-nms was requested and the model has %d outputs; confirm the Swift side "
            "decodes them. VNRecognizeObjectsRequest gives no labels for a raw tensor, so with "
            "the current engine this artifact can never fire." % len(outputs)
        )

    numpy = import_numpy()
    image = dummy_image(numpy, args.image_size)
    feed_name = inputs[0] if inputs else "image"
    result, elapsed = timed_predict(mlmodel, {feed_name: image}, args.image_size)
    note("dummy prediction on %dx%d %s: %.2f ms" % (args.image_size, args.image_size, feed_name, elapsed))

    reported = extract_labels(result)
    if with_nms and not result:
        raise ToolError("the prediction returned no output dictionary.", "re-run with --verbose.")
    if class_names is None:
        note("class list unavailable in --compile-only mode (it comes from the weights); checked "
             "the outputs, the labels the model reported, and the strings baked in the artifact")
    else:
        report_class_coverage(sorted(class_names), args)
    embedded_check(compiled, class_names)
    if reported:
        known = {normalize_label(n) for n in (class_names or [])}
        for label in reported:
            if known and normalize_label(label) not in known:
                raise ToolError(
                    "the model reported label %r, which is not in the class list it shipped with "
                    "(%s ...)." % (label, ", ".join(sorted(known)[:8])),
                    "an index/name mismatch means the NMS class_list and the head disagree; do "
                    "not ship this artifact.",
                )
        note("reported labels: %s" % ", ".join(reported))
    else:
        # Say it plainly: a grey field legitimately has nothing in it. Asserting detections here
        # would be a fake test that passes only when the model is wrong.
        note("no detections on the synthetic grey image - expected; the class-list, embedded-label "
             "and output checks are the load-bearing ones")
    return {"outputs": outputs, "latency_ms": elapsed, "labels": reported, "feed_name": feed_name}


def embedded_check(compiled: Path, class_names: Optional[Sequence[str]]) -> None:
    """Do the guard label strings actually exist inside the compiled artifact?

    coremlc writes the MIL program as text (main.ml / model.mil), so a class list baked into the
    NMS op is readable there. This is the one check that reaches the compiled bytes rather than
    the weights they came from, which is what makes it worth the file walk. Inconclusive is
    reported as inconclusive: a toolchain that stores the list in a binary payload is not broken.
    """
    haystack = []
    scanned = 0
    for path in sorted(compiled.rglob("*")):
        if not path.is_file() or path.stat().st_size > 8 << 20:
            continue
        try:
            haystack.append(path.read_bytes().decode("utf-8", "ignore").lower())
            scanned += 1
        except OSError:
            continue
    text = "\n".join(haystack)
    if not text:
        warn("no text files could be read inside %s; the embedded-label check did not run" % compiled.name)
        return
    present = [label for label in GUARD_LABELS if label in text]
    note("guard labels found in the compiled artifact (%d file(s) scanned): %s"
         % (scanned, ", ".join(present) if present else "NONE"))
    if not present:
        expected = [n for n in (class_names or []) if normalize_label(n) in GUARD_LABELS]
        if expected:
            warn(
                "the weights carry %s but none of them appears in the compiled bytes; that is "
                "usually a binary-stored class list rather than a bug, so the dummy prediction "
                "and the runtime log on a device are the remaining evidence."
                % ", ".join(expected)
            )
        else:
            warn(
                "no guard label appears in the compiled artifact and the class list was not "
                "available to compare: confirm the labels in PopopxCameraGuardEngine's own "
                "logging on a device before trusting this build."
            )


def timed_predict(mlmodel: Any, feed: Dict[str, Any], image_size: int) -> Tuple[Dict[str, Any], float]:
    """One warm-up call plus three timed calls; report the median (a first call pays compilation)."""
    try:
        mlmodel.predict(feed)
        timings = []
        for _ in range(3):
            started = time.perf_counter()
            result = mlmodel.predict(feed)
            timings.append((time.perf_counter() - started) * 1000.0)
    except Exception as exc:
        raise ToolError(
            "the verified model failed to run a prediction: %s" % exc,
            "if the message mentions the NMS op or a deployment target, the composite op needs a "
            "newer coremltools/macOS than this machine has: retry with --skip-nms and decode in "
            "Swift, on purpose.",
            "if it mentions an input size, the export did not honour imgsz=%d." % image_size,
        )
    return dict(result), statistics.median(timings)


def extract_labels(result: Dict[str, Any]) -> List[str]:
    """Strings that came out of a classes-style output, so we can compare them to the class list."""
    found = []  # type: List[str]
    for key, value in result.items():
        if not any(key.strip().lower().endswith(s) for s in ("classes", "class", "labels")):
            continue
        try:
            flat = value.flatten().tolist() if hasattr(value, "flatten") else list(value)  # type: ignore[arg-type]
        except Exception:
            continue
        for item in flat:
            if isinstance(item, (bytes, bytearray)):
                item = item.decode("utf-8", "replace")
            if isinstance(item, str) and item.strip():
                found.append(item.strip())
    seen, unique = set(), []  # type: set, List[str]
    for item in found:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def normalize_label(label: str) -> str:
    return " ".join(str(label).strip().lower().split())


def report_class_coverage(names: Union[List[str], Dict[int, str]], args: argparse.Namespace) -> None:
    """Print the effective class list against the Swift label table, and mean it when it is empty.

    Warn, never fail: a person-only custom weight is a legitimate file that produces a detector
    which can never fire. The point of saying it here is that nobody finds that out on a device.
    """
    # Accept either shape because both occur here: ultralytics gives {index: name}, the artifact
    # check gives the plain list it read back out of the compiled model.
    if isinstance(names, dict):
        names = [str(names[key]) for key in sorted(names)]
    lowered = [normalize_label(n) for n in names]
    present = [label for label in GUARD_LABELS if label in lowered]
    absent = [label for label in GUARD_LABELS if label not in lowered]

    say("    effective class list the export shipped (%d %s; read from the loaded weights, "
        "which is the list ultralytics embeds in the package)"
        % (len(names), "entry" if len(names) == 1 else "entries"))
    if len(names) <= 20:
        note(", ".join(names))
    else:
        note("%s ... (%d more)" % (", ".join(names[:12]), len(names) - 12))
    note("guard labels present: %s" % (", ".join(present) if present else "NONE"))
    if absent:
        note("guard labels absent from this model, so they can never fire: %s" % ", ".join(absent))
    if not present:
        warn(
            "none of the guard labels (%s) is in this model's class list: the exported detector "
            "can fire on nothing. That is a real risk with a person-only --custom-weights file, "
            "and the Swift side degrades quietly, so the guard would look enabled and do nothing."
            % ", ".join("'%s'" % label for label in GUARD_LABELS)
        )
        warn(
            "fix: use weights whose classes include cell phone / camera (a COCO yolo11n or "
            "yolov8n does), or train a phone detector and pass it with --custom-weights."
        )
    elif not any(label in present for label in TIER_ONE):
        warn(
            "only the tier-two labels %s are present: the >= 0.55 proximity path can fire, the "
            ">= 0.40 camera path can never. Weaker guard than intended, not a broken one."
            % ", ".join(TIER_TWO)
        )
    for coco_name, swift_names in COCO_SYNONYMS.items():
        if coco_name in lowered:
            warn(
                "this model has the COCO class %r, which the Swift label table does not contain: "
                "it matches neither %s, so every detection of it is discarded. Add %r to the table "
                "in PopopxCameraGuardEngine if it should count."
                % (coco_name, swift_names, coco_name)
            )
    extra = sorted({n for n in lowered if n not in GUARD_LABELS})
    if extra and args.verbose:
        note("ignored by the Swift map (%d): %s" % (len(extra), ", ".join(extra[:16])))


# ---- reporting ------------------------------------------------------------------------------

def artifact_digest(compiled: Optional[Path], mlpackage: Optional[Path]) -> Tuple[str, str]:
    """SHA-256 of the bytes that carry the weights, and the method used to get them.

    The method is part of the answer: a model.mil digest and a manifest digest are not comparable,
    and provenance evidence that cannot be compared is decoration.
    """
    if compiled:
        for candidate in (compiled / "model.mil", compiled / "main.ml"):
            if candidate.is_file():
                return sha256_file(candidate), "sha256 of %s inside %s" % (candidate.name, MLMODELC_DIRNAME)
        files = sorted((f for f in compiled.rglob("*") if f.is_file()), key=lambda f: str(f))
        if files:
            digest = hashlib.sha256()
            for f in files:
                digest.update(str(f.relative_to(compiled)).encode("utf-8"))
                digest.update(b"\0")
                digest.update(bytes.fromhex(sha256_file(f)))
            return digest.hexdigest(), "sha256 manifest over %d files in %s (no model.mil in " \
                "this compiled layout)" % (len(files), MLMODELC_DIRNAME)
    if mlpackage:
        spec = mlpackage / "Data" / "Model.mlmodel"
        if spec.is_file():
            return sha256_file(spec), "sha256 of Data/Model.mlmodel inside %s" % MLPACKAGE_DIRNAME
        files = sorted((f for f in mlpackage.rglob("*") if f.is_file()), key=lambda f: str(f))
        digest = hashlib.sha256()
        for f in files:
            digest.update(str(f.relative_to(mlpackage)).encode("utf-8"))
            digest.update(b"\0")
            digest.update(bytes.fromhex(sha256_file(f)))
        return digest.hexdigest(), "sha256 manifest over %d files in %s" % (len(files), MLPACKAGE_DIRNAME)
    return "", "none - no artifact to digest"


def environment() -> str:
    versions = []
    for name in ("ultralytics", "coremltools", "torch", "numpy"):
        module = sys.modules.get(name)
        if module is not None:
            versions.append("%s %s" % (name, getattr(module, "__version__", "?")))
    machine = platform.machine()
    return "%s %s (%s), python %s%s" % (
        platform.system(),
        platform.release(),
        machine,
        platform.python_version(),
        "; " + ", ".join(versions) if versions else "",
    )


def print_manual_steps(dest: Path, did_compile: bool) -> None:
    step("manual steps (this script will not do them)")
    block(
        "%s.\n"
        "Xcode then compiles the package into %s inside the app bundle on every build, which is\n"
        "why the resource you drag in is the package and not the compiled model."
        % (MANUAL_STEP, MLMODELC_DIRNAME),
        indent=2,
    )
    block(
        "open %s in Xcode, choose the POPOPX (iOS) target in the Add files dialog, and make sure\n"
        "\"Copy items if needed\" is unticked - the file must stay where this script wrote it\n"
        "(%s), or the repo and the project diverge." % (XCODEPROJ.name, dest)
    )
    block(
        "the .pbxproj is deliberately untouched, by repo rule (apps/ios/private-prompt.md:\n"
        "\"严禁使用脚本直接修改 .pbxproj 工程文件\" - the zero-change red line), and this script has\n"
        "no code path that opens it."
    )
    if not did_compile:
        block(
            "the offline %s written above is provenance and pre-bundle evidence; what the app\n"
            "runs is the copy Xcode builds from the .mlpackage." % MLMODELC_DIRNAME
        )
    block(
        "verify on a device with PopopxCameraGuardEngine's own logging: a model that loads and\n"
        "fires is the only proof that matters, and this script can only prove that it loads."
    )


def print_summary(args: argparse.Namespace, dest: Path, mlpackage: Optional[Path],
                  compiled: Optional[Path], verification: Optional[Dict[str, Any]],
                  weight_path: Optional[Path]) -> None:
    step("summary")
    say("    environment      : %s" % environment())
    say("    source weights   : %s" % args.description)
    if weight_path is not None:
        say("    weights file     : %s (%s)" % (weight_path, human_size(weight_path.stat().st_size)))
    say("    input / precision: %dx%d, %s, NMS %s"
        % (args.image_size, args.image_size, args.precision, "off" if args.skip_nms else "on"))
    if mlpackage:
        say("    package        : %s (%s)" % (mlpackage, human_size(dir_size(mlpackage))))
    if compiled:
        say("    compiled model : %s (%s)" % (compiled, human_size(dir_size(compiled))))
    else:
        say("    compiled model : not produced")
    digest, method = artifact_digest(compiled, mlpackage)
    say("    sha256         : %s\n    provenance     : %s" % (digest or "(not computed)", method))
    if verification:
        say("    verification   : loaded with coremltools, %d output feature(s) %s"
            % (len(verification["outputs"]), str(verification["outputs"])))
        say("    dummy latency  : %.2f ms for one %dx%d prediction on this Mac (CPU/Metal here, "
            "not the iPhone ANE number)"
            % (verification["latency_ms"], args.image_size, args.image_size))
    else:
        say("    verification   : NOT RUN - the compiled model was not loaded on this machine")
    say("    unverified     : on-device inference (ANE/CPU), detection accuracy on real frames, "
        "the < 12 ms iPhone target, and FP16+NMS behaviour on other coremltools versions")
    print_manual_steps(dest, bool(compiled))


def print_plan(args: argparse.Namespace, dest: Path) -> None:
    step("dry run: nothing was imported, nothing was written")
    say("    repo root      : %s" % ROOT)
    say("    destination    : %s%s" % (dest, "" if dest.exists() else " (would be created)"))
    if args.compile_only:
        say("    stage 1-2      : skipped (--compile-only)")
        say("    stage 3        : compile %s found there with coremltools" % MLPACKAGE_DIRNAME)
        package = dest / MLPACKAGE_DIRNAME
        if not package.exists():
            say("                     which is not there yet: %s" % package)
    elif args.custom_weights:
        say("    stage 1        : load %s (no download)" % Path(args.custom_weights).name)
        say("    stage 2        : export CoreML, imgsz=%d precision=%s nms=%s"
            % (args.image_size, args.precision, "off" if args.skip_nms else "on"))
        say("    stage 3-4      : compile to %s, then load it and run one dummy prediction"
            % MLMODELC_DIRNAME)
    else:
        say("    stage 1        : %s via ultralytics, cached download fallback to %s"
            % (DEFAULT_WEIGHTS[0], DEFAULT_WEIGHTS[1]))
        say("    stage 2        : export CoreML, imgsz=%d precision=%s nms=%s"
            % (args.image_size, args.precision, "off" if args.skip_nms else "on"))
        say("    stage 3-4      : compile to %s, then load it and run one dummy prediction"
            % MLMODELC_DIRNAME)
    say("    class map      : >= 0.40 %s" % TIER_ONE)
    say("                   : >= 0.55 %s" % TIER_TWO)
    say("                   : mapped, no threshold in the Swift table: %s" % MAPPED_ONLY)
    say("                   : the list the model can actually report is read from the weights at "
        "run time and checked then")
    say("    dependencies   : none imported; dry-run works on a bare machine by design")
    say("    install        : python3 -m pip install -r scripts/requirements.txt (real runs only)")
    print_manual_steps(dest, True)


# ---- main -----------------------------------------------------------------------------------

def run(args: argparse.Namespace, dest: Path) -> int:
    cache_dir = (
        Path(str(args.cache_dir)).expanduser()
        if args.cache_dir
        else default_cache_dir()
    )
    if not cache_dir.is_absolute():
        cache_dir = Path.cwd() / cache_dir
    args.cache_dir = cache_dir

    mlpackage = None  # type: Optional[Path]
    compiled = None  # type: Optional[Path]
    weight_path = None  # type: Optional[Path]
    class_names = None  # type: Optional[List[str]]
    verification = None  # type: Optional[Dict[str, Any]]

    if args.compile_only:
        args.description = "existing %s" % MLPACKAGE_DIRNAME
        existing = dest / MLPACKAGE_DIRNAME
        if not existing.is_dir():
            raise ToolError(
                "--compile-only needs %s in %s and it is not there." % (MLPACKAGE_DIRNAME, dest),
                "run the export first (drop --compile-only), or copy a package you trust into "
                "that directory.",
            )
        mlpackage = existing
    else:
        model, name, weight_path = load_source_model(args, cache_dir)
        args.description = name
        class_names = [str(v) for _, v in sorted(names_from_model(model).items())]
        if args.verbose:
            note("class list from the weights: %d entries" % len(class_names))
        if weight_path is not None and weight_path.is_file():
            note("weights sha256: %s" % sha256_file(weight_path))
        source = export_mlpackage(args, model, cache_dir)
        mlpackage = install_package(source, dest)

    compiled = compile_model(mlpackage, dest)
    verification = verify_artifact(args, compiled, class_names)
    print_summary(args, dest, mlpackage, compiled, verification, weight_path)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        dest = validate_arguments(args)
    except ToolError as exc:
        if args.verbose:
            print("ARGS: parsed %s" % vars(args), file=sys.stderr, flush=True)
        return fail(exc)
    if args.dry_run:
        print_plan(args, dest)
        return 0
    try:
        return run(args, dest)
    except ToolError as exc:
        return fail(exc)
    except KeyboardInterrupt:
        say("\ninterrupted; the destination may hold a partial artifact, re-run to replace it")
        return 1
    except Exception as exc:  # a traceback from a third-party library is a bug report, not a plan
        if args.verbose:
            traceback.print_exc()  # on --verbose the frames are the point: keep them visible
        return fail(
            ToolError(
                "unexpected %s: %s" % (type(exc).__name__, exc),
                "this is not an argument problem; re-run with --verbose to get the traceback, and "
                "include the toolchain line from the summary when you report it.",
                "the ML stack (ultralytics/torch/coremltools) owns this failure, so check its "
                "version against scripts/requirements.txt before blaming the weights.",
            )
        )


if __name__ == "__main__":
    sys.exit(main())

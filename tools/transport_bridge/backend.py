import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

try:
    import fcntl
except ImportError:  # pragma: no cover - non-POSIX fallback
    fcntl = None


ROOT = pathlib.Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "Cargo.toml"


def default_state_dir() -> pathlib.Path:
    root_hash = hashlib.sha256(str(ROOT).encode("utf-8")).hexdigest()[:12]
    if xdg_state_home := os.environ.get("XDG_STATE_HOME"):
        return pathlib.Path(xdg_state_home) / "muxly" / "transport_bridge" / root_hash
    if home := os.environ.get("HOME"):
        return pathlib.Path(home) / ".local" / "state" / "muxly" / "transport_bridge" / root_hash
    return pathlib.Path(tempfile.gettempdir()) / "muxly" / "transport_bridge" / root_hash


STATE_DIR = pathlib.Path(
    os.environ.get("MUXLY_TRANSPORT_BRIDGE_STATE_DIR", default_state_dir())
)
TARGET_DIR = STATE_DIR / "target"
BIN_PATH = TARGET_DIR / "release" / "muxly-transport-bridge"
LOCK_PATH = STATE_DIR / "build.lock"
FINGERPRINT_PATH = STATE_DIR / "build.sha256"


def cargo_env() -> dict[str, str]:
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(TARGET_DIR)
    return env


def source_fingerprint() -> str:
    digest = hashlib.sha256()

    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if "target" in relative.parts or "__pycache__" in relative.parts:
            continue
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")

    return digest.hexdigest()


def build_is_current(fingerprint: str) -> bool:
    if not BIN_PATH.is_file():
        return False
    try:
        recorded = FINGERPRINT_PATH.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return False
    return recorded == fingerprint


def ensure_build() -> pathlib.Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    with LOCK_PATH.open("a+b") as lock_file:
        if fcntl is not None:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            fingerprint = source_fingerprint()
            if build_is_current(fingerprint):
                return BIN_PATH

            TARGET_DIR.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["cargo", "build", "--release", "--manifest-path", str(MANIFEST_PATH)],
                check=True,
                env=cargo_env(),
            )
            FINGERPRINT_PATH.write_text(fingerprint, encoding="utf-8")
            return BIN_PATH
        finally:
            if fcntl is not None:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def main() -> None:
    binary = ensure_build()
    os.execv(binary, [str(binary), *sys.argv[1:]])


if __name__ == "__main__":
    main()

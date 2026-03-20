import os
import pathlib
import subprocess
import sys
import tempfile
import hashlib


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


def cargo_env() -> dict[str, str]:
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(TARGET_DIR)
    return env


def ensure_build() -> pathlib.Path:
    TARGET_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["cargo", "build", "--release", "--manifest-path", str(MANIFEST_PATH)],
        check=True,
        env=cargo_env(),
    )
    return BIN_PATH


def main() -> None:
    binary = ensure_build()
    os.execv(binary, [str(binary), *sys.argv[1:]])


if __name__ == "__main__":
    main()

import argparse
import os
import pathlib
import random
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass


REPO = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_TRANSPORTS = ("tcp", "http", "h2", "h3wt")
DEFAULT_SECONDS_PER_TRANSPORT = 5.0
DEFAULT_MIN_WORKERS = 6
DEFAULT_MAX_WORKERS = 16
DEFAULT_MAX_BURST = 4
DEFAULT_MAX_JITTER_SECONDS = 0.250


def repo_binary(env_name: str, relative: str) -> pathlib.Path:
    value = os.environ.get(env_name)
    if value:
        return pathlib.Path(value)
    return REPO / relative


PROBE = repo_binary(
    "MUXLY_ASYNC_STRESS_PROBE_BINARY",
    "zig-out/bin/muxly-async-transport-probe",
)
MUXLYD = repo_binary("MUXLY_TEST_DAEMON_BINARY", "zig-out/bin/muxlyd")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run randomized async transport stress coverage."
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="assume zig-out/bin/muxlyd and the stress probe already exist",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="force the scheduler seed instead of generating one",
    )
    parser.add_argument(
        "--seconds-per-transport",
        type=float,
        default=DEFAULT_SECONDS_PER_TRANSPORT,
        help="time budget for each transport before it is retired",
    )
    parser.add_argument(
        "--min-workers",
        type=int,
        default=DEFAULT_MIN_WORKERS,
        help="minimum worker count for the stress scheduler",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=DEFAULT_MAX_WORKERS,
        help="maximum worker count for the stress scheduler",
    )
    parser.add_argument(
        "--transports",
        default=",".join(DEFAULT_TRANSPORTS),
        help="comma-separated subset of transports to stress",
    )
    return parser.parse_args()


def build_binaries() -> None:
    subprocess.run(
        ["zig", "build", "muxlyd", "async-transport-stress-probe"],
        cwd=REPO,
        check=True,
    )


def parse_transport_list(raw: str) -> list[str]:
    transports = [item.strip() for item in raw.split(",") if item.strip()]
    if not transports:
        raise AssertionError("transport list must not be empty")
    invalid = [item for item in transports if item not in DEFAULT_TRANSPORTS]
    if invalid:
        raise AssertionError(f"unsupported stress transports: {', '.join(invalid)}")
    return transports


def compute_worker_count(
    cpu_count: int | None, min_workers: int, max_workers: int
) -> int:
    if min_workers <= 0 or max_workers <= 0:
        raise AssertionError("worker bounds must be positive")
    if min_workers > max_workers:
        raise AssertionError("min-workers must be <= max-workers")
    logical = max(cpu_count or 1, 1)
    return max(min(logical * 2, max_workers), min_workers)


@dataclass
class Lease:
    transport: str
    burst: int
    jitter_seconds: float


@dataclass
class RunRecord:
    transport: str
    run_index: int
    duration_seconds: float
    log_path: pathlib.Path


class StressScheduler:
    def __init__(
        self,
        transports: list[str],
        seconds_per_transport: float,
        seed: int,
    ) -> None:
        self._rng = random.Random(seed)
        self._lock = threading.Lock()
        self._started = time.monotonic()
        self._halfway_seconds = seconds_per_transport * len(transports) / 2.0
        self._reshuffled = False
        self._order = transports[:]
        self._rng.shuffle(self._order)
        self._next_index = 0
        self._remaining = {
            transport: seconds_per_transport for transport in self._order
        }
        self._run_counts = {transport: 0 for transport in self._order}

    def lease(self) -> Lease | None:
        with self._lock:
            self._maybe_reshuffle_locked()
            live = [transport for transport in self._order if self._remaining[transport] > 0.0]
            if not live:
                return None

            selected = None
            for _ in range(len(self._order)):
                candidate = self._order[self._next_index]
                self._next_index = (self._next_index + 1) % len(self._order)
                if self._remaining[candidate] > 0.0:
                    selected = candidate
                    break
            if selected is None:
                return None

            return Lease(
                transport=selected,
                burst=self._rng.randint(1, DEFAULT_MAX_BURST),
                jitter_seconds=self._rng.random() * DEFAULT_MAX_JITTER_SECONDS,
            )

    def record_run(self, transport: str, duration_seconds: float) -> int:
        with self._lock:
            self._remaining[transport] = max(
                0.0, self._remaining[transport] - duration_seconds
            )
            return self._run_counts[transport]

    def claim_run_index(self, transport: str) -> int:
        with self._lock:
            self._run_counts[transport] += 1
            return self._run_counts[transport]

    def remaining(self, transport: str) -> float:
        with self._lock:
            return self._remaining[transport]

    def summary(self) -> dict[str, dict[str, float | int]]:
        with self._lock:
            return {
                transport: {
                    "runs": self._run_counts[transport],
                    "remaining_seconds": self._remaining[transport],
                }
                for transport in self._order
            }

    def order_snapshot(self) -> list[str]:
        with self._lock:
            return list(self._order)

    def _maybe_reshuffle_locked(self) -> None:
        if self._reshuffled:
            return
        elapsed = time.monotonic() - self._started
        if elapsed < self._halfway_seconds:
            return
        self._rng.shuffle(self._order)
        self._next_index = 0
        self._reshuffled = True


def run_probe(
    *,
    transport: str,
    seed: int,
    env: dict[str, str],
    log_path: pathlib.Path,
) -> float:
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as handle:
        completed = subprocess.run(
            [
                str(PROBE),
                "--transport",
                transport,
                "--seed",
                str(seed),
            ],
            cwd=REPO,
            env=env,
            text=True,
            stdout=handle,
            stderr=subprocess.STDOUT,
            timeout=300,
        )
    duration = time.monotonic() - started
    if completed.returncode != 0:
        raise AssertionError(
            f"stress probe failed: transport={transport} seed={seed} log={log_path}"
        )
    return duration


def prewarm_probes(
    *,
    transports: list[str],
    seed: int,
    env: dict[str, str],
    log_dir: pathlib.Path,
) -> None:
    for transport in transports:
        log_path = log_dir / f"prewarm-{transport}.log"
        duration = run_probe(
            transport=transport,
            seed=seed,
            env=env,
            log_path=log_path,
        )
        print(
            f"[prewarm] {transport} duration={duration:.2f}s log={log_path}"
        )


def worker_main(
    *,
    worker_name: str,
    scheduler: StressScheduler,
    seed: int,
    env: dict[str, str],
    log_dir: pathlib.Path,
    stop_event: threading.Event,
    failure_box: list[BaseException],
) -> None:
    while not stop_event.is_set():
        lease = scheduler.lease()
        if lease is None:
            return

        if lease.jitter_seconds > 0:
            time.sleep(lease.jitter_seconds)

        for _ in range(lease.burst):
            if stop_event.is_set():
                return
            if scheduler.remaining(lease.transport) <= 0.0:
                break

            run_index = scheduler.claim_run_index(lease.transport)
            log_path = log_dir / f"{lease.transport}-run-{run_index:03d}.log"
            try:
                duration = run_probe(
                    transport=lease.transport,
                    seed=seed,
                    env=env,
                    log_path=log_path,
                )
            except BaseException as exc:  # noqa: BLE001
                failure_box.append(exc)
                stop_event.set()
                return

            scheduler.record_run(lease.transport, duration)
            print(
                f"[{worker_name}] {lease.transport} run={run_index} "
                f"duration={duration:.2f}s log={log_path}"
            )


def main() -> None:
    args = parse_args()
    transports = parse_transport_list(args.transports)
    if not args.skip_build:
        build_binaries()

    seed = args.seed if args.seed is not None else random.SystemRandom().randrange(2**63)
    worker_count = compute_worker_count(
        os.cpu_count(), args.min_workers, args.max_workers
    )
    scheduler = StressScheduler(transports, args.seconds_per_transport, seed)
    env = os.environ.copy()
    env["MUXLY_TEST_DAEMON_BINARY"] = str(MUXLYD)
    env["MUXLY_ASYNC_STRESS_SEED"] = str(seed)

    log_dir = pathlib.Path(
        tempfile.mkdtemp(prefix=f"muxly-transport-stress-{seed}-")
    )
    stop_event = threading.Event()
    failure_box: list[BaseException] = []
    threads = []

    print(
        "seed="
        f"{seed} transports={','.join(transports)} "
        f"workers={worker_count} seconds_per_transport={args.seconds_per_transport:.2f} "
        f"initial_order={','.join(scheduler.order_snapshot())} log_dir={log_dir}"
    )

    prewarm_probes(transports=transports, seed=seed, env=env, log_dir=log_dir)

    for index in range(worker_count):
        thread = threading.Thread(
            target=worker_main,
            kwargs={
                "worker_name": f"w{index + 1}",
                "scheduler": scheduler,
                "seed": seed,
                "env": env,
                "log_dir": log_dir,
                "stop_event": stop_event,
                "failure_box": failure_box,
            },
            daemon=True,
        )
        thread.start()
        threads.append(thread)

    for thread in threads:
        thread.join()

    print(f"summary={scheduler.summary()}")

    if failure_box:
        raise failure_box[0]


if __name__ == "__main__":
    main()

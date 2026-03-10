#!/usr/bin/env python3
import itertools
import time


GOALS = [
    "goal: forall n, shimmer(n) -> shimmer(n + 1)",
    "goal: exists trail, mirror(trail) and stable(trail)",
    "goal: preserve tail-focus under nested proof replay",
]

LEMMA_CANDIDATES = [
    "trying lemma mirror_tail",
    "trying lemma vroom_induction",
    "trying lemma recurse_without_spilling",
]

PROGRESS_LINES = [
    "new subgoal spawned",
    "counterexample suspected at depth 7",
    "counterexample dissolved after normalization",
    "rewriting with theorem stage.scope",
    "backtracking without panic",
    "qed? ... no",
    "proof state still deliciously unsettled",
]


def main() -> None:
    for goal, lemma in zip(itertools.cycle(GOALS), itertools.cycle(LEMMA_CANDIDATES)):
        print(goal, flush=True)
        print(lemma, flush=True)
        for line in PROGRESS_LINES:
            print(line, flush=True)
            time.sleep(0.12)
        print("checkpoint: theorem-demo", flush=True)
        time.sleep(0.2)


if __name__ == "__main__":
    main()

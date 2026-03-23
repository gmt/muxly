import unittest

import transport_stress_test as stress


class TransportStressSchedulerTest(unittest.TestCase):
    def test_compute_worker_count_clamps_to_bounds(self) -> None:
        self.assertEqual(stress.compute_worker_count(2, 6, 16), 6)
        self.assertEqual(stress.compute_worker_count(8, 6, 16), 16)
        self.assertEqual(stress.compute_worker_count(5, 6, 16), 10)

    def test_parse_transport_list_rejects_invalid_values(self) -> None:
        with self.assertRaises(AssertionError):
            stress.parse_transport_list("h2,banana")

    def test_scheduler_skips_exhausted_transports(self) -> None:
        scheduler = stress.StressScheduler(["tcp", "h2"], 1.0, seed=7)
        scheduler.record_run("tcp", 1.0)
        lease = scheduler.lease()
        self.assertIsNotNone(lease)
        self.assertEqual(lease.transport, "h2")

    def test_scheduler_marks_halfway_reshuffle(self) -> None:
        scheduler = stress.StressScheduler(["tcp", "http", "h2", "h3wt"], 1.0, seed=9)
        scheduler._started -= scheduler._halfway_seconds + 0.1
        self.assertFalse(scheduler._reshuffled)
        lease = scheduler.lease()
        self.assertIsNotNone(lease)
        self.assertTrue(scheduler._reshuffled)


if __name__ == "__main__":
    unittest.main()

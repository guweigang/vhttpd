#!/usr/bin/env python3
"""Fault injection stays bounded and never strands the owned child stopped."""
import signal
import unittest

from executor_lane_warmup_probe import (
    BootstrapPauseBudget, active_decode_phase, pause_owned_child, PAUSE_SECONDS,
)


class FakeStop:
    def __init__(self, cancelled=False, fail=False):
        self.cancelled = cancelled
        self.fail = fail
        self.waits = []

    def is_set(self):
        return self.cancelled

    def wait(self, duration):
        self.waits.append(duration)
        if self.fail:
            raise RuntimeError('injected wait failure')


class WarmupProbeTests(unittest.TestCase):
    def test_each_bootstrap_has_a_finite_budget_that_log_polling_cannot_refresh(self):
        budget = BootstrapPauseBudget()
        self.assertEqual([budget.claim(1) for _ in range(20)], [True] * 3 + [False] * 17)
        self.assertEqual([budget.claim(2) for _ in range(20)], [True] * 3 + [False] * 17)
        self.assertFalse(budget.claim(1))
        self.assertAlmostEqual(3 * PAUSE_SECONDS, 2.1)

    def test_completed_decode_does_not_claim_a_pause_and_next_decode_has_its_own_phase(self):
        begin = '[vjsx] embedded gzip decode begin\n'
        done = '[vjsx] embedded gzip decode done bytes=9112572 elapsed_ms=80\n'
        self.assertIsNone(active_decode_phase(''))
        self.assertEqual(active_decode_phase(begin), 1)
        self.assertIsNone(active_decode_phase(begin + done))
        self.assertEqual(active_decode_phase(begin + done + begin), 2)
        self.assertIsNone(active_decode_phase((begin + done) * 2))

    def test_normal_pause_resumes_the_same_owned_child(self):
        signals = []
        stop = FakeStop()
        self.assertIsNotNone(pause_owned_child(123, stop, lambda *args: signals.append(args)))
        self.assertEqual(signals, [(123, signal.SIGSTOP), (123, signal.SIGCONT)])
        self.assertEqual(stop.waits, [PAUSE_SECONDS])

    def test_wait_failure_still_resumes_the_owned_child(self):
        signals = []
        with self.assertRaisesRegex(RuntimeError, 'injected wait failure'):
            pause_owned_child(456, FakeStop(fail=True), lambda *args: signals.append(args))
        self.assertEqual(signals, [(456, signal.SIGSTOP), (456, signal.SIGCONT)])

    def test_cancelled_fixture_does_not_stop_another_child(self):
        signals = []
        stop = FakeStop(cancelled=True)
        self.assertIsNone(pause_owned_child(789, stop, lambda *args: signals.append(args)))
        self.assertEqual(signals, [])
        self.assertEqual(stop.waits, [])


if __name__ == '__main__':
    unittest.main()

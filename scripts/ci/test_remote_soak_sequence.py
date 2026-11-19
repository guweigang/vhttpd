import unittest

from remote_soak_sequence import assess


def samples(load, cooldown):
    return [dict(phase=phase,runtime=dict(VmRSS=rss,fd_count=22))
            for phase,values in [('baseline',[60000]*3),('load',load),('cooldown',cooldown)]
            for rss in values]


class SequenceGateTests(unittest.TestCase):
    def setUp(self):
        self.result = dict(status='completed',http_errors=0,paseo_errors=0,http_ok=1000,paseo_ok=100)

    def test_collectable_allocation_peak_is_not_mistaken_for_retained_growth(self):
        rows = samples([60000,61000,60000,130000,120000,90000],[65000,62000,61000])
        self.assertEqual(assess(self.result,rows,'mixed')['settled_rss_kib'],62000)

    def test_original_isolated_paseo_growth_blocks_the_next_stage(self):
        rows = samples([57992,58000,60000,75000,90000,100092],[100092,100092,100092])
        with self.assertRaisesRegex(ValueError,'Retained RSS grew'):
            assess(self.result,rows,'paseo')

    def test_partial_callback_fix_with_remaining_query_growth_is_rejected(self):
        rows = samples([58000,59124,60000,75000,82000,87176],[89740]*3)
        with self.assertRaisesRegex(ValueError,'Retained RSS grew'):
            assess(self.result,rows,'paseo')

    def test_failed_workload_or_missing_traffic_never_starts_full_soak(self):
        rows = samples([60000]*6,[60000]*3)
        for updates in [dict(status='failed'),dict(http_errors=1),dict(paseo_ok=0)]:
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                assess({**self.result,**updates},rows,'mixed')

    def test_short_or_uncooled_run_is_not_accepted(self):
        with self.assertRaisesRegex(ValueError,'Insufficient'):
            assess(self.result,samples([60000]*6,[]),'mixed')

    def test_transient_rss_excess_also_blocks_full_soak(self):
        rows = samples([60000]*6,[60000]*3)
        rows[7]['runtime']['VmRSS'] = 257*1024
        with self.assertRaisesRegex(ValueError,'exceeded 256 MiB'):
            assess(self.result,rows,'mixed')

    def test_isolated_fd_peaks_are_recorded_and_allow_recovery(self):
        rows = samples([60000]*90,[60000]*3)
        for index in [42, 76]:
            rows[index]['runtime']['fd_count'] = 31
        fd = assess(self.result,rows,'mixed')['fd']
        self.assertEqual(fd['peak_load_fd'],31)
        self.assertEqual(fd['load_window_medians'],[22,22,22])
        self.assertTrue(fd['returned_to_baseline'])

    def test_sustained_fd_growth_blocks_even_if_cooldown_recovers(self):
        rows = samples([60000]*90,[60000]*3)
        for row in rows[33:93]:
            row['runtime']['fd_count'] = 23
        with self.assertRaisesRegex(ValueError,'Sustained file descriptor growth'):
            assess(self.result,rows,'mixed')

    def test_cooldown_above_idle_fd_baseline_blocks(self):
        rows = samples([60000]*6,[60000]*3)
        for row in rows[-3:]:
            row['runtime']['fd_count'] = 23
        with self.assertRaisesRegex(ValueError,'did not return to baseline'):
            assess(self.result,rows,'mixed')


if __name__ == '__main__':
    unittest.main()

import unittest

from remote_soak_sequence import assess


def samples(load, cooldown):
    return [dict(phase=phase,runtime=dict(VmRSS=rss,fd_count=22))
            for phase,values in [('load',load),('cooldown',cooldown)] for rss in values]


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

    def test_transient_resource_excess_also_blocks_full_soak(self):
        rows = samples([60000]*6,[60000]*3)
        rows[4]['runtime']['VmRSS'] = 257*1024
        with self.assertRaisesRegex(ValueError,'exceeded 256 MiB'):
            assess(self.result,rows,'mixed')
        rows[4]['runtime']['VmRSS'] = 60000
        rows[4]['runtime']['fd_count'] = 40
        with self.assertRaisesRegex(ValueError,'descriptor growth'):
            assess(self.result,rows,'mixed')


if __name__ == '__main__':
    unittest.main()

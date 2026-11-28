import unittest

from ws_client import wait_for_control_message


class ControlFrames:
    def __init__(self, *frames):
        self.frames = iter(frames)

    def json(self, timeout):
        if timeout <= 0:
            raise AssertionError('invalid read timeout')
        try:
            return next(self.frames)
        except StopIteration:
            raise TimeoutError('no more control frames') from None


class PaseoControlMessageTests(unittest.TestCase):
    def test_reconnect_receives_old_client_disconnect_before_new_client_connect(self):
        sync = {'type': 'sync', 'connectionIds': ['previous']}
        connected = {'type': 'connected', 'connectionId': 'current'}
        control = ControlFrames(sync, {'type': 'disconnected', 'connectionId': 'previous'}, connected)

        self.assertEqual(wait_for_control_message(control, 'sync'), sync)
        self.assertEqual(wait_for_control_message(control, 'connected', 'current'), connected)

    def test_lifecycle_notice_can_arrive_during_control_startup(self):
        sync = {'type': 'sync', 'connectionIds': []}
        control = ControlFrames({'type': 'disconnected', 'connectionId': 'previous'}, sync)

        self.assertEqual(wait_for_control_message(control, 'sync'), sync)

    def test_disconnect_for_current_client_fails(self):
        control = ControlFrames({'type': 'disconnected', 'connectionId': 'current'})

        with self.assertRaises(AssertionError):
            wait_for_control_message(control, 'connected', 'current')

    def test_timeout_reports_the_actual_frames_and_expected_connection_id(self):
        control = ControlFrames({'type': 'connected', 'connectionId': 'previous'})

        with self.assertRaisesRegex(TimeoutError, "id='current'.*'previous'"):
            wait_for_control_message(control, 'connected', 'current')


if __name__ == '__main__':
    unittest.main()

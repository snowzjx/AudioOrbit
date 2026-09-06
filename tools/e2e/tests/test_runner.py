import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.request

spec = importlib.util.spec_from_file_location("runner", Path(__file__).parents[1] / "run.py")
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def snapshot(sequence=1, frames=100, generation="route-1"):
    return {"schema": 1, "runID": "run", "instanceID": "instance", "sequence": sequence,
            "accessibility": True, "enabled": True, "routes": [{
                "bundleID": "com.apple.Safari", "automatic": True, "state": "running",
                "rendererStarted": True, "actualUID": "output-B", "requestedUID": "output-B",
                "displayUUID": "DISPLAY-B", "generation": generation,
                **{key: frames for key in ("captured", "rendered", "nonSilent", "captureCallbacks", "renderCallbacks")}}]}


class OracleTests(unittest.TestCase):
    def check(self):
        return r.RouteCheck("run", "output-B", "DISPLAY-B")

    def test_requires_stable_binding_and_continuing_audio(self):
        check = self.check()
        self.assertFalse(check.observe(snapshot(), 0))
        self.assertFalse(check.observe(snapshot(2, 200), 0.5))
        self.assertTrue(check.observe(snapshot(3, 300), 1.1))

    def test_requested_output_cannot_substitute_for_actual_binding(self):
        check = self.check()
        wrong = snapshot()
        wrong["routes"][0]["actualUID"] = "output-A"
        self.assertFalse(check.observe(wrong, 0))
        wrong["sequence"] = 2
        self.assertFalse(check.observe(wrong, 5))

    def test_frozen_audio_counters_never_pass_even_after_early_progress(self):
        check = self.check()
        check.observe(snapshot(), 0)
        check.observe(snapshot(2, 200), 0.1)
        self.assertFalse(check.observe(snapshot(3, 200), 2))
        self.assertFalse(check.observe(snapshot(4, 200), 5))

    def test_non_silent_counter_is_required(self):
        check = self.check()
        first = snapshot()
        first["routes"][0]["nonSilent"] = 0
        check.observe(first, 0)
        second = snapshot(2, 200)
        second["routes"][0]["nonSilent"] = 0
        self.assertFalse(check.observe(second, 2))

    def test_stale_snapshot_is_a_driver_failure(self):
        check = self.check()
        check.observe(snapshot(), 0)
        with self.assertRaises(r.DriverFailure):
            check.observe(snapshot(), 2)

    def test_other_run_restart_and_reordering_fail(self):
        for key, value in (("runID", "other"), ("instanceID", "other"), ("sequence", 0)):
            check = self.check()
            check.observe(snapshot(), 0)
            changed = snapshot(2, 200)
            changed[key] = value
            with self.assertRaises(r.DriverFailure):
                check.observe(changed, 1)

    def test_migration_requires_a_new_stability_interval(self):
        check = self.check()
        check.observe(snapshot(), 0)
        self.assertFalse(check.observe(snapshot(2, 10, "route-2"), 1))
        self.assertFalse(check.observe(snapshot(3, 20, "route-2"), 1.5))
        self.assertTrue(check.observe(snapshot(4, 30, "route-2"), 2.1))

    def test_extra_routes_and_wrong_display_do_not_pass(self):
        for kind in ("extra", "display", "manual", "binding-error"):
            check = self.check()
            value = snapshot()
            if kind == "extra":
                value["routes"].append(copy.deepcopy(value["routes"][0]))
            elif kind == "display":
                value["routes"][0]["displayUUID"] = "DISPLAY-A"
            elif kind == "manual":
                value["routes"][0]["automatic"] = False
            else:
                value["routes"][0]["bindingError"] = "unavailable"
            self.assertFalse(check.observe(value, 0))

    def test_late_wrong_binding_restarts_hold(self):
        check = self.check()
        check.observe(snapshot(), 0)
        wrong = snapshot(2, 200)
        wrong["routes"][0]["actualUID"] = "output-A"
        self.assertFalse(check.observe(wrong, 0.8))
        self.assertFalse(check.observe(snapshot(3, 300), 1.1))
        self.assertFalse(check.observe(snapshot(4, 400), 1.5))


class FixtureTests(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual(r.byte_range(None, 100), (0, 99, False))
        self.assertEqual(r.byte_range("bytes=10-19", 100), (10, 19, True))
        self.assertEqual(r.byte_range("bytes=90-", 100), (90, 99, True))
        self.assertEqual(r.byte_range("bytes=-10", 100), (90, 99, True))
        for value in ("bytes=100-", "bytes=20-10", "bytes=-0", "bytes=1-2,4-5"):
            with self.assertRaises(ValueError):
                r.byte_range(value, 100)

    def test_http_video_range_and_telemetry(self):
        with tempfile.TemporaryDirectory() as directory:
            video = Path(directory) / "video.mp4"
            video.write_bytes(bytes(range(100)))
            server = r.FixtureServer(video, "run")
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                request = urllib.request.Request(base + "/run/video.mp4", headers={"Range": "bytes=4-9"})
                with urllib.request.urlopen(request) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.read(), bytes(range(4, 10)))
                request = urllib.request.Request(base + "/run/state", data=json.dumps({"total": 2}).encode(), method="POST")
                urllib.request.urlopen(request).close()
                self.assertEqual(server.state("run")["total"], 2)
                with urllib.request.urlopen(base + "/run-silent") as response:
                    self.assertNotIn(b"<video", response.read())
            finally:
                server.shutdown()
                server.server_close()


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.config = {"targets": [{"displayUUID": "A", "outputUID": "one"}, {"displayUUID": "B", "outputUID": "two"}]}
        self.inventory = {"displays": [{"uuid": "A", "mirrored": False}, {"uuid": "B", "mirrored": False}],
                          "outputs": [{"uid": "one", "alive": True}, {"uid": "two", "alive": True}],
                          "accessibility": True, "postEvents": True, "sessionReady": True, "apps": [], "playing": []}

    def test_good_setup_and_missing_permission(self):
        self.assertEqual(r.preflight(self.inventory, self.config), [])
        self.inventory["accessibility"] = False
        self.assertTrue(r.preflight(self.inventory, self.config))

    def test_same_output_mirrored_display_and_unbounded_timeout_block(self):
        config = copy.deepcopy(self.config)
        config["targets"][1]["outputUID"] = "one"
        with self.assertRaises(r.Blocked):
            r.validate_config(config, self.inventory)
        config = copy.deepcopy(self.config)
        config["moveTimeout"] = float("nan")
        with self.assertRaises(r.Blocked):
            r.validate_config(config, self.inventory)
        self.inventory["displays"][1]["mirrored"] = True
        with self.assertRaises(r.Blocked):
            r.validate_config(self.config, self.inventory)

    def test_personal_audioorbit_and_playback_block(self):
        self.inventory["apps"] = ["me.snowzjx.AudioOrbit"]
        self.inventory["playing"] = [{"pid": 1}]
        self.assertEqual(len(r.preflight(self.inventory, self.config)), 2)

    def test_blocked_report_is_not_a_pass_in_junit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            r.write_report(path, {"status": "blocked", "duration": 0, "message": "Permission missing"})
            self.assertIn('<error message="Permission missing"', (path / "junit.xml").read_text())




class LauncherTests(unittest.TestCase):
    def test_driver_completion_survives_launcher_exit_one(self):
        from unittest.mock import patch
        class FakeApp:
            def __init__(self, executable, args, directory, log_name):
                self.directory = directory
                self.log_name = log_name
            def wait(self, timeout):
                (self.directory / self.log_name).write_text('{"accessibility": true}')
                (self.directory / "completed").write_text("success")
            def poll(self):
                return 1
        with patch.object(r, "LaunchedApp", FakeApp):
            self.assertTrue(r.run_driver(Path('/app/Contents/MacOS/driver'), 'inventory')['accessibility'])

    def test_response_without_completion_is_rejected(self):
        from unittest.mock import patch
        class IncompleteApp:
            def __init__(self, executable, args, directory, log_name):
                (directory / log_name).write_text('{"frame": [0,0,720,600]}')
            def wait(self, timeout):
                return 0
            def poll(self):
                return 0
        with patch.object(r, "LaunchedApp", IncompleteApp):
            with self.assertRaises(r.DriverFailure):
                r.run_driver(Path('/app/Contents/MacOS/driver'), 'frame')

    def test_timeout_cancels_app_before_removing_private_directory(self):
        from unittest.mock import patch
        events = []
        class StalledApp:
            def __init__(self, executable, args, directory, log_name):
                self.directory = directory
                self.stopped = False
            def wait(self, timeout):
                if not self.stopped:
                    raise r.subprocess.TimeoutExpired('open', timeout)
                events.append(('wait', self.directory.exists()))
            def poll(self):
                return 0 if self.stopped else None
            def terminate(self):
                events.append(('cancel', self.directory.exists()))
                self.stopped = True
        with patch.object(r, "LaunchedApp", StalledApp):
            with self.assertRaises(r.DriverFailure):
                r.run_driver(Path('/app/Contents/MacOS/driver'), 'drag')
        self.assertEqual(events, [('cancel', True), ('wait', True)])

    def test_forced_cleanup_refuses_reused_pid(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            app = object.__new__(r.LaunchedApp)
            app.directory = Path(temporary)
            app.executable = Path('/test/Contents/MacOS/app')
            (app.directory / 'app.pid').write_text('1234')
            with patch.object(r.subprocess, 'check_output', return_value='/unrelated/app'), patch.object(r.os, 'kill') as kill:
                app.kill()
                kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()

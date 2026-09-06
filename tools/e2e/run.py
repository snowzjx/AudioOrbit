#!/usr/bin/env python3
"""Local Safari/display integration runner. Python 3 standard library only."""
import argparse
import collections
import fcntl
import hashlib
import html
import http.server
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET


class TestFailure(Exception):
    category = "routing_failure"


class Blocked(TestFailure):
    category = "blocked"


class DriverFailure(TestFailure):
    category = "driver_failure"


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


class LaunchedApp:
    """LaunchServices owns TCC attribution; the waiter is not the app process."""
    def __init__(self, executable, args, directory, log_name="app.log"):
        self.directory = Path(directory)
        self.executable = Path(executable)
        self.waiter = subprocess.Popen([
            "/usr/bin/open", "-n", "-g", "-W",
            "--stdout", str(self.directory / log_name),
            "--stderr", str(self.directory / "stderr.log"),
            str(self.executable.parents[2]), "--args", *map(str, args)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def poll(self):
        return self.waiter.poll()

    def terminate(self):
        (self.directory / "stop.request").touch()

    def wait(self, timeout):
        return self.waiter.wait(timeout=timeout)

    def kill(self):
        # Never confuse the LaunchServices waiter with the application. Only
        # signal a PID whose live command still identifies this private run.
        try:
            pid = int((self.directory / "app.pid").read_text())
            command = subprocess.check_output(
                ["/bin/ps", "-p", str(pid), "-o", "command="], text=True)
            if str(self.executable) in command and str(self.directory) in command:
                os.kill(pid, signal.SIGKILL)
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass


def run_driver(driver, *args, timeout=8):
    with tempfile.TemporaryDirectory(prefix="audioorbit-driver-") as temporary:
        directory = Path(temporary)
        process = None
        try:
            process = LaunchedApp(driver, ["--managed-directory", directory,
                os.getpid(), *args], directory, "response.json")
            process.wait(timeout)
            result = json.loads((directory / "response.json").read_text())
            if "error" in result:
                raise DriverFailure(result["error"])
            # open -W intermittently exits 1 after a successful short-lived
            # launch. Require the driver's atomic completion acknowledgement;
            # a partial response or launcher-only success cannot pass.
            if (directory / "completed").read_text() != "success":
                raise DriverFailure(f"Driver did not finish: {args[0]}")
            return result
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            raise DriverFailure(f"Desktop driver did not respond to {args[0]}") from error
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(3)


def validate_config(config, inventory):
    if not isinstance(config, dict):
        raise Blocked("The local configuration must be a JSON object.")
    targets = config.get("targets", [])
    if not isinstance(targets, list) or len(targets) != 2 or not all(isinstance(t, dict) and isinstance(t.get("displayUUID"), str) and isinstance(t.get("outputUID"), str) for t in targets):
        raise Blocked("Configure exactly two targets: displayUUID and outputUID for A and B.")
    displays = {d["uuid"].upper(): d for d in inventory["displays"] if not d["mirrored"]}
    outputs = {d["uid"] for d in inventory["outputs"] if d["alive"]}
    if len({t.get("displayUUID", "").upper() for t in targets}) != 2 or len({t.get("outputUID") for t in targets}) != 2:
        raise Blocked("A and B must use distinct, non-mirrored displays and distinct outputs.")
    for target in targets:
        if target.get("displayUUID", "").upper() not in displays or target.get("outputUID") not in outputs:
            raise Blocked("A configured display/output is unavailable or mirrored. Run inventory and update the local configuration.")
    for key, default in (("initialTimeout", 15), ("moveTimeout", 5), ("holdSeconds", 1)):
        value = config.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < (1 if key == "holdSeconds" else 2) or value > 120:
            raise Blocked(f"Invalid {key}; deadlines must be finite and bounded (2–120 s; hold 1–120 s).")
    return [displays[t["displayUUID"].upper()] for t in targets]


def preflight(inventory, config=None):
    issues = []
    if not inventory["accessibility"] or not inventory["postEvents"]:
        checks = []
        if not inventory["accessibility"]:
            checks.append("Accessibility")
        if not inventory["postEvents"]:
            checks.append("mouse-event posting")
        issues.append("AudioOrbit E2E Driver permission check failed: " + ", ".join(checks) + ". "
                      "Enable the installed driver in System Settings → Privacy & Security → Accessibility. "
                      "If it is already enabled, remove that driver's entry and add the installed copy again; "
                      "an earlier build may have left a permission tied to a different code signature. "
                      "Driver: " + inventory.get("driverBundle", "~/Applications/AudioOrbit Tests/AudioOrbit E2E Driver.app"))
    if not inventory["sessionReady"]:
        issues.append("Use a logged-in, unlocked foreground macOS desktop.")
    if any(a in inventory["apps"] for a in ("me.snowzjx.AudioOrbit", "me.snowzjx.AudioOrbit.E2E")):
        issues.append("Quit the existing AudioOrbit instance before running the isolated test app.")
    if inventory["playing"]:
        issues.append("Pause other audio/video playback before running (prefer a dedicated test account).")
    if config is None:
        issues.append("Provide --config with two display/output mappings; use configure to copy your current AudioOrbit mappings.")
    else:
        try:
            validate_config(config, inventory)
        except Blocked as error:
            issues.append(str(error))
    return issues


class RouteCheck:
    """Independent oracle: manifest expectations, real binding, fresh deltas."""
    def __init__(self, run_id, output_uid, display_uuid, hold=1):
        self.run_id = run_id
        self.output_uid = output_uid
        self.display_uuid = display_uuid.upper()
        self.hold = hold
        self.instance = None
        self.sequence = -1
        self.last_fresh = None
        self.baseline = None
        self.stable_since = None
        self.reason = "Waiting for a live automatic Safari route"

    def observe(self, snapshot, now):
        if snapshot.get("schema") != 1 or snapshot.get("runID") != self.run_id:
            raise DriverFailure("Observation schema/run mismatch")
        if self.instance is not None and self.instance != snapshot.get("instanceID"):
            raise DriverFailure("AudioOrbit restarted during the test")
        self.instance = snapshot.get("instanceID")
        sequence = snapshot.get("sequence")
        if not self.instance or not isinstance(sequence, int):
            raise DriverFailure("Invalid observation identity")
        if sequence < self.sequence:
            raise DriverFailure("Observation sequence went backwards")
        if sequence == self.sequence:
            if self.last_fresh is not None and now - self.last_fresh > 1.5:
                raise DriverFailure("AudioOrbit observation stream stalled")
            return False
        self.sequence, self.last_fresh = sequence, now
        if not snapshot.get("accessibility"):
            raise Blocked("Grant Accessibility to the separate AudioOrbit E2E app, then rerun.")
        routes = snapshot.get("routes", [])
        if len(routes) != 1:
            self.baseline = None
            self.stable_since = None
            self.reason = f"Expected one live route, observed {len(routes)}"
            return False
        route = routes[0]
        valid = (snapshot.get("enabled") and route.get("bundleID") == "com.apple.Safari"
                 and route.get("automatic") and route.get("state") == "running"
                 and route.get("rendererStarted") and not route.get("bindingError")
                 and route.get("actualUID") == self.output_uid
                 and route.get("requestedUID") == self.output_uid
                 and route.get("displayUUID", "").upper() == self.display_uuid)
        if not valid:
            self.baseline = None
            self.stable_since = None
            self.reason = "Live Safari route/actual HAL binding does not match the expected display and output"
            return False
        counters = tuple(route.get(key, 0) for key in ("captured", "rendered", "nonSilent", "captureCallbacks", "renderCallbacks"))
        generation = route.get("generation")
        if not generation:
            raise DriverFailure("Missing route generation")
        if self.baseline is None or self.baseline[0] != generation:
            self.baseline = generation, counters, now
            self.stable_since = now
            return False
        if any(a < b for a, b in zip(counters, self.baseline[1])):
            raise DriverFailure("Audio counters reset without a new route generation")
        if not all(a > b for a, b in zip(counters, self.baseline[1])):
            self.reason = "Audio capture/render/non-silent counters did not advance"
            self.stable_since = now
            return False
        self.baseline = generation, counters, now
        self.reason = "Correct renderer binding with advancing audio"
        return now - self.stable_since >= self.hold


def byte_range(header, length):
    if not header:
        return 0, length - 1, False
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
    if not match or not any(match.groups()):
        raise ValueError("Invalid range")
    start, end = match.groups()
    if not start:
        if int(end) <= 0:
            raise ValueError("Invalid suffix")
        return max(0, length - int(end)), length - 1, True
    start = int(start)
    end = min(int(end), length - 1) if end else length - 1
    if start >= length or end < start:
        raise ValueError("Unsatisfiable range")
    return start, end, True


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, video, run_id):
        self.video = video
        self.run_id = run_id
        self.states = {}
        self.state_lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def state(self, token):
        with self.state_lock:
            return dict(self.states.get(token, {}))


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == f"/{self.server.run_id}/video.mp4":
            size = self.server.video.stat().st_size
            try:
                start, end, partial = byte_range(self.headers.get("Range"), size)
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with self.server.video.open("rb") as source:
                    source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        block = source.read(min(65536, remaining))
                        if not block:
                            break
                        self.wfile.write(block)
                        remaining -= len(block)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        tokens = (self.server.run_id, self.server.run_id + "-silent")
        token = parsed.path.strip("/")
        if token not in tokens:
            self.send_error(404)
            return
        silent = token.endswith("-silent")
        body = ("<!doctype html><meta charset='utf-8'><title>AudioOrbit E2E " + token + " END</title>"
                "<style>body{font:20px system-ui;margin:24px;background:#102030;color:white}button{font:inherit;padding:12px;margin:8px}video{width:100%;max-width:640px}</style>"
                "<h1>AudioOrbit test window</h1>" + ("<p>Silent focus-test window</p>" if silent else f"""
                <button aria-label="Orbit Play" onclick="v.play().catch(e=>error=e.message)">Play</button>
                <button aria-label="Orbit Pause" onclick="v.pause()">Pause</button>
                <button aria-label="Orbit Fullscreen" onclick="v.webkitEnterFullscreen()">Fullscreen</button>
                <video id="v" loop playsinline preload="auto" src="/{self.server.run_id}/video.mp4"></video>
                <p id="status">Ready</p>
                <script>
                let error='',total=0,last=0; const v=document.getElementById('v');
                setInterval(()=>{{const t=v.currentTime;const delta=t-last;
                  if(!v.paused && delta>0 && delta<1)total+=delta;last=t;
                  document.getElementById('status').textContent='Playback: '+t.toFixed(2)+' seconds';
                  fetch('/{token}/state',{{method:'POST',headers:{{'Content-Type':'application/json'}},
                    body:JSON.stringify({{time:t,total,paused:v.paused,muted:v.muted,volume:v.volume,
                      ready:v.readyState,fullscreen:!!v.webkitDisplayingFullscreen,error}})}}).catch(()=>{{}});
                }},200);
                </script>""")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if self.path != f"/{self.server.run_id}/state":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 4096:
                raise ValueError()
            state = json.loads(self.rfile.read(length))
            if not isinstance(state, dict):
                raise ValueError()
            state["received"] = time.monotonic()
            with self.server.state_lock:
                self.server.states[self.server.run_id] = state
        except (ValueError, TypeError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()


def write_report(directory, report):
    write_json(directory / "report.json", report)
    suite = ET.Element("testsuite", name="safari-smoke", tests="1", failures=str(int(report["status"] in ("routing_failure", "driver_failure", "interrupted"))), errors=str(int(report["status"] == "blocked")))
    case = ET.SubElement(suite, "testcase", name="Safari A-B-A and focus", time=str(round(report["duration"], 3)))
    if report["status"] != "passed":
        ET.SubElement(case, "error" if report["status"] == "blocked" else "failure", message=report.get("message", ""))
    ET.ElementTree(suite).write(directory / "junit.xml", encoding="utf-8", xml_declaration=True)
    content = html.escape(json.dumps(report, indent=2))
    (directory / "report.html").write_text("<!doctype html><meta charset='utf-8'><title>AudioOrbit test</title><style>body{font:16px system-ui;margin:40px;max-width:1000px}pre{white-space:pre-wrap}</style><h1>AudioOrbit Safari smoke test</h1><p>Software verification only; physical sound is unverified.</p><pre>" + content + "</pre>")


class Runner:
    def __init__(self, args, config):
        self.args, self.config = args, config
        self.build = Path(args.build_dir)
        self.apps = Path(args.apps_dir).expanduser()
        self.driver = self.apps / "AudioOrbit E2E Driver.app/Contents/MacOS/AudioOrbitE2EDriver"
        self.run_id = str(uuid.uuid4())
        self.directory = Path(tempfile.mkdtemp(prefix="audioorbit-e2e-"))
        self.app = self.watcher = self.awake = self.server = None
        self.windows = []
        self.trace = collections.deque(maxlen=6000)
        self.aliases = {}
        self.report = {"runID": self.run_id, "verification": "software", "status": "blocked", "steps": [], "cleanup": []}
        self.started = time.monotonic()
        self.lock = None
        self.app_log = None
        self.last_snapshot_read = None

    def call(self, *args, **kwargs):
        return run_driver(self.driver, *args, **kwargs)

    def clean_snapshot(self, snapshot):
        result = {k: snapshot.get(k) for k in ("sequence", "uptime", "enabled", "accessibility")}
        result["routes"] = []
        for route in snapshot.get("routes", []):
            item = {k: route.get(k) for k in ("state", "automatic", "rendererStarted", "captured", "rendered", "nonSilent", "underflow", "overflow", "queued")}
            for key in ("generation", "windowID", "actualUID", "requestedUID", "displayUUID"):
                value = route.get(key, "")
                if not value:
                    item[key] = "unavailable"
                else:
                    self.aliases.setdefault(value, f"identity-{len(self.aliases) + 1}")
                    item[key] = self.aliases[value]
            item["bindingError"] = bool(route.get("bindingError"))
            result["routes"].append(item)
        return result

    def snapshot(self):
        if self.app.poll() is not None:
            raise DriverFailure("AudioOrbit E2E exited unexpectedly; inspect the private app log")
        if self.watcher.poll() is not None:
            raise DriverFailure("Independent default-output observer exited")
        if (self.directory / "default-changed").exists():
            raise TestFailure("System default output changed during the test")
        try:
            data = json.loads((self.directory / "snapshot.json").read_text())
        except (OSError, ValueError):
            if self.last_snapshot_read is not None and time.monotonic() - self.last_snapshot_read > 1.5:
                raise DriverFailure("AudioOrbit observation file disappeared or became unreadable")
            return None
        self.last_snapshot_read = time.monotonic()
        if not self.trace or self.trace[-1].get("sequence") != data.get("sequence"):
            self.trace.append(self.clean_snapshot(data))
        return data

    def geometry(self, token, target, timeout=5):
        deadline = time.monotonic() + timeout
        stable_since, previous = None, None
        while time.monotonic() < deadline:
            bounds = self.call("frame", token)["frame"]
            x, y, w, h = bounds
            tx, ty, tw, th = target["frame"]
            inside = x >= tx and y >= ty and x + w <= tx + tw and y + h <= ty + th
            unchanged = previous is not None and all(abs(a - b) < 2 for a, b in zip(bounds, previous))
            if inside and unchanged:
                stable_since = stable_since or time.monotonic()
                if time.monotonic() - stable_since >= 0.3:
                    return bounds
            else:
                stable_since = None
            previous = bounds
            time.sleep(0.1)
        raise DriverFailure(f"Fixture window did not settle inside the requested display: window={bounds}, display={target['frame']}")

    def route(self, label, target_index, timeout):
        target = self.config["targets"][target_index]
        checker = RouteCheck(self.run_id, target["outputUID"], target["displayUUID"], self.config.get("holdSeconds", 1))
        start = time.monotonic()
        playing_baseline = self.server.state(self.run_id).get("total", 0)
        last_geometry = 0
        while time.monotonic() - start < timeout:
            now = time.monotonic()
            state = self.server.state(self.run_id)
            if now - state.get("received", 0) > 2 or state.get("paused", True) or state.get("muted") or state.get("volume", 0) <= 0:
                raise DriverFailure("Fixture playback stopped or telemetry became stale")
            if now - last_geometry > 0.8:
                self.geometry(self.run_id, self.displays[target_index], timeout=1.5)
                last_geometry = time.monotonic()
            snapshot = self.snapshot()
            if time.monotonic() - start >= timeout:
                break
            if snapshot is not None and checker.observe(snapshot, time.monotonic()) and state.get("total", 0) > playing_baseline + 0.5:
                self.report["steps"].append({"name": label, "status": "passed", "seconds": round(time.monotonic() - start, 3), "output": "AB"[target_index], "evidence": self.clean_snapshot(snapshot)})
                return
            time.sleep(0.1)
        raise TestFailure(f"{label}: {checker.reason}")

    def execute(self):
        # A per-user lock spans all build directories and all fixture windows.
        lock_path = Path(tempfile.gettempdir()) / f"audioorbit-e2e-{os.getuid()}.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, "w")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Blocked("Another AudioOrbit desktop test is running") from error
        inventory = self.call("inventory")
        issues = preflight(inventory, self.config)
        if issues:
            raise Blocked("\n".join(issues))
        self.displays = validate_config(self.config, inventory)
        self.report.update({"macOS": inventory["macOS"], "safariVersion": inventory["safariVersion"]})
        for i, target in enumerate(self.config["targets"]):
            self.aliases[target["outputUID"]] = "output-" + "AB"[i]
            self.aliases[target["displayUUID"].upper()] = "display-" + "AB"[i]
        self.report["topology"] = [{"display": "AB"[i], "frame": d["frame"]} for i, d in enumerate(self.displays)]
        video = self.build / "fixture.mp4"
        app_path = self.apps / "AudioOrbit E2E.app/Contents/MacOS/AudioOrbit"
        if not app_path.exists() or not video.exists():
            raise Blocked("Run ./scripts/test-e2e.sh build first")
        self.report["fixtureSHA256"] = hashlib.sha256(video.read_bytes()).hexdigest()
        self.report["appSHA256"] = hashlib.sha256(app_path.read_bytes()).hexdigest()
        manifest = {"runID": self.run_id, "runnerPID": os.getpid()}
        write_json(self.directory / "manifest.json", manifest)
        mappings = [{"displayUUID": t["displayUUID"], "displayNameHint": "display-" + "AB"[i],
                     "audioDeviceUID": t["outputUID"], "audioDeviceNameHint": "output-" + "AB"[i], "behavior": "routeToDevice"} for i, t in enumerate(self.config["targets"])]
        write_json(self.directory / "mappings.json", {"schemaVersion": 3, "mappings": mappings, "routingEnabled": True, "cachedRoutes": [], "ignoredApplications": [], "headphoneOverrideEnabled": False})
        self.watcher = subprocess.Popen([str(self.driver), "default-watch", str(self.directory / "default-changed")], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        with selectors.DefaultSelector() as selector:
            selector.register(self.watcher.stdout, selectors.EVENT_READ)
            if not selector.select(5):
                raise DriverFailure("Default-output observer did not start")
            response = json.loads(self.watcher.stdout.readline())
        if response.get("defaultUID") != inventory["defaultUID"]:
            raise DriverFailure("Default output changed during preflight")
        self.awake = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(os.getpid())])
        self.app = LaunchedApp(app_path, ["--e2e-directory", self.directory], self.directory)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            snapshot = self.snapshot()
            if snapshot is not None:
                if not snapshot.get("accessibility"):
                    raise Blocked("Grant Accessibility to AudioOrbit E2E (the test app), then rerun.")
                break
            time.sleep(0.1)
        else:
            raise DriverFailure("AudioOrbit did not publish its first observation")
        self.server = FixtureServer(video, self.run_id)
        url = f"http://127.0.0.1:{self.server.server_port}/{self.run_id}"
        owned = self.call("open", url, timeout=20)["windowID"]
        self.windows.append((owned, self.run_id))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.call("frame", self.run_id)
                break
            except DriverFailure:
                time.sleep(0.2)
        width = min(1000, *(d["frame"][2] - 120 for d in self.displays))
        height = min(600, *(d["frame"][3] - 160 for d in self.displays))
        if width < 640 or height < 480:
            raise Blocked("Displays need enough room for a 640×480 Safari fixture window plus margins")
        positions = [(d["frame"][0] + 60, d["frame"][1] + 70) for d in self.displays]
        self.call("place", self.run_id, *positions[0], width, height)
        self.geometry(self.run_id, self.displays[0])
        self.call("click", self.run_id, "Orbit Play")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.server.state(self.run_id)
            if state.get("total", 0) > 0.5 and not state.get("paused"):
                break
            time.sleep(0.1)
        else:
            raise DriverFailure("Safari did not start the fixture video after Play")
        self.route("Initial playback on A", 0, self.config.get("initialTimeout", 15))
        for i in range(self.args.repeat):
            for target_index in (1, 0):
                started = time.monotonic()
                self.call("drag", self.run_id, *positions[target_index])
                released = time.monotonic()
                self.geometry(self.run_id, self.displays[target_index])
                self.route(f"Move {i + 1} to {'AB'[target_index]}", target_index, self.config.get("moveTimeout", 5))
                self.report["steps"][-1].update({"fromReleaseSeconds": round(time.monotonic() - released, 3), "includingDragSeconds": round(time.monotonic() - started, 3)})
        token = self.run_id + "-silent"
        owned = self.call("open", url + "-silent", timeout=20)["windowID"]
        self.windows.append((owned, token))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.call("place", token, *positions[1], width, height)
                break
            except DriverFailure:
                time.sleep(0.2)
        self.geometry(token, self.displays[1])
        self.call("focus", token)
        self.route("Focus silent window on B; playback remains on A", 0, self.config.get("moveTimeout", 5))
        self.snapshot()
        self.report["status"] = "passed"
        self.report["message"] = "Safari A→B→A and focus checks passed in software. Physical audio is unverified."

    def cleanup(self):
        if self.windows:
            try:
                self.call("release-mouse")
            except TestFailure as error:
                self.report["cleanup"].append(f"Mouse release failed: {error}")
        for owned, token in reversed(self.windows):
            try:
                if not self.call("close", owned, self.run_id, timeout=10).get("closed"):
                    self.report["cleanup"].append("An owned window changed; left it open to preserve its contents")
            except TestFailure:
                self.report["cleanup"].append("Could not close an owned Safari window")
        for name in ("app", "watcher", "awake"):
            process = getattr(self, name)
            if process is not None:
                try:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
                    self.report["cleanup"].append(f"Forced termination of test {name}; normal cleanup was incomplete")
        if self.app_log:
            self.app_log.close()
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        if self.lock:
            self.lock.close()
        if (self.directory / "default-changed").exists() and self.report["status"] == "passed":
            self.report["status"] = "routing_failure"
            self.report["message"] = "System default output changed during teardown"
        if self.report["cleanup"] and self.report["status"] == "passed":
            self.report["status"] = "driver_failure"
            self.report["message"] = "Checks passed but cleanup was incomplete"
        self.report["duration"] = time.monotonic() - self.started
        write_json(self.directory / "trace.json", list(self.trace))
        # Private transient state contains correlation IDs; reports use aliases.
        for name in ("snapshot.json", "mappings.json", "manifest.json"):
            (self.directory / name).unlink(missing_ok=True)
        write_report(self.directory, self.report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="/tmp/AudioOrbitE2E")
    parser.add_argument("--apps-dir", default=str(Path.home() / "Applications/AudioOrbit Tests"))
    parser.add_argument("command", choices=("inventory", "configure", "preflight", "run", "help"), nargs="?", default="help")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--suite", choices=("safari-smoke",), default="safari-smoke")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if args.command == "help":
        parser.print_help()
        print("First: ./scripts/test-e2e.sh build\nThen: configure --config /path/to/local-lab.json; preflight --config ...; run --config ...")
        return 0
    if not 1 <= args.repeat <= 100:
        parser.error("--repeat must be 1–100")
    driver = Path(args.apps_dir).expanduser() / "AudioOrbit E2E Driver.app/Contents/MacOS/AudioOrbitE2EDriver"
    if not driver.exists():
        raise Blocked("Build the test tools first: ./scripts/test-e2e.sh build")
    config = json.loads(args.config.read_text()) if args.config and args.config.exists() else None
    if args.command == "run":
        runner = Runner(args, config)
        def interrupt(*_):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, interrupt)
        try:
            runner.execute()
        except TestFailure as error:
            runner.report.update(status=error.category, message=str(error))
        except KeyboardInterrupt:
            runner.report.update(status="interrupted", message="Run interrupted")
        except Exception as error:
            runner.report.update(status="driver_failure", message=f"Runner error: {type(error).__name__}: {error}")
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            runner.cleanup()
        print(runner.report["status"] + ": " + runner.report.get("message", ""))
        print("Report: " + str(runner.directory / "report.html"))
        return 0 if runner.report["status"] == "passed" else (2 if runner.report["status"] == "blocked" else 1)
    inventory = run_driver(driver, "inventory")
    if args.command == "inventory":
        print(json.dumps(inventory, indent=2))
    elif args.command == "configure":
        if args.config is None or args.config.exists():
            raise Blocked("Supply --config with a new local file path; existing configurations are not overwritten.")
        saved = Path.home() / "Library/Application Support/AudioOrbit/configuration-v1.json"
        mappings = json.loads(saved.read_text()).get("mappings", []) if saved.exists() else []
        active = {d["uuid"].upper() for d in inventory["displays"] if not d["mirrored"]}
        targets = [{"displayUUID": m["displayUUID"], "outputUID": m["audioDeviceUID"]} for m in mappings if m.get("behavior") == "routeToDevice" and m["displayUUID"].upper() in active]
        if len(targets) != 2:
            raise Blocked("Could not select exactly two current mappings. Use inventory and create a configuration using tools/e2e/lab.example.json.")
        config = {"targets": targets, "initialTimeout": 15, "moveTimeout": 5, "holdSeconds": 1}
        validate_config(config, inventory)
        write_json(args.config, config)
        print("Copied your current display/output mappings to " + str(args.config))
    else:
        issues = preflight(inventory, config)
        print("\n".join(issues) if issues else "Preflight passed. First app/Automation permission prompts may still need approval on the initial run.")
        return 2 if issues else 0
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except (TestFailure, OSError, ValueError) as error:
        print(f"{getattr(error, 'category', 'blocked')}: {error}", file=sys.stderr)
        sys.exit(2)

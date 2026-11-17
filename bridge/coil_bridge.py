"""coil's bridge: one Jupyter kernel, spoken to by Emacs in JSON lines.

Emacs starts this as a plain subprocess, in the project's environment, and
talks to it on stdin and stdout, one JSON object per line.  It attaches to the
project's kernel if one is running, or starts one, detached, so that it
outlives this process and Emacs.  When Emacs goes, so does the bridge; the
kernel stays.

It speaks the Jupyter protocol, not Python: the kernel's command line is
given to it, so any kernel will do.

Security (see the README):
- the kernel listens on Unix sockets (transport "ipc") in the state
  directory, which must be the user's own and closed to everyone else (0700);
- messages are signed with a random key, which is in the connection file
  (0600), never on the command line;
- outputs are passed on as data, and only the MIME types Emacs draws:
  nothing in them is acted on here.

Requests (Emacs -> bridge), each with an integer "id":
  {"op": "execute", "code": ...}      runs code; events follow, then "done"
      with "breakpoints": [[file, line, temporary], ...], it stops there
      (a null file is this code's own); see coil_debug.py
  {"op": "complete", "code", "pos"}   -> {"event": "reply", "content": ...}
  {"op": "inspect", "code", "pos", "detail"}
  {"op": "is_complete", "code"}
  {"op": "input", "value"}            answers an input_request
  {"op": "interrupt"}
  {"op": "shutdown"}                  stops the kernel, then this

Events (bridge -> Emacs): "ready", "missing", "fatal", "status", "input"
(execution count), "stream", "display", "result", "error", "clear",
"input_request", "done", "reply", "died", "shutdown"; and "codefile", the
name of the file the kernel runs code as (pdb shows it).
"""

import argparse
import json
import os
import queue
import secrets
import signal
import stat
import subprocess
import sys
import time

# What Emacs is given of each output: what it draws, and the text to fall
# back on.  Anything else (HTML, JavaScript, SVG, LaTeX) stays here.
MIME_TYPES = ("text/plain", "image/png", "image/jpeg")
MAX_MESSAGE = 50 * 1024 * 1024

# Our own channel to Emacs; stdout itself goes to stderr, so that a stray
# print from a library cannot break the stream.
OUT = os.fdopen(os.dup(1), "w", encoding="utf-8")
os.dup2(2, 1)


def emit(event, **fields):
    line = json.dumps({"event": event, **fields}, separators=(",", ":"), default=str)
    if len(line) > MAX_MESSAGE:
        line = json.dumps(
            {"event": event, "id": fields.get("id"),
             "data": {"text/plain": f"[output of {len(line) // 2**20} MB not shown]"}})
    OUT.write(line + "\n")
    OUT.flush()


# The kernel's breakpoint helper (coil_debug.py), installed as the module
# _coil_debug by a silent run of this, in a namespace of its own: the
# session's is left alone.  A version installed before steps aside.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "coil_debug.py"),
          encoding="utf-8") as _f:
    _source = _f.read()
DEBUG_INSTALL = (
    "exec(%r, {'__name__': '_coil_install'})"
    % ("import sys, types\n"
       "_old = sys.modules.get('_coil_debug')\n"
       "if _old is not None and hasattr(_old, 'uninstall'): _old.uninstall()\n"
       "_m = types.ModuleType('_coil_debug')\n"
       "exec(%r, _m.__dict__)\n"
       "sys.modules['_coil_debug'] = _m\n" % _source))

_hash = []


def cell_file_name(code):
    """The name of the file ipykernel runs CODE as: its hash, and .py.

    The directory (the kernel's own) is left out: Emacs knows a cell's file
    by its name.  None if this ipykernel names cells otherwise.
    """
    if not _hash:
        try:
            from ipykernel.compiler import get_tmp_hash_seed, murmur2_x86
            _hash.append(lambda code: "%d.py" % murmur2_x86(code, get_tmp_hash_seed()))
        except Exception:
            _hash.append(None)
    return _hash[0] and _hash[0](code)


try:
    import zmq
    from jupyter_client import BlockingKernelClient
    from jupyter_client.connect import write_connection_file
except ImportError as error:
    emit("missing", what=str(error))
    sys.exit(3)


# --- The state directory ----------------------------------------------------


def check_state(directory):
    """Make DIRECTORY, or insist that it is the user's and closed to others."""
    os.makedirs(directory, mode=0o700, exist_ok=True)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        emit("fatal", message=f"{directory} is not a directory of your own")
        sys.exit(4)
    if info.st_mode & 0o077:
        os.chmod(directory, 0o700)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, TypeError):
        return False
    except PermissionError:
        return False  # someone else's process now: not our kernel
    return True


def read_pid(state):
    try:
        with open(os.path.join(state, "kernel.pid")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def connect(connection_file, timeout):
    client = BlockingKernelClient()
    client.load_connection_file(connection_file)
    client.start_channels(hb=False)
    try:
        client.wait_for_ready(timeout=timeout)
    except RuntimeError:
        client.stop_channels()
        return None
    return client


def create_subshell(client, features):
    """A subshell of the kernel's (JEP 91), or None if it has none."""
    if "kernel subshells" not in features:
        return None
    msg = client.session.msg("create_subshell_request", {})
    client.control_channel.send(msg)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            reply = client.control_channel.get_msg(timeout=1)
        except queue.Empty:
            continue
        if reply["parent_header"].get("msg_id") == msg["header"]["msg_id"]:
            return reply["content"].get("subshell_id")
    return None


def clear(state):
    for name in os.listdir(state):
        if name in ("kernel.json", "kernel.pid") or name.startswith("k-"):
            try:
                os.remove(os.path.join(state, name))
            except OSError:
                pass


def start(state, cwd, argv_template):
    """Start a kernel, detached, and return (client, pid, process)."""
    clear(state)
    connection_file = os.path.join(state, "kernel.json")
    old = os.umask(0o077)
    try:
        write_connection_file(
            connection_file, transport="ipc", ip=os.path.join(state, "k"),
            key=secrets.token_hex(32).encode())
    finally:
        os.umask(old)
    argv = [a.replace("{connection_file}", connection_file)
             .replace("{python}", sys.executable) for a in argv_template]
    env = dict(os.environ)
    env.pop("JPY_PARENT_PID", None)  # else ipykernel dies with its parent
    with open(os.path.join(state, "kernel.log"), "ab", buffering=0) as log:
        os.chmod(log.name, 0o600)
        process = subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log,
            stderr=log, start_new_session=True)
    with open(os.path.join(state, "kernel.pid"), "w") as f:
        f.write(str(process.pid))
    client = connect(connection_file, timeout=60)
    if client is None:
        process.kill()
        emit("fatal", message="the kernel did not start: see "
             + os.path.join(state, "kernel.log"))
        sys.exit(5)
    return client, process.pid, process


# --- Serving Emacs ----------------------------------------------------------


class Bridge:
    def __init__(self, state, client, pid, process=None, subshell=None):
        self.state = state
        self.subshell = subshell  # where completion and docs are asked
        self.client = client
        self.pid = pid
        self.process = process  # ours, if we started it: to reap
        self.ids = {}           # kernel msg_id -> Emacs request id
        self.ops = {}           # kernel msg_id -> op
        self.halves = {}        # execute msg_id -> set of {"reply", "idle"}
        self.replies = {}

    def request(self, message):
        op, rid, c = message.get("op"), message.get("id"), self.client
        if op == "execute":
            code = message["code"]
            name = cell_file_name(code)
            breaks = message.get("breakpoints")
            if breaks:
                # The helper, told what the cell is to stop at, first.
                c.execute(DEBUG_INSTALL + "\n__import__('sys').modules['_coil_debug'].expect(%r, %r)"
                          % (name, [tuple(b) for b in breaks]),
                          silent=True, store_history=False)
            msg_id = c.execute(code, store_history=True,
                               allow_stdin=True, stop_on_error=True)
            if name:
                emit("codefile", id=rid, name=name)
        elif op == "complete":
            msg_id = self.side("complete_request", {
                "code": message["code"], "cursor_pos": message.get("pos")})
        elif op == "inspect":
            msg_id = self.side("inspect_request", {
                "code": message["code"], "cursor_pos": message.get("pos"),
                "detail_level": message.get("detail", 0)})
        elif op == "is_complete":
            msg_id = self.side("is_complete_request", {"code": message["code"]})
        elif op == "input":
            c.input(message.get("value", ""))
            return
        elif op == "interrupt":
            if self.pid and pid_alive(self.pid):
                os.kill(self.pid, signal.SIGINT)
            return
        elif op == "shutdown":
            self.shutdown()
        else:
            emit("reply", id=rid, content={"status": "error",
                                           "evalue": f"unknown op {op!r}"})
            return
        self.ids[msg_id] = rid
        self.ops[msg_id] = op

    def side(self, kind, content):
        """Ask the kernel on its subshell, if it has one: answered while code runs."""
        msg = self.client.session.msg(kind, content)
        if self.subshell:
            msg["header"]["subshell_id"] = self.subshell
        self.client.shell_channel.send(msg)
        return msg["header"]["msg_id"]

    def leave(self):
        """Go, leaving the kernel as it was."""
        if self.subshell:
            c = self.client
            c.control_channel.send(c.session.msg(
                "delete_subshell_request", {"subshell_id": self.subshell}))
            time.sleep(0.1)

    def shutdown(self):
        try:
            self.client.shutdown()
        except Exception:
            pass
        for _ in range(50):
            if not (self.pid and pid_alive(self.pid)):
                break
            if self.process:
                self.process.poll()
            time.sleep(0.1)
        else:
            os.kill(self.pid, signal.SIGKILL)
        clear(self.state)
        emit("shutdown")
        sys.exit(0)

    def finish(self, msg_id, half):
        halves = self.halves.setdefault(msg_id, set())
        halves.add(half)
        if halves == {"reply", "idle"}:
            content = self.replies.pop(msg_id, {})
            emit("done", id=self.ids.pop(msg_id), status=content.get("status"),
                 count=content.get("execution_count"))
            self.ops.pop(msg_id, None)
            del self.halves[msg_id]

    def iopub(self, msg):
        parent = msg["parent_header"].get("msg_id")
        rid = self.ids.get(parent)
        if rid is None or self.ops.get(parent) != "execute":
            return  # not ours, or not something with output
        kind, content = msg["msg_type"], msg["content"]
        if kind == "status":
            emit("status", id=rid, state=content["execution_state"])
            if content["execution_state"] == "idle":
                self.finish(parent, "idle")
        elif kind == "execute_input":
            emit("input", id=rid, count=content.get("execution_count"))
        elif kind == "stream":
            emit("stream", id=rid, name=content["name"], text=content["text"])
        elif kind in ("display_data", "update_display_data", "execute_result"):
            data = {k: v for k, v in content.get("data", {}).items() if k in MIME_TYPES}
            if kind == "execute_result":
                emit("result", id=rid, count=content.get("execution_count"), data=data)
            else:
                emit("display", id=rid, data=data)
        elif kind == "error":
            emit("error", id=rid, ename=content["ename"], evalue=content["evalue"],
                 traceback=content["traceback"])
        elif kind == "clear_output":
            emit("clear", id=rid, wait=content.get("wait", False))

    def shell(self, msg):
        parent = msg["parent_header"].get("msg_id")
        if parent not in self.ids:
            return
        if self.ops.get(parent) == "execute":
            self.replies[parent] = msg["content"]
            self.finish(parent, "reply")
        else:
            emit("reply", id=self.ids.pop(parent), content=msg["content"])
            self.ops.pop(parent, None)

    def stdin(self, msg):
        parent = msg["parent_header"].get("msg_id")
        content = msg["content"]
        # What the kernel printed before asking (the debugger's place, say)
        # comes on another socket, and may come after the question: it is
        # passed on first.
        c = self.client
        deadline = time.monotonic() + 0.05
        while time.monotonic() < deadline:
            if c.iopub_channel.msg_ready():
                self.iopub(c.iopub_channel.get_msg(timeout=0))
            elif not c.iopub_channel.socket.poll(10):
                break
        emit("input_request", id=self.ids.get(parent), prompt=content.get("prompt", ""),
             password=bool(content.get("password")))

    def serve(self):
        c = self.client
        channels = {c.iopub_channel.socket: (c.iopub_channel, self.iopub),
                    c.shell_channel.socket: (c.shell_channel, self.shell),
                    c.stdin_channel.socket: (c.stdin_channel, self.stdin),
                    c.control_channel.socket: (c.control_channel, lambda msg: None)}
        poller = zmq.Poller()
        for socket in channels:
            poller.register(socket, zmq.POLLIN)
        poller.register(sys.stdin.fileno(), zmq.POLLIN)
        pending = b""
        checked = time.monotonic()
        while True:
            events = dict(poller.poll(500))
            if sys.stdin.fileno() in events:
                chunk = os.read(sys.stdin.fileno(), 1 << 16)
                if not chunk:
                    self.leave()
                    return  # Emacs is gone; the kernel stays
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if line.strip():
                        try:
                            self.request(json.loads(line))
                        except (ValueError, KeyError) as error:
                            emit("reply", id=None, content={"status": "error",
                                                            "evalue": str(error)})
            for socket, (channel, handle) in channels.items():
                if socket in events:
                    while channel.msg_ready():
                        handle(channel.get_msg(timeout=0))
            if time.monotonic() - checked > 2:
                checked = time.monotonic()
                if self.process:
                    self.process.poll()
                if not pid_alive(self.pid):
                    emit("died")
                    return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--kernel", required=True,
                        help="the kernel's command, a JSON list; {connection_file} "
                        "and {python} are filled in")
    parser.add_argument("--attach-only", action="store_true")
    args = parser.parse_args()

    state = os.path.abspath(args.state)
    check_state(state)
    connection_file = os.path.join(state, "kernel.json")
    pid = read_pid(state)
    client = None
    if pid and pid_alive(pid) and os.path.exists(connection_file):
        client = connect(connection_file, timeout=5)
    process = None
    fresh = client is None
    if fresh:
        if args.attach_only:
            emit("fatal", message="no kernel running")
            sys.exit(6)
        client, pid, process = start(state, args.cwd, json.loads(args.kernel))
    # Its own reply: those to the readiness checks may still be waiting.
    info = client.kernel_info()
    content = {}
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            reply = client.get_shell_msg(timeout=1)
        except queue.Empty:
            continue
        if reply["parent_header"].get("msg_id") == info:
            content = reply["content"]
            break
    subshell = create_subshell(client, content.get("supported_features", []))
    language = content.get("language_info", {})
    emit("ready", fresh=fresh, pid=pid,
         language=language.get("name"), version=language.get("version"),
         implementation=content.get("implementation"),
         implementation_version=content.get("implementation_version"),
         environment=sys.prefix,
         banner=content.get("banner", ""), subshell=bool(subshell))
    Bridge(state, client, pid, process, subshell).serve()


if __name__ == "__main__":
    main()

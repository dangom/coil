# coil

A Python session for Emacs, on a Jupyter kernel. You work in your `.py`
files, send code to the session, and get results, figures and errors back in
an ordinary Emacs buffer. The session lives on when Emacs closes.

The reference is **Positron's console**:
- a kernel per project;
- completion from the live objects, even while code runs;
- a plot history;
- sessions that survive a restart.

coil aims for the same experience, done the Emacs way: buffers, keys and
completion that behave like the rest of Emacs.

*Status: a first working version, used through a Doom config. See
[Status](#status) for what is tested and what is not done yet.*


## Using it

```elisp
(add-to-list 'load-path "~/projects/coil")
(require 'coil-python)
(add-hook 'python-base-mode-hook #'coil-python-mode)
```

A project needs `ipykernel` where its kernel runs. In a pixi project, coil
offers to add it to a **`dev` environment**, not to the project's
dependencies:
- `ipykernel` (and IPython with it) goes into `[feature.dev.dependencies]`;
- a `dev` environment is made of that feature, in the same solve group as
  the default one, so the packages they share have the same versions;
- the kernel runs in `dev`, fully activated (`pixi shell-hook -e dev`).

Your buffers, and the language server, keep the default environment. A
project with no `dev` environment runs its kernel in the buffer's own
environment. The name is `coil-python-pixi-environment`.

### In a `.py` buffer

These are python.el's keys, except `C-c C-c` and `C-c C-b`.

| Key | Sends |
|---|---|
| `C-c C-z`, `C-c C-p` | nothing; goes to the session, starting it if need be |
| `C-c C-c` | the top-level statement point is in: all of the function, class or block (decorators, `else`, `except` too), or the line; or the region |
| `C-c C-b` | the buffer (with `C-u`, its `if __name__ == "__main__"` block too) |
| `C-c C-r` | the region |
| `C-c C-e` | the statement at point, or the region |
| `C-c C-s` | a line read from the minibuffer |
| `C-M-x` | the function or class at point, with its decorators |
| `C-c C-n` | the `# %%` cell at point, then moves to the next |
| `C-c C-l` | `%run` the file |
| `C-c C-f`, `C-c C-d` | nothing; shows what the session knows of the name at point |
| `C-c C-k` | nothing; interrupts (with `C-u`, restarts the kernel) |

With `coil-eldoc-in-source`, eldoc there also asks the live session (after
the language server), for what only it knows: a data frame's columns, a
value's type.

`M-x run-python` and any other python.el REPL command open or send to coil's
session too: they are remapped while `coil-python-mode` is on.

After `C-c C-n`, the cell's `# %%` line shows how it went: `✓ 0.45 s`, or
`✗ ZeroDivisionError: division by zero`. Clicking it shows the output.

### In the session buffer

Type at the `»` prompt. `RET` runs the input when it is complete, and starts
an indented line when it is not (the kernel decides, as IPython does).

| Key | Does |
|---|---|
| `C-RET` | runs the input, complete or not |
| `C-j` | a new line |
| `TAB` | completes, from the live session |
| (eldoc) | the signature and summary of what is at point, from the live session: `pd.read_csv(filepath_or_buffer, *, sep, …) -> DataFrame  Read a comma-separated…` |
| `M-p` / `M-n` | the input history, kept across restarts |
| `C-c C-c`, `C-c C-k` | interrupt (with `C-u`, restart the kernel) |
| `C-c C-n` / `C-c C-p` | the next / previous cell |
| `C-c C-o` | every figure of the project, newest first |
| `C-c C-q` | shuts the kernel down |
| `C-c C-d` | detaches: the kernel runs on; `C-c C-z`, or any send, attaches again |

On a cell (the output is read-only, so plain letters are free):

| Key | Does |
|---|---|
| `n` / `p` | next / previous cell |
| `RET` | visits the code it came from (or copies it to the prompt) |
| `w` | copies its output |
| `o` | opens its figure at full size |
| `c` | pins its figure, as `coil-pin-function` does |
| `P` | every figure |
| `TAB` | unfolds long output |

**Other commands:**
- `coil-restart`;
- `coil-list-sessions`: every kernel coil knows of, with its pid, memory,
  uptime, and whether this Emacs is attached. `RET` attaches to one (or
  starts it) and shows it, `d` detaches, `k` kills, `g` looks again;
- `coil-trust` and `coil-untrust`;
- `coil-python-add-missing-imports`, which offers each import the language
  server cannot find.

### Debugging

It is IPython's debugger (pdb), in the session's own kernel, so everything
the session has defined is there to look at. coil follows it in the source,
as edebug does.

| Key (in a `.py` buffer) | Does |
|---|---|
| `C-c C-x x` | runs the cell (or region) and stops at this line; with `C-u`, at its first |
| `C-c C-x b` | sets a breakpoint on this line, or takes it away |
| `C-c C-x B` | takes away every breakpoint of the buffer |
| `C-c C-x d` | opens the debugger where the last error was raised (`%debug`) |
| `C-c C-x e` | has every error open the debugger, or no longer (`%pdb`) |

In the session, `d` on a failed cell does the same as `C-c C-x d`.

**Where it stopped** has an arrow in the fringe, and the line is highlighted.
That buffer takes single keys while it is stopped:

| Key | Does |
|---|---|
| `n`, `SPC` | next line, over calls |
| `s` | step into the call |
| `c` | continue, to the next breakpoint or the end |
| `r` | on to the end of this function |
| `u` / `d` | up / down the stack (the arrow follows, into other files too) |
| `e` | the value of the name at point, or of the region, in the echo area; `C-u e` asks for an expression |
| `RET` | on to this line |
| `b` | a breakpoint here, or not (the debugger is told at once) |
| `w` | the stack, in the session |
| `q` | quit; what was running stops too |
| `?` | these keys |

The session's prompt becomes `ipdb>` while the debugger waits. Type anything
pdb takes there: `pp vars()`, `!x = 3`, `interact`.

**Breakpoints are marks, not code.** No `breakpoint()` line goes into the
file. Every run started while there are breakpoints stops at them, wherever
they are:
- in the cell being sent;
- in a function sent before, from any buffer;
- in a module of the project that the code imports;
- under `%run`.

Runs with no breakpoints anywhere are not traced, so they run at full speed.

How it works:
- ipykernel runs each cell as a file named after a hash of its code. pdb
  shows that file.
- The bridge computes the same name for every code it sends (event
  `codefile`). coil remembers which lines of which buffer each name was, and
  maps pdb's place back to them.
- For a run with breakpoints, the bridge first installs `bridge/coil_debug.py`
  in the kernel. It does this silently, as a module of its own, so no names
  appear in your namespace. The bridge tells it the breakpoints.
- `coil_debug.py` sets them as pdb breakpoints when IPython is about to run
  that cell. The cell is sent exactly as written.
- Tracing starts there and ends when the cell ends.
- IPython runs a cell's last expression as code of its own. Stepping off the
  end of one part goes on to the next part, not into IPython.

Limits:
- A cell with a cell magic (`%%time`) runs its body elsewhere, so
  breakpoints inside it are not met.
- If the buffer is edited after code is sent, a breakpoint on the old lines
  can stop on the wrong line until the code is sent again.


## Architecture

```
 .py buffer ──┐
              ├── coil.el ══ pipe, JSON lines ══ coil_bridge.py ══ ZMQ (ipc) ══ ipykernel
 session buf ─┘   (Emacs)                       (project env)                 (project env,
                                                                                detached)
```

- **Kernel.** `ipykernel`, started by the bridge in the project's
  environment.
  - The environment is the one of the buffer the session was started from:
    with envrc and direnv, the project's.
  - The kernel runs detached, in its own session and process group, so it
    outlives the bridge and Emacs.
- **Bridge.** `bridge/coil_bridge.py`, about 400 lines on `jupyter_client`
  (which `ipykernel` brings).
  - Emacs runs it as a plain subprocess, with `python -I`, so nothing in the
    project directory can shadow its imports.
  - It attaches to the project's kernel if one is alive, or starts one.
  - It speaks JSON lines on stdin and stdout and listens on nothing.
  - When Emacs goes, it goes; the kernel stays.
- **Completion while code runs.** Completion, docs and `is_complete` are
  asked on a kernel **subshell** (JEP 91, ipykernel 7), which answers while
  the main shell is busy. Measured: 0.04 s during a running `time.sleep`.
- **Emacs side.** Plain functions over the bridge's messages; no EIEIO, no
  monads, no native module.

**Why ipykernel, not an instrumented plain Python.** IPython's kernel brings,
all of them needed:
- the display protocol (pandas, PIL and matplotlib figures);
- its completer (filenames inside strings, too);
- subshells, interrupt and `input()`;
- readable tracebacks, and `%run`, `%debug` and `%timeit`.

The protocol between Emacs and the bridge is coil's own, so a lighter
backend could replace bridge and kernel later without the Emacs side
changing.

### Files

- `coil.el`: sessions, the session buffer, sending code, completion,
  figures, the log. Nothing in it knows about Python.
- `coil-python.el`: Python's part:
  - the interpreter and kernel, from the buffer's environment;
  - python.el's keys and `# %%` cells;
  - pixi: adding `ipykernel` and missing packages.
- `coil-debug.el`: the debugger. It takes pdb's prompt and marks where pdb
  stopped, adds the stepping keys and the breakpoints, and opens post-mortem.
- `bridge/coil_bridge.py`: the bridge. It speaks the Jupyter protocol, not
  Python, so it can drive any kernel. It also names the cells as ipykernel
  does, when ipykernel is there.
- `bridge/coil_debug.py`: the breakpoints, inside the kernel.

Another language later means another `coil-<language>.el`.

### Hooks, for what is not coil's

coil does not know about canvases, slide decks or folders of figures. It
offers:
- `coil-pin-function`, called by `c` with a figure's image file and its cell;
- `coil-figure-functions`, run with the session, the cell and the image file
  of every figure as it is drawn;
- `coil-cell-done-functions`, run with the session and the cell when a cell
  ends;
- `coil-input-request-functions`, which may take a question from the kernel
  (`input()`, pdb's prompt) rather than leave it to the minibuffer, and
  `coil-ask` and `coil-answer` to ask it at the session's prompt;
- `coil-breakpoints-function`, which says where a run is to stop.

The Doom config that uses coil pins figures to canvacs canvases with these:
the figure goes to `figures/NAME.png` in the project and becomes an image
card whose source is the script, and a re-run rewrites the file.


## Sessions

- **One kernel per project root:** `doom-project-root`, else `project.el`'s
  root, else the directory.
- **Starting.** The first send, or `C-c C-z`, starts the bridge. It attaches
  to the project's kernel if one answers, and starts one if not. Sends made
  meanwhile wait in a queue.
- **Surviving.** The kernel is started in its own session and process
  group, with nothing tying it to the bridge, so it lives on when the bridge
  or Emacs ends. Its connection file, pid and log stay in coil's state
  directory, and that is how a later Emacs finds it again.
- **History.**
  - Each cell is logged as it ends: its code, source, timing and outputs,
    with figures as PNG files.
  - A new session buffer is rebuilt from the log, the last
    `coil-log-cells` cells of it.
  - A new kernel starts a new log; `coil-log-keep` old ones are kept, and
    figures no kept log refers to are deleted.


## Missing imports

- **At run time:** a `ModuleNotFoundError` offers to add the package to the
  pixi project: "No module named sklearn. Add scikit-learn to …?" with the
  choices conda-forge, PyPI or no.
- **On yes:**
  1. `pixi add` runs in the background;
  2. the project's buffers reload their environment;
  3. coil asks whether to run the cell again. A running kernel imports a
     newly installed package without a restart.
- **Before running:** `coil-python-add-missing-imports` offers each import
  the language server (ty) reports as unresolved.
- **Import names:** `coil-python-packages` maps the ones whose package is
  named otherwise (`sklearn` → `scikit-learn`, `cv2` → `opencv`, …).


## Security

Kernel output, files read by code, and packages are all untrusted.

### Output that tries to act

Text printed by code can carry terminal escape sequences, and a crafted file
or web response can carry anything. (The comint-mime hole found in the
setup coil replaces was this: an escape sequence in printed text made Emacs
read or delete an arbitrary file.)
- Output reaches Emacs only as Jupyter messages, already split into stream
  text, MIME bundles and errors.
- In text, only colour sequences (SGR) are applied. Other CSI sequences are
  dropped, and any other escape stays as visible text. Nothing is acted on.
- **Drawn:** `image/png` and `image/jpeg` only, through Emacs's image
  libraries.
- **Never drawn:** HTML, LaTeX, SVG and JavaScript. HTML can reach the
  network, LaTeX runs TeX, and SVG can reference other files. The bridge
  drops them; only their `text/plain` alternative is shown.
- **Size limits:** 50 MB per message (in the bridge), and a PNG of more
  than `coil-max-image-pixels` is not drawn. Emacs's own `max-image-size`
  applies as well.
- No file path ever comes from the kernel. Images arrive as data.

### Kernel access

Whoever can talk to a kernel can run code as you.
- The kernel listens on Unix sockets (the `ipc` transport) in a directory
  only you can open (0700).
- Messages are signed with a fresh 256-bit HMAC key per kernel.
  `write_connection_file` defaults to an **empty** key; the bridge always
  passes one.
- Connection files are 0600, in `$XDG_STATE_HOME/coil/<project hash>/`. They
  are outside the project, so they are never committed or synced with it.
- The bridge listens on nothing; it is reached only through its pipe.
- **One exception, from ipykernel:** it always opens a port on `127.0.0.1`
  so that output from forked subprocesses reaches the session
  (`IOPubThread(pipe=True)`, hard-coded).
  - It accepts output only, never code, and only with a random 16-byte token.
  - What it forwards is checked against the kernel's HMAC key by the bridge.
  - Checked with `lsof`: it is the kernel's only network socket.

### Code that runs on start

Starting a kernel runs code from the project: pixi activation scripts, `.pth`
files, `sitecustomize`, IPython startup files.
- coil starts a kernel only in a project you have trusted. It asks once, and
  keeps the answer in `trusted.eld` in its state directory.
- `coil-untrust` revokes it. The Doom config counts accepting its `.envrc`
  offer as the same trust.

### Installing packages

`pixi add` of a name taken from code is a typosquatting risk: a malicious or
misspelt import in a cloned repo could get a hostile package installed.
- Nothing is installed without asking. The prompt names the exact package
  and where it comes from.
- conda-forge is the default; PyPI only on an explicit choice.
- A name not found on conda-forge gets a warning, and no conda-forge choice:
  "Check the name: a misspelt or planted import can install a hostile
  package."
- A name guessed from the import, rather than known from the table, is said
  to be a guess.
- An install changes `pixi.toml` and `pixi.lock`, so it shows in `git diff`.

### What the session keeps

Outputs can contain secrets: tokens, data, personal information.
- The log and its figures are 0600, in the state directory, outside the
  project.
- `coil-log-keep` limits how many are kept; nil keeps none.
- Only pinning writes into the project (through `coil-pin-function`).

### Not defended against

- **Code you choose to run.** Running a cell runs code as you; coil is not a
  sandbox.
- **Other processes running as you.** They can read your files and sockets
  anyway.
- **A malicious project you have trusted.**


## Status

### Tested

Tested by hand, on a pixi project with IPython 9 and ipykernel 7:
- the bridge's lifecycle: start, execute, error, figure, `input()`,
  completion, interrupt, detach and reattach with state kept, shutdown that
  cleans up its files;
- the security properties above, including the `lsof` check;
- the session buffer:
  - cells, colour tracebacks and figures;
  - `RET` deciding between running and a new line;
  - completion of members and of filenames in strings, also while a cell
    runs;
  - interrupt;
  - `# %%` cells and their summaries;
  - the missing-import offer, for a known name and for a misspelt one;
  - restart and shutdown;
  - **closing Emacs and reattaching to the same kernel**, with the history
    rebuilt from the log.
- pinning to a canvacs canvas through the Doom config's
  `coil-pin-function`, and a re-run rewriting the pinned figure.

### Not done yet

- **Live completion in `.py` buffers.** `coil-completion-at-point` works
  there, but it is not merged with eglot's: corfu shows one source at a
  time. It needs `cape-capf-super` or similar.
- **A code action for ty's diagnostic.** There is the command
  `coil-python-add-missing-imports` instead.
- **Tests in the repository.** The checks above were run by hand.
- **The conda-forge lookup is synchronous.** `pixi search`, before the
  missing-import prompt, takes a second or two and Emacs waits for it.

### Open questions

- **Idle kernels.** Shut down after a time, or never automatically?
  (Today: never; `coil-list-sessions` shows them.)

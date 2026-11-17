"""coil's breakpoints, in the kernel.

Before a run that has breakpoints, Emacs has this file's text run silently,
and then `expect': the next cell, if it is the one expected, runs with them.
The cell itself is sent as it was written.  The breakpoints are pdb's
(IPython's debugger), set on the files the code runs from: a real file, or
the file ipykernel names a cell after.  Nothing is traced unless a run has
breakpoints, and only during that run: the tracing ends with it.
"""

import linecache
import os
import sys

from IPython import get_ipython
from IPython.core.debugger import Pdb


class Debugger(Pdb):
    """IPython's debugger, stepping through a cell as one piece of code.

    IPython runs a cell in parts: its last expression is code of its own, so
    that its value is shown.  Stepping off the end of one part goes on to the
    first line of the next, rather than into IPython or out of the cell.
    """

    cell = None          # the cell's file
    _between = False     # off the end of a part: stop at the next

    def _part(self, frame):
        return frame.f_code.co_filename == self.cell and frame.f_code.co_name == "<module>"

    def break_anywhere(self, frame):
        # The cell's parts are always traced, to step through them.
        return self._part(frame) or super().break_anywhere(frame)

    def stop_here(self, frame):
        if self._between and self._part(frame):
            self._between = False
            self.set_step()
            return True
        return super().stop_here(frame)

    def user_call(self, frame, argument_list):
        if not self._part(frame):   # a part's first line is stop enough
            super().user_call(frame, argument_list)

    def user_return(self, frame, return_value):
        if self._part(frame):
            # Run on: to the next part, if there is one; else out of the cell.
            self._between = True
            self._set_stopinfo(self.botframe, None, -1)
            return
        super().user_return(frame, return_value)


_expected = None


def expect(name, breaks):
    """Have the next cell, if its file is NAME, stop at BREAKS.

    BREAKS is a list of (file, line, temporary): a file of None is that
    cell; a bare name, another cell's, in the same directory.
    """
    global _expected
    _expected = (name, breaks)
    events = get_ipython().events
    if _on_cell not in events.callbacks["pre_run_cell"]:
        events.register("pre_run_cell", _on_cell)


def uninstall():
    """Let a newer version of this module take over."""
    events = get_ipython().events
    if _on_cell in events.callbacks["pre_run_cell"]:
        events.unregister("pre_run_cell", _on_cell)


def _on_cell(info):
    global _expected
    if _expected is None:
        return
    (name, breaks), _expected = _expected, None
    raw = info.raw_cell or ""
    cell = get_ipython().compile.get_code_name(raw, raw, 0)
    if name is not None and os.path.basename(cell) != name:
        return  # not the cell expected (it was never run): no breakpoints
    # Known to linecache before IPython compiles it, so that its lines can
    # have breakpoints; IPython puts it there again, transformed.
    linecache.cache.setdefault(cell, (len(raw), None, raw.splitlines(True), cell))
    _arm(cell, breaks)


def _arm(cell, breaks):
    debugger = Debugger()
    debugger.cell = cell
    for name, line, temporary in breaks:
        if name is None:
            path = cell
        elif os.path.isabs(name):
            path = name
        else:
            path = os.path.join(os.path.dirname(cell), name)
        debugger.set_break(path, line, temporary=bool(temporary))
    if not debugger.breaks:
        return
    shell = get_ipython()

    def disarm(*_):
        sys.settrace(None)
        debugger.clear_all_breaks()
        shell.events.unregister("post_execute", disarm)

    shell.events.register("post_execute", disarm)
    # As bdb's set_trace, but running on to a breakpoint rather than
    # stopping at once.  The outermost frame is the bottom, as for set_trace.
    debugger.reset()
    bottom = sys._getframe()
    while bottom.f_back is not None:
        bottom = bottom.f_back
    debugger.botframe = bottom
    debugger.set_continue()
    sys.settrace(debugger.trace_dispatch)

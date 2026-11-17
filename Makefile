EMACS ?= emacs
PYTHON ?= python3

.PHONY: test test-elisp test-bridge compile clean

# The Emacs side, with the kernel stubbed: needs only Emacs.
test-elisp:
	$(EMACS) -Q --batch -L . -l test/coil-test.el -f ert-run-tests-batch-and-exit

# The bridge with a real kernel: run in an environment with ipykernel.
test-bridge:
	$(PYTHON) -I test/test_bridge.py

test: compile test-elisp test-bridge

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile coil.el coil-debug.el coil-python.el
	@rm -f *.elc

clean:
	rm -f *.elc
	rm -rf bridge/__pycache__ test/__pycache__

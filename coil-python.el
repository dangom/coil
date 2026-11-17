;;; coil-python.el --- Python in coil: its kernel, its keys, its imports -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Gomez

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; What coil needs to know of Python:
;;
;; - how to start a kernel: ipykernel, from the buffer's environment (the
;;   project's, where direnv or envrc has set it), offered to a pixi project
;;   that lacks it;
;; - the keys of python.el, sending to the session (`coil-python-mode');
;; - what to do with an import that is not installed: offer to add it to the
;;   project, asking first, saying exactly what and from where.

;;; Code:

(require 'coil)
(require 'coil-debug)
(require 'python)

(declare-function envrc-mode "envrc" (&optional arg))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diag))

(defgroup coil-python nil
  "Python in coil."
  :group 'coil
  :prefix "coil-python-")

(defcustom coil-python-packages
  '(("sklearn" . "scikit-learn") ("skimage" . "scikit-image") ("cv2" . "opencv")
    ("PIL" . "pillow") ("yaml" . "pyyaml") ("bs4" . "beautifulsoup4")
    ("Bio" . "biopython") ("dateutil" . "python-dateutil") ("dotenv" . "python-dotenv")
    ("attr" . "attrs") ("OpenSSL" . "pyopenssl") ("Crypto" . "pycryptodome")
    ("serial" . "pyserial") ("usb" . "pyusb") ("docx" . "python-docx")
    ("pptx" . "python-pptx") ("fitz" . "pymupdf") ("jwt" . "pyjwt") ("zmq" . "pyzmq")
    ("torch" . "pytorch") ("umap" . "umap-learn") ("igraph" . "python-igraph")
    ("MySQLdb" . "mysqlclient") ("gi" . "pygobject") ("wx" . "wxpython")
    ("git" . "gitpython") ("jose" . "python-jose") ("magic" . "python-magic")
    ("lal" . "python-lal") ("tables" . "pytables") ("Levenshtein" . "levenshtein")
    ("sentence_transformers" . "sentence-transformers") ("google.protobuf" . "protobuf"))
  "Imports whose package is named otherwise, on conda-forge."
  :type '(alist :key-type string :value-type string))

(defvar coil-python-kernel '("{python}" "-m" "ipykernel_launcher" "-f" "{connection_file}")
  "The kernel's command; the bridge fills in the braces.")


;;; The environment

(defun coil-python--env-prefix ()
  "The environment this buffer's own variables name, or nil.
Only a value set for this buffer (by envrc) counts, not Emacs's own."
  (let ((global (default-value 'process-environment)))
    (cl-loop for var in '("CONDA_PREFIX" "VIRTUAL_ENV")
             for value = (getenv var)
             when (and value (not (equal value (getenv-internal var global))))
             return value)))

(defun coil-python-interpreter ()
  "The Python of this buffer's environment, which runs the bridge."
  (if-let* ((prefix (coil-python--env-prefix)))
      (cl-find-if #'file-executable-p
                  (list (expand-file-name "bin/python" prefix)
                        (expand-file-name "bin/python3" prefix)))
    (or (executable-find "python3") (executable-find "python"))))

(defun coil-python--pixi-root (dir)
  "The root of the pixi project DIR is in, or nil."
  (when-let* ((root (locate-dominating-file
                     dir (lambda (d)
                           (or (file-exists-p (expand-file-name "pixi.toml" d))
                               (let ((py (expand-file-name "pyproject.toml" d)))
                                 (and (file-exists-p py)
                                      (with-temp-buffer
                                        (insert-file-contents py)
                                        (search-forward "[tool.pixi" nil t)))))))))
    (file-name-as-directory (expand-file-name root))))

(defun coil-python--reload-environment (root)
  "Have the buffers under ROOT read their environment again."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p envrc-mode)
                 (file-in-directory-p default-directory root))
        (envrc-mode -1)
        (envrc-mode 1)))))

(defcustom coil-python-pixi-environment "dev"
  "The pixi environment the kernel runs in, where the project has it.
The tools of the session (ipykernel, and IPython with it) belong there, in a
feature of that name, not among the project's own dependencies.  It shares
the default environment's solve group: the same versions of all they share."
  :type 'string)

(defun coil-python--pixi (root commands then &optional failed)
  "Run the pixi COMMANDS (argument lists) at ROOT in turn, in the background.
Then THEN; or FAILED, if one of them fails.  Their output is in the buffer
\" *coil pixi*\"."
  (let ((default-directory root)
        (log (get-buffer-create " *coil pixi*")))
    (if (null commands)
        (when then (funcall then))
      (let ((command (cons "pixi" (car commands))))
        (with-current-buffer log
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "$ " (string-join command " ") "\n")))
        (message "coil: %s..." (string-join command " "))
        (make-process
         :name "coil pixi" :buffer log :command command :noquery t
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (if (zerop (process-exit-status process))
                           (coil-python--pixi root (cdr commands) then failed)
                         (message "coil: `%s' failed; see the buffer \" *coil pixi*\""
                                  (string-join command " "))
                         (when failed (funcall failed))))))))))

(defun coil-python--pixi-add (root packages pypi then)
  "Add PACKAGES to the pixi project ROOT's dependencies, in the background.
From PyPI if PYPI, else conda-forge.  Then THEN."
  (coil-python--pixi root `(("add" ,@(and pypi '("--pypi")) ,@packages))
                     (lambda ()
                       (message "coil: added %s" (string-join packages ", "))
                       (coil-python--reload-environment root)
                       (when then (funcall then)))))

(defun coil-python--pixi-environments (root)
  "The environments the pixi project ROOT declares."
  (with-temp-buffer
    (when (zerop (call-process "pixi" nil t nil "info" "--json" "--manifest-path" root))
      (goto-char (point-min))
      (mapcar (lambda (env) (alist-get 'name env))
              (alist-get 'environments_info
                         (json-parse-buffer :object-type 'alist :array-type 'list
                                            :null-object nil :false-object nil))))))

(defun coil-python-environment (root)
  "The variables of the kernel's pixi environment at ROOT, activated, or nil.
Nil where ROOT is not a pixi project with `coil-python-pixi-environment':
then the kernel runs in the buffer's own environment."
  (when-let* (((executable-find "pixi"))
              (pixi (coil-python--pixi-root root))
              ((member coil-python-pixi-environment (coil-python--pixi-environments pixi))))
    (with-temp-buffer
      (when (zerop (call-process "pixi" nil t nil "shell-hook" "--json"
                                 "-e" coil-python-pixi-environment "--manifest-path" pixi))
        (goto-char (point-min))
        (let ((vars (alist-get 'environment_variables
                               (json-parse-buffer :object-type 'alist :null-object nil)))
              (env (copy-sequence (default-value 'process-environment))))
          (pcase-dolist (`(,name . ,value) vars)
            (setq env (cons (format "%s=%s" name value)
                            (seq-remove (lambda (entry)
                                          (string-prefix-p (format "%s=" name) entry))
                                        env))))
          env)))))

(defun coil-python--missing (session)
  "The kernel's environment has no jupyter_client: offer ipykernel, which
brings it (and IPython), to the pixi project's dev environment."
  (let ((root (coil-session-root session))
        (env coil-python-pixi-environment))
    (if-let* ((pixi (and (executable-find "pixi") (coil-python--pixi-root root))))
        (when (y-or-n-p (format "Add ipykernel to %s's `%s' environment (a pixi feature: not the project's dependencies)? "
                                (abbreviate-file-name pixi) env))
          (let ((declared (coil-python--pixi-environments pixi)))
            (coil-python--pixi
             pixi
             (if (member env declared)
                 `(("add" "--feature" ,env "ipykernel"))
               ;; pixi makes an environment only of a feature it has: the
               ;; feature first (pixi adds it unresolved, as no environment
               ;; uses it yet), then the environment, then the version pinned
               ;; and installed.
               `(("add" "--feature" ,env "ipykernel")
                 ("workspace" "environment" "add" ,env "--feature" ,env
                  "--solve-group" "default")
                 ;; The default environment in the same solve group -- the
                 ;; same versions of what they share -- unless the project
                 ;; says otherwise of it already.
                 ,@(unless (coil-python--declares-default-p pixi)
                     '(("workspace" "environment" "add" "default"
                        "--solve-group" "default" "--force")))
                 ("upgrade" "--feature" ,env "ipykernel")
                 ("install" "-e" ,env)))
             (lambda ()
               (message "coil: ipykernel added to the `%s' environment" env)
               (coil--start root (coil-session-backend session) session)))))
      (message "coil: install ipykernel in this project's environment, then C-c C-z"))))

(defun coil-python--declares-default-p (root)
  "Whether the manifest at ROOT already defines its default environment."
  (cl-some (lambda (name)
             (let ((file (expand-file-name name root)))
               (and (file-exists-p file)
                    (with-temp-buffer
                      (insert-file-contents file)
                      (re-search-forward "^[ \t]*default[ \t]*=" nil t)))))
           '("pixi.toml" "pyproject.toml")))

(add-to-list 'coil-backends
             `(python-base-mode
               :name "python"
               :interpreter coil-python-interpreter
               :environment coil-python-environment
               :kernel ,coil-python-kernel
               :mode python-mode
               :missing coil-python--missing))


;;; Imports not installed

(defvar coil-python--offered nil
  "Modules offered this Emacs session, by project: not asked again.")

(defun coil-python--package (module)
  "The conda-forge package for MODULE, and whether that is known, not guessed."
  (let ((top (car (split-string module "\\."))))
    (if-let* ((known (or (cdr (assoc module coil-python-packages))
                         (cdr (assoc top coil-python-packages)))))
        (cons known t)
      (cons (downcase (string-replace "_" "-" top)) nil))))

(defun coil-python--on-conda-forge-p (package)
  "Whether conda-forge has PACKAGE, by that exact name; nil if unsure."
  (with-temp-buffer
    (and (executable-find "pixi")
         (zerop (call-process "pixi" nil t nil "search" "--channel" "conda-forge" package))
         (progn (goto-char (point-min))
                (re-search-forward (concat "^" (regexp-quote package) "\\b") nil t)))))

(defun coil-python-offer-package (module root &optional then)
  "Offer to add the package for MODULE to the pixi project ROOT; THEN after."
  (let* ((guess (coil-python--package module))
         (package (car guess))
         (known (cdr guess))
         (found (progn (message "coil: looking for %s on conda-forge..." package)
                       (coil-python--on-conda-forge-p package)))
         (warning (cond ((not found)
                         (format "  %s is not on conda-forge.  Check the name: a misspelt or planted import can install a hostile package."
                                 package))
                        ((not known)
                         (format "  (%s is a guess from the import name.)" package))))
         (choice (read-multiple-choice
                  (format "No module named %s.  Add %s to %s?%s"
                          module package (abbreviate-file-name root) (or warning ""))
                  (append (and found '((?c "conda-forge" "pixi add, from conda-forge")))
                          '((?p "PyPI" "pixi add --pypi, from PyPI")
                            (?n "no" "do not add it"))))))
    (pcase (car choice)
      (?c (coil-python--pixi-add root (list package) nil then))
      (?p (coil-python--pixi-add root (list (read-string "PyPI package: " package)) t then)))))

(defun coil-python--missing-module (cell)
  "The module CELL failed to import, if that is how it failed."
  (cl-loop for output in (coil-cell-outputs cell)
           when (and (equal (alist-get 'type output) "error")
                     (member (alist-get 'ename output) '("ModuleNotFoundError" "ImportError"))
                     (string-match "No module named '\\([^']+\\)'" (or (alist-get 'evalue output) "")))
           return (match-string 1 (alist-get 'evalue output))))

(defun coil-python--offer-after-error (session cell)
  "After CELL failed on an import, offer to add the package and run it again."
  (when-let* (((equal (plist-get (coil-session-backend session) :name) "python"))
              (module (coil-python--missing-module cell))
              (root (coil-python--pixi-root (coil-session-root session)))
              (key (cons root module))
              ((not (member key coil-python--offered))))
    (push key coil-python--offered)
    (run-at-time
     0 nil
     (lambda ()
       (coil-python-offer-package
        module root
        (lambda ()
          (when (y-or-n-p (format "Run In [%s] again? " (coil-cell-count cell)))
            (coil-execute (coil-cell-code cell) :file (coil-cell-file cell)
                          :line (coil-cell-line cell) :session session))))))))

(add-hook 'coil-cell-done-functions #'coil-python--offer-after-error)

(defun coil-python-add-missing-imports ()
  "Offer to add each import of this buffer the language server cannot find."
  (interactive)
  (let ((root (or (coil-python--pixi-root default-directory)
                  (user-error "Not in a pixi project")))
        modules)
    (dolist (diagnostic (and (fboundp 'flymake-diagnostics) (flymake-diagnostics)))
      (let ((text (flymake-diagnostic-text diagnostic)))
        (when (string-match "\\(?:module\\|import\\) [`'\"]\\([[:alnum:]_.]+\\)[`'\"]" text)
          (cl-pushnew (match-string 1 text) modules :test #'equal))))
    (unless modules (user-error "No unresolved imports here"))
    (dolist (module (nreverse modules))
      (coil-python-offer-package module root))))


;;; Sending code

(defun coil-python--text (start end &optional with-main)
  "The code from START to END, dedented; the main block dropped unless WITH-MAIN.
Returned as (CODE . ORIGIN), ORIGIN the buffer's line that is CODE's first."
  ;; python.el pads the code with newlines so that its lines are the
  ;; buffer's; they are trimmed, and counted.
  (let* ((raw (python-shell-buffer-substring start end (not with-main) t))
         (code (string-trim-left raw "\n+")))
    (cons (string-trim-right code "[ \t\n]+")
          (1+ (- (length raw) (length code))))))

(cl-defun coil-python--send (start end &optional with-main &key breakpoints)
  (pcase-let ((`(,code . ,origin) (coil-python--text start end with-main)))
    (coil-execute code
                  :file (buffer-file-name)
                  :line (line-number-at-pos start)
                  :origin origin
                  :breakpoints (and breakpoints (funcall breakpoints origin code)))))

(defun coil-python-send-buffer (&optional with-main)
  "Run the buffer; with WITH-MAIN (C-u), its `__main__' block too."
  (interactive "P")
  (coil-python--send (point-min) (point-max) with-main))

(defun coil-python-send-region (start end)
  "Run the region."
  (interactive "r")
  (coil-python--send start end))

(defun coil-python-send-statement ()
  "Run the statement at point, or the region if there is one."
  (interactive)
  (if (use-region-p)
      (coil-python-send-region (region-beginning) (region-end))
    (coil-python--send (save-excursion (python-nav-beginning-of-statement) (point))
                       (save-excursion (python-nav-end-of-statement) (point)))))

(defun coil-python-send-defun ()
  "Run the function or class at point, decorators and all."
  (interactive)
  (save-excursion
    (end-of-line)
    (python-nav-beginning-of-defun)
    (while (save-excursion (forward-line -1) (looking-at-p "[ \t]*@"))
      (forward-line -1))
    (let ((start (point)))
      (python-nav-end-of-defun)
      (coil-python--send start (point)))))

(defun coil-python-send-block ()
  "Run the block at point, its header (`for', `if', `with'...) and all.
Outside any block, the statement at point."
  (interactive)
  (let ((beg (save-excursion
               (and (python-nav-beginning-of-block)
                    (line-beginning-position))))
        (end (save-excursion (python-nav-end-of-block))))
    (if (and beg end)
        (coil-python--send beg end)
      (coil-python-send-statement))))

(defconst coil-python--clause-regexp "\\(?:elif\\|else\\|except\\|finally\\)\\_>"
  "A line that goes on a statement begun above it.")

(defun coil-python--top-level-line-p ()
  "Whether the line at point begins a statement at the top level."
  (save-excursion
    (beginning-of-line)
    (and (looking-at-p "[^ \t\n#]")
         (let ((ppss (syntax-ppss)))
           (and (zerop (car ppss)) (not (nth 3 ppss)))))))

(defun coil-python--top-level-bounds ()
  "The top-level statement point is in: (START . END).
A function or class with its decorators, a block with its `elif', `else',
`except' and `finally'.  Between two, the one before; before any, the first."
  (save-excursion
    (beginning-of-line)
    (while (and (not (coil-python--top-level-line-p)) (zerop (forward-line -1))))
    (unless (coil-python--top-level-line-p)
      (while (and (not (coil-python--top-level-line-p)) (zerop (forward-line 1)) (not (eobp)))))
    (unless (coil-python--top-level-line-p)
      (user-error "No code here"))
    ;; Up from a clause to what it goes on, and to the decorators.
    (while (and (looking-at-p coil-python--clause-regexp) (zerop (forward-line -1)))
      (while (and (not (coil-python--top-level-line-p)) (zerop (forward-line -1)))))
    ;; A decorator's arguments may take lines of their own.
    (while (let ((above (save-excursion
                          (and (zerop (forward-line -1))
                               (progn (while (and (looking-at-p "[ \t]")
                                                  (zerop (forward-line -1))))
                                      (and (looking-at-p "@") (point)))))))
             (and above (goto-char above))))
    (let ((start (point))
          (decorated (looking-at-p "@")))
      ;; Down to the next statement that is not part of this one.
      (forward-line 1)
      (while (and (not (eobp))
                  (or (not (coil-python--top-level-line-p))
                      (looking-at-p coil-python--clause-regexp)
                      decorated))
        (when (coil-python--top-level-line-p)
          (setq decorated (looking-at-p "@")))
        (forward-line 1))
      ;; Without the blank lines and comments that come before the next.
      (forward-line -1)
      (while (and (> (point) start) (looking-at-p "[ \t]*\\(?:#.*\\)?$"))
        (forward-line -1))
      (cons start (line-end-position)))))

(defun coil-python-send-top-level ()
  "Run the top-level statement point is in: all of the function, class or
block (decorators, `else' and `except' too), or the line.  Or the region."
  (interactive)
  (if (use-region-p)
      (coil-python-send-region (region-beginning) (region-end))
    (pcase-let ((`(,start . ,end) (coil-python--top-level-bounds)))
      (coil-python--send start end))))

(defconst coil-python-cell-regexp "^[ \t]*#[ \t]*%%"
  "The line that begins a cell, as VS Code, Spyder and Positron have it.")

(defun coil-python--cell-bounds ()
  "The cell at point: (HEADER START END), HEADER its `# %%' line or nil."
  (save-excursion
    (end-of-line)
    (let* ((header (and (re-search-backward coil-python-cell-regexp nil t) (point)))
           (start (if header (line-beginning-position 2) (point-min)))
           (end (progn (goto-char start)
                       (if (re-search-forward coil-python-cell-regexp nil t)
                           (line-beginning-position)
                         (point-max)))))
      (list header start end))))

(defun coil-python-send-cell ()
  "Run the cell at point (from one `# %%' to the next), and go to the next.
How it went is shown on its `# %%' line."
  (interactive)
  (pcase-let ((`(,header ,start ,end) (coil-python--cell-bounds)))
    (let ((cell (coil-python--send start end)))
      (when header
        (save-excursion
          (goto-char header)
          (dolist (old (overlays-in (line-beginning-position) (line-end-position)))
            (when (overlay-get old 'coil-summary) (delete-overlay old)))
          (let ((overlay (make-overlay (line-end-position) (line-end-position) nil t nil)))
            (overlay-put overlay 'coil-summary t)
            (overlay-put overlay 'after-string (propertize "  …" 'face 'coil-header))
            (setf (coil-cell-overlay cell) overlay))))
      (goto-char end)
      (when (looking-at-p coil-python-cell-regexp) (forward-line 1)))))

(defun coil-python-debug (&optional from-top)
  "Run the cell at point (or the region) in the debugger, stopping at this line.
With FROM-TOP (\\[universal-argument]), at its first line, to step through
it all.  The breakpoints set (\\[coil-debug-toggle-breakpoint]) stop it too."
  (interactive "P")
  (pcase-let* ((`(,_ ,start ,end) (if (use-region-p)
                                      (list nil (region-beginning) (region-end))
                                    (coil-python--cell-bounds)))
               (line (save-excursion (when from-top (goto-char start))
                                     (coil-debug--code-line))))
    (deactivate-mark)
    (coil-python--send start end nil
                       :breakpoints (lambda (origin _code)
                                      (list (vector :null (1+ (- line origin)) t))))))

(defun coil-python-run-file ()
  "Save the file and %run it."
  (interactive)
  (save-buffer)
  (coil-execute (format "%%run %s" (shell-quote-argument (buffer-file-name)))
                :file (buffer-file-name) :line 1))

(defun coil-python-send-string (code)
  "Run CODE, read from the minibuffer."
  (interactive "sRun: ")
  (coil-execute code))

(defun coil-python-repl ()
  "The project's session buffer, started if need be: for Doom's REPL handler."
  (interactive)
  (coil--buffer (coil-current-session t)))

(defun coil-python-switch ()
  "Go to the project's session, starting it if need be."
  (interactive)
  (pop-to-buffer (coil--buffer (coil-current-session t))))

(defvar-keymap coil-python-mode-map
  "C-c C-z" #'coil-python-switch
  "C-c C-p" #'coil-python-switch
  "C-c C-c" #'coil-python-send-top-level
  "C-c C-r" #'coil-python-send-region
  "C-c C-e" #'coil-python-send-statement
  "C-c C-b" #'coil-python-send-buffer
  "C-M-x"   #'coil-python-send-defun
  "C-c C-n" #'coil-python-send-cell
  "C-c C-l" #'coil-python-run-file
  "C-c C-f" #'coil-inspect
  "C-c C-d" #'coil-inspect
  "C-c C-k" #'coil-interrupt
  "C-c C-s" #'coil-python-send-string
  ;; The debugger (coil-debug.el).
  "C-c C-x x" #'coil-python-debug
  "C-c C-x b" #'coil-debug-toggle-breakpoint
  "C-c C-x B" #'coil-debug-clear-breakpoints
  "C-c C-x d" #'coil-debug-post-mortem
  "C-c C-x e" #'coil-debug-toggle-on-error
  ;; Whatever else calls python.el's REPL, by command or menu, gets coil's.
  "<remap> <run-python>"                   #'coil-python-switch
  "<remap> <python-shell-switch-to-shell>" #'coil-python-switch
  "<remap> <python-shell-send-buffer>"     #'coil-python-send-buffer
  "<remap> <python-shell-send-region>"     #'coil-python-send-region
  "<remap> <python-shell-send-statement>"  #'coil-python-send-statement
  "<remap> <python-shell-send-block>"      #'coil-python-send-block
  "<remap> <python-eldoc-at-point>"        #'coil-inspect
  "<remap> <python-describe-at-point>"     #'coil-inspect
  "<remap> <python-shell-send-defun>"      #'coil-python-send-defun
  "<remap> <python-shell-send-file>"       #'coil-python-run-file
  "<remap> <python-shell-send-string>"     #'coil-python-send-string)

;;;###autoload
(define-minor-mode coil-python-mode
  "Send Python to the project's coil session, with python.el's keys.
\\{coil-python-mode-map}"
  :lighter nil
  :keymap coil-python-mode-map
  ;; Eldoc after the language server's: it speaks only if
  ;; `coil-eldoc-in-source'.  Completion before it, so as to add to its
  ;; candidates (`coil-completion-in-source').
  (if coil-python-mode
      (progn
        (add-hook 'eldoc-documentation-functions #'coil-eldoc 90 t)
        (add-hook 'completion-at-point-functions #'coil-source-completion-at-point -50 t))
    (remove-hook 'eldoc-documentation-functions #'coil-eldoc t)
    (remove-hook 'completion-at-point-functions #'coil-source-completion-at-point t)))

(provide 'coil-python)
;;; coil-python.el ends here

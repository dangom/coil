;;; coil.el --- A Jupyter session in an Emacs buffer -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, processes

;;; Commentary:

;; A session with a Jupyter kernel, one per project, in an ordinary buffer of
;; cells: the code, then what it printed, its value, its figures, its error.
;; The kernel outlives Emacs; the session buffer comes back from a log.
;;
;; This file knows nothing of any language: a backend (coil-python.el) says
;; how to start the kernel, and sends code to it with `coil-execute'.  The
;; kernel is spoken to through bridge/coil_bridge.py, a plain subprocess, in
;; JSON lines.
;;
;; Output is untrusted: it is inserted as text, with its colours, and figures
;; (PNG and JPEG) as images.  Nothing in it is acted on.  See the README.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'text-property-search)
(require 'ring)

(declare-function project-root "project" (project))

(defgroup coil nil
  "A Jupyter session in an Emacs buffer."
  :group 'processes
  :prefix "coil-")

(defcustom coil-state-directory
  (expand-file-name "coil/" (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Where coil keeps each project's kernel connection, log and figures.
Only you can read it: it is made mode 0700, its files 0600."
  :type 'directory)

(defcustom coil-log-cells 300
  "How many cells of the log are shown again when a session buffer is made."
  :type 'natnum)

(defcustom coil-log-keep 5
  "How many past sessions' logs are kept per project, the current one aside.
A log holds what was run and what it printed: nil keeps none at all."
  :type '(choice natnum (const :tag "Keep no log" nil)))

(defcustom coil-fold-lines 200
  "Output of a cell longer than this many lines is folded, TAB to unfold."
  :type 'natnum)

(defcustom coil-fold-input-lines 12
  "Code of a cell longer than this many lines is folded, TAB to unfold.
Its first `coil-fold-input-shown' lines stay in view."
  :type 'natnum)

(defcustom coil-fold-input-shown 6
  "How many lines of folded code stay in view."
  :type 'natnum)

(defcustom coil-image-max-width 900
  "The widest a figure is shown, in pixels, or nil for the window's width."
  :type '(choice natnum (const nil)))

(defcustom coil-max-image-pixels (* 40 1000 1000)
  "A PNG of more pixels than this is not drawn."
  :type 'natnum)

(defcustom coil-cell-done-functions nil
  "Functions called with the session and the cell, once a cell is done."
  :type 'hook)

(defcustom coil-figure-functions nil
  "Functions called with the session, the cell and the image file of a figure.
Run for each figure a cell shows, as it comes."
  :type 'hook)

(defvar coil-input-request-functions nil
  "Functions called with the session, the cell and an input_request event.
The first to return non-nil has taken the question (as the debugger's, see
coil-debug.el); if none does, it is asked in the minibuffer.")

(defvar coil-breakpoints-function nil
  "A function of the session and the cell about to run, returning where it is
to stop: a list of [FILE LINE TEMPORARY], FILE the name of the kernel's file
or `:null' for the cell's own, TEMPORARY t or `:false'; or nil, to just run.")

(defvar coil-bridge
  (expand-file-name "bridge/coil_bridge.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The bridge, run by the environment's own interpreter.")

(defvar coil-backends nil
  "How to start a kernel, by major mode: (MODE . PLIST).
PLIST has :name, a string; :interpreter, a function returning the Python
that runs the bridge -- it must have jupyter_client; :environment, optional,
a function of the project root returning the kernel's `process-environment'
when it is not the buffer's (nil to keep the buffer's); :kernel, the kernel's
argv, with {python} and {connection_file} filled in by the bridge; :mode,
the major mode its code is shown in; :missing, a function called with the
session when the bridge finds jupyter_client missing.")

(defface coil-header '((t :inherit shadow))
  "The line above each cell.")
(defface coil-prompt '((t :inherit minibuffer-prompt))
  "The prompt of the session buffer.")
(defface coil-ok '((t :inherit success))
  "A cell that ran.")
(defface coil-failed '((t :inherit error))
  "A cell that failed.")
(defface coil-stderr '((t :inherit warning))
  "What a cell wrote to stderr.")
(defface coil-code '((((background light)) :extend t :background "gray96")
                     (t :extend t :background "gray15"))
  "The code of a cell: a faint tint, to tell it from its output.")
(defface coil-rule '((((background light)) :underline (:color "gray85" :position t))
                     (t :underline (:color "gray25" :position t)))
  "The hairline under each cell, across the window.")


;;; State, trust

(defun coil--state-dir (root &optional make)
  "The directory of ROOT's kernel and log, made (mode 0700) if MAKE."
  (let ((dir (expand-file-name (substring (secure-hash 'sha256 root) 0 12)
                               coil-state-directory)))
    (when make
      (with-file-modes #o700
        (make-directory dir t))
      (set-file-modes coil-state-directory #o700)
      (set-file-modes dir #o700)
      (let ((name (expand-file-name "root" dir)))
        (unless (file-exists-p name)
          (with-file-modes #o600
            (write-region root nil name nil 'silent)))))
    dir))

(defun coil--trust-file ()
  (expand-file-name "trusted.eld" coil-state-directory))

(defun coil--trusted ()
  (let ((file (coil--trust-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (read (current-buffer)))))))

(defun coil-trusted-p (root)
  "Whether ROOT may have a kernel started in it."
  (member (file-name-as-directory root) (coil--trusted)))

(defun coil--write-trusted (roots)
  (with-file-modes #o700 (make-directory coil-state-directory t))
  (with-file-modes #o600
    (with-temp-file (coil--trust-file)
      (prin1 roots (current-buffer)))))

(defun coil-trust (root)
  "Trust ROOT: let coil start a kernel there, which runs the project's code."
  (interactive (list (coil--root)))
  (setq root (file-name-as-directory (file-truename root)))
  (unless (coil-trusted-p root)
    (coil--write-trusted (cons root (coil--trusted))))
  root)

(defun coil-untrust (root)
  "Stop trusting ROOT.  Its running kernel, if any, is left to be shut down."
  (interactive (list (completing-read "Untrust: " (coil--trusted) nil t)))
  (coil--write-trusted (delete (file-name-as-directory root) (coil--trusted))))

(defun coil--ensure-trusted (root)
  (unless (coil-trusted-p root)
    (if (y-or-n-p (format "Start a kernel in %s?  It runs the project's code (its environment's activation, startup files): trust it? "
                          (abbreviate-file-name root)))
        (coil-trust root)
      (user-error "Not trusted: %s" (abbreviate-file-name root)))))


;;; Sessions

(cl-defstruct (coil-session (:constructor coil--session-create) (:copier nil))
  root name state backend process buffer env path
  (next-id 0) (requests (make-hash-table)) queue (partial "")
  ready status pid fresh
  completing                            ; a completion request not answered yet
  asking                                ; (CELL . PROMPT): the kernel's question,
                                        ; answered at the session's prompt
  (codefiles (make-hash-table :test #'equal))) ; the kernel's file of a cell -> it

(cl-defstruct (coil-cell (:constructor coil--cell-create) (:copier nil))
  uid code file line count status start duration outputs
  beg ostart out clear-pending overlay
  origin                                ; the line of FILE that is the code's first
  codefile)                             ; the file the kernel runs it as

(defvar coil--sessions (make-hash-table :test #'equal)
  "The sessions of this Emacs, by project root.")

(defvar-local coil--session nil
  "The session of this session buffer.")
(defvar-local coil--prompt-start nil "Where the prompt begins.")
(defvar-local coil--input-start nil "Where the input begins.")
(defvar-local coil--ready-at nil "Where to say the kernel is ready: above what waits for it.")

(defvar coil-root-function #'coil--default-root
  "A function returning the project root of the current buffer.")

(defun coil--default-root ()
  (or (and (fboundp 'doom-project-root) (doom-project-root))
      (and (fboundp 'project-current)
           (when-let* ((project (project-current))) (project-root project)))
      default-directory))

(defun coil--root ()
  (if coil--session
      (coil-session-root coil--session)
    (file-name-as-directory (file-truename (funcall coil-root-function)))))

(defun coil--backend ()
  (or (and coil--session (coil-session-backend coil--session))
      (cdr (cl-find-if (lambda (entry) (derived-mode-p (car entry))) coil-backends))
      (user-error "coil does not know how to run %s" major-mode)))

(defun coil--live-p (session)
  (and session (process-live-p (coil-session-process session))))

(defun coil-current-session (&optional start)
  "This buffer's session; started first, if START and there is none."
  (let* ((root (coil--root))
         (session (or coil--session (gethash root coil--sessions))))
    (cond ((coil--live-p session) session)
          (start (coil--start root (if session (coil-session-backend session)
                                     (coil--backend))
                              session)))))

(defun coil--start (root backend &optional session)
  "Start the bridge for ROOT, attaching to its kernel or starting one."
  (coil--ensure-trusted root)
  (let* ((session (or session
                      (coil--session-create
                       :root root :backend backend
                       :name (file-name-nondirectory (directory-file-name root))
                       ;; The environment of the buffer it is started from,
                       ;; which envrc made the project's: kept for restarts.
                       :env process-environment :path exec-path)))
         (state (coil--state-dir root t))
         ;; The backend may name the kernel's environment itself (a pixi
         ;; project's dev one); else it is the buffer's, kept from the start.
         (_ (when-let* ((environment (plist-get backend :environment))
                        (env (funcall environment root)))
              (setf (coil-session-env session) env
                    (coil-session-path session)
                    (append (parse-colon-path (getenv-internal "PATH" env))
                            (list exec-directory)))))
         (python (let ((process-environment (coil-session-env session))
                       (exec-path (coil-session-path session)))
                   (funcall (plist-get backend :interpreter))))
         (process-environment (coil-session-env session))
         (exec-path (coil-session-path session))
         (default-directory root))
    ;; One bridge per session: an old one is let go (its kernel stays).
    (when (process-live-p (coil-session-process session))
      (delete-process (coil-session-process session)))
    (unless python
      (user-error "No interpreter for the kernel in %s" (abbreviate-file-name root)))
    ;; What attaching from elsewhere (the list of sessions) needs to know.
    (with-file-modes #o600
      (write-region (prin1-to-string (list :interpreter python
                                           :backend (plist-get backend :name)))
                    nil (expand-file-name "bridge.eld" state) nil 'silent))
    (setf (coil-session-state session) state
          (coil-session-ready session) nil
          (coil-session-status session) (if (equal (coil-session-status session)
                                                    "missing jupyter_client")
                                             "missing jupyter_client"
                                           "starting")
          (coil-session-partial session) ""
          (coil-session-completing session) nil)
    ;; What was sent while the kernel's tools were being installed still
    ;; waits; otherwise what was asked of the bridge before is gone with it.
    (unless (equal (coil-session-status session) "missing jupyter_client")
      (setf (coil-session-queue session) nil)
      (clrhash (coil-session-requests session)))
    (puthash root session coil--sessions)
    (setf (coil-session-process session)
          (make-process
           :name (format "coil %s" (coil-session-name session))
           :command (list python "-I" coil-bridge
                          "--state" state "--cwd" root
                          "--kernel" (json-serialize (vconcat (plist-get backend :kernel))))
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :stderr (get-buffer-create (format " *coil stderr %s*" (coil-session-name session)))
           :filter (lambda (process output) (coil--filter session process output))
           :sentinel (lambda (process event) (coil--sentinel session process event))))
    (with-current-buffer (coil--buffer session)
      ;; Above what is sent from now on -- or above what already waits.
      (unless (and coil--ready-at (marker-position coil--ready-at)
                   (coil-session-queue session))
        (setq coil--ready-at (copy-marker coil--prompt-start))))
    (coil--refresh-mode-line session)
    session))

(defun coil--send (session op &rest fields)
  "Send OP with FIELDS (a plist) to SESSION's bridge; return the request id.
Before the kernel is ready, it waits in a queue."
  (let* ((id (cl-incf (coil-session-next-id session)))
         (line (concat (json-serialize (append (list :id id :op op) fields)) "\n")))
    (if (coil-session-ready session)
        (process-send-string (coil-session-process session) line)
      (setf (coil-session-queue session)
            (append (coil-session-queue session) (list line))))
    id))

(defun coil--request (session op timeout &rest fields)
  "Send OP and wait for its reply, up to TIMEOUT seconds; nil if none came."
  (when (coil-session-ready session)
    (let* ((reply 'waiting)
           (id (apply #'coil--send session op fields))
           (until (+ (float-time) timeout)))
      (puthash id (lambda (content) (setq reply content)) (coil-session-requests session))
      (while (and (eq reply 'waiting) (< (float-time) until)
                  (process-live-p (coil-session-process session)))
        (accept-process-output (coil-session-process session) 0.02))
      (remhash id (coil-session-requests session))
      (unless (eq reply 'waiting) reply))))

(defun coil--filter (session process output)
  ;; Only the session's own bridge is heard: one let go, or of a session
  ;; since replaced, could otherwise write into a buffer no longer its own.
  (when (and (eq process (coil-session-process session))
             (eq session (gethash (coil-session-root session) coil--sessions)))
    (coil--filter-1 session output)))

(defun coil--filter-1 (session output)
  (let ((text (concat (coil-session-partial session) output))
        (start 0))
    (while (string-match "\n" text start)
      (let ((line (substring text start (match-beginning 0))))
        (setq start (match-end 0))
        (unless (string-empty-p line)
          (condition-case err
              (coil--event session (json-parse-string line :object-type 'alist
                                                      :array-type 'list
                                                      :null-object nil
                                                      :false-object nil))
            (error (message "coil: %s" (error-message-string err)))))))
    (setf (coil-session-partial session) (substring text start))))

(defun coil--sentinel (session process _event)
  (unless (process-live-p process)
    (setf (coil-session-ready session) nil)
    (unless (member (coil-session-status session) '("shut down" "restarting"))
      (setf (coil-session-status session) "detached"))
    (coil--refresh-mode-line session)))

(defun coil--event (session event)
  (let ((kind (alist-get 'event event))
        (cell (gethash (alist-get 'id event) (coil-session-requests session))))
    (pcase kind
      ("ready" (coil--ready session event))
      ("missing"
       (setf (coil-session-status session) "missing jupyter_client")
       (if-let* ((missing (plist-get (coil-session-backend session) :missing)))
           (run-at-time 0 nil missing session)
         (message "coil: the environment has no jupyter_client")))
      ("fatal"
       (setf (coil-session-status session) "failed")
       (message "coil: %s" (alist-get 'message event)))
      ("died"
       (unless (member (coil-session-status session) '("restarting" "shut down"))
         (setf (coil-session-status session) "kernel died")
         (coil--note session "The kernel died.  C-c C-z or any send starts a new one.")))
      ("shutdown" (setf (coil-session-status session) "shut down"))
      ("reply"
       (remhash (alist-get 'id event) (coil-session-requests session))
       (when (functionp cell) (funcall cell (alist-get 'content event))))
      ("input_request" (run-at-time 0 nil #'coil--input-request session cell event))
      (_ (when (coil-cell-p cell) (coil--cell-event session cell kind event))))
    (coil--refresh-mode-line session)))

(defun coil--ready (session event)
  (setf (coil-session-ready session) t
        (coil-session-status session) "idle"
        (coil-session-pid session) (alist-get 'pid event)
        (coil-session-fresh session) (alist-get 'fresh event))
  (coil--stop-asking session)
  (with-current-buffer (coil--buffer session)
    (when (alist-get 'fresh event)
      (clrhash (coil-session-codefiles session))
      (coil--rotate-log session))
    (coil--note session (coil--kernel-line event) coil--ready-at))
  (dolist (line (coil-session-queue session))
    (process-send-string (coil-session-process session) line))
  (setf (coil-session-queue session) nil))

(defun coil--kernel-line (event)
  "What the kernel of the ready EVENT is: language, shell, environment, pid."
  (let ((language (alist-get 'language event))
        (implementation (alist-get 'implementation event)))
    (string-join
     (delq nil
           (list (if (alist-get 'fresh event) "New kernel" "Attached to the running kernel")
                 (and language (concat (capitalize language) " " (or (alist-get 'version event) "")))
                 (and implementation (not (equal implementation language))
                      (concat (if (equal implementation "ipython") "IPython" implementation)
                              " " (or (alist-get 'implementation_version event) "")))
                 (and (alist-get 'environment event)
                      (abbreviate-file-name (alist-get 'environment event)))
                 (format "pid %s" (alist-get 'pid event))))
     " · ")))


;;; The session buffer

(defvar-local coil--history nil "What was typed, a ring.")
(defvar-local coil--history-index nil)

(defvar-keymap coil-mode-map
  "RET" #'coil-return
  "C-j" #'newline-and-indent
  "C-<return>" #'coil-submit
  "TAB" #'completion-at-point
  "M-p" #'coil-previous-input
  "M-n" #'coil-next-input
  "C-c C-c" #'coil-interrupt
  "C-c C-n" #'coil-next-cell
  "C-c C-p" #'coil-previous-cell
  "C-c C-k" #'coil-interrupt
  "C-c C-q" #'coil-shutdown
  "C-c C-d" #'coil-detach
  "C-c C-o" #'coil-plots
  "C-a" #'coil-beginning-of-line)

(defvar-keymap coil-cell-map
  :doc "Keys on a cell: the output is read-only, so letters are free."
  "n" #'coil-next-cell
  "p" #'coil-previous-cell
  "RET" #'coil-visit-source
  "w" #'coil-copy-output
  "o" #'coil-open-figure
  "c" #'coil-pin-figure
  "P" #'coil-plots
  "TAB" #'coil-toggle-fold)

(define-derived-mode coil-mode nil "coil"
  "A session with a Jupyter kernel.

Type at the prompt; RET runs what is there when it is complete, and
starts an indented line when it is not.  Above, the cells:
\\{coil-cell-map}
\\{coil-mode-map}"
  (setq-local coil--history (make-ring 500)
              coil--prompt-start (point-min-marker)
              coil--input-start (point-min-marker)
              truncate-lines nil
              word-wrap t
              mode-line-process '(:eval (coil--mode-line-process)))
  (set-marker-insertion-type coil--prompt-start t)
  (add-hook 'completion-at-point-functions #'coil-completion-at-point nil t)
  (add-hook 'eldoc-documentation-functions #'coil-eldoc nil t)
  (eldoc-mode 1)
  (font-lock-mode -1))

(defun coil--buffer (session)
  "SESSION's buffer, made if need be, with its history from the log."
  (let ((buffer (coil-session-buffer session)))
    (if (buffer-live-p buffer)
        buffer
      (setq buffer (get-buffer-create (format "*coil: %s*" (coil-session-name session))))
      ;; Never another live session's buffer, which has the same name.
      (when-let* ((other (buffer-local-value 'coil--session buffer))
                  ((not (eq other session)))
                  ((coil--live-p other)))
        (setq buffer (generate-new-buffer (buffer-name buffer))))
      ;; Known as the session's before it is filled: filling it asks for it.
      (setf (coil-session-buffer session) buffer)
      (with-current-buffer buffer
        (coil-mode)
        (setq coil--session session
              default-directory (coil-session-root session))
        (setq-local process-environment (coil-session-env session)
                    exec-path (coil-session-path session))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (set-marker coil--prompt-start (point-min))
          (coil--insert-prompt)
          (coil--replay-log session)))
      buffer)))

(defun coil--insert-prompt (&optional text)
  "Make the prompt TEXT, or the usual one; what is typed after it stays."
  (let ((inhibit-read-only t)
        (text (or text "» ")))
    (save-excursion
      (goto-char coil--prompt-start)
      (delete-region (point) coil--input-start)
      (insert (propertize text 'face 'coil-prompt 'read-only t 'field 'coil-prompt
                          'rear-nonsticky t 'front-sticky '(read-only)))
      ;; Typed text goes after the input marker, which stays put.
      (set-marker coil--input-start (point)))
    ;; The prompt is inserted at its own start, which moved past it.
    (set-marker coil--prompt-start (- coil--input-start (length text)))))

(defun coil--claim (beg end cell)
  "Make BEG..END part of CELL: read-only, with the cell's keys."
  (add-text-properties beg end `(coil-cell ,cell read-only t keymap ,coil-cell-map
                                           front-sticky (read-only))))

(defun coil--note (session text &optional at)
  "Put TEXT above the prompt of SESSION's buffer, or AT, a line of its own."
  (with-current-buffer (coil--buffer session)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (or at coil--prompt-start))
        ;; Before the markers there: a cell waiting at AT stays after its note.
        (insert-before-markers (propertize (concat text "\n\n") 'face 'coil-header 'read-only t
                            'front-sticky '(read-only)))))))

(defun coil--fontify (code mode)
  "CODE, fontified as MODE does, with `face' rather than `font-lock-face'."
  (if (not (fboundp mode))
      code
    (with-temp-buffer
      (insert code)
      (delay-mode-hooks (funcall mode))
      (font-lock-ensure)
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change pos 'font-lock-face nil (point-max)))
                (face (get-text-property pos 'font-lock-face)))
            (when face (put-text-property pos next 'face face))
            (setq pos next))))
      (buffer-string))))

(defun coil--header (cell)
  (let* ((count (coil-cell-count cell))
         (status (coil-cell-status cell))
         (where (and (coil-cell-file cell)
                     (format "  %s:%s" (file-name-nondirectory (coil-cell-file cell))
                             (coil-cell-line cell))))
         (mark (pcase status
                 ("ok" (propertize "✓" 'face 'coil-ok))
                 ((or "error" "aborted") (propertize (if (equal status "error") "✗" "aborted")
                                                     'face 'coil-failed))
                 (_ "…")))
         (time (and (coil-cell-duration cell)
                    (format " %.2f s" (coil-cell-duration cell)))))
    ;; Where it came from on the left; how it went at the right edge.
    (let ((right (concat mark (if time (propertize time 'face 'coil-header) ""))))
      (concat (propertize (format "In [%s]%s" (or count "*") (or where "")) 'face 'coil-header)
              (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
              right))))

(defun coil--insert-cell (session cell)
  "Put CELL in SESSION's buffer, above the prompt."
  (with-current-buffer (coil--buffer session)
    (let ((inhibit-read-only t)
          (mode (plist-get (coil-session-backend session) :mode)))
      (save-excursion
        (goto-char coil--prompt-start)
        (let ((beg (point)))
          (insert (coil--header cell) "\n")
          (let ((code (point)))
            (insert (coil--fontify (string-trim-right (coil-cell-code cell)) mode) "\n")
            (add-face-text-property code (point) 'coil-code t)
            (coil--fold-input code (point)))
          (let ((ostart (point)))
            ;; The cell ends with a hairline across the window.
            (insert (propertize " " 'display '(space :align-to (- right 1)) 'face 'coil-rule)
                    "\n")
            (setf (coil-cell-beg cell) (copy-marker beg)
                  (coil-cell-ostart cell) (copy-marker ostart)
                  (coil-cell-out cell) (copy-marker ostart t)))
          (coil--claim beg (point) cell))))))

(defun coil--update-header (cell)
  (when-let* ((beg (coil-cell-beg cell))
              ((marker-buffer beg)))
    (with-current-buffer (marker-buffer beg)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char beg)
          (delete-region (point) (line-end-position))
          (insert (coil--header cell))
          (coil--claim (line-beginning-position) (line-end-position) cell))))))

(defmacro coil--at-output (cell &rest body)
  "Run BODY at the end of CELL's output, the inserted text claimed for it."
  (declare (indent 1))
  `(when-let* ((out (coil-cell-out ,cell))
               ((marker-buffer out)))
     (with-current-buffer (marker-buffer out)
       (let ((inhibit-read-only t)
             (follow (cl-loop for window in (get-buffer-window-list nil nil t)
                              when (>= (window-point window) coil--input-start)
                              collect window)))
         (save-excursion
           (goto-char out)
           (let ((beg (point)))
             ,@body
             (coil--claim beg (point) ,cell)))
         ;; The prompt stays in view, the window scrolling no more than
         ;; that takes: nothing moves while it is in view.
         (dolist (window follow)
           (set-window-point window (point-max))
           (unless (pos-visible-in-window-p (point-max) window)
             (with-selected-window window
               (goto-char (point-max))
               (recenter -1))))))))

(defun coil--ansi (beg end)
  "Colour BEG..END from its SGR sequences, and drop the other CSI ones.
The faces go in `face': this buffer has no font-lock."
  (let ((ansi-color-apply-face-function
         (lambda (b e face) (when face (put-text-property b e 'face face)))))
    (ansi-color-apply-on-region beg end)))

(defun coil--insert-stream (cell text stderr)
  (coil--at-output cell
    (let ((text (string-replace "\r\n" "\n" text))
          (first t))
      (dolist (part (split-string text "\r"))
        ;; A carriage return writes over its line, as a progress bar does.
        (unless first
          (delete-region (max (line-beginning-position) (coil-cell-ostart cell)) (point)))
        (setq first nil)
        (let ((b (point)))
          (insert part)
          (coil--ansi b (point))
          (when stderr (add-face-text-property b (point) 'coil-stderr t)))))))

(defun coil--png-pixels (data)
  "The pixels of the PNG DATA says it is, from its header."
  (when (and (> (length data) 24) (string-prefix-p "\x89PNG" data))
    (cl-flet ((u32 (i) (+ (ash (aref data i) 24) (ash (aref data (+ i 1)) 16)
                          (ash (aref data (+ i 2)) 8) (aref data (+ i 3)))))
      (* (u32 16) (u32 20)))))

(defun coil--save-image (session data type)
  "Write the image DATA into SESSION's state, and return its file."
  (let* ((dir (expand-file-name "img/" (coil-session-state session)))
         (file (expand-file-name (concat (secure-hash 'sha1 data) "." (symbol-name type)) dir)))
    (with-file-modes #o700 (make-directory dir t))
    (unless (file-exists-p file)
      (with-file-modes #o600
        (let ((coding-system-for-write 'no-conversion))
          (write-region data nil file nil 'silent))))
    file))

(defun coil--image-width (buffer)
  (let ((window (get-buffer-window buffer t)))
    (min (or coil-image-max-width most-positive-fixnum)
         (if window (- (window-body-width window t) 20) 800))))

(defun coil--insert-image (cell file)
  (coil--at-output cell
    (let ((image (create-image file nil nil :max-width (coil--image-width (current-buffer)))))
      (insert-image image "[figure]")
      (put-text-property (1- (point)) (point) 'coil-image file)
      (insert "\n"))))

(defun coil--insert-text (cell text &optional prefix face)
  (coil--at-output cell
    (let ((b (point)))
      (when prefix (insert (propertize prefix 'face 'coil-header)))
      (let ((tb (point)))
        (insert text)
        (unless (bolp) (insert "\n"))
        (coil--ansi tb (point))
        (when face (add-face-text-property b (point) face t))))))

(defun coil--data (session cell data &optional count)
  "Show DATA, a MIME bundle: its figure if it has one, else its text."
  (let* ((png (alist-get 'image/png data))
         (jpeg (alist-get 'image/jpeg data))
         (text (alist-get 'text/plain data))
         (prefix (and count (format "Out[%s]: " count))))
    (cond
     ((or png jpeg)
      (let* ((type (if png 'png 'jpeg))
             (bytes (ignore-errors (base64-decode-string (or png jpeg))))
             (pixels (and bytes (coil--png-pixels bytes))))
        (cond ((not bytes)
               (coil--insert-text cell "[an image that could not be decoded]\n" nil 'coil-failed))
              ((and pixels (> pixels coil-max-image-pixels))
               (coil--insert-text cell (format "[an image of %d pixels, not drawn]\n" pixels)
                                  nil 'coil-failed))
              (t
               (let ((file (coil--save-image session bytes type)))
                 (push `((type . "image") (file . ,(file-name-nondirectory file)))
                       (coil-cell-outputs cell))
                 (coil--insert-image cell file)
                 (run-hook-with-args 'coil-figure-functions session cell file))))))
     (text
      (push `((type . ,(if count "result" "text")) (text . ,text) (prefix . ,prefix))
            (coil-cell-outputs cell))
      (coil--insert-text cell text prefix)))))

(defun coil--clear-output (cell)
  (coil--at-output cell
    (delete-region (coil-cell-ostart cell) (point)))
  (setf (coil-cell-outputs cell) nil))

(defun coil--cell-event (session cell kind event)
  (when (and (coil-cell-clear-pending cell)
             (member kind '("stream" "display" "result" "error")))
    (setf (coil-cell-clear-pending cell) nil)
    (coil--clear-output cell))
  (pcase kind
    ("status"
     (setf (coil-session-status session) (alist-get 'state event)))
    ("input"
     ;; It runs from now: the time before was spent waiting its turn.
     (setf (coil-cell-count cell) (alist-get 'count event)
           (coil-cell-start cell) (float-time))
     (coil--update-header cell))
    ("stream"
     (let ((stderr (equal (alist-get 'name event) "stderr"))
           (text (alist-get 'text event)))
       (push `((type . "stream") (name . ,(alist-get 'name event)) (text . ,text))
             (coil-cell-outputs cell))
       (coil--insert-stream cell text stderr)))
    ("display" (coil--data session cell (alist-get 'data event)))
    ("result" (coil--data session cell (alist-get 'data event) (alist-get 'count event)))
    ("error"
     (let ((traceback (string-join (alist-get 'traceback event) "\n")))
       (push `((type . "error") (ename . ,(alist-get 'ename event))
               (evalue . ,(alist-get 'evalue event)) (traceback . ,traceback))
             (coil-cell-outputs cell))
       (coil--insert-text cell traceback)))
    ("clear"
     (if (alist-get 'wait event)
         (setf (coil-cell-clear-pending cell) t)
       (coil--clear-output cell)))
    ("codefile"
     (setf (coil-cell-codefile cell) (alist-get 'name event))
     (puthash (alist-get 'name event) cell (coil-session-codefiles session)))
    ("done"
     (remhash (alist-get 'id event) (coil-session-requests session))
     (when (eq (car (coil-session-asking session)) cell)
       (coil--stop-asking session))
     (setf (coil-cell-status cell) (alist-get 'status event)
           (coil-cell-duration cell) (- (float-time) (coil-cell-start cell)))
     (when (alist-get 'count event)
       (setf (coil-cell-count cell) (alist-get 'count event)))
     (coil--update-header cell)
     (coil--fold cell)
     (coil--summarize cell)
     (coil--log-cell session cell)
     (run-hook-with-args 'coil-cell-done-functions session cell))))

(defun coil-show-cell (cell)
  "Show CELL in its session buffer."
  (when-let* ((beg (coil-cell-beg cell))
              (buffer (marker-buffer beg)))
    (pop-to-buffer buffer)
    (goto-char beg)
    (recenter 0)))

(defun coil--summarize (cell)
  "Say how CELL went where it came from, if it was given a place (an overlay)."
  (when-let* ((overlay (coil-cell-overlay cell))
              ((overlay-buffer overlay)))
    (let* ((error (cl-find "error" (coil-cell-outputs cell)
                           :key (lambda (output) (alist-get 'type output)) :test #'equal))
           (text (if (equal (coil-cell-status cell) "ok")
                     (propertize (format "  ✓ %.2f s" (coil-cell-duration cell)) 'face 'coil-ok)
                   (propertize (format "  ✗ %s"
                                       (if error
                                           (truncate-string-to-width
                                            (format "%s: %s" (alist-get 'ename error)
                                                    (alist-get 'evalue error))
                                            80 nil nil "…")
                                         (coil-cell-status cell)))
                               'face 'coil-failed))))
      (overlay-put overlay 'after-string
                   (propertize text 'mouse-face 'highlight 'help-echo "mouse-1: the output"
                               'keymap (define-keymap
                                         "<mouse-1>" (lambda () (interactive) (coil-show-cell cell))))))))

(defun coil--make-fold (beg end label)
  "Hide BEG..END, showing LABEL in its place; TAB shows it again."
  (let ((overlay (make-overlay beg end)))
    (overlay-put overlay 'invisible t)
    (overlay-put overlay 'evaporate t)    ; gone with its text
    (overlay-put overlay 'coil-fold label)
    (overlay-put overlay 'before-string label)
    overlay))

(defun coil--fold-input (beg end)
  "Fold the code from BEG to END (after its newline), if it is long."
  (save-excursion
    (goto-char beg)
    (let ((lines (count-lines beg end)))
      (when (and (> lines coil-fold-input-lines)
                 (zerop (forward-line coil-fold-input-shown)))
        (coil--make-fold (point) (1- end)
                         (propertize (format "… %d more lines  TAB"
                                             (- lines coil-fold-input-shown))
                                     'face '(coil-header coil-code)))))))

(defun coil--fold (cell)
  "Fold CELL's output after `coil-fold-lines' lines."
  (when-let* ((out (coil-cell-out cell))
              ((marker-buffer out)))
    (with-current-buffer (marker-buffer out)
      (save-excursion
        (goto-char (coil-cell-ostart cell))
        (when (and (zerop (forward-line coil-fold-lines))
                   (< (point) (1- out)))
          (coil--make-fold (point) (1- out)
                           (propertize (format "… %d more lines  TAB\n"
                                               (count-lines (point) (1- out)))
                                       'face 'coil-header)))))))

(defun coil-toggle-fold ()
  "Show, or fold again, the long code or output of the cell at point."
  (interactive)
  (let* ((cell (or (get-text-property (point) 'coil-cell) (user-error "Not on a cell")))
         (code-p (< (point) (coil-cell-ostart cell))))
    (dolist (overlay (if code-p
                         (overlays-in (coil-cell-beg cell) (coil-cell-ostart cell))
                       (overlays-in (coil-cell-ostart cell) (coil-cell-out cell))))
      (when-let* ((label (overlay-get overlay 'coil-fold)))
        (let ((fold (not (overlay-get overlay 'invisible))))
          (overlay-put overlay 'invisible fold)
          (overlay-put overlay 'before-string (and fold label)))))))


;;; Running code

(cl-defun coil-execute (code &key file line origin session breakpoints)
  "Run CODE in SESSION (this buffer's, started if need be).
FILE and LINE say where it came from, ORIGIN which of FILE's lines is the
first of CODE (LINE, if not given).  It stops at BREAKPOINTS, a list as
`coil-breakpoints-function' returns, and at the latter's.  Return the cell."
  (let* ((session (or session (coil-current-session t)))
         (cell (coil--cell-create :uid (format "%x-%x" (truncate (float-time)) (random 65536))
                                  :code code :file file :line line
                                  :origin (or origin line)
                                  :start (float-time)))
         (breakpoints (append breakpoints
                              (and coil-breakpoints-function
                                   (funcall coil-breakpoints-function session cell)))))
    (coil--insert-cell session cell)
    (let ((id (apply #'coil--send session "execute" :code code
                     (and breakpoints (list :breakpoints (vconcat breakpoints))))))
      (puthash id cell (coil-session-requests session)))
    (unless (get-buffer-window (coil--buffer session) t)
      (display-buffer (coil--buffer session)
                      '((display-buffer-reuse-window display-buffer-use-some-window
                                                     display-buffer-pop-up-window)
                        (inhibit-same-window . t))))
    cell))

(defun coil--input-request (session cell event)
  "Answer the kernel's `input()' from the minibuffer; C-g interrupts it.
Unless one of `coil-input-request-functions' takes the question."
  (unless (and (not (alist-get 'password event))
               (run-hook-with-args-until-success 'coil-input-request-functions
                                                 session cell event))
    (let ((value (condition-case nil
                     (if (alist-get 'password event)
                         (read-passwd (alist-get 'prompt event))
                       (read-string (alist-get 'prompt event)))
                   (quit (coil--send session "interrupt") ""))))
      (coil--send session "input" :value value)
      (when (alist-get 'password event) (clear-string value)))))

(defun coil-ask (session cell prompt)
  "Have the kernel's question, PROMPT, answered at SESSION's prompt.
The prompt becomes PROMPT; what is typed there next is the answer."
  (setf (coil-session-asking session) (cons cell prompt))
  (with-current-buffer (coil--buffer session)
    (coil--insert-prompt (propertize prompt 'face 'coil-prompt))))

(defun coil--stop-asking (session)
  (when (coil-session-asking session)
    (setf (coil-session-asking session) nil)
    (when (buffer-live-p (coil-session-buffer session))
      (with-current-buffer (coil-session-buffer session)
        (coil--insert-prompt)))))

(defun coil-answer (session value)
  "Answer SESSION's question with VALUE, which is written under its cell."
  (pcase-let ((`(,cell . ,prompt) (or (coil-session-asking session)
                                      (user-error "The kernel asks nothing now"))))
    (coil--stop-asking session)
    (coil--insert-text cell (concat value "\n") prompt)
    (push `((type . "stream") (name . "stdout") (text . ,(concat prompt value "\n")))
          (coil-cell-outputs cell))
    (coil--send session "input" :value value)))

(defun coil-interrupt (&optional restart)
  "Interrupt what the kernel is running.
With RESTART (\\[universal-argument]), restart the kernel instead, losing its state."
  (interactive "P")
  (if restart
      (coil-restart)
    (coil--send (or (coil-current-session) (user-error "No session")) "interrupt")))

(defun coil-detach ()
  "Let go of the kernel, which runs on: C-c C-z, or any send, attaches again."
  (interactive)
  (let ((session (or (coil-current-session) (user-error "Not attached"))))
    (setf (coil-session-status session) "detached")
    (delete-process (coil-session-process session))
    (coil--note session "Detached: the kernel runs on.  C-c C-z, or any send, attaches again.")
    (coil--refresh-mode-line session)))

(defun coil-restart ()
  "Shut the kernel down, and start a new one."
  (interactive)
  (let ((session (coil-current-session t)))
    (when (y-or-n-p "Restart the kernel, losing its state? ")
      (setf (coil-session-status session) "restarting")
      ;; Sent once the bridge is ready, if it is not yet.
      (coil--send session "shutdown")
      (let ((until (+ (float-time) 30)))
        (while (and (process-live-p (coil-session-process session))
                    (< (float-time) until))
          (accept-process-output (coil-session-process session) 0.1)))
      (coil--start (coil-session-root session) (coil-session-backend session) session))))

(defun coil-shutdown ()
  "Shut the kernel down: its state is lost; the log is kept."
  (interactive)
  (when-let* ((session (coil-current-session)))
    (when (y-or-n-p "Shut the kernel down, losing its state? ")
      (setf (coil-session-status session) "shut down")
      (coil--send session "shutdown"))))


;;; Input

(defun coil--in-input-p ()
  (and coil--input-start (>= (point) coil--input-start)))

(defun coil--input ()
  (buffer-substring-no-properties coil--input-start (point-max)))

(defun coil-beginning-of-line ()
  "To the start of the input on its first line, else of the line."
  (interactive)
  (if (and (coil--in-input-p)
           (<= (line-beginning-position) coil--input-start))
      (goto-char coil--input-start)
    (move-beginning-of-line 1)))

(defun coil-return ()
  "Run the input if it is complete, else start a new line; on a cell, visit it."
  (interactive)
  (cond ((not (coil--in-input-p)) (coil-visit-source))
        ((coil-session-asking coil--session) (coil-submit))
        ((string-blank-p (coil--input)) nil)
        (t
         (let* ((reply (coil--request coil--session "is_complete" 1 :code (coil--input)))
                (status (alist-get 'status reply)))
           (if (and (equal status "incomplete") (= (point) (point-max)))
               (insert "\n" (or (alist-get 'indent reply) ""))
             (coil-submit))))))

(defun coil-submit ()
  "Run the input, complete or not."
  (interactive)
  (let ((code (coil--input)))
    (if (coil-session-asking coil--session)
        ;; An answer, blank or not (a blank line repeats pdb's last command).
        (progn (delete-region coil--input-start (point-max))
               (coil-answer coil--session code))
      (unless (string-blank-p code)
        (ring-insert coil--history code)
        (setq coil--history-index nil)
        (delete-region coil--input-start (point-max))
        (coil-execute code :session coil--session)))))

(defun coil--history-step (n)
  (when (ring-empty-p coil--history) (user-error "No history"))
  (setq coil--history-index
        (if coil--history-index
            (min (max (+ coil--history-index n) 0) (1- (ring-length coil--history)))
          (max 0 (1- n))))
  (delete-region coil--input-start (point-max))
  (goto-char (point-max))
  (insert (ring-ref coil--history coil--history-index)))

(defun coil-previous-input ()
  "The input before, from the history."
  (interactive)
  (coil--history-step 1))

(defun coil-next-input ()
  "The input after, from the history."
  (interactive)
  (if (and coil--history-index (> coil--history-index 0))
      (coil--history-step -1)
    (setq coil--history-index nil)
    (delete-region coil--input-start (point-max))))


;;; Completion and docs

(defcustom coil-completion-timeout 0.5
  "The longest completion waits for the kernel, in seconds.
Typing stops the wait at once, whatever this says."
  :type 'number)

(defun coil--complete-at (session code pos)
  "The kernel's completions of CODE at POS, or nil.
Typing comes first: the wait ends at the first key pressed, and while an
answer is still being worked out (a library's first, by jedi, can take
seconds) no other question is put behind it -- the keys are not held up."
  (unless (and (coil-session-completing session)
               ;; One never answered (the kernel died, say) is let go.
               (< (- (float-time) (coil-session-completing session)) 10))
    (let* ((reply 'waiting)
           (id (coil--send session "complete" :code code :pos pos))
           (until (+ (float-time) coil-completion-timeout)))
      (setf (coil-session-completing session) (float-time))
      (puthash id (lambda (content)
                    (setf (coil-session-completing session) nil)
                    (setq reply content))
               (coil-session-requests session))
      (while (and (eq reply 'waiting)
                  (< (float-time) until)
                  (not (input-pending-p))
                  (process-live-p (coil-session-process session)))
        (accept-process-output (coil-session-process session) 0.01))
      (when (and (listp reply) (equal (alist-get 'status reply) "ok"))
        reply))))

(defun coil-completion-at-point ()
  "Completion from the live session, for `completion-at-point-functions'.
In the session buffer, of the input; elsewhere, of the line at point."
  (when-let* ((session (coil-current-session))
              ((coil-session-ready session)))
    (let* ((input-p (and coil--session (coil--in-input-p)))
           (base (if input-p coil--input-start (line-beginning-position)))
           (code (buffer-substring-no-properties base (if input-p (point-max) (line-end-position))))
           (reply (coil--complete-at session code (- (point) base))))
      (when-let* ((matches (alist-get 'matches reply)))
        (list (+ base (alist-get 'cursor_start reply))
              (+ base (alist-get 'cursor_end reply))
              matches
              :exclusive 'no)))))

(defcustom coil-eldoc-in-source nil
  "Whether eldoc in source buffers also asks the live session.
The language server answers there already; this adds what only the running
session knows, as the type and size of a data frame."
  :type 'boolean)

(defun coil--sections (text)
  "IPython's inspection TEXT, as an alist of its sections: (\"Signature\" . ...)."
  (let (sections)
    (with-temp-buffer
      (insert (ansi-color-filter-apply text))
      (goto-char (point-min))
      (while (re-search-forward "^\\([A-Z][a-z]+\\(?: [a-z]+\\)*\\):[ \t]*" nil t)
        (let ((name (match-string 1))
              (beg (point))
              (end (save-excursion
                     (if (re-search-forward "^[A-Z][a-z]+\\(?: [a-z]+\\)*:" nil t)
                         (match-beginning 0)
                       (point-max)))))
          (push (cons name (string-trim (buffer-substring beg end))) sections)
          (goto-char end))))
    (nreverse sections)))

(defun coil--split-top (string)
  "STRING split at the commas outside brackets and quotes."
  (let ((depth 0) (quote nil) (start 0) parts)
    (dotimes (i (length string))
      (let ((c (aref string i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\' ?\")) (setq quote c))
              ((memq c '(?\( ?\[ ?\{)) (cl-incf depth))
              ((memq c '(?\) ?\] ?\})) (cl-decf depth))
              ((and (eq c ?,) (zerop depth))
               (push (substring string start i) parts)
               (setq start (1+ i))))))
    (nreverse (cons (substring string start) parts))))

(defun coil--short-signature (signature)
  "SIGNATURE with its parameters' names only, and its return type unquoted."
  (if (not (string-match "\\`\\([^(]*\\)(\\(\\(?:.\\|\n\\)*\\))\\(?:\\s-*->\\s-*\\(.*\\)\\)?\\'"
                         signature))
      signature
    (let* ((name (match-string 1 signature))
           (returns (match-string 3 signature))
           (params (cl-loop for part in (coil--split-top (match-string 2 signature))
                            for param = (string-trim part)
                            unless (string-empty-p param)
                            collect (if (string-match "\\`[*/]*[[:alnum:]_]*" param)
                                        (match-string 0 param)
                                      param))))
      (concat name "(" (string-join params ", ") ")"
              (let ((returns (and returns (string-trim (string-trim returns) "['\"]" "['\"]"))))
                (and returns (not (equal returns "None")) (concat " -> " returns)))))))

(defun coil--eldoc-text (content)
  "A line for eldoc from an inspect reply's CONTENT: (TEXT . THING), or nil."
  (when-let* (((alist-get 'found content))
              (text (alist-get 'text/plain (alist-get 'data content)))
              (sections (coil--sections text)))
    (cl-flet ((get (&rest names)
                (cl-some (lambda (name) (cdr (assoc name sections))) names))
              (one-line (string)
                (string-trim (replace-regexp-in-string
                              "(\\s-+" "(" (replace-regexp-in-string
                                              ",?\\s-*\n\\s-*\\()\\)" "\\1"
                                              (replace-regexp-in-string "\n\\s-*" " " string))))))
      (let* ((signature (get "Signature" "Init signature" "Call signature"))
             (doc (get "Docstring" "Init docstring" "Class docstring"))
             (first (and doc (not (string-prefix-p "<no docstring>" doc))
                         (car (split-string doc "\n\\s-*\n" t))))
             (summary (and first (one-line first))))
        (cond
         (signature
          (let ((signature (coil--short-signature (one-line signature))))
            (cons (if summary (concat signature "  " (propertize summary 'face 'shadow)) signature)
                  (and (string-match "\\`\\([^(]+\\)(" signature) (match-string 1 signature)))))
         ((get "Type")
          (let ((form (get "String form")))
            (cons (concat (get "Type")
                          (and form (concat "  " (propertize (truncate-string-to-width
                                                              (one-line form) 120 nil nil "…")
                                                             'face 'shadow))))
                  nil))))))))

(defun coil-eldoc (callback &rest _)
  "Eldoc from the live session: the signature, or the type, of what is at point.
Asked of the kernel in the background (on its subshell: also while code runs)."
  (when-let* ((session (coil-current-session))
              ((coil-session-ready session))
              ((or (and coil--session (coil--in-input-p))
                   (and (not coil--session) coil-eldoc-in-source))))
    (let* ((input-p (and coil--session (coil--in-input-p)))
           (base (if input-p coil--input-start (line-beginning-position)))
           (code (buffer-substring-no-properties
                  base (if input-p (point-max) (line-end-position))))
           (pos (- (point) base)))
      (unless (string-blank-p code)
        (let ((id (coil--send session "inspect" :code code :pos pos :detail 0)))
          (puthash id (lambda (content)
                        (when-let* ((doc (coil--eldoc-text content)))
                          (funcall callback (car doc) :thing (cdr doc)
                                   :face 'font-lock-function-name-face)))
                   (coil-session-requests session))
          t)))))

(defun coil-inspect ()
  "Show what the live session knows of the name at point."
  (interactive)
  (let* ((session (or (coil-current-session) (user-error "No session")))
         (input-p (and coil--session (coil--in-input-p)))
         (base (if input-p coil--input-start (line-beginning-position)))
         (code (buffer-substring-no-properties base (if input-p (point-max) (line-end-position))))
         (reply (coil--request session "inspect" 5 :code code :pos (- (point) base) :detail 0))
         (text (alist-get 'text/plain (alist-get 'data reply))))
    (unless (and text (alist-get 'found reply))
      (user-error "Nothing known of that"))
    (with-help-window "*coil inspect*"
      (with-current-buffer standard-output
        (let ((inhibit-read-only t))
          (insert text)
          (coil--ansi (point-min) (point-max)))))))


;;; Moving about

(defun coil--cell-at (&optional pos)
  (get-text-property (or pos (point)) 'coil-cell))

(defun coil-next-cell (&optional n)
  "To the next cell's start; with N, the Nth."
  (interactive "p")
  (dotimes (_ (or n 1))
    (let ((here (coil--cell-at)))
      (when here (goto-char (coil-cell-beg here)))
      (let ((match (save-excursion
                     (when here (goto-char (coil-cell-out here)))
                     (text-property-search-forward 'coil-cell nil
                                                   (lambda (_ value) (and value (not (eq value here))))
                                                   nil))))
        (if match (goto-char (prop-match-beginning match))
          (goto-char coil--input-start))))))

(defun coil-previous-cell (&optional n)
  "To the previous cell's start; with N, the Nth."
  (interactive "p")
  (dotimes (_ (or n 1))
    (let* ((here (coil--cell-at))
           (match (save-excursion
                    (when here (goto-char (coil-cell-beg here)))
                    (text-property-search-backward 'coil-cell nil
                                                   (lambda (_ value) (and value (not (eq value here))))
                                                   nil))))
      (if match
          (goto-char (coil-cell-beg (prop-match-value match)))
        (user-error "No cell before")))))

(defun coil-visit-source ()
  "Visit the code the cell at point came from."
  (interactive)
  (let ((cell (or (coil--cell-at) (user-error "Not on a cell"))))
    (if (not (coil-cell-file cell))
        (progn (goto-char (point-max))
               (unless (string-blank-p (coil--input))
                 (delete-region coil--input-start (point-max)))
               (insert (string-trim-right (coil-cell-code cell))))
      (find-file-other-window (coil-cell-file cell))
      (goto-char (point-min))
      (forward-line (1- (or (coil-cell-line cell) 1)))
      (pulse-momentary-highlight-one-line (point)))))

(defun coil-copy-output ()
  "Copy the output of the cell at point, as text."
  (interactive)
  (let ((cell (or (coil--cell-at) (user-error "Not on a cell"))))
    (kill-new (string-trim (buffer-substring-no-properties
                            (coil-cell-ostart cell) (coil-cell-out cell))))
    (message "Copied the output of In [%s]" (coil-cell-count cell))))

(defun coil--image-at ()
  (let ((cell (or (coil--cell-at) (user-error "Not on a cell"))))
    (or (get-text-property (point) 'coil-image)
        (let ((pos (coil-cell-ostart cell)) file)
          (while (and (not file) (< pos (coil-cell-out cell)))
            (setq file (get-text-property pos 'coil-image)
                  pos (1+ pos)))
          file)
        (user-error "No figure here"))))

(defun coil-open-figure ()
  "Open the figure at point, or the cell's first, at full size."
  (interactive)
  (find-file-other-window (coil--image-at)))

(defvar coil-pin-function nil
  "What `coil-pin-figure' does with a figure: called with its image file and
the cell that drew it.  A canvas, a folder of figures, a slide deck: coil
leaves that to the configuration.")

(defun coil-pin-figure ()
  "Pin the figure at point, as `coil-pin-function' does."
  (interactive)
  (unless coil-pin-function
    (user-error "Nowhere to pin figures: set `coil-pin-function'"))
  (funcall coil-pin-function (coil--image-at) (coil--cell-at)))


;;; The log

(defun coil--log-file (session)
  (expand-file-name "log.jsonl" (coil-session-state session)))

(defun coil--log-cell (session cell)
  (when coil-log-keep
    (let ((entry `((uid . ,(coil-cell-uid cell))
                   (code . ,(coil-cell-code cell))
                   (file . ,(or (coil-cell-file cell) :null))
                   (line . ,(or (coil-cell-line cell) :null))
                   (count . ,(or (coil-cell-count cell) :null))
                   (status . ,(or (coil-cell-status cell) :null))
                   (duration . ,(or (coil-cell-duration cell) :null))
                   (time . ,(format-time-string "%FT%T%z" (coil-cell-start cell)))
                   (outputs . ,(vconcat
                                (mapcar (lambda (output)
                                          (mapcar (lambda (pair) (cons (car pair) (or (cdr pair) :null)))
                                                  output))
                                        (reverse (coil-cell-outputs cell))))))))
      (with-file-modes #o600
        (write-region (concat (json-serialize entry) "\n") nil
                      (coil--log-file session) 'append 'silent)))))

(defun coil--read-log (file &optional last)
  "The cells logged in FILE, oldest first; only the LAST so many, if given."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((lines (split-string (buffer-string) "\n" t)))
        (when (and last (> (length lines) last))
          (setq lines (last lines last)))
        (delq nil (mapcar (lambda (line)
                            (ignore-errors
                              (json-parse-string line :object-type 'alist :array-type 'list
                                                 :null-object nil :false-object nil)))
                          lines))))))

(defun coil--replay-log (session)
  "Show again the cells of SESSION's log, as they ended."
  (let ((img (expand-file-name "img/" (coil-session-state session))))
    (dolist (entry (coil--read-log (coil--log-file session) coil-log-cells))
      (let ((cell (coil--cell-create :uid (alist-get 'uid entry)
                                     :code (alist-get 'code entry)
                                     :file (alist-get 'file entry)
                                     :line (alist-get 'line entry)
                                     :count (alist-get 'count entry)
                                     :status (alist-get 'status entry)
                                     :duration (alist-get 'duration entry))))
        (ring-insert coil--history (alist-get 'code entry))
        (coil--insert-cell session cell)
        (dolist (output (alist-get 'outputs entry))
          (pcase (alist-get 'type output)
            ("stream" (coil--insert-stream cell (alist-get 'text output)
                                           (equal (alist-get 'name output) "stderr")))
            ((or "text" "result") (coil--insert-text cell (alist-get 'text output)
                                                     (alist-get 'prefix output)))
            ("error" (coil--insert-text cell (alist-get 'traceback output)))
            ("image" (let ((file (expand-file-name (alist-get 'file output) img)))
                       (if (file-exists-p file)
                           (coil--insert-image cell file)
                         (coil--insert-text cell "[figure no longer kept]\n" nil 'coil-header)))))
          (push output (coil-cell-outputs cell)))
        (coil--fold cell)))
    (when (file-exists-p (coil--log-file session))
      (coil--note session "Above: from the log."))))

(defun coil--rotate-log (session)
  "Begin a new log for a new kernel; keep `coil-log-keep' old ones."
  (let* ((state (coil-session-state session))
         (log (coil--log-file session)))
    (when (file-exists-p log)
      (rename-file log (expand-file-name (format-time-string "log-%Y%m%dT%H%M%S.jsonl") state) t))
    (let ((old (sort (directory-files state t "\\`log-.*\\.jsonl\\'") #'string>)))
      (dolist (file (nthcdr (or coil-log-keep 0) old))
        (delete-file file)))
    (coil--prune-images session)))

(defun coil--prune-images (session)
  "Delete the figures no kept log refers to."
  (let* ((state (coil-session-state session))
         (img (expand-file-name "img/" state))
         (used (make-hash-table :test #'equal)))
    (when (file-directory-p img)
      (dolist (log (directory-files state t "\\`log.*\\.jsonl\\'"))
        (dolist (entry (coil--read-log log))
          (dolist (output (alist-get 'outputs entry))
            (when-let* ((file (alist-get 'file output)))
              (puthash file t used)))))
      (dolist (file (directory-files img nil "\\`[0-9a-f]+\\.\\(png\\|jpeg\\)\\'"))
        (unless (gethash file used)
          (delete-file (expand-file-name file img)))))))


;;; Figures, all of them

(defvar-local coil--plot-starts nil "Where each figure begins.")

(defun coil-plots ()
  "Every figure of this project's sessions, the newest first; n and p to move."
  (interactive)
  (let* ((root (coil--root))
         (state (coil--state-dir root))
         (img (expand-file-name "img/" state))
         (logs (sort (directory-files state t "\\`log.*\\.jsonl\\'")
                     (lambda (a b) (string> (file-name-nondirectory a) (file-name-nondirectory b)))))
         ;; log.jsonl sorts after the dated ones: the current, first.
         (buffer (get-buffer-create (format "*coil plots: %s*"
                                            (file-name-nondirectory (directory-file-name root))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (coil-plots-mode)
        (setq coil--plot-starts nil)
        (dolist (log logs)
          (dolist (entry (reverse (coil--read-log log)))
            (dolist (output (reverse (alist-get 'outputs entry)))
              (when-let* ((name (alist-get 'file output))
                          (file (expand-file-name name img))
                          ((file-exists-p file)))
                (let ((beg (point)))
                  (push beg coil--plot-starts)
                  (insert (propertize (format "In [%s]  %s  %s\n" (alist-get 'count entry)
                                              (if (alist-get 'file entry)
                                                  (format "%s:%s" (file-name-nondirectory (alist-get 'file entry))
                                                          (alist-get 'line entry))
                                                "")
                                              (alist-get 'time entry))
                                      'face 'coil-header))
                  (insert-image (create-image file nil nil :max-width (coil--image-width buffer)) "[figure]")
                  (insert "\n\n")
                  (add-text-properties beg (point) `(coil-plot ,file coil-entry ,entry)))))))
        (setq coil--plot-starts (nreverse coil--plot-starts))
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    (when (= (buffer-size buffer) 0)
      (message "No figures yet"))))

(defvar-keymap coil-plots-mode-map
  "n" #'coil-plots-next
  "p" #'coil-plots-previous
  "o" #'coil-plots-open
  "RET" #'coil-plots-visit)

(define-derived-mode coil-plots-mode special-mode "coil plots"
  "The figures of a project's sessions, newest first.")

(defun coil-plots-next ()
  "The next figure."
  (interactive)
  (if-let* ((next (cl-find-if (lambda (start) (> start (point))) coil--plot-starts)))
      (progn (goto-char next) (recenter 0))
    (message "The last figure")))

(defun coil-plots-previous ()
  "The figure before."
  (interactive)
  (if-let* ((previous (cl-find-if (lambda (start) (< start (point))) (reverse coil--plot-starts))))
      (progn (goto-char previous) (recenter 0))
    (message "The first figure")))

(defun coil-plots-open ()
  (interactive)
  (find-file-other-window (or (get-text-property (point) 'coil-plot) (user-error "No figure here"))))

(defun coil-plots-visit ()
  "Visit the code that drew the figure at point."
  (interactive)
  (let ((entry (or (get-text-property (point) 'coil-entry) (user-error "No figure here"))))
    (if-let* ((file (alist-get 'file entry)))
        (progn (find-file-other-window file)
               (goto-char (point-min))
               (forward-line (1- (or (alist-get 'line entry) 1))))
      (message "%s" (alist-get 'code entry)))))


;;; Sessions, all of them

(defun coil--pid-alive-p (pid)
  (and pid (process-attributes pid) t))

(defun coil--known-kernels ()
  "Every project coil keeps state for: (ROOT STATE PID)."
  (when (file-directory-p coil-state-directory)
    (cl-loop for state in (directory-files coil-state-directory t "\\`[0-9a-f]\\{12\\}\\'")
             for root-file = (expand-file-name "root" state)
             for pid-file = (expand-file-name "kernel.pid" state)
             when (file-readable-p root-file)
             collect (list (with-temp-buffer (insert-file-contents root-file) (buffer-string))
                           state
                           (and (file-readable-p pid-file)
                                (with-temp-buffer (insert-file-contents pid-file)
                                                  (string-to-number (buffer-string))))))))

(defun coil-list-sessions ()
  "List the kernels coil has started, running or not."
  (interactive)
  (let ((buffer (get-buffer-create "*coil sessions*")))
    (with-current-buffer buffer
      (coil-sessions-mode)
      (coil--sessions-refresh)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

(define-derived-mode coil-sessions-mode tabulated-list-mode "coil sessions"
  "The kernels coil knows of, running or not.
RET attaches to the one at point (or starts it) and shows it; d detaches;
k kills it; g looks again."
  (setq tabulated-list-format [("Project" 45 t) ("Kernel" 8 t) ("Memory" 9 t)
                               ("Up" 8 t) ("Attached" 8 t)])
  (add-hook 'tabulated-list-revert-hook #'coil--sessions-refresh nil t)
  (tabulated-list-init-header))

(defun coil--sessions-refresh ()
  (setq tabulated-list-entries
        (cl-loop for (root state pid) in (coil--known-kernels)
                 for alive = (and pid (coil--pid-alive-p pid))
                 for attributes = (and alive (process-attributes pid))
                 for rss = (alist-get 'rss attributes)
                 for up = (alist-get 'etime attributes)
                 collect (list state
                               (vector (abbreviate-file-name root)
                                       (if alive (number-to-string pid) "-")
                                       (if rss (format "%d MB" (/ rss 1024)) "")
                                       (if up (coil--duration (float-time up)) "")
                                       (if (coil--live-p (gethash root coil--sessions)) "yes" ""))))))

(defun coil--duration (seconds)
  (cond ((< seconds 3600) (format "%dm" (/ seconds 60)))
        ((< seconds 86400) (format "%dh" (/ seconds 3600)))
        (t (format "%dd" (/ seconds 86400)))))

(defun coil--sessions-entry ()
  (or (cl-find (tabulated-list-get-id) (coil--known-kernels) :key #'cadr :test #'equal)
      (user-error "No session here")))

(defun coil-attach (root)
  "Attach to ROOT's kernel, starting it if it is not running; return its buffer."
  (let* ((state (coil--state-dir root))
         (session (gethash root coil--sessions)))
    (unless (coil--live-p session)
      (let* ((file (expand-file-name "bridge.eld" state))
             (saved (and (file-readable-p file)
                         (with-temp-buffer (insert-file-contents file)
                                           (ignore-errors (read (current-buffer))))))
             (backend (or (cl-find (plist-get saved :backend) (mapcar #'cdr coil-backends)
                                   :key (lambda (b) (plist-get b :name)) :test #'equal)
                          (user-error "Not known how %s was started: open one of its files"
                                      (abbreviate-file-name root))))
             (interpreter (plist-get saved :interpreter))
             (default-directory root))
        (setq session (coil--start root (append (list :interpreter (lambda () interpreter))
                                                backend)
                                   session))))
    (coil--buffer session)))

(defun coil-sessions-attach ()
  "Attach to the kernel at point, starting it if it is not running, and show it."
  (interactive)
  (pop-to-buffer (coil-attach (car (coil--sessions-entry)))))

(defun coil-sessions-detach ()
  "Detach from the kernel at point; it runs on."
  (interactive)
  (let ((session (gethash (car (coil--sessions-entry)) coil--sessions)))
    (unless (coil--live-p session) (user-error "Not attached"))
    (with-current-buffer (coil--buffer session) (coil-detach))
    (revert-buffer)))

(defun coil-kill (root)
  "Kill ROOT's kernel, if it runs: its state is lost; the log is kept."
  (pcase-let ((`(,_ ,state ,pid) (or (assoc root (coil--known-kernels))
                                     (user-error "No kernel for %s" root))))
    (when (and pid (coil--pid-alive-p pid))
      (when-let* ((session (gethash root coil--sessions))
                  ((coil--live-p session)))
        (setf (coil-session-status session) "shut down")
        (delete-process (coil-session-process session)))
      (signal-process pid 'term)
      (dolist (name (directory-files state t "\\`\\(kernel\\.json\\|kernel\\.pid\\|k-[0-9]+\\)\\'"))
        (delete-file name)))))

(defun coil-kernels ()
  "The kernels running, as plists: :root :pid :memory (bytes) :up (seconds)
:attached (whether this Emacs is)."
  (cl-loop for (root _state pid) in (coil--known-kernels)
           for attributes = (and pid (coil--pid-alive-p pid) (process-attributes pid))
           when attributes
           collect (list :root root :pid pid
                         :memory (* 1024 (or (alist-get 'rss attributes) 0))
                         :up (float-time (or (alist-get 'etime attributes) 0))
                         :attached (coil--live-p (gethash root coil--sessions)))))

(defun coil-sessions-kill ()
  "Kill the kernel at point."
  (interactive)
  (pcase-let ((`(,root ,_ ,pid) (coil--sessions-entry)))
    (when (and pid (coil--pid-alive-p pid)
               (y-or-n-p (format "Kill the kernel of %s? " (abbreviate-file-name root))))
      (coil-kill root)
      (revert-buffer))))

(define-key coil-sessions-mode-map "k" #'coil-sessions-kill)
(define-key coil-sessions-mode-map (kbd "RET") #'coil-sessions-attach)
(define-key coil-sessions-mode-map "d" #'coil-sessions-detach)


;;; The mode line

(defun coil--mode-line-process ()
  (when coil--session
    (let ((status (coil-session-status coil--session)))
      (concat " " (propertize (or status "") 'face (if (equal status "busy") 'warning 'shadow))))))

(defun coil--refresh-mode-line (session)
  (when (buffer-live-p (coil-session-buffer session))
    (with-current-buffer (coil-session-buffer session)
      (force-mode-line-update))))

(provide 'coil)
;;; coil.el ends here

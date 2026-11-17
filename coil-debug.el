;;; coil-debug.el --- Python's debugger in coil: stop, step, look -*- lexical-binding: t; -*-

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

;; The debugger is IPython's (pdb), in the session's own kernel: what it has
;; defined, its data, all there to look at.  coil follows it in the source:
;;
;; - where it stopped is marked in the file, with an arrow in the fringe, and
;;   that buffer takes single keys, as edebug's does: n next, s step in,
;;   c continue, r return, u and d up and down the stack, e the value at point,
;;   RET on to this line, b a breakpoint, q quit, ? the keys;
;; - its prompt is the session's, for anything else pdb takes (`p df.shape',
;;   `pp vars()', `!x = 3');
;; - breakpoints are marks in the fringe, not code: a run that meets one stops
;;   there, whether in the cell sent, in a function sent before, or in a file
;;   of the project;
;; - after an error, `coil-debug-post-mortem' (d on the cell) opens the
;;   debugger where it was raised.
;;
;; pdb names a cell's code by the file ipykernel ran it as; coil knows which
;; lines of which buffer that was (`coil-cell-codefile').

;;; Code:

(require 'coil)

(declare-function python-info-current-symbol "python" (&optional replace-self))

(defgroup coil-debug nil
  "Python's debugger, in coil."
  :group 'coil
  :prefix "coil-debug-")

(defface coil-debug-line '((t :inherit highlight :extend t))
  "The line the debugger is stopped at.")

(defface coil-debug-breakpoint '((t :inherit error))
  "The mark of a breakpoint.")

(defconst coil-debug--prompt-regexp "\\`\\(?:ipdb>\\|(Pdb)\\|(ipdb)\\)\\s-*\\'"
  "The debugger's prompt, IPython's or pdb's.")

(defconst coil-debug--where-regexp "^> \\(.+?\\)(\\([0-9]+\\))"
  "The line pdb prints where it stops: > FILE(LINE)function().")


;;; State

(cl-defstruct (coil-debug--state (:constructor coil-debug--state-create) (:copier nil))
  cell                                  ; the cell the debugger runs in
  buffer                                ; the buffer stopped in, with the keys
  queue                                 ; answers to the next prompts
  echo                                  ; where to show the next answer's output from
  cells-dir)                            ; the kernel's directory of cells

(defvar coil-debug--states (make-hash-table :test #'eq :weakness 'key)
  "The debugging, by session.")

(defvar coil-debug--last-errors (make-hash-table :test #'eq :weakness 'key)
  "The last cell that failed, by session: the error `%debug' opens.")

(defvar-local coil-debug--session nil
  "The session this buffer is stopped in.")

(defun coil-debug--state (session)
  (or (gethash session coil-debug--states)
      (puthash session (coil-debug--state-create) coil-debug--states)))

(defvar coil-debug--arrow nil
  "Where the debugger is stopped: a marker, for the fringe's arrow.")
(put 'coil-debug--arrow 'overlay-arrow-string "=>")
(put 'coil-debug--arrow 'overlay-arrow-bitmap 'right-triangle)
(add-to-list 'overlay-arrow-variable-list 'coil-debug--arrow)

(defvar coil-debug--line nil "The overlay on the line stopped at.")


;;; Where it stopped

(defun coil-debug--location (cell)
  "Where the debugger last said it is, in CELL's output: (PATH . LINE)."
  (when-let* ((out (coil-cell-out cell))
              (buffer (marker-buffer out)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char out)
        (when (re-search-backward coil-debug--where-regexp (coil-cell-ostart cell) t)
          (cons (match-string-no-properties 1)
                (string-to-number (match-string-no-properties 2))))))))

(defun coil-debug--cell-path-p (path)
  (string-match-p "/ipykernel_[0-9]+/[0-9]+\\.py\\'" path))

(defun coil-debug--source (session state path line)
  "The buffer's place of PATH's LINE: (FILE-OR-BUFFER . LINE), or nil.
A cell sent from a file is that file's lines; one typed in the session is
its own lines there; a real file is itself."
  (let ((cell (and (coil-debug--cell-path-p path)
                   (gethash (file-name-nondirectory path) (coil-session-codefiles session)))))
    (cond
     (cell
      (setf (coil-debug--state-cells-dir state) (file-name-directory path))
      (let ((n (1- line)))
        (cond ((and (coil-cell-file cell) (coil-cell-origin cell))
               (cons (coil-cell-file cell) (+ (coil-cell-origin cell) n)))
              ((and (coil-cell-beg cell) (marker-buffer (coil-cell-beg cell)))
               (with-current-buffer (marker-buffer (coil-cell-beg cell))
                 ;; Under the cell's header line.
                 (cons (current-buffer)
                       (+ (line-number-at-pos (coil-cell-beg cell)) 1 n)))))))
     ((and (file-name-absolute-p path) (file-exists-p path))
      (cons path line)))))

(defun coil-debug--leave-buffer (state)
  (let ((old (coil-debug--state-buffer state)))
    (when (buffer-live-p old)
      (with-current-buffer old
        (coil-debug-mode -1)))
    (setf (coil-debug--state-buffer state) nil)))

(defun coil-debug--show (session state place)
  "Mark PLACE, (FILE-OR-BUFFER . LINE), as where SESSION is stopped."
  (let* ((buffer (if (bufferp (car place)) (car place) (find-file-noselect (car place))))
         (session-buffer (coil-session-buffer session))
         (pos (with-current-buffer buffer
                (save-restriction
                  (widen)
                  (goto-char (point-min))
                  (forward-line (1- (cdr place)))
                  (point)))))
    ;; Stopped in folded code: unfold it.
    (with-current-buffer buffer
      (dolist (overlay (overlays-at pos))
        (when (overlay-get overlay 'coil-fold)
          (overlay-put overlay 'invisible nil)
          (overlay-put overlay 'before-string nil))))
    (setq coil-debug--arrow (with-current-buffer buffer (copy-marker pos)))
    (unless (overlayp coil-debug--line)
      (setq coil-debug--line (make-overlay 1 1))
      (overlay-put coil-debug--line 'face 'coil-debug-line)
      (overlay-put coil-debug--line 'priority 10))
    (move-overlay coil-debug--line pos
                  (with-current-buffer buffer
                    (save-excursion (goto-char pos) (line-beginning-position 2)))
                  buffer)
    ;; The keys go with the arrow -- but not into the session, where one types.
    (unless (eq buffer (coil-debug--state-buffer state))
      (coil-debug--leave-buffer state))
    (unless (eq buffer session-buffer)
      (with-current-buffer buffer
        (setq coil-debug--session session)
        (coil-debug-mode 1))
      (setf (coil-debug--state-buffer state) buffer))
    ;; From the session's prompt, the source is shown beside it; from the
    ;; source, it is gone to.
    (let ((window (if (eq (window-buffer) session-buffer)
                      (display-buffer buffer '((display-buffer-reuse-window
                                                display-buffer-use-some-window)
                                               (inhibit-same-window . t)))
                    (pop-to-buffer buffer '((display-buffer-reuse-window
                                             display-buffer-same-window)))
                    (selected-window))))
      (when (window-live-p window)
        (set-window-point window pos)
        (when (eq window (selected-window))
          (goto-char pos))))))

(defun coil-debug--unshow ()
  (setq coil-debug--arrow nil)
  (when (overlayp coil-debug--line)
    (delete-overlay coil-debug--line)))

(defun coil-debug--echo-output (cell from)
  "What CELL printed since FROM, in the echo area."
  (when-let* ((out (coil-cell-out cell))
              (buffer (marker-buffer out)))
    (let ((text (string-trim (with-current-buffer buffer
                               (buffer-substring (min from out) out)))))
      (unless (string-empty-p text)
        (message "%s" text)
        t))))

(defun coil-debug--input-request (session cell event)
  "Take the debugger's prompt: mark where it stopped, and wait for a key."
  (let ((prompt (ansi-color-filter-apply (or (alist-get 'prompt event) ""))))
    (when (and (coil-cell-p cell)
               (string-match-p coil-debug--prompt-regexp prompt))
      (let ((state (coil-debug--state session)))
        (setf (coil-debug--state-cell state) cell)
        (coil-ask session cell prompt)
        (if-let* ((next (pop (coil-debug--state-queue state))))
            (coil-debug--answer session state next)
          (let* ((where (coil-debug--location cell))
                 (place (and where (coil-debug--source session state (car where) (cdr where))))
                 (echo (coil-debug--state-echo state)))
            (setf (coil-debug--state-echo state) nil)
            (if place
                (coil-debug--show session state place)
              (coil-debug--leave-buffer state)
              (coil-debug--unshow))
            (unless (and echo (coil-debug--echo-output cell echo))
              (message "%s"
                       (if place
                           (substitute-command-keys
                            "Debugging: \\<coil-debug-mode-map>\\[coil-debug-next] next  \\[coil-debug-step] step  \\[coil-debug-continue] continue  \\[coil-debug-return] return  \\[coil-debug-eval] value  \\[coil-debug-run-to-here] to here  \\[coil-debug-quit] quit  \\[coil-debug-help] more")
                         "Debugging, where there is no source: at the session's prompt"))))))
      t)))

(defun coil-debug--done (session cell)
  "When the cell the debugger ran in is done, so is the debugging."
  (when (equal (coil-cell-status cell) "error")
    (puthash session cell coil-debug--last-errors))
  (when-let* ((state (gethash session coil-debug--states))
              ((eq (coil-debug--state-cell state) cell)))
    (coil-debug--leave-buffer state)
    (coil-debug--unshow)
    (remhash session coil-debug--states)))

(add-hook 'coil-input-request-functions #'coil-debug--input-request)
(add-hook 'coil-cell-done-functions #'coil-debug--done)


;;; Commands, while stopped

(defun coil-debug--answer (session state command &optional echo)
  "Answer the prompt with COMMAND; with ECHO, show what it prints."
  (coil-answer session command)
  (when echo
    (setf (coil-debug--state-echo state)
          (marker-position (coil-cell-out (coil-debug--state-cell state))))))

(defun coil-debug--stopped ()
  "The session stopped here, and its state; or an error saying why not."
  (let* ((session (or coil-debug--session
                      (coil-current-session)
                      (user-error "No session")))
         (state (gethash session coil-debug--states)))
    (unless (and state (coil-session-asking session))
      (user-error (if state "Running: wait for it to stop" "Not debugging")))
    (cons session state)))

(defun coil-debug-send (&rest commands)
  "Send pdb COMMANDS, one to each prompt, the first now."
  (pcase-let ((`(,session . ,state) (coil-debug--stopped)))
    (setf (coil-debug--state-queue state) (cdr commands))
    (coil-debug--answer session state (car commands))))

(defun coil-debug-next ()
  "Run the line, stepping over calls."
  (interactive)
  (coil-debug-send "next"))

(defun coil-debug-step ()
  "Run the line, stepping into the first call."
  (interactive)
  (coil-debug-send "step"))

(defun coil-debug-continue ()
  "Run on, to the next breakpoint or the end."
  (interactive)
  (coil-debug-send "continue"))

(defun coil-debug-return ()
  "Run on to the end of this function."
  (interactive)
  (coil-debug-send "return"))

(defun coil-debug-up ()
  "To the frame that called this one."
  (interactive)
  (coil-debug-send "up"))

(defun coil-debug-down ()
  "To the frame this one called."
  (interactive)
  (coil-debug-send "down"))

(defun coil-debug-where ()
  "Show the stack, in the session."
  (interactive)
  (coil-debug-send "where"))

(defun coil-debug-quit ()
  "Stop debugging: what was running stops too."
  (interactive)
  (coil-debug-send "quit"))

(defun coil-debug--expression (&optional ask)
  (cond (ask (read-string "Value of: "))
        ((use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)))
        ((and (derived-mode-p 'python-base-mode) (python-info-current-symbol)))
        ((thing-at-point 'symbol t))
        (t (read-string "Value of: "))))

(defun coil-debug-eval (&optional ask)
  "Show the value of what is at point (the region, the name), in this frame.
With ASK (\\[universal-argument]), of an expression read."
  (interactive "P")
  (pcase-let ((`(,session . ,state) (coil-debug--stopped))
              (expression (coil-debug--expression ask)))
    (coil-debug--answer session state (concat "p " expression) t)))

(defun coil-debug-help ()
  "The debugger's keys."
  (interactive)
  (describe-keymap 'coil-debug-mode-map))


;;; Breakpoints

(define-fringe-bitmap 'coil-debug-breakpoint
  [#b00111100 #b01111110 #b11111111 #b11111111 #b11111111 #b11111111 #b01111110 #b00111100])

(defun coil-debug--breakpoint-overlays (&optional buffer beg end)
  (with-current-buffer (or buffer (current-buffer))
    (cl-remove-if-not (lambda (overlay) (overlay-get overlay 'coil-debug-breakpoint))
                      (overlays-in (or beg (point-min)) (or end (point-max))))))

(defun coil-debug--breakpoint-lines (buffer)
  "The lines of BUFFER's breakpoints."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (delete-dups
       (cl-loop for overlay in (coil-debug--breakpoint-overlays)
                if (= (overlay-start overlay) (overlay-end overlay))
                do (delete-overlay overlay) ; its line was deleted
                else collect (line-number-at-pos (overlay-start overlay)))))))

(defun coil-debug--code-line ()
  "The line at point, or the first line of code after it."
  (save-excursion
    (beginning-of-line)
    (while (and (looking-at-p "[ \t]*\\(?:#.*\\)?$") (zerop (forward-line 1)) (not (eobp))))
    (line-number-at-pos)))

(defun coil-debug--covers-p (cell file line)
  (and (equal (coil-cell-file cell) file)
       (coil-cell-origin cell)
       (<= (coil-cell-origin cell) line
           (+ (coil-cell-origin cell) (cl-count ?\n (coil-cell-code cell))))))

(defun coil-debug--kernel-places (session file line &optional latest)
  "Where FILE's LINE is, to the kernel: a list of (NAME . LINE).
NAME is a cell's file (sent from FILE) or FILE itself.  With LATEST, only
the place most recently sent, or else FILE."
  (let (cells)
    (maphash (lambda (name cell)
               (when (coil-debug--covers-p cell file line)
                 (push (cons name cell) cells)))
             (coil-session-codefiles session))
    (setq cells (sort cells (lambda (a b) (> (coil-cell-start (cdr a)) (coil-cell-start (cdr b))))))
    (let ((places (cl-loop for (name . cell) in (seq-take cells (if latest 1 20))
                           collect (cons name (1+ (- line (coil-cell-origin cell)))))))
      (if (and latest places)
          places
        (append places
                (and (file-exists-p file)
                     (delete-dups (list (cons file line) (cons (file-truename file) line)))))))))

(defun coil-debug--breakpoints (session cell)
  "Where CELL is to stop: every breakpoint, in it and in what it may call.
For `coil-breakpoints-function'."
  (let (breaks)
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer))
                  (lines (and (coil-debug--breakpoint-overlays buffer)
                              (coil-debug--breakpoint-lines buffer))))
        (dolist (line lines)
          (when (coil-debug--covers-p cell file line)
            (push (vector :null (1+ (- line (coil-cell-origin cell))) :false) breaks))
          (dolist (place (coil-debug--kernel-places session file line))
            (push (vector (car place) (cdr place) :false) breaks)))))
    (nreverse breaks)))

(setq coil-breakpoints-function #'coil-debug--breakpoints)

(defun coil-debug--kernel-path (_session state name)
  "NAME, a cell's file or a path, as the kernel knows it."
  (if (file-name-absolute-p name)
      name
    (concat (or (coil-debug--state-cells-dir state)
                (user-error "Not known yet where the kernel keeps its cells"))
            name)))

(defun coil-debug-toggle-breakpoint ()
  "Set a breakpoint on this line, or take it away.
It is a mark, not code: every run from then stops there.  While debugging,
the debugger is told at once."
  (interactive)
  (unless (buffer-file-name) (user-error "Breakpoints are set in a file"))
  (let* ((line (coil-debug--code-line))
         (beg (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))
         (existing (coil-debug--breakpoint-overlays nil beg (save-excursion (goto-char beg) (line-end-position))))
         (session (or coil-debug--session (coil-current-session)))
         (state (and session (gethash session coil-debug--states))))
    (if existing
        (mapc #'delete-overlay existing)
      (let ((overlay (make-overlay beg (save-excursion (goto-char beg) (line-end-position)))))
        (overlay-put overlay 'coil-debug-breakpoint t)
        (overlay-put overlay 'before-string
                     (propertize "●" 'display '(left-fringe coil-debug-breakpoint coil-debug-breakpoint)))))
    (when (and state (coil-session-asking session))
      (pcase-let ((`(,name . ,kline) (car (coil-debug--kernel-places session (buffer-file-name) line t))))
        (when name
          (coil-debug-send (format "%s %s:%d" (if existing "clear" "break")
                                   (coil-debug--kernel-path session state name) kline)))))
    (message (if existing "Breakpoint taken away" "Breakpoint on line %d") line)))

(defun coil-debug-clear-breakpoints ()
  "Take away every breakpoint of this buffer."
  (interactive)
  (mapc #'delete-overlay (coil-debug--breakpoint-overlays))
  (message "No breakpoints in %s" (buffer-name)))

(defun coil-debug-run-to-here ()
  "Run on to this line."
  (interactive)
  (pcase-let* ((`(,session . ,state) (coil-debug--stopped))
               (line (coil-debug--code-line))
               (`(,name . ,kline) (car (coil-debug--kernel-places session (buffer-file-name) line t))))
    (unless name (user-error "The kernel has not run this line"))
    (coil-debug-send (format "tbreak %s:%d" (coil-debug--kernel-path session state name) kline)
                     "continue")))


;;; Starting

(defun coil-debug-post-mortem ()
  "Open the debugger where the last error was raised."
  (interactive)
  (let* ((session (or (coil-current-session) (user-error "No session")))
         (here (and coil--session (get-text-property (point) 'coil-cell)))
         (last (gethash session coil-debug--last-errors)))
    (when (and here (not (eq here last)))
      (user-error (if last
                      (format "Only the last error can be debugged: In [%s]" (coil-cell-count last))
                    "This cell's error is not the last")))
    (coil-execute "%debug" :session session)))

(defun coil-debug-toggle-on-error ()
  "Have every error open the debugger, or no longer (IPython's %pdb)."
  (interactive)
  (coil-execute "%pdb" :session (coil-current-session t)))

(defvar-keymap coil-debug-mode-map
  :doc "The keys of a buffer the debugger is stopped in."
  "n"   #'coil-debug-next
  "SPC" #'coil-debug-next
  "s"   #'coil-debug-step
  "c"   #'coil-debug-continue
  "r"   #'coil-debug-return
  "u"   #'coil-debug-up
  "d"   #'coil-debug-down
  "w"   #'coil-debug-where
  "e"   #'coil-debug-eval
  "b"   #'coil-debug-toggle-breakpoint
  "RET" #'coil-debug-run-to-here
  "q"   #'coil-debug-quit
  "?"   #'coil-debug-help)

(define-minor-mode coil-debug-mode
  "Keys to step the debugger stopped in this buffer.
On while it is stopped here; the arrow in the fringe is where.
\\{coil-debug-mode-map}"
  :lighter " Debug"
  :keymap coil-debug-mode-map
  (unless coil-debug-mode
    (kill-local-variable 'coil-debug--session)))

;; On a failed cell in the session: d opens the debugger there.
(keymap-set coil-cell-map "d" #'coil-debug-post-mortem)

(provide 'coil-debug)
;;; coil-debug.el ends here

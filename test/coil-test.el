;;; coil-test.el --- Tests of coil that need no kernel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Gomez
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run with `make test-elisp'.  The kernel is stubbed: its replies are
;; given, as the bridge would pass them on.  The bridge, with a real
;; kernel, is tested by test_bridge.py.

;;; Code:

(require 'ert)
(require 'coil)
(require 'coil-python)
(require 'flymake)

;;;; Completion in source buffers, merged with another's

(defvar coil-test--reply nil "The kernel's reply to the next completion.")
(defvar coil-test--cell nil "The cell of the last completion asked.")
(defvar coil-test--exited nil "The candidate the other's exit function saw.")

(defun coil-test--other-capf ()
  "A completion function like eglot's: a function table, metadata, properties."
  (let ((bounds (or (bounds-of-thing-at-point 'symbol) (cons (point) (point)))))
    (list (car bounds) (cdr bounds)
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata (category . coil-test)
                           (display-sort-function . (lambda (cs) (sort cs #'string>))))
              (complete-with-action action (list (propertize "copy" 'theirs t)
                                                 (propertize "corr" 'theirs t))
                                    string pred)))
          :annotation-function (lambda (c) (and (get-text-property 0 'theirs c) " theirs"))
          :exit-function (lambda (c _status) (setq coil-test--exited c)))))

(defmacro coil-test--with-kernel (text reply &rest body)
  "Run BODY in a buffer of TEXT, point at its end, the kernel answering REPLY."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (setq coil-test--reply ,reply coil-test--exited nil)
     (setq-local coil-completion-merge-with '(coil-test--other-capf))
     (setq-local completion-at-point-functions
                 (list #'coil-source-completion-at-point #'coil-test--other-capf))
     (cl-letf (((symbol-function 'coil-current-session)
                (lambda (&rest _) (coil--session-create :ready t)))
               ((symbol-function 'process-live-p) (lambda (_) t))
               ((symbol-function 'coil--complete-send)
                (lambda (&rest _) (setq coil-test--cell (list coil-test--reply))))
               ((symbol-function 'coil--complete-wait)
                (lambda (_session cell _until)
                  (let ((reply (car cell))) (and (listp reply) reply))))
               ((symbol-function 'coil--complete-at) (lambda (&rest _) coil-test--reply)))
       ,@body)))

(defconst coil-test--df-reply
  '((status . "ok") (cursor_start . 3) (cursor_end . 5)
    (matches "columns" "copy")
    (metadata (_jupyter_types_experimental
               ((text . "columns") (type . "instance"))
               ((text . "copy") (type . "function"))))))

(ert-deftest coil-merged-adds-the-session-candidates ()
  (coil-test--with-kernel "df.co" coil-test--df-reply
    (pcase-let* ((`(,beg ,end ,table . ,props) (coil-source-completion-at-point))
                 (all (all-completions "co" table)))
      (should (equal (list beg end) '(4 6)))
      ;; The other's first, the session's after, without the one both have.
      (should (equal all '("copy" "corr" "columns")))
      (should (equal (mapcar (plist-get props :annotation-function) all)
                     '(" theirs" " theirs" " instance")))
      (should (eq (funcall (plist-get props :company-kind) (nth 2 all)) 'variable)))))

(ert-deftest coil-merged-keeps-the-other-metadata-and-order ()
  (coil-test--with-kernel "df.co" coil-test--df-reply
    (pcase-let* ((`(,_ ,_ ,table . ,_) (coil-source-completion-at-point))
                 (all (all-completions "co" table))
                 (meta (completion-metadata "co" table nil)))
      (should (eq (completion-metadata-get meta 'category) 'coil-test))
      ;; The other's sort applies to its own; the session's stay last.
      (should (equal (funcall (completion-metadata-get meta 'display-sort-function)
                              (copy-sequence all))
                     '("corr" "copy" "columns"))))))

(ert-deftest coil-merged-exit-function-only-for-the-other ()
  (coil-test--with-kernel "df.co" coil-test--df-reply
    (pcase-let* ((`(,_ ,_ ,table . ,props) (coil-source-completion-at-point))
                 (all (all-completions "co" table))
                 (exit (plist-get props :exit-function)))
      (funcall exit (nth 2 all) 'finished)
      (should-not coil-test--exited)
      (funcall exit (car all) 'finished)
      (should (equal coil-test--exited "copy")))))

(ert-deftest coil-merged-rebases-a-dictionary-key ()
  ;; d["a| : the kernel replaces from the quote, the other from the symbol.
  (coil-test--with-kernel "d[\"a"
      '((status . "ok") (cursor_start . 2) (cursor_end . 4)
        (matches "\"alpha\"" "\"also\""))
    (pcase-let ((`(,beg ,_ ,table . ,_) (coil-source-completion-at-point)))
      (should (= beg 4))
      (should (equal (all-completions "a" table) '("alpha\"" "also\""))))))

(ert-deftest coil-merged-inserts ()
  (coil-test--with-kernel "df.colu"
      '((status . "ok") (cursor_start . 3) (cursor_end . 7) (matches "columns"))
    (completion-at-point)
    (should (equal (buffer-string) "df.columns"))))

(ert-deftest coil-merged-late-answer-joins-at-the-next-key ()
  (coil-test--with-kernel "df.co" 'waiting
    (pcase-let ((`(,_ ,_ ,table . ,_) (coil-source-completion-at-point)))
      (should (equal (all-completions "co" table) '("copy" "corr")))
      (setcar coil-test--cell '((status . "ok") (cursor_start . 3) (cursor_end . 5)
                                (matches "columns")))
      (should (equal (all-completions "co" table) '("copy" "corr" "columns"))))))

(ert-deftest coil-merged-alone-without-another ()
  (coil-test--with-kernel "x = foo.ba"
      '((status . "ok") (cursor_start . 8) (cursor_end . 10) (matches "bar"))
    (setq-local completion-at-point-functions (list #'coil-source-completion-at-point))
    (pcase-let ((`(,beg ,end ,table . ,_) (coil-source-completion-at-point)))
      (should (equal (list beg end table) '(9 11 ("bar")))))))

(ert-deftest coil-merged-nothing-without-a-session ()
  (with-temp-buffer
    (insert "foo")
    (cl-letf (((symbol-function 'coil-current-session) #'ignore))
      (should-not (coil-source-completion-at-point)))))

(ert-deftest coil-merged-steps-aside-for-others ()
  ;; A source not in `coil-completion-merge-with' (lsp-mode's, say) is
  ;; left alone: coil answers nothing, and it answers as it would.
  (coil-test--with-kernel "df.co" coil-test--df-reply
    (setq-local coil-completion-merge-with '(eglot-completion-at-point))
    (should-not (coil-source-completion-at-point))
    (completion-at-point)
    (should (member (buffer-string) '("df.copy" "df.corr" "df.co")))))

(ert-deftest coil-merged-off ()
  (coil-test--with-kernel "df.co" coil-test--df-reply
    (let ((coil-completion-in-source nil))
      (should-not (coil-source-completion-at-point)))))

(ert-deftest coil-rebase ()
  (with-temp-buffer
    (insert "abcdef")
    ;; Same span: unchanged.
    (should (equal (coil--rebase "bcx" 2 4 2 4) "bcx"))
    ;; Kernel's starts earlier: the text before the other's start must be kept.
    (should (equal (coil--rebase "abx" 1 3 2 3) "bx"))
    (should-not (coil--rebase "zzx" 1 3 2 3))
    ;; Kernel's starts later: the text between is put before it.
    (should (equal (coil--rebase "cx" 3 4 1 4) "abcx"))
    ;; The other's ends later: the rest is kept after it.
    (should (equal (coil--rebase "bx" 2 3 2 5) "bxcd"))))

;;;; The idle watch's note

(ert-deftest coil-ended-text ()
  (let ((at (encode-time '(0 20 12 17 11 2026 nil nil t))))
    (should (string-match-p
             "\\`The kernel ran nothing for 48 h, and was shut down .*coil-kernel-idle-hours"
             (coil--ended-text "The kernel" `((idle . 172800) (at . ,(float-time at))))))
    (should (string-match-p "for 1.5 h"
                            (coil--ended-text "The kernel" '((idle . 5400) (at . 0)))))))

;;;; Unresolved imports, and eglot's code actions

(ert-deftest coil-python-unresolved-module ()
  (should (equal (coil-python--unresolved-module
                  "Cannot resolve imported module `sklearn`\ninfo: ...") "sklearn"))
  (should (equal (coil-python--unresolved-module
                  "Import \"yaml\" could not be resolved from source") "yaml"))
  (should (equal (coil-python--unresolved-module "No module named 'cv2.aruco'") "cv2.aruco"))
  ;; Not a missing package: a missing member, and a case that is not ty's.
  (should-not (coil-python--unresolved-module "Module `pandas` has no member `nope`"))
  (should-not (coil-python--unresolved-module "cannot resolve imported module `x`"))
  (should-not (coil-python--unresolved-module nil)))

(defconst coil-test--action-params
  '(:context (:diagnostics
              [(:code "import-not-found" :message "Cannot resolve imported module `sklearn`")
               (:code "import-not-found" :message "Cannot resolve imported module `sklearn`")
               (:code "missing-attribute" :message "Module `os.path` has no member `nope`")])))

(defmacro coil-test--in-pixi-project (&rest body)
  `(with-temp-buffer
     (setq-local coil-python-mode t)
     (cl-letf (((symbol-function 'coil-python--pixi-root) (lambda (_) "/project/")))
       ,@body)))

(ert-deftest coil-python-code-actions ()
  (coil-test--in-pixi-project
   (let ((actions (coil-python--code-actions coil-test--action-params)))
     (should (= (length actions) 1))     ; once per module
     (should (equal (coil-python--code-action-module (car actions)) "sklearn"))
     ;; As a Command too, as some clients pass it on.
     (should (equal (coil-python--code-action-module (plist-get (car actions) :command))
                    "sklearn"))
     (should-not (coil-python--code-action-module '(:title "x" :command "other"))))
   (let ((coil-python-code-actions nil))
     (should-not (coil-python--code-actions coil-test--action-params))))
  ;; Not in a pixi project, or the mode off: none.
  (with-temp-buffer
    (setq-local coil-python-mode t)
    (cl-letf (((symbol-function 'coil-python--pixi-root) #'ignore))
      (should-not (coil-python--code-actions coil-test--action-params)))))

(ert-deftest coil-python-code-actions-only-for-eglot ()
  (coil-test--in-pixi-project
   (let ((request (lambda (&rest _) [(:title "theirs")])))
     ;; Another jsonrpc client (dape, say): its answer is untouched.
     (cl-letf (((symbol-function 'object-of-class-p) #'ignore))
       (should (equal (coil-python--around-request
                       request 'conn :textDocument/codeAction coil-test--action-params)
                      [(:title "theirs")])))
     (cl-letf (((symbol-function 'object-of-class-p) (lambda (&rest _) t)))
       ;; Eglot's: coil's action after the server's.
       (let ((actions (coil-python--around-request
                       request 'conn :textDocument/codeAction coil-test--action-params)))
         (should (= (length actions) 2))
         (should (equal (plist-get (aref actions 0) :title) "theirs")))
       ;; Any other request: untouched.
       (should (equal (coil-python--around-request request 'conn :textDocument/hover nil)
                      [(:title "theirs")]))
       ;; Asynchronous, as eglot's suggestions are asked.
       (let (got)
         (coil-python--around-async-request
          (lambda (_c _m _p &rest args) (funcall (plist-get args :success-fn) []))
          'conn :textDocument/codeAction coil-test--action-params
          :success-fn (lambda (r) (setq got r)))
         (should (= (length got) 1)))))))

(ert-deftest coil-python-missing-import-at-point ()
  (with-temp-buffer
    (insert "import os\nimport sklearn\n")
    (let ((diagnostic (flymake-make-diagnostic
                       (current-buffer) 18 25 :error
                       "ty [import-not-found]: Cannot resolve imported module `sklearn`")))
      (setq-local flymake-mode t)
      (cl-letf (((symbol-function 'flymake-diagnostics)
                 (lambda (&optional beg end)
                   (and (<= beg 25) (>= (or end beg) 18) (list diagnostic)))))
        (goto-char 12)                  ; on the line, not on the name
        (should (equal (coil-python-missing-import-at-point) '("sklearn" 18 . 25)))
        (goto-char 1)
        (should-not (coil-python-missing-import-at-point))))))

;;;; Offers of missing packages

(ert-deftest coil-python-offers-are-asked-one-at-a-time ()
  (let (asked (depth 0) (most 0) (pending 0)
        coil-python--offers coil-python--offering)
    (cl-letf (((symbol-function 'coil-python--conda-forge-lookup)
               ;; Answers come later, as from `pixi search', in any order.
               (lambda (package callback)
                 (cl-incf pending)
                 (run-at-time (if (equal package "numpyy") 0.05 0.1) nil
                              (lambda ()
                                (cl-decf pending)
                                (funcall callback (not (equal package "numpyy")))))))
              ((symbol-function 'read-multiple-choice)
               (lambda (prompt choices &rest _)
                 (cl-incf depth)
                 (setq most (max most depth))
                 (push (cons prompt (mapcar #'car choices)) asked)
                 (accept-process-output nil 0.2) ; the user, reading
                 (cl-decf depth)
                 '(?n "no"))))
      (coil-python-offer-package "sklearn" "/project/")
      (coil-python-offer-package "numpyy" "/project/")
      ;; Nothing is asked before the lookups are done: nothing waited for.
      (should (null asked))
      (let ((until (+ (float-time) 5)))
        (while (and (< (length asked) 2) (< (float-time) until))
          (accept-process-output nil 0.02)))
      (should (= most 1))
      (should (= pending 0))
      (pcase-let ((`((,numpyy . ,numpyy-keys) (,sklearn . ,sklearn-keys)) (reverse asked)))
        ;; Not found: warned of, and not offered from conda-forge.
        (should (string-match-p "numpyy was not found on conda-forge" numpyy))
        (should (equal numpyy-keys '(?p ?n)))
        (should (string-match-p "Add scikit-learn" sklearn))
        (should (equal sklearn-keys '(?c ?p ?n)))))))

(ert-deftest coil-python-lookup-remembers-what-it-found ()
  (let ((coil-python--on-conda-forge (make-hash-table :test #'equal))
        found)
    (puthash "polars" t coil-python--on-conda-forge)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "Looked up again"))))
      (coil-python--conda-forge-lookup "polars" (lambda (f) (setq found f))))
    (should (eq found t))))

(provide 'coil-test)
;;; coil-test.el ends here

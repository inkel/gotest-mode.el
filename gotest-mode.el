;;; gotest-mode.el --- Run Go tests and benchmarks via Transient  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.6.0"))
;; Keywords: go, test, languages, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run Go tests and benchmarks from Emacs using a Transient menu.
;; The main entry point is `gotest-dwim', bound to C-c t by default
;; when `gotest-mode' is active.
;;
;; Usage:
;;   (add-hook 'go-mode-hook #'gotest-mode)
;;
;; Then press C-c t in a Go buffer to open the Transient menu.
;; Press C-u C-c t inside a test or benchmark function to run it directly.
;; Click on any `func TestXXX' or `func BenchmarkXXX' line to run it.

;;; Code:

(require 'transient)
(require 'compile)
(require 'cl-lib)

;;; Customization

(defgroup gotest nil
  "Run Go tests and benchmarks."
  :group 'tools
  :prefix "gotest-")

(defcustom gotest-go-executable "go"
  "Path to the Go executable."
  :type 'string
  :group 'gotest)

(defcustom gotest-default-package "./..."
  "Default package pattern passed to `go test'.
Use \"./...\" to test the entire module, or \".\" for the current package."
  :type 'string
  :group 'gotest)

(defcustom gotest-compilation-buffer-name "*Go Test*"
  "Name of the buffer used for `go test' output."
  :type 'string
  :group 'gotest)

;;; Compilation mode

(defconst gotest--error-regexps
  '(;; Test failure lines: "    foo_test.go:42: some message"
    (gotest-test-failure
     "^[[:space:]]+\\([^[:space:]\n:]+\\.go\\):\\([0-9]+\\):"
     1 2 nil 2)
    ;; Panic stack frames: "\t/path/to/file.go:42 +0x..."
    (gotest-panic
     "^\t\\([^\t\n]+\\.go\\):\\([0-9]+\\)"
     1 2 nil 2))
  "Compilation error regexp entries for `go test' output.")

(defun gotest--find-file (filename)
  "Locate FILENAME by searching recursively under the module root.
Absolute paths are returned as-is.  Relative paths are first tried
directly under `default-directory' (the module root), then located
via a recursive directory search."
  (if (file-name-absolute-p filename)
      filename
    (let ((direct (expand-file-name filename default-directory)))
      (if (file-exists-p direct)
          direct
        (car (directory-files-recursively
              default-directory
              (concat "\\`" (regexp-quote (file-name-nondirectory filename)) "\\'")))))))

(define-compilation-mode gotest-compilation-mode "Go Test"
  "Compilation mode for `go test' output with clickable file links."
  (dolist (entry gotest--error-regexps)
    (add-to-list 'compilation-error-regexp-alist-alist entry))
  (setq-local compilation-error-regexp-alist
              (append (mapcar #'car gotest--error-regexps)
                      compilation-error-regexp-alist))
  (setq-local compilation-parse-errors-filename-function
              #'gotest--find-file))

;;; Helpers

(defun gotest--module-root ()
  "Return the Go module root for the current buffer, or `default-directory'."
  (or (and buffer-file-name
           (locate-dominating-file buffer-file-name "go.mod"))
      default-directory))

(defun gotest--run (args &optional extra-flags)
  "Run `go test' with ARGS from the transient and optional EXTRA-FLAGS.
EXTRA-FLAGS are prepended before ARGS (and before the package pattern).
If ARGS contains a `-package=' entry it is used as the package pattern
instead of `gotest-default-package' and is stripped before invoking go.
The command runs in the module root directory."
  (let* ((root (gotest--module-root))
         (pkg  (or (transient-arg-value "-package=" args) gotest-default-package))
         (args (cl-remove-if (lambda (a) (string-prefix-p "-package=" a)) args))
         (cmd  (mapconcat #'identity
                          (append (list gotest-go-executable "test")
                                  extra-flags
                                  args
                                  (list pkg))
                          " ")))
    (let ((default-directory root))
      (compilation-start cmd #'gotest-compilation-mode (lambda (_) gotest-compilation-buffer-name)))))

(defun gotest--function-at-point ()
  "Return (KIND . NAME) if point is on or inside a test/benchmark function.
KIND is `test' or `benchmark'; NAME is the Go function name string.
Returns nil when the nearest enclosing function is not a test or benchmark."
  (save-excursion
    (beginning-of-line)
    ;; re-search-backward does not match at point, so check current line first.
    (unless (looking-at "^func ")
      (re-search-backward "^func " nil t))
    (let ((line (buffer-substring-no-properties (point) (line-end-position))))
      (cond
       ((string-match "^func \\(Test[[:alnum:]_]+\\)(" line)
        (cons 'test (match-string 1 line)))
       ((string-match "^func \\(Benchmark[[:alnum:]_]+\\)(" line)
        (cons 'benchmark (match-string 1 line)))
       (t nil)))))

(defun gotest--run-function (kind name)
  "Run the single test or benchmark identified by KIND and NAME.
KIND is `test' or `benchmark'; NAME is the Go function name string."
  (let ((pattern (concat "^" (regexp-quote name) "$")))
    (pcase kind
      ('test      (gotest--run nil (list (concat "-run=" pattern))))
      ('benchmark (gotest--run nil (list (concat "-bench=" pattern) "-run=^$"))))))

(defun gotest--current-package ()
  "Return the package set in the active transient invocation, or the default.
Reads directly from `transient--suffixes' (the live infix state) so that
test/benchmark completion lists honour a package already selected by the user."
  (or (and (boundp 'transient--suffixes)
           (cl-some (lambda (obj)
                      (and (slot-exists-p obj 'argument)
                           (equal (oref obj argument) "-package=")
                           (oref obj value)))
                    transient--suffixes))
      gotest-default-package))

(defun gotest--list-packages ()
  "Return Go package import paths in the module via `go list'.
The default package pattern is prepended so it always appears as a choice."
  (let ((default-directory (gotest--module-root)))
    (with-temp-buffer
      (call-process gotest-go-executable nil '(t nil) nil
                    "list" gotest-default-package)
      (cons gotest-default-package
            (split-string (buffer-string) "\n" t)))))

(defun gotest--read-package (prompt initial-input history)
  "Read a Go package path with completion from `go list'."
  (completing-read prompt (gotest--list-packages)
                   nil nil initial-input history))

(defun gotest--list-functions (prefix)
  "Return Go test/benchmark names starting with PREFIX via `go test -list'.
Runs `go test -list=^PREFIX' in the module root and returns only lines
that begin with PREFIX, filtering out summary lines like \"ok\" or \"FAIL\".
Benchmarks require `-bench=.' to appear in the listing, so it is added
automatically when PREFIX is \"Benchmark\".
Uses the package currently selected in the transient (if any) so that
completion reflects the chosen package."
  (let ((default-directory (gotest--module-root))
        (pkg   (gotest--current-package))
        (extra (when (string-prefix-p "Benchmark" prefix) '("-bench=."))))
    (with-temp-buffer
      (apply #'call-process gotest-go-executable nil '(t nil) nil
             "test" (concat "-list=^" prefix)
             (append extra (list pkg)))
      (seq-filter (lambda (s) (string-prefix-p prefix s))
                  (split-string (buffer-string) "\n" t)))))

(defun gotest--read-test-name (prompt initial-input history)
  "Read a test name with completion from `go test -list'."
  (completing-read prompt (gotest--list-functions "Test")
                   nil nil initial-input history))

(defun gotest--read-bench-name (prompt initial-input history)
  "Read a benchmark name with completion from `go test -list'."
  (completing-read prompt (gotest--list-functions "Benchmark")
                   nil nil initial-input history))

;;;###autoload
(defun gotest-run-function-at-point ()
  "Run the test or benchmark function enclosing point.
Signals a user error if point is not inside a test or benchmark."
  (interactive)
  (let ((fn (gotest--function-at-point)))
    (if fn
        (gotest--run-function (car fn) (cdr fn))
      (user-error "Not inside a test or benchmark function"))))

;;; Named infix arguments

(transient-define-argument gotest:--run ()
  "Filter tests by name regexp."
  :description "Test name regexp"
  :class 'transient-option
  :key "-r"
  :argument "-run="
  :prompt "Run tests matching: "
  :reader #'gotest--read-test-name)

(transient-define-argument gotest:--count ()
  "Number of times to run each test."
  :description "Run count"
  :class 'transient-option
  :key "-c"
  :argument "-count="
  :prompt "Count: "
  :init-value (lambda (obj) (oset obj value "1")))

(transient-define-argument gotest:--timeout ()
  "Test timeout duration (e.g. 30s, 5m)."
  :description "Timeout"
  :class 'transient-option
  :key "-d"
  :argument "-timeout="
  :prompt "Timeout (e.g. 30s): ")

(transient-define-argument gotest:--tags ()
  "Build tags to pass to go test."
  :description "Build tags"
  :class 'transient-option
  :key "-T"
  :argument "-tags="
  :prompt "Build tags: ")

(transient-define-argument gotest:--package ()
  "Package pattern to test (overrides `gotest-default-package')."
  :description "Package"
  :class 'transient-option
  :key "-P"
  :argument "-package="
  :prompt "Package: "
  :reader #'gotest--read-package)

(transient-define-argument gotest:--bench ()
  "Benchmark name regexp."
  :description "Benchmark regexp"
  :class 'transient-option
  :key "-B"
  :argument "-bench="
  :prompt "Run benchmarks matching: "
  :init-value (lambda (obj) (oset obj value "."))
  :reader #'gotest--read-bench-name)

(transient-define-argument gotest:--benchtime ()
  "Duration or iteration count per benchmark (e.g. 10s, 100x)."
  :description "Benchmark time"
  :class 'transient-option
  :key "-t"
  :argument "-benchtime="
  :prompt "Benchtime (e.g. 10s, 100x): ")

;;; Suffix commands

;;;###autoload
(transient-define-suffix gotest-test (args)
  "Run `go test' with the current transient arguments."
  :description "Run tests"
  (interactive (list (transient-args 'gotest-dispatch)))
  (gotest--run args))

;;;###autoload
(transient-define-suffix gotest-benchmark (args)
  "Run `go test -bench' with the current benchmark transient arguments."
  :description "Run benchmarks"
  (interactive (list (transient-args 'gotest-benchmark-dispatch)))
  (let ((bench-arg (or (transient-arg-value "-bench=" args) ".")))
    (gotest--run
     (cl-remove-if (lambda (a) (string-prefix-p "-bench=" a)) args)
     ;; -run=^$ suppresses tests so only benchmarks run (standard Go idiom).
     ;; It goes in extra-flags (before args) so any user -run= overrides it.
     (list (concat "-bench=" bench-arg) "-run=^$"))))

;;; Benchmark sub-prefix

;;;###autoload (autoload 'gotest-benchmark-dispatch "gotest-mode" nil t)
(transient-define-prefix gotest-benchmark-dispatch ()
  "Run Go benchmarks."
  ["Benchmark Options"
   (gotest:--bench)
   ("-m" "Memory allocations" "-benchmem")
   (gotest:--benchtime)]
  ["Shared Options"
   ("-v" "Verbose" "-v")
   (gotest:--run)
   (gotest:--tags)
   (gotest:--count)
   (gotest:--timeout)
   (gotest:--package)]
  ["Run"
   ("b" "Run benchmarks" gotest-benchmark)])

;;; Main prefix

;;;###autoload (autoload 'gotest-dispatch "gotest-mode" nil t)
(transient-define-prefix gotest-dispatch ()
  "Run Go tests and benchmarks."
  ["Test Options"
   ("-v" "Verbose" "-v")
   (gotest:--run)
   (gotest:--tags)
   (gotest:--count)
   (gotest:--timeout)
   (gotest:--package)]
  ["Actions"
   ("t" "Run tests"      gotest-test)
   ("b" "Run benchmarks" gotest-benchmark-dispatch)])

;;; Overlays

(defvar-local gotest--overlays nil
  "List of overlays created by `gotest-mode' for clickable test/benchmark lines.")

(defvar-local gotest--refresh-timer nil
  "Idle timer used to debounce overlay refresh after buffer changes.")

(defun gotest--make-overlay (beg end kind name)
  "Create a clickable overlay from BEG to END for function KIND NAME.
KIND is `test' or `benchmark'; NAME is the Go function name string."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'gotest-button t)
    (overlay-put ov 'mouse-face 'highlight)
    (overlay-put ov 'help-echo (format "mouse-1: run %s" name))
    (overlay-put ov 'keymap
                 (let ((km (make-sparse-keymap)))
                   (define-key km [mouse-1]
                     (lambda (_event)
                       (interactive "e")
                       (gotest--run-function kind name)))
                   km))
    ov))

(defun gotest--remove-overlays ()
  "Delete all gotest overlays in the current buffer."
  (mapc #'delete-overlay gotest--overlays)
  (setq gotest--overlays nil))

(defun gotest--refresh-overlays ()
  "Remove and recreate clickable overlays for all test/benchmark declarations."
  (gotest--remove-overlays)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            "^func \\(Test\\|Benchmark\\)\\([[:alnum:]_]+\\)(" nil t)
      (let* ((kind-str  (match-string 1))
             (func-name (concat kind-str (match-string 2)))
             (kind      (if (string= kind-str "Test") 'test 'benchmark))
             (ov        (gotest--make-overlay
                         (line-beginning-position) (line-end-position)
                         kind func-name)))
        (push ov gotest--overlays)))))

(defun gotest--schedule-refresh (&rest _)
  "Schedule an idle-timer refresh of gotest overlays."
  (when gotest--refresh-timer
    (cancel-timer gotest--refresh-timer))
  (setq gotest--refresh-timer
        (run-with-idle-timer
         0.5 nil
         (let ((buf (current-buffer)))
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (gotest--refresh-overlays))))))))

;;; Minor mode

(defun gotest-dwim (arg)
  "Open the gotest dispatch menu, or with prefix ARG run function at point.
With a prefix argument, run the test or benchmark enclosing point directly.
Without a prefix argument, open the Transient menu."
  (interactive "P")
  (if arg
      (gotest-run-function-at-point)
    (gotest-dispatch)))

(defvar gotest-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t") #'gotest-dwim)
    map)
  "Keymap for `gotest-mode'.")

;;;###autoload
(define-minor-mode gotest-mode
  "Minor mode for running Go tests via Transient.
Binds \\[gotest-dwim] to open the test/benchmark menu, or with a prefix
argument run the test/benchmark function at point.  Adds clickable overlays
on test and benchmark function declaration lines."
  :lighter " GoTest"
  :keymap gotest-mode-map
  :group 'gotest
  (if gotest-mode
      (progn
        (gotest--refresh-overlays)
        (add-hook 'after-change-functions #'gotest--schedule-refresh nil t))
    (gotest--remove-overlays)
    (when gotest--refresh-timer
      (cancel-timer gotest--refresh-timer)
      (setq gotest--refresh-timer nil))
    (remove-hook 'after-change-functions #'gotest--schedule-refresh t)))

;;;###autoload
(defun gotest-maybe-enable ()
  "Enable `gotest-mode' if the current buffer visits a Go source file."
  (when (derived-mode-p 'go-mode)
    (gotest-mode 1)))

(provide 'gotest-mode)
;;; gotest-mode.el ends here

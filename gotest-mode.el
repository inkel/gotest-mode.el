;;; gotest-mode.el --- Run Go tests and benchmarks via Transient  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.6.0"))
;; Keywords: go, test, languages, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run Go tests and benchmarks from Emacs using a Transient menu.
;; The main entry point is `gotest-dispatch', bound to C-c t by default
;; when `gotest-mode' is active.
;;
;; Usage:
;;   (add-hook 'go-mode-hook #'gotest-mode)
;;
;; Then press C-c t in a Go buffer to open the menu.

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
The command runs in the module root directory."
  (let* ((root (gotest--module-root))
         (cmd (mapconcat #'identity
                         (append (list gotest-go-executable "test")
                                 extra-flags
                                 args
                                 (list gotest-default-package))
                         " ")))
    (let ((default-directory root))
      (compilation-start cmd #'gotest-compilation-mode (lambda (_) gotest-compilation-buffer-name)))))

;;; Named infix arguments

(transient-define-argument gotest:--run ()
  "Filter tests by name regexp."
  :description "Test name regexp"
  :class 'transient-option
  :key "-r"
  :argument "-run="
  :prompt "Run tests matching: ")

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

(transient-define-argument gotest:--bench ()
  "Benchmark name regexp."
  :description "Benchmark regexp"
  :class 'transient-option
  :key "-B"
  :argument "-bench="
  :prompt "Run benchmarks matching: "
  :init-value (lambda (obj) (oset obj value ".")))

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
   (gotest:--timeout)]
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
   (gotest:--timeout)]
  ["Actions"
   ("t" "Run tests"      gotest-test)
   ("b" "Run benchmarks" gotest-benchmark-dispatch)])

;;; Minor mode

(defvar gotest-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t") #'gotest-dispatch)
    map)
  "Keymap for `gotest-mode'.")

;;;###autoload
(define-minor-mode gotest-mode
  "Minor mode for running Go tests via Transient.
Binds \\[gotest-dispatch] to open the test/benchmark menu."
  :lighter " GoTest"
  :keymap gotest-mode-map
  :group 'gotest)

;;;###autoload
(defun gotest-maybe-enable ()
  "Enable `gotest-mode' if the current buffer visits a Go source file."
  (when (derived-mode-p 'go-mode)
    (gotest-mode 1)))

(provide 'gotest-mode)
;;; gotest-mode.el ends here

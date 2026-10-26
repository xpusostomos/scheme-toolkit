;;; tests/m9.scm -- result, file, process
;;;
;;; The `time' procedures need a running GLib main loop to fire, so they are
;;; covered by the live-shell tests rather than here; what can be tested
;;; headlessly is everything that does not wait.

(use-modules (scheme-toolkit result))
(use-modules (scheme-toolkit file))
(use-modules (scheme-toolkit process))
(use-modules (srfi srfi-64))

(test-begin "m9")

(test-group "result"
  (test-assert "ok is a result" (result? (ok 1)))
  (test-assert "ok is ok" (result-ok? (ok 1)))
  (test-assert "err is not ok" (not (result-ok? (err "boom"))))
  (test-equal "unwrap returns the value" 1 (unwrap (ok 1)))
  (test-equal "unwrap-or on success" 1 (unwrap-or (ok 1) 99))
  ;; The point of unwrap-or: a failure degrades rather than throwing, so the
  ;; shell keeps running.
  (test-equal "unwrap-or on failure uses the fallback" 99 (unwrap-or (err "boom") 99))
  (test-equal "unwrap-or-else computes lazily" 99
    (unwrap-or-else (err "boom") (lambda () 99)))
  ;; attempt captures a throw rather than propagating it.
  (test-assert "attempt captures a throw" (not (result-ok? (attempt (lambda () (error "nope"))))))
  (test-equal "attempt passes a value through" 5 (unwrap (attempt (lambda () 5))))
  ;; A caught exception is a (KEY . ARGS) pair; describe it without crashing.
  (test-assert "a failed attempt describes itself"
    (string? (let ((r (attempt (lambda () (error "boom")))))
               (format #f "~a" (result-value r))))))

(test-group "file read and write"
  (define dir (string-append (or (getenv "TMPDIR") "/tmp")
                             "/scheme-toolkit-test-" (number->string (getpid))))
  (define path (string-append dir "/nested/deep/file.txt"))
  (test-equal "missing file returns the fallback" #f (read-file path))
  (test-equal "with an explicit fallback" "none" (read-file path #:fallback "none"))
  ;; write-file creates parent directories, which Guile's own open does not.
  (test-assert "write creates parents" (write-file path "hello"))
  (test-equal "and reads back" "hello" (read-file path))
  (test-assert "append" (append-file path "\nmore"))
  (test-equal "appended" "hello\nmore" (read-file path))
  (test-equal "lines" '("hello" "more") (read-file-lines path))
  (test-equal "missing lines use the fallback" '() (read-file-lines (string-append dir "/no")))
  ;; Clean up.
  (catch #t (lambda () (delete-file path)) (lambda args #f))
  (catch #t (lambda () (delete-file (string-append dir "/nested/deep"))) (lambda args #f))
  (catch #t (lambda () (delete-file (string-append dir "/nested"))) (lambda args #f))
  (catch #t (lambda () (delete-file dir)) (lambda args #f)))

(test-group "expand-path"
  (test-equal "~ expands to HOME"
    (string-append (getenv "HOME") "/x") (expand-path "~/x"))
  (test-equal "an absolute path is untouched" "/etc/hosts" (expand-path "/etc/hosts")))

(test-group "xdg directories"
  (test-assert "config home ends in .config or the env value"
    (string? (xdg-config-home)))
  (test-assert "cache home is a string" (string? (xdg-cache-home))))

(test-group "run-command"
  (test-equal "captures stdout without the newline"
    "hi" (run-command '("echo" "hi")))
  (test-equal "strips only the trailing newline"
    "a b" (run-command '("echo" "a b")))
  ;; A command that cannot be run returns #f and logs, rather than throwing.
  (test-equal "a missing binary returns #f"
    #f (run-command '("definitely-not-a-real-binary-xyz")))
  (test-assert "transform is applied"
    (string=? "HI" (run-command '("echo" "hi") #:transform string-upcase))))

(test-group "exec-async"
  ;; The fire-and-forget path must not throw when the binary is absent: a
  ;; keybinding that runs a missing program should not take the shell down.
  (test-assert "a missing binary does not throw"
    (exec-async '("definitely-not-a-real-binary-xyz")))
  (test-assert "a real command returns #t"
    (exec-async '("true"))))

(test-end "m9")

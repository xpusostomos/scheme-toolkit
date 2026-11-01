;;; tests/notify.scm -- notification status detection
;;;
;;; The interesting property is not "can we show a notification" but "do we KNOW
;;; whether our view of notifications means anything".  A shell whose daemon has
;;; been outbid by another process sees an EMPTY LIST, which is identical to a
;;; quiet desktop -- so the status must be reported separately or the UI lies.
;;;
;;; These tests therefore assert the DETECTION, not a live notification: they
;;; must pass whether or not anything owns the bus on the machine running them.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit notify))
(use-modules (srfi srfi-64))

(test-begin "notify")

(test-group "the bus question is answerable"
  ;; Whatever the answer, the call must complete and be well-typed: #f or a
  ;; :N.M unique name.  A string of the wrong shape would silently make the
  ;; status check below answer 'owner when it should answer 'elsewhere.
  (let ((owner (bus-name-owner "org.freedesktop.Notifications")))
    (test-assert "returns #f or a unique name"
      (or (not owner)
          (and (string? owner)
               (string-prefix? ":" owner))))
    ;; A name nothing could own: the bus answers an ERROR, which must come back
    ;; as #f rather than as a partial parse.
    (test-assert "a name nobody owns answers #f"
      (not (bus-name-owner "com.example.DefinitelyNotOwned.ByAnyone")))))

(test-group "status is one of four symbols"
  (test-assert "and never anything else"
    (memq (notify-status) '(owner elsewhere absent unknown))))

(test-group "a description always exists"
  ;; This is what a shell logs at startup, so an unhandled status would be a
  ;; crash in the one place a user would look for an explanation.
  (let ((text (describe-notify-status)))
    (test-assert "is a non-empty string"
      (and (string? text) (not (string-null? text))))
    (test-assert "and names the subject" (string-contains text "notifications"))))

(test-group "the status agrees with the bus"
  ;; The two answers must not contradict each other -- that is the actual
  ;; contract: notify-status must be derived from bus-name-owner, not guessed.
  (let* ((owner (bus-name-owner "org.freedesktop.Notifications"))
         (status (notify-status)))
    ;; AN OWNER DOES NOT IMPLY 'elsewhere.  If another process owns the name AND
    ;; this process's own AstalNotifd could not acquire its proxy -- which is
    ;; what happens when a shell or a quickshell got there first -- then 'absent
    ;; is the truthful answer, and it is the answer a fresh process gives on this
    ;; machine.  Asserted as the pair rather than the single value, because what
    ;; the contract actually forbids is answering 'owner when someone else has
    ;; the name.
    (if owner
        (test-assert "an owner elsewhere means the shell does not claim it"
          (memq status '(elsewhere absent)))
        (test-assert "no owner means the shell can own it"
          (memq status '(owner absent))))))

(test-group "history is a list, even when nothing can be read"
  ;; Callers map over this.  A #f here would be a crash in the notification UI
  ;; on exactly the machines where the daemon is elsewhere.
  (test-assert "always a list"
    (list? (notify-history))))

(test-end "notify")

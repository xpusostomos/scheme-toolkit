;;; tests/launcher.scm -- prefix routing, plugin isolation, frecency
;;;
;;; Three behaviours matter and each has a failure that is silent in use:
;;;
;;;   - a prefix must be STRIPPED before the handler sees the query, or every
;;;     web search is a search for "?whatever";
;;;   - a plugin that throws must not empty the launcher, or one broken source
;;;     hides every working one;
;;;   - frecency must mix frequency with recency, or a command run once last
;;;     year outranks a habit.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit launcher))
;; st-peek reads an accessor without recording a dependency; the launcher's
;; results are a computed, so the test needs it.
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit file))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-11))
(use-modules (srfi srfi-64))

(define test-dir (string-append (or (getenv "TMPDIR") "/tmp")
                                "/stk-launcher-" (number->string (getpid))))

(clear-plugins!)

(test-begin "launcher")

(test-group "a result carries what a row needs"
  (let ((r (make-result "Firefox" #:description "Browser"
                        #:icon "firefox" #:id "firefox.desktop")))
    (test-equal "title" "Firefox" (result-title r))
    (test-equal "description" "Browser" (result-description r))
    (test-equal "icon" "firefox" (result-icon r))
    (test-equal "id" "firefox.desktop" (result-id r))
    (test-assert "closes by default" (result-close? r))
    (test-assert "a hint can decline to close"
      (not (result-close? (make-result "type more" #:close? #f))))))

(test-group "routing by prefix"
  (clear-plugins!)
  (register-plugin! (make-plugin "apps"
                                 (lambda (q push)
                                   (push (make-result (string-append "app:" q)
                                                      #:id (string-append "app:" q))))))
  (register-plugin! (make-plugin "web"
                                 (lambda (q push)
                                   (push (make-result (string-append "web:" q))))
                                 #:prefix "?" #:prioritize? #t))
  ;; A bare query goes to the unprefixed plugin only.
  (test-equal "an unprefixed query" '("app:linux")
    (map result-title (route "linux")))
  ;; A prefixed one goes to BOTH (the unprefixed plugin claims everything) --
  ;; but the prefix is STRIPPED for the one that declares it.
  (let ((titles (map result-title (route "?linux"))))
    (test-assert "the prefixed plugin ran with the prefix removed"
      (member "web:linux" titles))
    (test-assert "and did not see the prefix"
      (not (member "web:?linux" titles)))))

(test-group "a failing plugin does not empty the launcher"
  (clear-plugins!)
  (register-plugin! (make-plugin "good"
                                 (lambda (q push) (push (make-result "good")))))
  (register-plugin! (make-plugin "bad"
                                 (lambda (q push) (error "this plugin is broken"))))
  (test-equal "the working plugin's result still arrives"
    '("good") (map result-title (route "x"))))

(test-group "limit applies after collection"
  ;; Applied per-plugin, one chatty source would starve the others -- with
  ;; three results available and a limit of one, the single row is one of them
  ;; rather than the first plugin's entire output.
  (clear-plugins!)
  (register-plugin! (make-plugin "a"
                                 (lambda (q push)
                                   (push (make-result "a1")) (push (make-result "a2")))))
  (register-plugin! (make-plugin "b"
                                 (lambda (q push) (push (make-result "b1")))))
  (test-equal "one row" 1 (length (route "x" #:limit 1)))
  ;; Registration order is newest-first, so plugin b runs first and both of its
  ;; rows precede plugin a's.  Asserted explicitly because a launcher whose
  ;; ordering drifted would still "work", just with the wrong row first.
  (test-equal "and the order is plugin order, newest registration first"
    '("b1" "a1" "a2") (map result-title (route "x")))
  (test-equal "so the limited row is the first plugin's"
    '("b1") (map result-title (route "x" #:limit 1))))

(test-group "plugin ordering puts the specific first"
  (clear-plugins!)
  (register-plugin! (make-plugin "general" (lambda (q push) #f)))
  (register-plugin! (make-plugin "specific" (lambda (q push) #f) #:prefix "?"))
  (test-equal "the prefixed plugin is tried first"
    '("specific" "general")
    (map plugin-name (plugins-for "?x")))
  (test-equal "but an unprefixed query only matches the general one"
    '("general")
    (map plugin-name (plugins-for "x"))))

(test-group "frecency mixes frequency with recency"
  (frecency-clear!)
  (let ((now 1000000))
    (frecency-add! "frequent" 50 (- now (* 60 60 24 30)))  ; 50 uses, a month ago
    (frecency-add! "recent" 2 (- now (* 60 60)))           ; twice, an hour ago
    ;; A month is ~30 half-lives, so the old score is gone; an hour is a
    ;; fraction of one, so the recent score is nearly intact.
    (test-assert "a recent small score beats an ancient large one"
      (> (frecency-score "recent" #:now now)
         (frecency-score "frequent" #:now now))))
  (test-equal "an unseen key scores 0" 0
    (frecency-score "never-seen" #:now 1000000)))

(test-group "recording a use adds before decaying"
  (frecency-clear!)
  (let ((now 2000000))
    (record-use! "x" now)
    (record-use! "x" now)
    (test-equal "two uses score about 2" 2.0
      (frecency-score "x" #:now now))))

(test-group "ranking puts scored results first and keeps the rest"
  (frecency-clear!)
  (let ((now 3000000))
    (frecency-add! "used" 10 now)
    (let ((rs (list (make-result "unranked-a")
                    (make-result "used-row" #:id "used")
                    (make-result "unranked-b"))))
      (test-equal "the ranked one comes first"
        '("used-row" "unranked-a" "unranked-b")
        (map result-title (frecency-rank rs #:now now))))))

(test-group "persistence round-trips"
  (let ((path (string-append test-dir "/frec.scm")))
    (frecency-clear!)
    (frecency-add! "alpha" 3.5 111)
    (frecency-add! "beta" 1.0 222)
    (test-assert "saves" (frecency-save! path))
    (frecency-clear!)
    (test-equal "cleared" 0 (frecency-score "alpha" #:now 111))
    (frecency-load! path)
    (test-equal "and reloaded" 3.5 (frecency-score "alpha" #:now 111))
    (test-equal "including the second" 1.0 (frecency-score "beta" #:now 222))))

(test-group "a corrupt ranking file is survivable"
  ;; A ranking aid must never stop a shell starting.
  (let ((path (string-append test-dir "/bad.scm")))
    (write-file path "(((unclosed")
    (frecency-clear!)
    (frecency-load! path)
    (test-equal "the table is simply empty" 0
      (frecency-score "anything" #:now 1))))

(test-group "a malformed entry does not lose the good ones"
  (let ((path (string-append test-dir "/partial.scm")))
    (write-file path "((\"good\" 4.0 100) (\"bad\" notanumber 100) 17)\n")
    (frecency-clear!)
    (frecency-load! path)
    (test-equal "the valid entry survived" 4.0
      (frecency-score "good" #:now 100))
    (test-equal "the invalid one was skipped" 0
      (frecency-score "bad" #:now 100))))

(test-group "a launcher is query in, results out"
  (clear-plugins!)
  (register-plugin! (make-plugin "apps"
                                 (lambda (q push)
                                   (push (make-result (string-append "app:" q))))))
  (let-values (((query set-query! results) (make-launcher #:frecency? #f)))
    (test-equal "an empty query has no results" '() (st-peek results))
    (set-query! "fir")
    (test-equal "and a query routes" '("app:fir")
      (map result-title (st-peek results)))
    ;; Reading the results BEFORE changing the query and then changing it is
    ;; the case that broke first: the computed had cached the empty result, and
    ;; because it read the query with st-peek it never recorded the query as a
    ;; source, so nothing told it to recompute.  Asserted explicitly because
    ;; the two assertions above pass without exercising it -- they set the
    ;; query first, so the very first read was already correct.
    (set-query! "bar")
    (test-equal "and changing it again after a peek still updates"
      '("app:bar") (map result-title (st-peek results)))))

;; Clean up.
(for-each (lambda (name)
            (catch #t (lambda () (delete-file (string-append test-dir "/" name)))
                   (lambda args #f)))
          '("frec.scm" "bad.scm" "partial.scm"))
(catch #t (lambda () (delete-file test-dir)) (lambda args #f))
(clear-plugins!)

(test-end "launcher")

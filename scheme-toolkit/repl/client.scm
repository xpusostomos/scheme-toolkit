(define-library (scheme-toolkit repl client)
  ;; The client half of the development back door: `se --repl[=PORT]'.
  ;;
  ;; **It starts no editor.** This is `emacsclient' the other way round -
  ;; the server side (`server.el''s `server-start', here
  ;; `schemacs/repl.sld''s `start-repl!') is what an editor opens with
  ;; `--server', and this connects to one of those and gives the terminal
  ;; back to it as a REPL. What is typed here is read and evaluated *in
  ;; the editor's process*, at the back door (`poll-repl!'), so this needs
  ;; nothing but a socket - and it deliberately does not load the editor's
  ;; libraries, so that `se --repl' cannot start an editor even by
  ;; accident.
  ;;
  ;; THE PROTOCOL is the one the cooperative REPL server speaks: a banner
  ;; and a prompt when a client arrives, and afterwards one answer per
  ;; expression. That is why the server-to-terminal direction is copied a
  ;; **character** at a time - a prompt has no newline in it, and a
  ;; line-at-a-time reader would sit on it until the next answer came.
  ;; The terminal-to-server direction is a line at a time, because that is
  ;; what a terminal hands over: it is in canonical mode and the line
  ;; arrives when RET does.
  ;;
  ;; WHERE THE PORT COMES FROM. With `--repl=PORT' it is given. Without,
  ;; it is read from the files `start-repl!' writes - the port number in
  ;; `$XDG_RUNTIME_DIR/schemacs-repl-<pid>.port' (or `/tmp', when
  ;; `XDG_RUNTIME_DIR' is unset), newest first - which is the same
  ;; convention `tools/repl.py' reads. That convention is in three places
  ;; now (here, `repl.sld' which writes it, and the Python tool); it is
  ;; one line, and this library must not import the editor's libraries to
  ;; reach it. What it does *not* share with the Python tool is how a
  ;; candidate is accepted: that one checks the pid is alive, this one
  ;; connects and keeps the socket if it answers, which tests the thing
  ;; that actually matters.
  (import (scheme base)
          (scheme file)
          ;; `display' is `(scheme write)''s; `write-char' and `newline'
          ;; are `(scheme base)''s, which R7RS puts the character writers
          ;; in
          (only (scheme write) display)
          (only (ice-9 threads) call-with-new-thread)
          ;; `sort' is Guile's own (it is a core binding, not a library's
          ;; - see `(guile)'), and the three string tests are SRFI 13's.
          ;; `string-append' deliberately comes from `(scheme base)' and
          ;; not from here: the same name from two libraries is a
          ;; conflicting import in a `define-library', and the library
          ;; then does not compile at all.
          (only (srfi srfi-13) string-contains string-prefix? string-suffix?
                string-trim-right)
          (only (guile) AF_INET SOCK_STREAM catch close-port connect
                getcwd getenv inet-pton opendir readdir closedir
                shutdown socket sort stat stat:mtime))

  (export repl-port-files repl-connect repl-client run-repl-client
          repl-read-to-prompt repl-answer-error? repl-file-expression
          run-remote-files)

  (begin

    (define %shut-wr 1)
    ;; ^ The second argument of `shutdown': further *sends* are refused,
    ;; which is what half-closing the terminal's side means. POSIX's
    ;; `SHUT_WR' has the value 1; Guile does not bind the constant
    ;; (checked - `SHUT_WR' is unbound in `(guile)' and there is no
    ;; `(ice-9 socket)' in this Guile either), and the socket calls take
    ;; the number.

    (define (repl-port-directory)
      ;; Where `start-repl!' writes the port it took, which is where
      ;; `tools/repl.py' reads it from too.
      ;;--------------------------------------------------------------
      (or (getenv "XDG_RUNTIME_DIR") "/tmp"))

    (define (repl-port-file pid)
      ;; One editor's port file: the pid is in the name so that several
      ;; editors can have the back door open at once and each file says
      ;; which editor it belongs to. `repl.sld' writes exactly this name.
      ;;--------------------------------------------------------------
      (string-append (repl-port-directory)
                     "/schemacs-repl-" (number->string pid) ".port"))

    (define (repl-port-in path)
      ;; The port number in one of those files, or #f when it is not
      ;; readable or does not hold one.
      ;;--------------------------------------------------------------
      (catch #t
        (lambda ()
          (call-with-input-file path
            (lambda (in)
              (let ((line (read-line in)))
                (and (not (eof-object? line))
                     (string->number (string-trim-right line)))))))
        (lambda args #f)))

    (define (repl-port-files)
      ;; Every port file there is, as `(PATH . PORT)', newest first - the
      ;; editor that started last is the one a bare `--repl' means, which
      ;; is what `tools/repl.py' picks too.
      ;;--------------------------------------------------------------
      (let ((names (catch #t
                     (lambda ()
                       (let ((dir (opendir (repl-port-directory))))
                         (let loop ((out '()))
                           (let ((name (readdir dir)))
                             (if (eof-object? name)
                                 (begin (closedir dir) (reverse out))
                                 (loop (cons name out)))))))
                     (lambda args '()))))
        (let loop ((rest names) (found '()))
          (cond ((null? rest)
                 (map cadr
                      (sort found (lambda (a b) (> (car a) (car b))))))
                ((not (string-prefix? "schemacs-repl-" (car rest)))
                 (loop (cdr rest) found))
                ((not (string-suffix? ".port" (car rest)))
                 (loop (cdr rest) found))
                (else
                 (let ((path (string-append (repl-port-directory)
                                            "/" (car rest))))
                   (let ((port (repl-port-in path))
                         (mtime (and (file-exists? path)
                                     (catch #t
                                       (lambda () (stat:mtime (stat path)))
                                       (lambda args #f)))))
                     (if (and port mtime)
                         (loop (cdr rest) (cons (list mtime port) found))
                         (loop (cdr rest) found)))))))))

    (define (repl-connect port)
      ;; A socket connected to the server on PORT, or #f when there is
      ;; none - a connection refused is the ordinary answer here, because
      ;; a port file outlives the editor that wrote it.
      ;;--------------------------------------------------------------
      (let ((s (socket AF_INET SOCK_STREAM 0)))
        (guard (e (#t (catch #t (lambda () (close-port s)) (lambda args #f))
                     #f))
          (connect s AF_INET (inet-pton AF_INET "127.0.0.1") port)
          s)))

    (define (repl-client socket in out)
      ;; Be a REPL for the server on SOCKET: what it says is copied to
      ;; OUT as it arrives, and what is typed at IN is sent to it.
      ;;
      ;; Answers when the server closes its end, or when IN ends - the
      ;; terminal's C-d, or a pipe running out - which half-closes this
      ;; side so that the server's REPL reads end of input and finishes
      ;; the session. It is half of a close on purpose: the socket is
      ;; still needed for the rest of the answer.
      ;;
      ;; **The two directions are two threads**, because both ends can be
      ;; silent at once and a single thread would be waiting on one of
      ;; them. The terminal's side is the thread and the server's is this
      ;; one, so that the server closing is what ends the session.
      ;;--------------------------------------------------------------
      (call-with-new-thread
       (lambda ()
         (let loop ()
           (let ((line (read-line in)))
             (if (eof-object? line)
                 (catch #t (lambda () (shutdown socket %shut-wr))
                        (lambda args #f))
                 (begin
                   (display line socket)
                   (newline socket)
                   (flush-output-port socket)
                   (loop)))))))
      (let loop ()
        (let ((c (read-char socket)))
          (unless (eof-object? c)
            (write-char c out)
            (flush-output-port out)
            (loop)))))

    (define (repl-connect-any port)
      ;; The socket to talk to: PORT when `--repl=PORT' or
      ;; `--remote=PORT' named one, otherwise the newest editor that
      ;; answers.
      ;;--------------------------------------------------------------
      (let loop ((ports (if port (list port) (repl-port-files))))
        (cond ((null? ports) #f)
              (else (or (repl-connect (car ports))
                        (loop (cdr ports)))))))

    (define (repl-open-session port option)
      ;; The socket of a running editor's REPL, or an error worth its own
      ;; words - "the editor is not running" and "it was not started with
      ;; `--server'" look the same from here and a user can act on the
      ;; difference. OPTION is `--repl' or `--remote', for that message.
      ;;--------------------------------------------------------------
      (let ((socket (repl-connect-any port)))
        (unless socket
          (error (if port
                     (string-append "no REPL server is listening on port "
                                    (number->string port))
                     (string-append "no editor is running with the back door "
                                    "open, and " option
                                    " was given no port"))))
        socket))

    (define (repl-prompt? line)
      ;; Whether LINE - the characters since the last newline - is the
      ;; REPL's prompt: `scheme@(guile-user)> ', or the nested
      ;; `scheme@(guile-user) [1]> ' an error leaves behind.
      ;;--------------------------------------------------------------
      (and (string-prefix? "scheme@" line)
           (string-suffix? "> " line)))

    (define (repl-read-to-prompt socket)
      ;; Everything the server writes up to and including the next prompt,
      ;; or #f when the connection ends before one comes.
      ;;
      ;; **The prompt is tested as the *last line*, not as "the text ends
      ;; with `>'".** A *value* can end with `>' - a buffer prints as
      ;; `#<buffer README.md>' - so the looser test stops before the
      ;; prompt has arrived, and the next expression sent would then be
      ;; answered by the remains of the previous one's answer.
      ;;--------------------------------------------------------------
      (let loop ((out '()) (line ""))
        (let ((c (read-char socket)))
          (if (eof-object? c)
              #f
              (let ((out (cons c out))
                    (line (if (char=? c #\newline)
                              ""
                              (string-append line (string c)))))
                (if (repl-prompt? line)
                    (list->string (reverse out))
                    (loop out line)))))))

    (define (repl-send socket text)
      ;; One expression, and the newline that tells the reader it is
      ;; whole.
      ;;--------------------------------------------------------------
      (display text socket)
      (newline socket)
      (flush-output-port socket))

    (define (repl-last-line text)
      ;; TEXT after its last newline.
      ;;--------------------------------------------------------------
      (let loop ((i (- (string-length text) 1)))
        (cond ((< i 0) text)
              ((char=? #\newline (string-ref text i))
               (substring text (+ i 1) (string-length text)))
              (else (loop (- i 1))))))

    (define (repl-answer-error? answer)
      ;; Whether the editor's ANSWER to an expression was an error's: the
      ;; REPL leaves a *nested* prompt - `scheme@(guile-user) [1]>' - where
      ;; a value leaves the plain one, which is Guile's way of saying it
      ;; is in a debugger and waiting.
      ;;--------------------------------------------------------------
      (let ((line (repl-last-line answer)))
        (and (string-prefix? "scheme@" line)
             (string-contains line "["))))

    (define (repl-answer-text answer)
      ;; ANSWER without the prompt line it ends with, for a message.
      ;;--------------------------------------------------------------
      (string-trim-right
       (let loop ((i (- (string-length answer) 1)))
         (cond ((< i 0) answer)
               ((char=? #\newline (string-ref answer i)) (substring answer 0 i))
               (else (loop (- i 1)))))))

    (define (repl-absolute-file name)
      ;; NAME as the editor should see it: a relative one is expanded
      ;; against *this* process's directory, which is the directory the
      ;; user typed the command in and not the editor's.
      ;;--------------------------------------------------------------
      (if (and (> (string-length name) 0) (char=? #\/ (string-ref name 0)))
          name
          (string-append (getcwd) "/" name)))

    (define (repl-file-expression file)
      ;; What `--remote' sends for FILE: one `find-file', which is the
      ;; command the user would have typed. It is *text to be read*, so
      ;; the name goes in as a string literal, written out character by
      ;; character - a name with a quote or a backslash in it would
      ;; otherwise end the literal or escape what follows.
      ;;--------------------------------------------------------------
      (let ((name (repl-absolute-file file)))
        (let loop ((i 0) (out "(find-file \""))
          (if (>= i (string-length name))
              (string-append out "\")")
              (let ((c (string-ref name i)))
                (loop (+ i 1)
                      (string-append out
                                     (if (or (char=? c #\") (char=? c #\\))
                                         (string #\\ c)
                                         (string c)))))))))

    (define (run-remote-files port files)
      ;; `--remote': open FILES in a running editor and leave. It is
      ;; `emacsclient' in one direction and no more than that - there is
      ;; no `server.el' protocol here, no `-dir' handshake and no
      ;; `find-file-noselect'/window dance: each name becomes one
      ;; `find-file`, evaluated by the editor, and the editor draws the
      ;; result.
      ;;
      ;; **Nothing is printed when it works.** The editor is the answer,
      ;; which is what `emacsclient' does too; an error the editor
      ;; reported is raised, so the launcher prints it and exits 1.
      ;;--------------------------------------------------------------
      (let ((socket (repl-open-session port "--remote")))
        (unless (repl-read-to-prompt socket)
          (close-port socket)
          (error "the editor closed the connection before its prompt"))
        (for-each
         (lambda (file)
           (repl-send socket (repl-file-expression file))
           (let ((answer (repl-read-to-prompt socket)))
             (cond ((not answer)
                    (close-port socket)
                    (error "the editor closed the connection while opening ~a"
                           file))
                   ((repl-answer-error? answer)
                    (close-port socket)
                    (error "~a: ~a" file (repl-answer-text answer))))))
         files)
        (close-port socket)))

    (define (run-repl-client port)
      ;; The command line's `--repl': find a server, connect to it, and be
      ;; a REPL for it. PORT when `--repl=PORT' named one, otherwise the
      ;; newest editor that answers.
      ;;--------------------------------------------------------------
      (let ((socket (repl-open-session port "--repl")))
        (repl-client socket (current-input-port) (current-output-port))))

    ))

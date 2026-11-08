;;;; tests/test-terminal.lisp — tests for src/terminal.lisp: ANSI strings, terminal size, keys
;;;; (DESIGN.md §5.8).

(in-package :game-of-life-test)

(defun %locale-says-utf8-p ()
  "What DESIGN.md §4.7 says UTF8-OUTPUT-P must answer for a stream without an external format
name: the first of LC_ALL, LC_CTYPE and LANG that is set (and not empty) decides by containing
\"UTF\" case-insensitively; when none is set the answer is T."
  (let ((value (find-if (lambda (v) (and v (plusp (length v))))
                        (list (game-of-life::%getenv "LC_ALL")
                              (game-of-life::%getenv "LC_CTYPE")
                              (game-of-life::%getenv "LANG")))))
    (if value
        (and (search "UTF" (string-upcase value)) t)
        t)))

(defun %stdin-not-a-tty-p ()
  "True when `stty -g` on the process's own stdin fails, i.e. stdin is not a terminal (or stty
is missing). Any error means not-a-tty; never hangs: stty reads nothing."
  (null (ignore-errors
         (uiop:run-program (game-of-life::%stty-command "-g")
                           :input :interactive :output :string))))

(deftest terminal/ansi
  (is-equal (format nil "~C[2J" #\Esc) (ansi-clear))
  (is-equal (format nil "~C[H" #\Esc) (ansi-home))
  (is-equal (format nil "~C[?25l" #\Esc) (ansi-hide-cursor))
  (is-equal (format nil "~C[?25h" #\Esc) (ansi-show-cursor))
  (is-equal (format nil "~C[?1049h" #\Esc) (ansi-enter-alternate-screen))
  (is-equal (format nil "~C[?1049l" #\Esc) (ansi-leave-alternate-screen))
  (is (not (eq (ansi-home) (ansi-home))) "fresh strings")
  (is (every #'stringp (list (ansi-clear) (ansi-home) (ansi-hide-cursor) (ansi-show-cursor)
                             (ansi-enter-alternate-screen) (ansi-leave-alternate-screen))))
  ;; nothing is written by asking for them
  (multiple-value-bind (value out err)
      (with-captured-output (o e)
        (list (ansi-clear) (ansi-home) (ansi-hide-cursor) (ansi-show-cursor)
              (ansi-enter-alternate-screen) (ansi-leave-alternate-screen)))
    (is-equal 6 (length value))
    (is-equal "" out)
    (is-equal "" err)))

(deftest terminal/parse-size
  (is-equal '(80 24) (multiple-value-list (parse-terminal-size "24 80")))
  (is-equal '(80 24) (multiple-value-list (parse-terminal-size (format nil "24 80~%"))))
  (is-equal '(132 50) (multiple-value-list (parse-terminal-size "50 132")))
  (is-equal '(80 24) (multiple-value-list (parse-terminal-size "  24   80  ")))
  (is (null (parse-terminal-size "x")))
  (is (null (parse-terminal-size "0 80")))
  (is (null (parse-terminal-size "24 0")))
  (is (null (parse-terminal-size "0 0")))
  (is (null (parse-terminal-size "")))
  (is (null (parse-terminal-size "24")))
  (is (null (parse-terminal-size "24 80 1")))
  (is (null (parse-terminal-size "24 eighty")))
  (is (null (parse-terminal-size "-24 80"))))

(deftest terminal/size-never-fails
  (multiple-value-bind (columns rows) (terminal-size)
    (is (and (integerp columns) (plusp columns)) "columns is a positive integer: ~S" columns)
    (is (and (integerp rows) (plusp rows)) "rows is a positive integer: ~S" rows))
  ;; calling it twice is harmless and consistent
  (is-equal (multiple-value-list (terminal-size)) (multiple-value-list (terminal-size))))

(deftest terminal/utf8-output-p
  (let ((v (utf8-output-p)))
    (is (or (eq v t) (eq v nil)) "a boolean for *standard-output*: ~S" v))
  (let ((v (utf8-output-p *standard-output*)))
    (is (or (eq v t) (eq v nil)) "a boolean for an explicit stream: ~S" v))
  (let ((v (utf8-output-p (make-string-output-stream))))
    (is (or (eq v t) (eq v nil)) "a boolean for a string stream: ~S" v)
    (is (eq (%locale-says-utf8-p) v) "a string stream has no format name, the locale decides"))
  (let ((v (utf8-output-p (make-broadcast-stream))))
    (is (or (eq v t) (eq v nil)) "a boolean for a broadcast stream: ~S" v)))

(deftest terminal/read-key
  (is-equal #\q (read-key (make-string-input-stream "q")))
  (is-equal nil (read-key (make-string-input-stream "")))
  (is-equal :escape (read-key (make-string-input-stream (format nil "~C[A" #\Esc))))
  (is-equal :escape (read-key (make-string-input-stream (string #\Esc))))
  (is-equal :escape (read-key (make-string-input-stream (format nil "~C[1;5C" #\Esc))))
  (let ((s (make-string-input-stream "qw")))
    (is-equal #\q (read-key s))
    (is-equal #\w (read-key s))
    (is-equal nil (read-key s))
    (is (null (read-key s)) "still nil at end of file"))
  ;; an arrow key drains what is waiting
  (let ((s (make-string-input-stream (format nil "~C[Ax" #\Esc))))
    (is-equal :escape (read-key s))
    (is (member (read-key s) '(nil #\x)) "after the escape sequence only x or nothing remains"))
  (is-equal #\Space (read-key (make-string-input-stream " ")))
  (is-equal #\+ (read-key (make-string-input-stream "+")))
  (is-equal #\Newline (read-key (make-string-input-stream (string #\Newline))))
  (let ((*standard-input* (make-string-input-stream "n")))
    (is-equal #\n (read-key))
    (is-equal nil (read-key))))

(deftest terminal/with-raw-keyboard-no-tty
  (let ((ran nil)
        (seen :unset)
        (not-a-tty (%stdin-not-a-tty-p)))
    (with-raw-keyboard (available)
      (setf ran t seen available))
    (is ran "the body runs")
    (is (or (eq seen t) (eq seen nil)) "AVAILABLE is a boolean: ~S" seen)
    (when not-a-tty
      (is (eq seen nil) "without a tty AVAILABLE is nil")))
  ;; the body's values come back; the variable may go unused
  (is-equal '(1 2) (multiple-value-list (with-raw-keyboard (k) (values 1 2))))
  (is-equal :done (with-raw-keyboard (unused) :done))
  ;; with-terminal-ui without a keyboard binds KEYS to nil and brackets the output
  (let* ((s (make-string-output-stream))
         (seen :unset)
         (value (with-terminal-ui (keys :stream s :alternate-screen nil :keyboard nil)
                  (setf seen keys)
                  (write-string "body" s)
                  :result))
         (out (get-output-stream-string s)))
    (is-equal :result value)
    (is-equal nil seen)
    (is (%starts-with-p (format nil "~C[?25l~C[2J" #\Esc #\Esc) out) "hide cursor, clear: ~S" out)
    (is (search "body" out))
    (is (%ends-with-p (format nil "~C[?25h" #\Esc) out))
    (is (not (search (format nil "~C[?1049" #\Esc) out)) "no alternate screen asked"))
  (let* ((s (make-string-output-stream))
         (value (with-terminal-ui (keys :stream s :keyboard nil) (declare (ignorable keys)) 42))
         (out (get-output-stream-string s)))
    (is-equal 42 value)
    (is (%starts-with-p (format nil "~C[?1049h" #\Esc) out) "alternate screen on by default")
    (is (%ends-with-p (format nil "~C[?25h~C[?1049l" #\Esc #\Esc) out) "show cursor, then leave"))
  ;; the cleanup runs when the body unwinds
  (let ((s (make-string-output-stream)))
    (ignore-errors
     (with-terminal-ui (keys :stream s :keyboard nil)
       (error "boom")))
    (is (%ends-with-p (format nil "~C[?25h~C[?1049l" #\Esc #\Esc) (get-output-stream-string s))
        "the terminal is restored after an error")))

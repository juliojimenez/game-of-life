;;;; src/terminal.lisp — ANSI sequences, terminal size, raw keyboard, with-terminal-ui
;;;; (DESIGN.md §4.7).
;;;;
;;;; Nothing here touches the terminal except through `stty`, which is always run through
;;;; %STTY-COMMAND (sh with SIGTTOU ignored) and the process's own stdin, so it acts on the user's
;;;; terminal on SBCL, ECL and CCL alike. No FFI.

(in-package :game-of-life)

(%muffle-compiler-notes)

;;; ---- ANSI sequences ------------------------------------------------------------------------

(defun %csi (text)
  "ESC [ followed by TEXT, as a fresh string."
  (concatenate 'string (string (code-char 27)) "[" text))

(defun ansi-clear ()
  "The sequence that clears the screen (ESC[2J), as a fresh string. Writes nothing."
  (%csi "2J"))

(defun ansi-home ()
  "The sequence that moves the cursor to the top-left corner (ESC[H), as a fresh string."
  (%csi "H"))

(defun ansi-hide-cursor ()
  "The sequence that hides the cursor (ESC[?25l), as a fresh string."
  (%csi "?25l"))

(defun ansi-show-cursor ()
  "The sequence that shows the cursor (ESC[?25h), as a fresh string."
  (%csi "?25h"))

(defun ansi-enter-alternate-screen ()
  "The sequence that switches to the alternate screen (ESC[?1049h), as a fresh string."
  (%csi "?1049h"))

(defun ansi-leave-alternate-screen ()
  "The sequence that returns to the normal screen (ESC[?1049l), as a fresh string."
  (%csi "?1049l"))

;;; ---- stty ----------------------------------------------------------------------------------

(defun %stty-command (&rest args)
  "The command line that runs `stty ARGS...` through sh with SIGTTOU ignored:
(\"sh\" \"-c\" \"trap '' TTOU; exec \\\"$0\\\" \\\"$@\\\"\" \"stty\" . ARGS). The only way this file
runs stty: CCL's run-program puts the child in its own process group, where a tcsetattr would stop
it with SIGTTOU; with the signal ignored the setting succeeds, and on SBCL and ECL the wrapper
changes nothing."
  (list* "sh" "-c" "trap '' TTOU; exec \"$0\" \"$@\"" "stty" args))

(defun %terminal-digits-p (string)
  "True when STRING is one or more ASCII digits."
  (and (plusp (length string))
       (every (lambda (c) (char<= #\0 c #\9)) string)))

(defun %terminal-size-tokens (string)
  "The whitespace-separated words of STRING, as a list of fresh strings."
  (let ((tokens '()) (start nil))
    (dotimes (i (length string))
      (let ((space (member (char string i) '(#\Space #\Tab #\Newline #\Return #\Page))))
        (cond ((and space start) (push (subseq string start i) tokens) (setf start nil))
              ((and (not space) (null start)) (setf start i)))))
    (when start (push (subseq string start) tokens))
    (nreverse tokens)))

(defun parse-terminal-size (string)
  "Parses stty's `rows cols` output (\"24 80\") and returns (values columns rows), or NIL when
STRING is not exactly two positive integers."
  (let ((tokens (%terminal-size-tokens string)))
    (when (and (= (length tokens) 2)
               (%terminal-digits-p (first tokens))
               (%terminal-digits-p (second tokens)))
      (let ((rows (parse-integer (first tokens)))
            (columns (parse-integer (second tokens))))
        (when (and (plusp rows) (plusp columns))
          (values columns rows))))))

(defun %terminal-env-integer (name)
  "The positive integer in the environment variable NAME, or NIL."
  (let ((value (%getenv name)))
    (and (stringp value)
         (%terminal-digits-p value)
         (let ((n (parse-integer value)))
           (and (plusp n) n)))))

(defun terminal-size ()
  "Returns (values columns rows) of the terminal: from `stty size` on the process's stdin, else
from the COLUMNS and LINES environment variables, else 80 and 24. Never signals."
  (handler-case
      (multiple-value-bind (columns rows)
          (parse-terminal-size (%run-program-output (%stty-command "size")))
        (if columns
            (values columns rows)
            (values (or (%terminal-env-integer "COLUMNS") 80)
                    (or (%terminal-env-integer "LINES") 24))))
    (error () (values 80 24))))

;;; ---- Output encoding -----------------------------------------------------------------------

(defun %terminal-utf-name-p (name)
  "True when the string NAME mentions UTF, case-insensitively."
  (and (search "UTF" (string-upcase name)) t))

(defun %terminal-locale ()
  "The first non-empty value of LC_ALL, LC_CTYPE and LANG, or NIL when none is set."
  (dolist (name '("LC_ALL" "LC_CTYPE" "LANG") nil)
    (let ((value (%getenv name)))
      (when (and (stringp value) (plusp (length value)))
        (return value)))))

(defun utf8-output-p (&optional (stream *standard-output*))
  "True when STREAM can show the half-block characters: its external format name (§4.2) mentions
UTF. When the stream has no known name (a string stream, or an unknown implementation), LC_ALL,
then LC_CTYPE, then LANG decide the same way; when none of them is set the answer is T."
  (let ((name (%stream-external-format-name stream)))
    (if name
        (%terminal-utf-name-p (princ-to-string name))
        (let ((locale (%terminal-locale)))
          (if locale
              (%terminal-utf-name-p locale)
              t)))))

;;; ---- Keyboard ------------------------------------------------------------------------------

(defun read-key (&optional (stream *standard-input*))
  "Non-blocking key read: NIL when no character is waiting or at end of file; :ESCAPE for an
escape sequence (a lone ESC, or ESC followed by more bytes such as an arrow key: everything
waiting is drained); otherwise the character."
  (let ((char (read-char-no-hang stream nil nil)))
    (cond ((null char) nil)
          ((char= char (code-char 27))
           (loop for more = (read-char-no-hang stream nil nil)
                 while more)
           :escape)
          (t char))))

(defun %terminal-saved-settings ()
  "The output of `stty -g` with the trailing newline trimmed (one shell word on macOS and Linux),
or NIL when stty failed (no tty, no stty)."
  (multiple-value-bind (output code) (%run-program-output (%stty-command "-g"))
    (let ((settings (string-trim '(#\Space #\Tab #\Newline #\Return) output)))
      (and (plusp (length settings))
           (or (null code) (eql code 0))
           settings))))

(defun %terminal-raw-mode ()
  "Puts the terminal in non-canonical, no-echo mode: `stty -icanon -echo min 1 time 0`."
  (%run-program-output (%stty-command "-icanon" "-echo" "min" "1" "time" "0"))
  t)

(defun %terminal-restore (settings)
  "Restores the terminal with `stty SETTINGS`, SETTINGS being a saved `stty -g` string."
  (%run-program-output (%stty-command settings))
  t)

(defmacro with-raw-keyboard ((available-var) &body body)
  "Saves the terminal settings with `stty -g`, puts the terminal in non-canonical no-echo mode
(`stty -icanon -echo min 1 time 0`), binds AVAILABLE-VAR to T and runs BODY; the saved settings
are restored in an unwind-protect cleanup. When `stty -g` fails (no tty, no stty), binds
AVAILABLE-VAR to NIL, changes nothing and runs BODY. AVAILABLE-VAR is declared ignorable."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (%terminal-saved-settings)))
       (unwind-protect
            (progn
              (when ,saved (%terminal-raw-mode))
              (let ((,available-var (and ,saved t)))
                (declare (ignorable ,available-var))
                ,@body))
         (when ,saved (%terminal-restore ,saved))))))

(defmacro with-terminal-ui ((keys-var &key (stream '*standard-output*) (alternate-screen t)
                                      (keyboard t))
                            &body body)
  "Runs BODY with the terminal set up for drawing: writes to STREAM the alternate-screen switch
(when ALTERNATE-SCREEN), hide-cursor and clear sequences, and runs BODY inside WITH-RAW-KEYBOARD
when KEYBOARD, binding KEYS-VAR to the keyboard's availability (NIL when KEYBOARD is NIL). The
cleanup shows the cursor, leaves the alternate screen when it was entered and finishes STREAM's
output. Returns BODY's values. KEYS-VAR is declared ignorable."
  (let ((s (gensym "STREAM"))
        (alternate (gensym "ALTERNATE"))
        (run-body (gensym "BODY"))
        (available (gensym "AVAILABLE")))
    `(let ((,s ,stream)
           (,alternate ,alternate-screen))
       (flet ((,run-body (,keys-var)
                (declare (ignorable ,keys-var))
                ,@body))
         (when ,alternate (write-string (ansi-enter-alternate-screen) ,s))
         (write-string (ansi-hide-cursor) ,s)
         (write-string (ansi-clear) ,s)
         (finish-output ,s)
         (unwind-protect
              (if ,keyboard
                  (with-raw-keyboard (,available) (,run-body ,available))
                  (,run-body nil))
           (write-string (ansi-show-cursor) ,s)
           (when ,alternate (write-string (ansi-leave-alternate-screen) ,s))
           (finish-output ,s))))))

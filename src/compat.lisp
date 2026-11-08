;;;; src/compat.lisp — every implementation-specific primitive, in one place (DESIGN.md §4.2).
;;;;
;;;; The rest of the system is portable Common Lisp plus ASDF's uiop. This is the only file with reader
;;;; conditionals on the Lisp implementation: SBCL gets its native call, ECL and CCL theirs, every other
;;;; implementation uiop or a portable fallback.

(in-package :game-of-life)

(defmacro %muffle-compiler-notes ()
  "At top level: silence SBCL's optimization notes for the rest of the file; nothing elsewhere."
  #+sbcl '(declaim (sb-ext:muffle-conditions sb-ext:compiler-note))
  #-sbcl nil)

(defun %getenv (name)
  "The environment variable NAME, or NIL."
  (uiop:getenv name))

(defun %command-line-arguments ()
  "The user arguments of this process, program name excluded."
  (uiop:command-line-arguments))

(defun %raw-command-line-arguments ()
  "The whole argv of this process, program name first."
  (uiop:raw-command-line-arguments))

(defun %debugger-disabled-p ()
  "True when this Lisp was started with its debugger disabled (SBCL's --non-interactive or
--disable-debugger install a hook named DEBUGGER-DISABLED-HOOK); NIL elsewhere."
  #+sbcl (let ((hook sb-ext:*invoke-debugger-hook*))
           (and hook (symbolp hook)
                (string= (symbol-name hook) "DEBUGGER-DISABLED-HOOK")
                (eq (symbol-package hook) (find-package "SB-DEBUG"))))
  #-sbcl nil)

(defun %exit (code)
  "End the process with exit status CODE. The caller flushes the streams first. SBCL skips the
unwinding (an unwinding exit from inside ASDF's compilation unit prints a spurious notice); ECL
and CCL unwind, and nothing here relies on avoiding that."
  #+sbcl (sb-ext:exit :code code :abort t)
  #+ecl (ext:quit code)
  #+ccl (ccl:quit code)
  #-(or sbcl ecl ccl) (uiop:quit code))

(defmacro %catch-interrupt (form &body on-interrupt)
  "Evaluate FORM; when Ctrl-C (SIGINT) arrives during it, abandon FORM (unwind-protect cleanups
run) and return the values of ON-INTERRUPT. SBCL and ECL signal a condition HANDLER-CASE sees (a
serious-condition, not an error). CCL never signals its condition: its SIGINT handler enters the
break loop directly, so CCL:*BREAK-HOOK* throws out instead. Elsewhere FORM runs alone and Ctrl-C
is not caught."
  (declare (ignorable on-interrupt))
  #+sbcl `(handler-case ,form
            (sb-sys:interactive-interrupt () ,@on-interrupt))
  #+ecl `(handler-case ,form
           (ext:interactive-interrupt () ,@on-interrupt))
  #+ccl (let ((tag (gensym "INTERRUPT-TAG")) (result (gensym "RESULT")))
          `(let ((,result (catch ',tag
                            (let ((ccl:*break-hook*
                                    (lambda (condition hook)
                                      (declare (ignore hook))
                                      (when (typep condition 'ccl:interrupt-signal-condition)
                                        (throw ',tag ',tag)))))
                              (multiple-value-list ,form)))))
             (if (eq ,result ',tag)
                 (progn ,@on-interrupt)
                 (values-list ,result))))
  #-(or sbcl ecl ccl) `(progn ,form))

(defun %run-program-output (command)
  "Run COMMAND (a list of strings) with this process's own standard input, so a program such as
stty acts on the user's terminal; capture its standard output; discard its error output. Returns
(values output-string exit-code). On any error (no such program, no terminal, a uiop limitation)
returns (values \"\" NIL). Never signals."
  (handler-case
      (multiple-value-bind (output error-output code)
          (uiop:run-program command :input :interactive :output :string
                                    :error-output nil :ignore-error-status t)
        (declare (ignore error-output))
        (values (if (stringp output) output "") code))
    (error () (values "" nil))))

(defun %stream-external-format-name (stream)
  "A string naming the external format of STREAM after following synonym streams (repeatedly) and
two-way streams (their output side); NIL for a string stream (ECL says :UCS-4 and CCL ISO-8859-1
for those, SBCL NIL: none of it describes the terminal) and NIL when unknown or on error."
  (ignore-errors
   (let ((s stream))
     (loop repeat 16
           do (cond ((typep s 'synonym-stream)
                     (setf s (symbol-value (synonym-stream-symbol s))))
                    ((typep s 'two-way-stream)
                     (setf s (two-way-stream-output-stream s)))
                    (t (return))))
     (if (typep s 'string-stream)
         nil
         (let ((format (stream-external-format s)))
           (and format (princ-to-string format)))))))

(defun %real-time-seconds ()
  "The real-time clock in seconds as a double-float (arbitrary origin; for frame pacing)."
  (/ (coerce (get-internal-real-time) 'double-float)
     (coerce internal-time-units-per-second 'double-float)))

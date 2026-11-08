;;;; tests/harness.lisp — zero-dependency test harness for Game of Life (DESIGN.md §5.1).
;;;; Package GAME-OF-LIFE-TEST is defined at the bottom of src/package.lisp.

(in-package :game-of-life-test)

;;; ------------------------------------------------------------------------------------------
;;; Registry and counters
;;; ------------------------------------------------------------------------------------------

(defvar *tests* '()
  "List of (name . thunk) in definition order (newest last).")
(defvar *failures* 0 "Failed checks in the current run.")
(defvar *checks* 0 "Checks performed in the current run.")
(defvar *current-test* nil "Name of the test being run, or NIL.")
(defvar *current-messages* '()
  "Failure messages recorded by the test being run (newest first).")
(defvar *temp-counter* 0
  "Counter that keeps the names of the temporary directories made in one run distinct.")

(defun %register-test (name thunk)
  "Register THUNK under NAME, replacing an existing test of that name in place."
  (let ((cell (assoc name *tests*)))
    (if cell
        (setf (cdr cell) thunk)
        (setf *tests* (nconc *tests* (list (cons name thunk))))))
  name)

(defun %pass ()
  "Record one passing check; returns T."
  (incf *checks*)
  t)

(defun %fail (control &rest args)
  "Record one failed check with a formatted message; returns NIL."
  (incf *checks*)
  (incf *failures*)
  (push (apply #'format nil control args) *current-messages*)
  nil)

(defun %condition-string (c)
  "A printable description of the condition C that never signals."
  (or (ignore-errors (princ-to-string c))
      (ignore-errors (format nil "~S" (type-of c)))
      "unprintable condition"))

;;; ------------------------------------------------------------------------------------------
;;; deftest / is / is-close / is-equal / signals
;;; ------------------------------------------------------------------------------------------

(defmacro deftest (name &body body)
  "Register (or replace) test NAME. BODY runs under HANDLER-CASE: any ERROR counts as a failure."
  `(progn
     (%register-test
      ',name
      (lambda ()
        (handler-case (progn ,@body)
          (error (e)
            (%fail "unhandled error ~S: ~A" (type-of e) (%condition-string e))))))
     ',name))

(defmacro is (form &optional (msg "") &rest args)
  "Check that FORM is true; on failure print the unevaluated FORM and MSG (a format control)."
  `(if ,form
       (%pass)
       (%fail "~S is false~@[ — ~A~]" ',form
              (let ((m (format nil ,msg ,@args))) (if (string= m "") nil m)))))

(defmacro is-close (a b &key (tol 1e-4) (msg ""))
  "Check that |A - B| <= TOL; on failure print both forms and values."
  (let ((va (gensym "A")) (vb (gensym "B")) (vt (gensym "TOL")))
    `(let ((,va ,a) (,vb ,b) (,vt ,tol))
       (if (<= (abs (- ,va ,vb)) ,vt)
           (%pass)
           (%fail "~S = ~S not within ~S of ~S = ~S~@[ — ~A~]"
                  ',a ,va ,vt ',b ,vb (let ((m ,msg)) (if (equal m "") nil m)))))))

(defmacro is-equal (expected form)
  "Check that FORM is EQUAL to EXPECTED; on failure print both."
  (let ((ve (gensym "EXPECTED")) (vf (gensym "ACTUAL")))
    `(let ((,ve ,expected) (,vf ,form))
       (if (equal ,ve ,vf)
           (%pass)
           (%fail "~S => ~S, expected ~S" ',form ,vf ,ve)))))

(defmacro signals (condition-type form)
  "Check that evaluating FORM signals (a subtype of) CONDITION-TYPE."
  `(handler-case (progn ,form (%fail "~S did not signal ~S" ',form ',condition-type))
     (,condition-type () (%pass))
     (error (e)
       (%fail "~S signaled ~S instead of ~S: ~A" ',form (type-of e) ',condition-type
              (%condition-string e)))))

;;; ------------------------------------------------------------------------------------------
;;; Runner
;;; ------------------------------------------------------------------------------------------

(defun %run-one (name thunk verbose)
  "Run THUNK as test NAME, printing the result line(s). Returns T iff it recorded no failure."
  (let ((*current-test* name)
        (*current-messages* '())
        (before *failures*))
    (funcall thunk)
    (let ((messages (reverse *current-messages*))
          (ok (= before *failures*)))
      (cond (ok (when verbose (format t "~A ... ok~%" name)))
            (t (format t "~A ... FAIL: ~A~@[ (+~D more)~]~%"
                       name (first messages)
                       (let ((n (1- (length messages)))) (if (plusp n) n nil)))
               (dolist (m (rest messages))
                 (format t "    ~A~%" m))))
      (finish-output)
      ok)))

(defun %non-interactive-p ()
  "True when the suite runs unattended and should end the process with an exit code (DESIGN.md
§5.1): the environment variable LIFE_NON_INTERACTIVE is set, \"--non-interactive\" is in the raw
command line, or this Lisp was started with its debugger disabled (SBCL's --non-interactive)."
  (or (game-of-life::%getenv "LIFE_NON_INTERACTIVE")
      (member "--non-interactive" (game-of-life::%raw-command-line-arguments) :test #'string=)
      (game-of-life::%debugger-disabled-p)))

(defun run-all-tests (&key (verbose t))
  "Run every registered test in definition order; print \"name ... ok | FAIL: reason\" lines and
the summary \"N checks, M failures\". Returns T iff there were no failures. When the suite runs
unattended (%NON-INTERACTIVE-P), flushes the streams and ends the process with exit code 0 (ok)
or 1 without unwinding."
  (setf *checks* 0 *failures* 0)
  (loop for (name . thunk) in *tests*
        do (%run-one name thunk verbose))
  (format t "~&~D checks, ~D failures~%" *checks* *failures*)
  (finish-output)
  (let ((ok (zerop *failures*)))
    (when (%non-interactive-p)
      (finish-output *standard-output*)
      (finish-output *error-output*)
      ;; without unwinding: the streams are already flushed, and an unwinding exit from inside
      ;; ASDF's compilation unit prints a spurious "compilation unit aborted" notice.
      (game-of-life::%exit (if ok 0 1)))
    ok))

(defun run-test (name)
  "Run the single test NAME (a symbol), printing its result line and a summary of its checks.
Returns T iff it recorded no failure; signals an error for an unknown name."
  (let ((cell (assoc name *tests*)))
    (unless cell
      (error "No test named ~S (known: ~{~S~^ ~})." name (mapcar #'car *tests*)))
    (let ((checks-before *checks*) (failures-before *failures*))
      (prog1 (%run-one (car cell) (cdr cell) t)
        (format t "~&~D checks, ~D failures~%"
                (- *checks* checks-before) (- *failures* failures-before))
        (finish-output)))))

;;; ------------------------------------------------------------------------------------------
;;; Helpers (DESIGN.md §5.1)
;;; ------------------------------------------------------------------------------------------

(defun long-tests-p ()
  "True when the slow oracles should run: the environment variable LIFE_LONG_TESTS is set."
  (game-of-life::%getenv "LIFE_LONG_TESTS"))

(defmacro with-captured-output ((out err) &body body)
  "Run BODY with *STANDARD-OUTPUT* bound to the string stream OUT and *ERROR-OUTPUT* to the
string stream ERR (both variables are visible to BODY and declared ignorable). Returns three
values: the primary value of BODY, what it wrote to standard output, and what it wrote to error
output."
  (let ((value (gensym "VALUE")))
    `(let ((,out (make-string-output-stream))
           (,err (make-string-output-stream)))
       (declare (ignorable ,out ,err))
       (let ((,value (let ((*standard-output* ,out)
                           (*error-output* ,err))
                       ,@body)))
         (values ,value
                 (get-output-stream-string ,out)
                 (get-output-stream-string ,err))))))

(defun %fresh-temp-dir ()
  "A new, empty directory under (uiop:temporary-directory)."
  (let ((dir (merge-pathnames
              (format nil "life-tests-~D-~D-~D/"
                      (get-universal-time) (get-internal-real-time) (incf *temp-counter*))
              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun temp-file (name)
  "A pathname for the file NAME (\"glider.rle\") inside a fresh, empty directory under
(uiop:temporary-directory). The directory exists; the file does not yet."
  (merge-pathnames name (%fresh-temp-dir)))

(defun cells-of (pattern-name)
  "The normalized cell list of the library pattern PATTERN-NAME."
  (pattern-cells (pattern pattern-name)))

;;; ------------------------------------------------------------------------------------------
;;; Fixtures shared by several test files
;;; ------------------------------------------------------------------------------------------

(defparameter *glider-cells* '((1 . 0) (2 . 1) (0 . 2) (1 . 2) (2 . 2))
  "The glider's cells (.O. / ..O / OOO), normalized and sorted by y then x.")

(defun %starts-with-p (prefix string)
  "True when STRING begins with PREFIX."
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun %ends-with-p (suffix string)
  "True when STRING ends with SUFFIX."
  (let ((start (- (length string) (length suffix))))
    (and (>= start 0) (string= suffix string :start2 start))))

(defun %split-lines (text)
  "TEXT split at newlines, without a trailing empty piece after a final newline."
  (let ((lines (uiop:split-string text :separator '(#\Newline))))
    (if (and lines (string= (car (last lines)) ""))
        (butlast lines)
        lines)))

(defun %pattern-world (name &rest make-world-keys)
  "A fresh world made with MAKE-WORLD-KEYS (the plane by default) holding the library pattern
NAME with its top-left cell at (0,0)."
  (let ((w (apply #'make-world make-world-keys)))
    (place w name :x 0 :y 0)
    w))

(defun %shift-after-steps (world n)
  "Step a copy of WORLD N times. Returns (values dx dy translated-p): the displacement of the
bounding box's top-left corner and whether the live cells are then exactly the start cells
shifted by (dx, dy)."
  (let* ((start (live-cells world))
         (copy (copy-world world)))
    (step-world copy n)
    (multiple-value-bind (x0 y0) (bounding-box world)
      (multiple-value-bind (x1 y1) (bounding-box copy)
        (let ((dx (- x1 x0)) (dy (- y1 y0)))
          (values dx dy
                  (equal (live-cells copy)
                         (mapcar (lambda (c) (cons (+ (car c) dx) (+ (cdr c) dy))) start))))))))

;;;; src/cli.lisp — argument parsing, usage, summary-line, main, main-entry (DESIGN.md §4.10).
;;;;
;;;; MAIN turns a list of argument strings into an exit code and never exits the process; it
;;;; prints to *STANDARD-OUTPUT* and *ERROR-OUTPUT* so tests can capture it. MAIN-ENTRY is the
;;;; executable's entry point and the only place that exits.

(in-package :game-of-life)

(%muffle-compiler-notes)

(defparameter *version* "0.1.0"
  "The version printed by --version.")

;;; ---- Usage ---------------------------------------------------------------------------------

(defparameter *cli-usage-text*
  "Usage: life [options] [PATTERN]

Conway's Game of Life in the terminal. PATTERN is a built-in name (see --list) or a
path to an RLE, plaintext or Life 1.06 file. Without a PATTERN a random soup is run.

Options:
  -r, --rule RULE         rulestring (B3/S23, 23/3, B36/S23) or name (life, highlife, seeds, ...)
  -t, --topology T        plane, torus or box (default: plane for a pattern, torus for a soup)
  -W, --width N           world width in cells (torus/box) or viewport width (plane)
  -H, --height N          world/viewport height in cells (defaults: the terminal)
  -d, --density F         soup density, 0..1 (default 0.3)
  -s, --seed N            soup seed (default: from the clock; shown in the status line)
  -g, --generations N     stop after N generations
  -f, --fps N             generations per second (default 20)
      --ascii             draw with # and space instead of half-block characters
      --dots              draw with O and . (the plaintext look)
      --follow            keep the viewport centered on the live cells (plane only)
      --stop-when-stable  stop when the world repeats itself or dies out
      --headless          no display: run, then print one summary line (implies --stop-when-stable;
                          --generations defaults to 1000)
      --write FILE        after the run, write the world to FILE as RLE
  -l, --list              list the built-in patterns and exit
      --show PATTERN      print a pattern as plaintext and exit
  -h, --help              this text
      --version           print the version

Keys: space pause, n step, +/- speed, f follow, r reseed, c clear, q quit.
"
  "The help text printed by USAGE.")

(defun usage (&optional (stream *standard-output*))
  "Prints the help text (every option, the keys) to STREAM."
  (write-string *cli-usage-text* stream)
  nil)

;;; ---- Argument parsing ----------------------------------------------------------------------

(defparameter *cli-options*
  '((("-r" "--rule")        :rule             :string)
    (("-t" "--topology")    :topology         :topology)
    (("-W" "--width")       :width            :positive-integer)
    (("-H" "--height")      :height           :positive-integer)
    (("-d" "--density")     :density          :density)
    (("-s" "--seed")        :seed             :integer)
    (("-g" "--generations") :generations      :natural)
    (("-f" "--fps")         :fps              :positive-real)
    (("--write")            :write            :string)
    (("--show")             :show             :string)
    (("--ascii")            :style            :ascii)
    (("--dots")             :style            :dots)
    (("--follow")           :follow           :flag)
    (("--stop-when-stable") :stop-when-stable :flag)
    (("--headless")         :headless         :flag)
    (("-l" "--list")        :list             :flag)
    (("-h" "--help")        :help             :flag)
    (("--version")          :version          :flag))
  "The command line options: (names key kind). KIND :flag, :ascii and :dots take no value and
store T, :ascii or :dots; the other kinds take a value and say how it is checked.")

(defun %cli-digits-p (string)
  "True when STRING is one or more ASCII digits."
  (and (plusp (length string))
       (every (lambda (c) (char<= #\0 c #\9)) string)))

(defun %parse-integer (string)
  "STRING as an integer (an optional sign, then digits), or NIL when it is anything else."
  (let ((start (if (and (plusp (length string)) (find (char string 0) "+-")) 1 0)))
    (and (%cli-digits-p (subseq string start))
         (parse-integer string))))

(defun %parse-real (string)
  "STRING as a non-negative number: digits with at most one period. An integer when there is no
period, else a double-float. NIL when STRING is anything else."
  (let ((dot (position #\. string)))
    (if (null dot)
        (and (%cli-digits-p string) (parse-integer string))
        (let ((whole (subseq string 0 dot))
              (fraction (subseq string (1+ dot))))
          (and (every (lambda (c) (char<= #\0 c #\9)) whole)
               (every (lambda (c) (char<= #\0 c #\9)) fraction)
               (plusp (+ (length whole) (length fraction)))
               (coerce (+ (if (plusp (length whole)) (parse-integer whole) 0)
                          (if (plusp (length fraction))
                              (/ (parse-integer fraction) (expt 10 (length fraction)))
                              0))
                       'double-float))))))

(defun %cli-option-value (name kind text)
  "TEXT, the value given for option NAME, converted and checked according to KIND; signals
USAGE-ERROR when it is malformed or out of range."
  (flet ((bad () (%usage-error "invalid value for ~A: ~S" name text)))
    (ecase kind
      (:string text)
      (:topology
       (cond ((string-equal text "plane") :plane)
             ((string-equal text "torus") :torus)
             ((string-equal text "box") :box)
             (t (bad))))
      (:positive-integer
       (let ((n (%parse-integer text)))
         (if (and n (plusp n)) n (bad))))
      (:integer
       (or (%parse-integer text) (bad)))
      (:natural
       (let ((n (%parse-integer text)))
         (if (and n (>= n 0)) n (bad))))
      (:density
       (let ((d (%parse-real text)))
         (if (and d (<= 0 d 1)) d (bad))))
      (:positive-real
       (let ((f (%parse-real text)))
         (if (and f (plusp f)) f (bad)))))))

(defun %cli-find-option (name)
  "The (names key kind) entry of *CLI-OPTIONS* for the option NAME (dashes included), or NIL."
  (find-if (lambda (entry) (member name (first entry) :test #'string=)) *cli-options*))

(defun parse-arguments (args)
  "Parses the list of argument strings ARGS into a property list with the keys :pattern, :rule,
:topology, :width, :height, :density, :seed, :generations, :fps, :style, :follow,
:stop-when-stable, :headless, :list, :help, :version, :write and :show (an option not given is
absent). `--opt value` and `--opt=value` both work, short options take the next argument, `--`
ends the options, `random` and `soup` as the pattern mean a soup (:pattern NIL). An unknown
option, a second positional, a missing or malformed value signals USAGE-ERROR."
  (let ((options '())
        (positional nil)
        (rest args))
    (labels ((store (key value)
               (setf (getf options key) value))
             (take-positional (arg)
               (when positional
                 (%usage-error "unexpected argument ~S (PATTERN is ~S already)" arg positional))
               (setf positional arg)
               (store :pattern (if (member arg '("random" "soup") :test #'string=) nil arg)))
             (take-option (arg)
               (let* ((equals (and (> (length arg) 2) (string= "--" arg :end2 2)
                                   (position #\= arg)))
                      (name (if equals (subseq arg 0 equals) arg))
                      (inline-value (and equals (subseq arg (1+ equals))))
                      (entry (or (%cli-find-option name)
                                 (%usage-error "unknown option ~S" name)))
                      (key (second entry))
                      (kind (third entry)))
                 (case kind
                   ((:flag :ascii :dots)
                    (when inline-value
                      (%usage-error "option ~A does not take a value" name))
                    (store key (if (eq kind :flag) t kind)))
                   (t
                    (let ((text (cond (inline-value)
                                      (rest (pop rest))
                                      (t (%usage-error "option ~A needs a value" name)))))
                      (store key (%cli-option-value name kind text))))))))
      (loop while rest
            do (let ((arg (pop rest)))
                 (cond ((string= arg "--")
                        (dolist (tail rest) (take-positional tail))
                        (setf rest nil))
                       ((and (> (length arg) 1) (char= (char arg 0) #\-))
                        (take-option arg))
                       (t (take-positional arg))))))
    options))

;;; ---- Summary -------------------------------------------------------------------------------

(defun summary-line (name world outcome period)
  "The one-line report of a run: \"NAME: generation G, population P\" for :limit (with \" (quit)\"
or \" (interrupted)\" appended for those outcomes), \"NAME: extinct at generation G\" for
:extinct, \"NAME: period PERIOD detected at generation G, population P\" for :periodic."
  (let ((generation (world-generation world))
        (count (population world)))
    (ecase outcome
      (:limit (format nil "~A: generation ~D, population ~D" name generation count))
      (:extinct (format nil "~A: extinct at generation ~D" name generation))
      (:periodic (format nil "~A: period ~D detected at generation ~D, population ~D"
                         name period generation count))
      (:quit (format nil "~A: generation ~D, population ~D (quit)" name generation count))
      (:interrupted (format nil "~A: generation ~D, population ~D (interrupted)"
                            name generation count)))))

;;; ---- Main ----------------------------------------------------------------------------------

(defun %cli-category-text (category)
  "A pattern category keyword as words: :still-life -> \"still life\"."
  (substitute #\Space #\- (string-downcase (symbol-name category))))

(defun %cli-show-pattern (name &optional (stream *standard-output*))
  "Prints the pattern NAME (a built-in or a file) for --show: one header line, then the rows as
WRITE-PLAINTEXT writes them, without the metadata lines."
  (let* ((entry (find-pattern-entry name))
         (pat (pattern name))
         (cells (pattern-population pat)))
    (if entry
        (format stream "~A (~A~@[, period ~D~], ~D cells)~%"
                (pattern-entry-name entry) (%cli-category-text (pattern-entry-category entry))
                (pattern-entry-period entry) cells)
        (format stream "~A (~D cells)~%" (or (pattern-name pat) name) cells))
    (with-input-from-string (in (write-plaintext pat nil))
      (loop for line = (read-line in nil)
            while line
            unless (and (plusp (length line)) (char= (char line 0) #\!))
              do (write-line line stream)))
    nil))

(defun %cli-viewport-cells (options style)
  "(values columns rows) of the viewport in cells: --width and --height, else the terminal's
columns and its rows minus the status line, multiplied by the cell rows per line of STYLE."
  (let ((width (getf options :width))
        (height (getf options :height)))
    (if (and width height)
        (values width height)
        (multiple-value-bind (columns rows) (terminal-size)
          (values (or width (max 1 columns))
                  (or height (max 1 (* (1- rows) (cells-per-row style)))))))))

(defun %cli-run (options)
  "Steps 2-6 of MAIN: builds the world from OPTIONS, runs it headless or interactively, prints the
summary line and writes the --write file. Returns 0."
  (let* ((pattern-name (getf options :pattern))
         (pat (and pattern-name (pattern pattern-name)))
         (rule (cond ((getf options :rule) (parse-rule (getf options :rule)))
                     ((and pat (pattern-rule pat)) (pattern-rule pat))
                     (t *life-rule*)))
         (headless (getf options :headless))
         (style (cond ((getf options :style))
                      ((utf8-output-p) :blocks)
                      (t :ascii)))
         (topology (or (getf options :topology) (if pat :plane :torus)))
         (plane (eq topology :plane))
         (density (or (getf options :density) 0.3))
         (seed nil)
         (reset nil)
         (name nil))
    (multiple-value-bind (columns rows) (%cli-viewport-cells options style)
      (let* ((world (if plane
                        (make-world :rule rule)
                        (make-world :rule rule :topology topology :width columns :height rows)))
             (viewport (default-viewport world columns rows)))
        (cond (pat
               (when (and (not plane)
                          (or (> (pattern-width pat) columns) (> (pattern-height pat) rows)))
                 (%life-error "pattern ~Dx~D does not fit the ~Dx~D ~(~A~) ~
                               (use --width/--height or -t plane)"
                              (pattern-width pat) (pattern-height pat) columns rows topology))
               (place world pat)
               (setf name (or (pattern-name pat) pattern-name)))
              (t
               (let ((x (viewport-x viewport))
                     (y (viewport-y viewport)))
                 (setf seed (randomize world :density density :seed (getf options :seed)
                                             :x x :y y :width columns :height rows))
                 (setf reset (lambda (w)
                               (clear-world w)
                               (setf seed (randomize w :density density
                                                       :x x :y y :width columns :height rows)))))))
        (multiple-value-bind (outcome period)
            (if headless
                (simulate world :generations (or (getf options :generations) 1000)
                                :stop-when-stable t)
                (run world :generations (getf options :generations)
                           :fps (or (getf options :fps) 20)
                           :style style
                           :viewport viewport
                           :follow (and plane (getf options :follow))
                           :stop-when-stable (getf options :stop-when-stable)
                           :reset reset
                           :seed seed))
          (let ((name (or name (format nil "soup ~Dx~D density ~,2F seed ~D"
                                       columns rows density seed))))
            (format t "~A~%" (summary-line name world outcome period))
            (let ((file (getf options :write)))
              (when file
                (write-pattern-file (pattern-from-world world :name name) file)))))
        0))))

(defun main (args)
  "The command: ARGS is the list of argument strings. Returns the exit code, never exits: 0 when
all went well, 1 for a LIFE-ERROR or any other error (\"life: <message>\" on *ERROR-OUTPUT*),
2 for a USAGE-ERROR (the message and \"Try 'life --help'.\"), 130 when Ctrl-C interrupted the
run (\"life: interrupted\")."
  (handler-case
      (let ((options (parse-arguments args)))
        (cond ((getf options :help) (usage) 0)
              ((getf options :version) (format t "life ~A~%" *version*) 0)
              ((getf options :list) (print-pattern-list) 0)
              ((getf options :show) (%cli-show-pattern (getf options :show)) 0)
              (t (%catch-interrupt (%cli-run options)
                   (format *error-output* "life: interrupted~%")
                   130))))
    (usage-error (e)
      (format *error-output* "life: ~A~%Try 'life --help'.~%" e)
      2)
    (life-error (e)
      (format *error-output* "life: ~A~%" e)
      1)
    (error (e)
      (format *error-output* "life: ~A~%" e)
      1)))

(defun main-entry ()
  "The executable's entry point: runs MAIN on the command line arguments, flushes the output
streams and exits the process with the code MAIN returned."
  (let ((code (main (%command-line-arguments))))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    (%exit code)))

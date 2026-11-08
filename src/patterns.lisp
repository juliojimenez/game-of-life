;;;; src/patterns.lisp — the built-in pattern library: drawings in plaintext, lookup by name, the
;;;; listing (DESIGN.md §4.6).

(in-package :game-of-life)

(defstruct (pattern-entry (:copier nil))
  "A library entry: KEY (kebab-case, what the command line takes), display NAME, CATEGORY
(:still-life :oscillator :spaceship :methuselah :gun), PERIOD (integer or NIL), a one-sentence
DESCRIPTION, the plaintext drawing TEXT and the PARSED pattern once it has been asked for."
  (key "" :type string)
  (name "" :type string)
  (category :still-life)
  (period nil)
  (description "" :type string)
  (text "" :type string)
  (parsed nil))

(defvar *pattern-entries* '()
  "The built-in library in definition order (a list of PATTERN-ENTRY).")

(defun %register-pattern (key name category period description text)
  "Add an entry at the end of the library, or replace the entry with the same KEY in place."
  (let ((entry (make-pattern-entry :key key :name name :category category :period period
                                   :description description :text text))
        (existing (find key *pattern-entries* :key #'pattern-entry-key :test #'string=)))
    (if existing
        (setf *pattern-entries* (substitute entry existing *pattern-entries*))
        (setf *pattern-entries* (append *pattern-entries* (list entry))))
    entry))

(defmacro define-pattern (key name category period description text)
  "Register (or replace, by KEY) a built-in pattern at the end of the library. CATEGORY is one of
:still-life :oscillator :spaceship :methuselah :gun; PERIOD an integer or NIL; TEXT the plaintext
drawing (O alive, . dead): one string, or a list of row strings joined with newlines."
  `(%register-pattern ,key ,name ,category ,period ,description
                      ,(if (stringp text) text (format nil "~{~A~^~%~}" text))))

(defun find-pattern-entry (name)
  "The library entry whose key is NAME (a string or symbol; case-insensitive, with -, _ and space
interchangeable), or NIL."
  (let ((key (%normalize-name (string name))))
    (find key *pattern-entries* :key #'pattern-entry-key :test #'string=)))

(defun list-patterns ()
  "The library entries in order (a fresh list)."
  (copy-list *pattern-entries*))

(defun %entry-pattern (entry)
  "The pattern of the library ENTRY, parsed from its drawing on first use and cached."
  (or (pattern-entry-parsed entry)
      (setf (pattern-entry-parsed entry)
            (%rename-pattern (parse-plaintext (pattern-entry-text entry))
                             (pattern-entry-name entry)))))

(defun %category-word (category)
  "The category keyword as words: still life, oscillator, spaceship, methuselah, gun."
  (substitute #\Space #\- (string-downcase (symbol-name category))))

(defun print-pattern-list (&optional (stream *standard-output*))
  "Print one line per library entry: key, category, period, cells, description."
  (dolist (entry *pattern-entries*)
    (format stream "~20A ~11A ~10A ~9A ~A~%"
            (pattern-entry-key entry)
            (%category-word (pattern-entry-category entry))
            (if (pattern-entry-period entry)
                (format nil "period ~D" (pattern-entry-period entry))
                "-")
            (format nil "~D cells" (pattern-population (%entry-pattern entry)))
            (pattern-entry-description entry)))
  (values))

(defun pattern (designator)
  "The pattern DESIGNATOR names: a PATTERN is returned as is; a pathname is read with
READ-PATTERN-FILE; a string or symbol names a library entry, else an existing file; anything else
signals UNKNOWN-PATTERN-ERROR."
  (cond ((pattern-p designator) designator)
        ((pathnamep designator) (read-pattern-file designator))
        ((or (stringp designator) (symbolp designator))
         (let ((entry (find-pattern-entry designator)))
           (cond (entry (%entry-pattern entry))
                 ((and (stringp designator) (uiop:file-exists-p designator))
                  (read-pattern-file (pathname designator)))
                 (t (error 'unknown-pattern-error :name (string designator))))))
        (t (error 'unknown-pattern-error :name (princ-to-string designator)))))

;;; ------------------------------------------------------------------------------------------
;;; The library (DESIGN.md §4.6; every drawing is checked by the tests in §5.4)
;;; ------------------------------------------------------------------------------------------

;;; Still lifes

(define-pattern "block" "Block" :still-life 1
  "The most common still life: a two-by-two square."
  ("OO"
   "OO"))

(define-pattern "beehive" "Beehive" :still-life 1
  "A six-cell still life shaped like a hexagon."
  (".OO."
   "O..O"
   ".OO."))

(define-pattern "loaf" "Loaf" :still-life 1
  "A seven-cell still life, the beehive with a bump."
  (".OO."
   "O..O"
   ".O.O"
   "..O."))

(define-pattern "boat" "Boat" :still-life 1
  "A five-cell still life, the tub with one corner filled."
  ("OO."
   "O.O"
   ".O."))

(define-pattern "tub" "Tub" :still-life 1
  "A four-cell diamond-shaped still life."
  (".O."
   "O.O"
   ".O."))

(define-pattern "ship" "Ship" :still-life 1
  "A six-cell still life: two opposite corners of a three-by-three square."
  ("OO."
   "O.O"
   ".OO"))

(define-pattern "pond" "Pond" :still-life 1
  "An eight-cell still life, the beehive stretched into a ring."
  (".OO."
   "O..O"
   "O..O"
   ".OO."))

;;; Oscillators

(define-pattern "blinker" "Blinker" :oscillator 2
  "The most common oscillator: three cells that flip between horizontal and vertical."
  ("OOO"))

(define-pattern "toad" "Toad" :oscillator 2
  "A period-2 oscillator of two offset rows of three."
  (".OOO"
   "OOO."))

(define-pattern "beacon" "Beacon" :oscillator 2
  "A period-2 oscillator of two blocks touching at a corner."
  ("OO.."
   "O..."
   "...O"
   "..OO"))

(define-pattern "clock" "Clock" :oscillator 2
  "A six-cell period-2 oscillator shaped like a clock face."
  ("..O."
   "O.O."
   ".O.O"
   ".O.."))

(define-pattern "figure-eight" "Figure eight" :oscillator 8
  "A period-8 oscillator of two three-by-three blocks touching at a corner."
  ("OOO..."
   "OOO..."
   "OOO..."
   "...OOO"
   "...OOO"
   "...OOO"))

(define-pattern "pentadecathlon" "Pentadecathlon" :oscillator 15
  "A row of ten cells that oscillates with period 15."
  ("..O....O.."
   "OO.OOOO.OO"
   "..O....O.."))

(define-pattern "pulsar" "Pulsar" :oscillator 3
  "The most common period-3 oscillator: 48 cells with fourfold symmetry."
  ("..OOO...OOO.."
   "............."
   "O....O.O....O"
   "O....O.O....O"
   "O....O.O....O"
   "..OOO...OOO.."
   "............."
   "..OOO...OOO.."
   "O....O.O....O"
   "O....O.O....O"
   "O....O.O....O"
   "............."
   "..OOO...OOO.."))

(define-pattern "galaxy" "Kok's galaxy" :oscillator 8
  "Kok's galaxy, a period-8 oscillator whose arms seem to rotate."
  ("OOOOOO.OO"
   "OOOOOO.OO"
   ".......OO"
   "OO.....OO"
   "OO.....OO"
   "OO.....OO"
   "OO......."
   "OO.OOOOOO"
   "OO.OOOOOO"))

(define-pattern "tumbler" "Tumbler" :oscillator 14
  "A period-14 oscillator that turns upside down and back."
  (".O.....O."
   "O.O...O.O"
   "O..O.O..O"
   "..O...O.."
   "..OO.OO.."))

;;; Spaceships

(define-pattern "glider" "Glider" :spaceship 4
  "The smallest spaceship; moves one cell diagonally every four generations."
  (".O."
   "..O"
   "OOO"))

(define-pattern "lwss" "Lightweight spaceship" :spaceship 4
  "The lightweight spaceship; moves two cells sideways every four generations."
  (".O..O"
   "O...."
   "O...O"
   "OOOO."))

(define-pattern "mwss" "Middleweight spaceship" :spaceship 4
  "The middleweight spaceship, the lightweight one with an extra cell."
  ("...O.."
   ".O...O"
   "O....."
   "O....O"
   "OOOOO."))

(define-pattern "hwss" "Heavyweight spaceship" :spaceship 4
  "The heavyweight spaceship, the largest of the three standard spaceships."
  ("...OO.."
   ".O....O"
   "O......"
   "O.....O"
   "OOOOOO."))

;;; Methuselahs

(define-pattern "r-pentomino" "R-pentomino" :methuselah nil
  "Five cells that evolve for 1103 generations before settling at 116 cells."
  (".OO"
   "OO."
   ".O."))

(define-pattern "diehard" "Diehard" :methuselah nil
  "Seven cells that vanish completely after 130 generations."
  ("......O."
   "OO......"
   ".O...OOO"))

(define-pattern "acorn" "Acorn" :methuselah nil
  "Seven cells that grow for 5206 generations and settle at 633 cells."
  (".O....."
   "...O..."
   "OO..OOO"))

;;; Guns

(define-pattern "gosper-glider-gun" "Gosper glider gun" :gun 30
  "The first known gun; emits a glider every 30 generations."
  ("........................O..........."
   "......................O.O..........."
   "............OO......OO............OO"
   "...........O...O....OO............OO"
   "OO........O.....O...OO.............."
   "OO........O...O.OO....O.O..........."
   "..........O.....O.......O..........."
   "...........O...O...................."
   "............OO......................"))

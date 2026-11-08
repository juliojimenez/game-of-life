;;;; tests/test-formats.lisp — tests for src/formats.lisp: patterns, RLE, plaintext, Life 1.06
;;;; (DESIGN.md §5.5).

(in-package :game-of-life-test)

(defparameter *glider-comment*
  (concatenate 'string "The smallest, most common, and first discovered spaceship."
               " Diagonal, has period 4 and speed c/4.")
  "The long #C comment of the LifeWiki glider file (built in two pieces to keep lines short).")

(defparameter *glider-rle-lines*
  (list "#N Glider"
        "#O Richard K. Guy"
        (concatenate 'string "#C " *glider-comment*)
        "#C www.conwaylife.com/wiki/index.php?title=Glider"
        "x = 3, y = 3, rule = B3/S23"
        "bob$2bo$3o!")
  "The LifeWiki / Golly glider file, line by line (DESIGN.md §5.5).")

(defun %lines (strings)
  "STRINGS joined, each followed by a newline."
  (format nil "~{~A~%~}" strings))

(defun %syntax-error-line (thunk)
  "Call THUNK; return the PATTERN-SYNTAX-ERROR-LINE of the pattern-syntax-error it signals, or
:NO-ERROR when it returns normally."
  (handler-case (progn (funcall thunk) :no-error)
    (pattern-syntax-error (e) (pattern-syntax-error-line e))))

(deftest formats/make-pattern-normalizes
  (let ((p (make-pattern '((12 . 22) (11 . 20) (10 . 22) (12 . 21) (11 . 22) (11 . 20) (12 . 22)))))
    (is (pattern-p p))
    (is-equal *glider-cells* (pattern-cells p))
    (is-equal 3 (pattern-width p))
    (is-equal 3 (pattern-height p))
    (is-equal 5 (pattern-population p))
    (is-equal nil (pattern-name p))
    (is-equal nil (pattern-rule p))
    (is-equal '() (pattern-comments p))
    (is (pattern-equal p (pattern "glider"))))
  (let ((p (make-pattern '((-4 . 9)) :name "Dot" :rule (parse-rule "highlife")
                                     :comments '("c1" "c2"))))
    (is-equal '((0 . 0)) (pattern-cells p))
    (is-equal 1 (pattern-width p))
    (is-equal 1 (pattern-height p))
    (is-equal "Dot" (pattern-name p))
    (is-equal "B36/S23" (rule-string (pattern-rule p)))
    (is-equal '("c1" "c2") (pattern-comments p)))
  (let ((e (make-pattern '())))
    (is-equal 0 (pattern-width e))
    (is-equal 0 (pattern-height e))
    (is-equal 0 (pattern-population e))
    (is-equal '() (pattern-cells e))
    (is (pattern-equal e (make-pattern '()))))
  (let ((p (make-pattern '((5 . 0) (0 . 3)))))     ; 6 wide, 4 tall
    (is-equal 6 (pattern-width p))
    (is-equal 4 (pattern-height p))
    (is-equal '((5 . 0) (0 . 3)) (pattern-cells p)))
  ;; pattern-equal ignores names, rules and comments
  (is (pattern-equal (make-pattern *glider-cells* :name "A" :rule (parse-rule "seeds"))
                     (make-pattern (reverse *glider-cells*) :name "B" :comments '("x"))))
  (is (not (pattern-equal (make-pattern *glider-cells*) (make-pattern '((0 . 0))))))
  (let ((s (princ-to-string (pattern "glider"))))
    (is (search "Glider" s))
    (is (search "3x3" s))
    (is (search "5 cells" s))))

(deftest formats/rle-glider
  (let ((p (parse-rle (%lines *glider-rle-lines*))))
    (is-equal "Glider" (pattern-name p))
    (is-equal (list "Richard K. Guy" *glider-comment*
                    "www.conwaylife.com/wiki/index.php?title=Glider")
              (pattern-comments p))
    (is (rule-p (pattern-rule p)))
    (is-equal "B3/S23" (rule-string (pattern-rule p)))
    (is-equal *glider-cells* (pattern-cells p))
    (is-equal 3 (pattern-width p))
    (is-equal 3 (pattern-height p))
    (is-equal 5 (pattern-population p))
    (is (pattern-equal p (pattern "glider")))
    (is-equal (%lines (list "#N Glider"
                            "#C Richard K. Guy"
                            (concatenate 'string "#C " *glider-comment*)
                            "#C www.conwaylife.com/wiki/index.php?title=Glider"
                            "x = 3, y = 3, rule = B3/S23"
                            "bo$2bo$3o!"))
              (write-rle p))
    (is-equal (write-rle p) (write-rle p nil))
    ;; destination T writes to *standard-output* and returns nil; a stream likewise
    (multiple-value-bind (value out err) (with-captured-output (o e) (write-rle p t))
      (is (null value))
      (is-equal (write-rle p) out)
      (is-equal "" err))
    (let ((s (make-string-output-stream)))
      (is (null (write-rle p s)))
      (is-equal (write-rle p) (get-output-stream-string s))))
  ;; the library glider writes the two-line body the design quotes
  (is-equal (format nil "#N Glider~%x = 3, y = 3, rule = B3/S23~%bo$2bo$3o!~%")
            (write-rle (pattern "glider")))
  (is-equal (format nil "x = 3, y = 3, rule = B3/S23~%bo$2bo$3o!~%")
            (write-rle (make-pattern *glider-cells*))))

(deftest formats/rle-round-trip
  (dolist (e (list-patterns))
    (let* ((key (pattern-entry-key e))
           (p (pattern key))
           (text (write-rle p))
           (back (parse-rle text)))
      (is (pattern-equal p back) "~A survives an RLE round trip" key)
      (is (equal (pattern-name p) (pattern-name back)) "~A keeps its name" key)
      (is (every (lambda (line) (<= (length line) 70)) (%split-lines text))
          "~A has no RLE line longer than 70 columns" key)
      (is (%ends-with-p (format nil "!~%") text) "~A ends with ! and a newline" key)))
  (let ((lines (%split-lines (write-rle (pattern "pulsar")))))
    (is-equal "#N Pulsar" (first lines))
    (is-equal "x = 13, y = 13, rule = B3/S23" (second lines))
    (is (<= 2 (length (cddr lines))) "the pulsar's data wraps to at least two lines")
    (is (every (lambda (l) (<= (length l) 70)) (cddr lines)))
    (is (%ends-with-p "!" (car (last lines))))
    (is-equal (concatenate 'string "2b3o3b3o2$o4bobo4bo$o4bobo4bo$o4bobo4bo$2b3o3b3o2$"
                           "2b3o3b3o$o4bobo4bo$o4bobo4bo$o4bobo4bo2$2b3o3b3o!")
              (apply #'concatenate 'string (cddr lines))))
  (let ((lines (%split-lines (write-rle (pattern "gosper-glider-gun")))))
    (is-equal "x = 36, y = 9, rule = B3/S23" (second lines))
    (is (every (lambda (l) (<= (length l) 70)) lines))))

(deftest formats/rle-edge-cases
  ;; no header, no !, no rule stated
  (is-equal *glider-cells* (pattern-cells (parse-rle "bo$2bo$3o!")))
  (is-equal *glider-cells* (pattern-cells (parse-rle "bo$2bo$3o")))
  (is-equal *glider-cells* (pattern-cells (parse-rle (format nil "x = 3, y = 3~%bo$2bo$3o"))))
  (is (null (pattern-rule (parse-rle "bo$2bo$3o!"))) "no rule stated means nil")
  (is (null (pattern-name (parse-rle "bo$2bo$3o!"))))
  (is-equal '() (pattern-comments (parse-rle "bo$2bo$3o!")))
  ;; multi-row $
  (let ((p (parse-rle "o3$o!")))
    (is-equal '((0 . 0) (0 . 3)) (pattern-cells p))
    (is-equal 1 (pattern-width p))
    (is-equal 4 (pattern-height p)))
  ;; the declared size is not the pattern's size: leading blank rows and columns vanish
  (let ((p (parse-rle (format nil "x = 10, y = 10~%2$3bo!"))))
    (is-equal '((0 . 0)) (pattern-cells p))
    (is-equal 1 (pattern-width p))
    (is-equal 1 (pattern-height p)))
  ;; CRLF
  (let ((p (parse-rle (format nil "#N G~C~%#C c~C~%x = 3, y = 3~C~%bo$2bo$3o!~C~%"
                              #\Return #\Return #\Return #\Return))))
    (is-equal "G" (pattern-name p))
    (is-equal '("c") (pattern-comments p))
    (is-equal *glider-cells* (pattern-cells p)))
  ;; rules in the header
  (is-equal "HighLife"
            (rule-nickname (pattern-rule
                            (parse-rle (format nil "x = 3, y = 3, rule = B36/S23~%bo$2bo$3o!")))))
  (let ((p (parse-rle (format nil "x = 3, y = 3, rule = LifeHistory~%bo$2bo$3o!"))))
    (is (null (pattern-rule p)) "an unknown rule is nil")
    (is (member "rule: LifeHistory" (pattern-comments p) :test #'string=)
        "the unknown rule is kept as a comment: ~S" (pattern-comments p))
    (is-equal *glider-cells* (pattern-cells p)))
  (is-equal "B3/S23"
            (rule-string (pattern-rule (parse-rle (format nil "x=3,y=3,rule=b3/s23~%3o!")))))
  (is-equal "B3/S23"
            (rule-string (pattern-rule
                          (parse-rle (format nil "X = 3 , Y = 3 , RULE = 23/3~%3o!")))))
  ;; a count before ! or the end is ignored; text after ! is ignored
  (is-equal 3 (pattern-population (parse-rle "3o2!")))
  (is-equal 3 (pattern-population (parse-rle "3o2")))
  (is-equal 3 (pattern-population (parse-rle "3o!garbage %%")))
  (is-equal 3 (pattern-population (parse-rle (format nil "3o!~%bo$2bo$3o!"))))
  ;; uppercase tags, dots, other letters as live cells, whitespace between tokens
  (is-equal *glider-cells* (pattern-cells (parse-rle "BO$2BO$3O!")))
  (is-equal *glider-cells* (pattern-cells (parse-rle ".o$..o$ooo!")))
  (is-equal *glider-cells* (pattern-cells (parse-rle "bA$2bC$3A!")))
  (is-equal *glider-cells* (pattern-cells (parse-rle (format nil "bo$2bo~%$3o!"))))
  (is-equal *glider-cells* (pattern-cells (parse-rle "bo $2bo $3o !")))
  (is-equal *glider-cells*
            (pattern-cells (parse-rle (format nil "x = 3, y = 3~%bo$~%2bo$~%3o!"))))
  ;; comments and other # lines
  (let ((p (parse-rle (format nil "#C one~%#c two~%#O three~%#P 0 0~%#N  Named ~%~A~%o!"
                              "x = 1, y = 1"))))
    (is-equal "Named" (pattern-name p))
    (is-equal '("one" "two" "three") (pattern-comments p))
    (is-equal '((0 . 0)) (pattern-cells p)))
  ;; errors carry the 1-based line
  (signals pattern-syntax-error (parse-rle "bo$2bo$3%!"))
  (is-equal 1 (%syntax-error-line (lambda () (parse-rle "bo$2bo$3%!"))))
  (is-equal 3 (%syntax-error-line
               (lambda () (parse-rle (format nil "#N x~%x = 3, y = 3~%bo$2bo$3%!")))))
  (is-equal 4 (%syntax-error-line
               (lambda () (parse-rle (format nil "#N x~%x = 3, y = 3~%bo$~%2bo$3%!")))))
  (let ((e (handler-case (progn (parse-rle "3%!") nil)
             (pattern-syntax-error (c) c))))
    (is (typep e 'life-error))
    (is (stringp (princ-to-string e))))
  ;; the empty pattern
  (is-equal (format nil "x = 0, y = 0, rule = B3/S23~%!~%") (write-rle (make-pattern '())))
  (is (pattern-equal (make-pattern '()) (parse-rle (write-rle (make-pattern '())))))
  (is-equal 0 (pattern-population (parse-rle "!")))
  (is-equal 0 (pattern-population (parse-rle (format nil "x = 0, y = 0, rule = B3/S23~%!~%"))))
  ;; writing: the pattern's rule, no count on runs of one, trailing dead cells omitted,
  ;; empty rows collapsed, one #C line per comment
  (is-equal (format nil "x = 3, y = 3, rule = B36/S23~%bo$2bo$3o!~%")
            (write-rle (make-pattern *glider-cells* :rule (parse-rule "highlife"))))
  (is-equal (format nil "x = 1, y = 4, rule = B3/S23~%o3$o!~%")
            (write-rle (make-pattern '((0 . 0) (0 . 3)))))
  (is-equal (format nil "x = 4, y = 2, rule = B3/S23~%o2bo$2o!~%")
            (write-rle (make-pattern '((0 . 0) (3 . 0) (0 . 1) (1 . 1)))))
  (is-equal (format nil "#C a~%#C b~%x = 2, y = 1, rule = B3/S23~%2o!~%")
            (write-rle (make-pattern '((0 . 0) (1 . 0)) :comments '("a" "b"))))
  ;; a long row wraps between tokens at 70 columns and reads back
  (let* ((cells (loop for x from 0 below 200 when (evenp x) collect (cons x 0)))
         (p (make-pattern cells))
         (text (write-rle p)))
    (is (every (lambda (l) (<= (length l) 70)) (%split-lines text)))
    (is (<= 2 (length (cddr (%split-lines text)))) "the 100-run row needs several lines")
    (is (pattern-equal p (parse-rle text)))))

(deftest formats/plaintext
  (let ((p (parse-plaintext (format nil "!Name: Glider~%!a comment~%.O.~%..O~%OOO~%"))))
    (is-equal "Glider" (pattern-name p))
    (is-equal '("a comment") (pattern-comments p))
    (is-equal *glider-cells* (pattern-cells p))
    (is-equal 3 (pattern-width p))
    (is-equal 3 (pattern-height p))
    (is (null (pattern-rule p))))
  (is-equal "Foo" (pattern-name (parse-plaintext (format nil "!name: Foo~%O"))))
  (is-equal "Foo" (pattern-name (parse-plaintext (format nil "!NAME:  Foo  ~%O"))))
  (is (null (pattern-name (parse-plaintext "O"))))
  (is-equal '("Author: me" "second") (pattern-comments (parse-plaintext
                                                        (format nil "!Author: me~%! second ~%O"))))
  ;; ragged rows, blank lines, every dead character, odd live characters, a final line
  ;; without a newline, CRLF
  (let ((p (parse-plaintext (format nil "O~%..O~%"))))
    (is-equal '((0 . 0) (2 . 1)) (pattern-cells p))
    (is-equal 3 (pattern-width p))
    (is-equal 2 (pattern-height p)))
  (let ((p (parse-plaintext (format nil "O~%~%O"))))
    (is-equal '((0 . 0) (0 . 2)) (pattern-cells p))
    (is-equal 3 (pattern-height p)))
  (is-equal '((0 . 0) (5 . 0)) (pattern-cells (parse-plaintext "O-0 .O")))
  (is-equal *glider-cells* (pattern-cells (parse-plaintext (format nil ".*.~%..#~%*#*"))))
  (is-equal *glider-cells* (pattern-cells (parse-plaintext (format nil ".O.~%..O~%OOO"))))
  (is-equal *glider-cells*
            (pattern-cells (parse-plaintext (format nil ".O.~C~%..O~C~%OOO~C~%"
                                                    #\Return #\Return #\Return))))
  ;; leading blank rows and columns normalize away
  (is-equal *glider-cells* (pattern-cells (parse-plaintext (format nil "~%..O.~%...O~%.OOO~%"))))
  (is-equal 0 (pattern-population (parse-plaintext "")))
  (is-equal 0 (pattern-population (parse-plaintext (format nil "!Name: Empty~%"))))
  ;; round trip for every library pattern
  (dolist (e (list-patterns))
    (let* ((key (pattern-entry-key e))
           (p (pattern key))
           (back (parse-plaintext (write-plaintext p))))
      (is (pattern-equal p back) "~A survives a plaintext round trip" key)
      (is (equal (pattern-name p) (pattern-name back)) "~A keeps its name" key)))
  ;; exact output
  (is-equal (format nil "!Name: Glider~%.O.~%..O~%OOO~%") (write-plaintext (pattern "glider")))
  (is-equal (format nil ".O.~%..O~%OOO~%") (write-plaintext (make-pattern *glider-cells*)))
  (is-equal (format nil "!Name: G~%!c1~%!c2~%O.~%.O~%")
            (write-plaintext (make-pattern '((0 . 0) (1 . 1)) :name "G" :comments '("c1" "c2"))))
  (is-equal (format nil "O...~%....~%....~%...O~%")
            (write-plaintext (make-pattern '((0 . 0) (3 . 3)))))
  (is-equal "" (write-plaintext (make-pattern '())))
  (is-equal (format nil "!Name: E~%") (write-plaintext (make-pattern '() :name "E")))
  ;; destinations
  (multiple-value-bind (value out err)
      (with-captured-output (o e) (write-plaintext (pattern "glider") t))
    (is (null value))
    (is-equal (format nil "!Name: Glider~%.O.~%..O~%OOO~%") out)
    (is-equal "" err))
  (let ((s (make-string-output-stream)))
    (is (null (write-plaintext (pattern "glider") s)))
    (is-equal (format nil "!Name: Glider~%.O.~%..O~%OOO~%") (get-output-stream-string s))))

(deftest formats/life106
  (let ((p (parse-life106 (format nil "#Life 1.06~%-1 -1~%0 0~%-2 1~%-1 1~%0 1~%"))))
    (is (pattern-p p))
    (is-equal *glider-cells* (pattern-cells p))
    (is (null (pattern-name p)))
    (is (null (pattern-rule p)))
    (is (pattern-equal p (pattern "glider"))))
  ;; # lines, blank lines, tabs, extra spaces, CRLF and a last line without a newline
  (let ((p (parse-life106 (format nil "#Life 1.06~C~%# a comment~%~%3~C4~%  5 6  ~%7 7"
                                  #\Return #\Tab))))
    (is-equal '((0 . 0) (2 . 2) (4 . 3)) (pattern-cells p)))
  (is-equal 0 (pattern-population (parse-life106 (format nil "#Life 1.06~%"))))
  (is-equal '((0 . 0)) (pattern-cells (parse-life106 (format nil "#Life 1.06~%10 10~%10 10~%"))))
  (signals pattern-syntax-error (parse-life106 (format nil "#Life 1.06~%1 2~%foo bar~%")))
  (is-equal 3 (%syntax-error-line
               (lambda () (parse-life106 (format nil "#Life 1.06~%1 2~%foo bar~%")))))
  (signals pattern-syntax-error (parse-life106 (format nil "#Life 1.06~%1~%")))
  (signals pattern-syntax-error (parse-life106 (format nil "#Life 1.06~%1 2 3~%")))
  (signals pattern-syntax-error (parse-life106 (format nil "#Life 1.06~%1.5 2~%"))))

(deftest formats/detect
  (let ((rle (format nil "x = 3, y = 3, rule = B3/S23~%bo$2bo$3o!~%"))
        (bare-rle "bo$2bo$3o!")
        (cells (format nil ".O.~%..O~%OOO~%"))
        (named-cells (format nil "!Name: Glider~%.O.~%..O~%OOO~%"))
        (lif (format nil "#Life 1.06~%1 0~%2 1~%0 2~%1 2~%2 2~%")))
    (dolist (text (list rle bare-rle cells named-cells lif))
      (is (pattern-equal (pattern "glider") (parse-pattern text)) "detects ~S" text))
    (is-equal "Glider" (pattern-name (parse-pattern named-cells)))
    (is-equal "B3/S23" (rule-string (pattern-rule (parse-pattern rle))))
    (is (pattern-equal (pattern "glider") (parse-pattern rle :format :rle)))
    (is (pattern-equal (pattern "glider") (parse-pattern cells :format :plaintext)))
    (is (pattern-equal (pattern "glider") (parse-pattern lif :format :life106)))
    (is (pattern-equal (pattern "glider") (parse-pattern bare-rle :format nil)))
    ;; a drawing of O and . with no ! is plaintext, not RLE; a header with spaces is RLE
    (is (pattern-equal (pattern "glider") (parse-pattern (format nil ".O.~%..O~%OOO"))))
    (is (pattern-equal (pattern "glider") (parse-pattern (format nil "#N G~%x=3,y=3~%bo$2bo$3o!"))))
    (is-equal "G" (pattern-name (parse-pattern (format nil "#N G~%x=3,y=3~%bo$2bo$3o!"))))
    ;; the chosen format's errors propagate
    (signals pattern-syntax-error (parse-pattern (format nil "#Life 1.06~%foo~%")))
    (signals pattern-syntax-error (parse-pattern (format nil "x = 3, y = 3~%bo$2bo$3%!")))
    ;; files
    (let ((rle-file (temp-file "glider.rle"))
          (cells-file (temp-file "glider.cells"))
          (lif-file (temp-file "g106.lif"))
          (anon-file (temp-file "myglider.rle")))
      (is (null (probe-file rle-file)) "temp-file names a file that does not exist yet")
      (write-pattern-file (pattern "glider") rle-file)
      (write-pattern-file (pattern "glider") cells-file :format :plaintext)
      (with-open-file (s lif-file :direction :output :if-exists :supersede)
        (write-string lif s))
      (with-open-file (s anon-file :direction :output :if-exists :supersede)
        (write-string bare-rle s))
      (is (probe-file rle-file))
      (is (%starts-with-p "#N Glider" (uiop:read-file-string rle-file)))
      (is-equal (write-rle (pattern "glider")) (uiop:read-file-string rle-file))
      (is-equal (write-plaintext (pattern "glider")) (uiop:read-file-string cells-file))
      (dolist (f (list rle-file cells-file lif-file anon-file))
        (is (pattern-equal (pattern "glider") (read-pattern-file f)) "reads ~A" f))
      (is-equal "Glider" (pattern-name (read-pattern-file rle-file)))
      (is-equal "Glider" (pattern-name (read-pattern-file cells-file)))
      (is-equal "g106" (pattern-name (read-pattern-file lif-file)))
      (is-equal "myglider" (pattern-name (read-pattern-file anon-file)))
      (is (pattern-equal (pattern "glider") (read-pattern-file rle-file :format :rle)))
      (is (pattern-equal (pattern "glider") (read-pattern-file cells-file :format :plaintext)))
      (is (pattern-equal (pattern "glider") (read-pattern-file lif-file :format :life106)))
      (is (pattern-equal (pattern "glider") (read-pattern-file (namestring rle-file))))
      ;; pattern resolves a pathname and a file name string
      (is (pattern-equal (pattern "glider") (pattern rle-file)))
      (is (pattern-equal (pattern "glider") (pattern (namestring rle-file))))
      (is-equal "myglider" (pattern-name (pattern (namestring anon-file))))
      ;; :if-exists :supersede by default, :error signals; a nameless plaintext has no header
      (write-pattern-file (make-pattern *glider-cells*) cells-file :format :plaintext)
      (is-equal (format nil ".O.~%..O~%OOO~%") (uiop:read-file-string cells-file))
      (is-equal "glider" (pattern-name (read-pattern-file cells-file)))
      (signals file-error (write-pattern-file (pattern "glider") cells-file :if-exists :error))
      (signals error (read-pattern-file (temp-file "missing.rle"))))))

(deftest formats/rotate-flip
  (let ((g (pattern "glider")))
    (is (pattern-equal g (rotate-pattern g 4)))
    (is (pattern-equal g (rotate-pattern g 0)))
    (is (pattern-equal g (rotate-pattern (rotate-pattern g) 3)))
    (is (not (pattern-equal g (rotate-pattern g))))
    (is (not (pattern-equal g (rotate-pattern g 2))))
    ;; .O. / ..O / OOO turned clockwise is O.. / O.O / OO.
    (is-equal '((0 . 0) (0 . 1) (2 . 1) (0 . 2) (1 . 2)) (pattern-cells (rotate-pattern g)))
    (is (pattern-equal (rotate-pattern g 2) (flip-pattern g :horizontal t :vertical t)))
    (is (pattern-equal (rotate-pattern g 3) (rotate-pattern (rotate-pattern g 2))))
    ;; .O. / ..O / OOO mirrored left-right is .O. / O.. / OOO
    (is-equal '((1 . 0) (0 . 1) (0 . 2) (1 . 2) (2 . 2))
              (pattern-cells (flip-pattern g :horizontal t)))
    ;; and top-bottom is OOO / ..O / .O.
    (is-equal '((0 . 0) (1 . 0) (2 . 0) (2 . 1) (1 . 2))
              (pattern-cells (flip-pattern g :vertical t)))
    (is (pattern-equal g (flip-pattern g)))
    (is (pattern-equal g (flip-pattern (flip-pattern g :horizontal t) :horizontal t)))
    (is (pattern-equal g (flip-pattern (flip-pattern g :vertical t) :vertical t)))
    (is-equal "Glider" (pattern-name (rotate-pattern g)))
    (is-equal "Glider" (pattern-name (flip-pattern g :vertical t)))
    (is-equal 3 (pattern-width (rotate-pattern g)))
    (is-equal 3 (pattern-height (rotate-pattern g))))
  ;; a non-square pattern swaps width and height and keeps name, rule and comments
  (let* ((p (make-pattern '((0 . 0) (1 . 0) (2 . 0)) :name "Blinker" :rule (parse-rule "highlife")
                                                      :comments '("c")))
         (r (rotate-pattern p)))
    (is-equal '((0 . 0) (0 . 1) (0 . 2)) (pattern-cells r))
    (is-equal 1 (pattern-width r))
    (is-equal 3 (pattern-height r))
    (is-equal "Blinker" (pattern-name r))
    (is-equal "B36/S23" (rule-string (pattern-rule r)))
    (is-equal '("c") (pattern-comments r))
    (is (pattern-equal p (rotate-pattern p 2)))
    (let ((f (flip-pattern p :horizontal t :vertical t)))
      (is (pattern-equal p f))
      (is-equal "Blinker" (pattern-name f))
      (is-equal '("c") (pattern-comments f))
      (is-equal "B36/S23" (rule-string (pattern-rule f)))))
  ;; O. / OO turned clockwise is OO / O.
  (is-equal '((0 . 0) (1 . 0) (0 . 1))
            (pattern-cells (rotate-pattern (make-pattern '((0 . 0) (0 . 1) (1 . 1))))))
  ;; the empty pattern stays empty
  (is-equal 0 (pattern-population (rotate-pattern (make-pattern '()))))
  (is-equal 0 (pattern-population (flip-pattern (make-pattern '()) :horizontal t))))

(deftest formats/from-world
  (let ((w (make-world :topology :torus :width 10 :height 10 :rule "highlife")))
    (place w "glider")
    (let ((p (pattern-from-world w)))
      (is (pattern-p p))
      (is (pattern-equal p (pattern "glider")))
      (is-equal *glider-cells* (pattern-cells p))
      (is (rule-equal (world-rule w) (pattern-rule p)))
      (is-equal "B36/S23" (rule-string (pattern-rule p)))
      (is (null (pattern-name p))))
    (is-equal "Mine" (pattern-name (pattern-from-world w :name "Mine"))))
  (let ((p (pattern-from-world (make-world))))
    (is-equal 0 (pattern-population p))
    (is-equal 0 (pattern-width p))
    (is-equal 0 (pattern-height p))
    (is-equal "B3/S23" (rule-string (pattern-rule p))))
  ;; negative coordinates normalize; the world is left alone
  (let ((w (make-world)))
    (place w "glider" :x -100 :y -50)
    (is (pattern-equal (pattern "glider") (pattern-from-world w)))
    (is-equal 5 (population w))
    (multiple-value-bind (x0 y0) (bounding-box w)
      (is-equal '(-100 -50) (list x0 y0))))
  ;; a world after stepping gives the current state
  (let ((w (%pattern-world "blinker")))
    (step-world w)
    (is-equal '((0 . 0) (0 . 1) (0 . 2)) (pattern-cells (pattern-from-world w)))))

;;;; src/formats.lisp — patterns and their text formats: RLE, plaintext and Life 1.06 readers, RLE and
;;;; plaintext writers, files (DESIGN.md §4.5).

(in-package :game-of-life)

;;; ------------------------------------------------------------------------------------------
;;; Patterns
;;; ------------------------------------------------------------------------------------------

(defstruct (pattern (:constructor %make-pattern) (:copier nil))
  "A normalized, immutable set of cells with a name, an optional rule and comments. CELLS are
(x . y) with the smallest x and the smallest y both 0, sorted by y then x; WIDTH and HEIGHT are
the bounding box (0x0 for the empty pattern)."
  (name nil)
  (cells '() :type list)
  (width 0 :type (integer 0))
  (height 0 :type (integer 0))
  (rule nil)
  (comments '() :type list))

(defmethod print-object ((pattern pattern) stream)
  (print-unreadable-object (pattern stream :type t)
    (format stream "~@[~S ~]~Dx~D ~D cells" (pattern-name pattern) (pattern-width pattern)
            (pattern-height pattern) (length (pattern-cells pattern)))))

(defun make-pattern (cells &key name rule comments)
  "A pattern from CELLS, a list of (x . y) in any order (duplicates allowed): shifted so the
smallest x and the smallest y are 0, sorted by y then x. RULE is a PARSE-RULE designator or NIL;
COMMENTS a list of strings."
  (let ((cells (remove-duplicates cells :test #'equal))
        (rule (and rule (parse-rule rule))))
    (if (null cells)
        (%make-pattern :name name :rule rule :comments (copy-list comments))
        (let ((min-x (reduce #'min cells :key #'car))
              (min-y (reduce #'min cells :key #'cdr))
              (max-x (reduce #'max cells :key #'car))
              (max-y (reduce #'max cells :key #'cdr)))
          (%make-pattern :name name :rule rule :comments (copy-list comments)
                         :cells (%sort-cells (mapcar (lambda (c) (cons (- (car c) min-x)
                                                                       (- (cdr c) min-y)))
                                                     cells))
                         :width (1+ (- max-x min-x))
                         :height (1+ (- max-y min-y)))))))

(defun %rename-pattern (pattern name)
  "PATTERN under NAME (a fresh struct sharing the cells)."
  (%make-pattern :name name :cells (pattern-cells pattern) :width (pattern-width pattern)
                 :height (pattern-height pattern) :rule (pattern-rule pattern)
                 :comments (pattern-comments pattern)))

(defun pattern-population (pattern)
  "The number of cells of PATTERN."
  (length (pattern-cells pattern)))

(defun pattern-equal (a b)
  "True when A and B have the same cells (names, rules and comments ignored)."
  (equal (pattern-cells a) (pattern-cells b)))

(defun %cells-of-designator (pattern)
  "The cells (x . y) of PATTERN for PLACE: a PATTERN struct, a built-in name (string or symbol,
resolved with PATTERN) or a list of cells."
  (cond ((listp pattern) pattern)
        ((or (stringp pattern) (symbolp pattern)) (pattern-cells (pattern pattern)))
        ((pattern-p pattern) (pattern-cells pattern))
        (t (%life-error "not a pattern designator: ~S" pattern))))

(defun %transform-pattern (pattern function)
  "PATTERN with every cell mapped through FUNCTION (x y -> (values x y)), normalized; the name,
rule and comments are kept."
  (make-pattern (mapcar (lambda (c)
                          (multiple-value-bind (x y) (funcall function (car c) (cdr c))
                            (cons x y)))
                        (pattern-cells pattern))
                :name (pattern-name pattern) :rule (pattern-rule pattern)
                :comments (pattern-comments pattern)))

(defun rotate-pattern (pattern &optional (quarter-turns 1))
  "PATTERN rotated clockwise by QUARTER-TURNS quarter turns (negative: counterclockwise)."
  (let ((result pattern))
    (loop repeat (mod quarter-turns 4)
          do (setf result (%transform-pattern result (lambda (x y) (values (- y) x)))))
    result))

(defun flip-pattern (pattern &key horizontal vertical)
  "PATTERN mirrored left-right (HORIZONTAL) and/or top-bottom (VERTICAL)."
  (%transform-pattern pattern (lambda (x y)
                                (values (if horizontal (- x) x) (if vertical (- y) y)))))

(defun pattern-from-world (world &key name)
  "The live cells of WORLD as a pattern named NAME, with the world's rule."
  (make-pattern (live-cells world) :name name :rule (world-rule world)))

;;; ------------------------------------------------------------------------------------------
;;; Text helpers
;;; ------------------------------------------------------------------------------------------

(defun %whitespace-p (ch)
  "True for the blank characters."
  (member ch '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun %lines (string)
  "STRING split at newlines, each line without a trailing #\\Return (CRLF files)."
  (let ((lines '()) (start 0))
    (loop
      (let ((i (position #\Newline string :start start)))
        (push (string-right-trim '(#\Return) (subseq string start i)) lines)
        (if i (setf start (1+ i)) (return))))
    (nreverse lines)))

(defun %trim (string)
  "STRING without leading and trailing blanks."
  (string-trim '(#\Space #\Tab #\Return) string))

(defun %split (string char)
  "STRING split at every CHAR."
  (loop with start = 0
        for i = (position char string :start start)
        collect (subseq string start i)
        while i
        do (setf start (1+ i))))

(defun %words (string)
  "The blank-separated words of STRING."
  (remove "" (%split (substitute #\Space #\Tab string) #\Space) :test #'string=))

(defun %call-with-destination (destination function)
  "FORMAT's destination convention: NIL returns a string, T means *STANDARD-OUTPUT*, a stream is
written to. FUNCTION takes the stream. Returns the string for NIL, else NIL."
  (cond ((null destination) (with-output-to-string (s) (funcall function s)))
        ((eq destination t) (funcall function *standard-output*) nil)
        (t (funcall function destination) nil)))

;;; ------------------------------------------------------------------------------------------
;;; RLE
;;; ------------------------------------------------------------------------------------------

(defun %rle-header-p (line)
  "True when LINE (trimmed) is an RLE header: x, optional blanks, =."
  (and (plusp (length line))
       (char-equal (char line 0) #\x)
       (let ((i (position-if-not (lambda (c) (member c '(#\Space #\Tab))) line :start 1)))
         (and i (char= (char line i) #\=)))))

(defun %parse-rle-header (line)
  "(values rule extra-comment) from the header LINE: rule = R goes through PARSE-RULE; when that
fails the rule is NIL and the extra comment is \"rule: R\". x and y are read and ignored (the size
is always the bounding box)."
  (let ((rule nil) (extra nil))
    (dolist (part (%split line #\,))
      (let ((eq (position #\= part)))
        (when eq
          (let ((key (string-downcase (%trim (subseq part 0 eq))))
                (value (%trim (subseq part (1+ eq)))))
            (when (string= key "rule")
              (setf rule (handler-case (parse-rule value)
                           (rule-syntax-error ()
                             (setf extra (format nil "rule: ~A" value))
                             nil))))))))
    (values rule extra)))

(defun parse-rle (string)
  "The pattern of the RLE text STRING, as Golly reads it: #N names, #C, #c and #O lines are
comments; the header x = W, y = H[, rule = R] is optional; the data is counts followed by b (dead),
o or any other letter (alive), $ (row ends) and ! (the end, optional); anything else is a
PATTERN-SYNTAX-ERROR with its line."
  (let ((name nil) (comments '()) (rule nil) (cells '()) (x 0) (y 0) (count nil) (done nil))
    (loop for line in (%lines string)
          for lineno from 1
          until done
          do (let ((trimmed (%trim line)))
               (cond ((zerop (length trimmed)))
                     ((char= (char trimmed 0) #\#)
                      (let ((tag (if (> (length trimmed) 1) (char trimmed 1) nil))
                            (text (%trim (subseq trimmed (min 2 (length trimmed))))))
                        (case tag
                          (#\N (setf name (if (plusp (length text)) text nil)))
                          ((#\C #\c #\O) (push text comments))
                          (t nil))))
                     ((%rle-header-p trimmed)
                      (multiple-value-bind (r extra) (%parse-rle-header trimmed)
                        (setf rule r)
                        (when extra (push extra comments))))
                     (t
                      (loop for ch across trimmed
                            until done
                            do (cond ((digit-char-p ch)
                                      (setf count (+ (* 10 (or count 0)) (digit-char-p ch))))
                                     ((member ch '(#\b #\B #\.))
                                      (incf x (or count 1))
                                      (setf count nil))
                                     ((char= ch #\$)
                                      (incf y (or count 1))
                                      (setf x 0 count nil))
                                     ((char= ch #\!) (setf done t))
                                     ((%whitespace-p ch))
                                     ((alpha-char-p ch)
                                      (dotimes (i (or count 1))
                                        (push (cons (+ x i) y) cells))
                                      (incf x (or count 1))
                                      (setf count nil))
                                     (t (error 'pattern-syntax-error :line lineno
                                               :message (format nil "unexpected character ~S ~
                                                                     in RLE data" ch)))))))))
    (make-pattern cells :name name :rule rule :comments (nreverse comments))))

(defun %rle-tokens (pattern)
  "The RLE data tokens of PATTERN (strings), ending with \"!\": per row, runs of b and o with the
trailing dead cells left out, rows separated by $ with empty rows collapsed into N$."
  (let* ((height (pattern-height pattern))
         (rows (make-array (max height 1) :initial-element '()))
         (tokens '())
         (owed 0))
    (dolist (cell (pattern-cells pattern))
      (push (car cell) (aref rows (cdr cell))))
    (flet ((token (n tag)
             (push (if (= n 1) (string tag) (format nil "~D~C" n tag)) tokens)))
      (dotimes (y height)
        (let ((xs (sort (aref rows y) #'<)))
          (cond ((null xs) (incf owed))
                (t (when (plusp owed)
                     (token owed #\$)
                     (setf owed 0))
                   (let ((pos 0))
                     (loop while xs
                           do (let ((start (first xs)) (len 1))
                                (loop while (and (rest xs) (= (second xs) (+ start len)))
                                      do (incf len)
                                         (pop xs))
                                (pop xs)
                                (when (> start pos) (token (- start pos) #\b))
                                (token len #\o)
                                (setf pos (+ start len)))))
                   (setf owed 1)))))
      (push "!" tokens))
    (nreverse tokens)))

(defun %write-wrapped (tokens stream &optional (width 70))
  "Write TOKENS to STREAM in lines of at most WIDTH characters, breaking only between tokens, with
a final newline."
  (let ((column 0))
    (dolist (token tokens)
      (when (and (plusp column) (> (+ column (length token)) width))
        (terpri stream)
        (setf column 0))
      (write-string token stream)
      (incf column (length token)))
    (terpri stream)))

(defun write-rle (pattern &optional destination)
  "Write PATTERN as RLE: #N name, one #C line per comment, the header x = W, y = H, rule = R
(R is the pattern's rule or B3/S23), then the data in lines of at most 70 characters. DESTINATION
follows FORMAT: NIL returns the text, T is *STANDARD-OUTPUT*, a stream is written to (then NIL)."
  (%call-with-destination
   destination
   (lambda (stream)
     (when (pattern-name pattern)
       (format stream "#N ~A~%" (pattern-name pattern)))
     (dolist (comment (pattern-comments pattern))
       (format stream "#C ~A~%" comment))
     (format stream "x = ~D, y = ~D, rule = ~A~%" (pattern-width pattern) (pattern-height pattern)
             (rule-string (or (pattern-rule pattern) *life-rule*)))
     (%write-wrapped (%rle-tokens pattern) stream))))

;;; ------------------------------------------------------------------------------------------
;;; Plaintext
;;; ------------------------------------------------------------------------------------------

(defun parse-plaintext (string)
  "The pattern of the plaintext STRING: lines starting with ! are metadata (!Name: X names it, any
other ! line is a comment); other lines are rows where . space - and 0 are dead and any other
non-blank character is alive; rows may be ragged, blank lines are empty rows."
  (let ((name nil) (comments '()) (cells '()) (y 0))
    (dolist (line (%lines string))
      (cond ((and (plusp (length line)) (char= (char line 0) #\!))
             (let ((rest (%trim (subseq line 1))))
               (if (and (>= (length rest) 5) (string-equal "name:" rest :end2 5))
                   (let ((value (%trim (subseq rest 5))))
                     (setf name (if (plusp (length value)) value nil)))
                   (push rest comments))))
            (t (loop for ch across line
                     for x from 0
                     unless (or (member ch '(#\. #\Space #\- #\0)) (%whitespace-p ch))
                       do (push (cons x y) cells))
               (incf y))))
    (make-pattern cells :name name :comments (nreverse comments))))

(defun %pattern-rows (pattern)
  "PATTERN as HEIGHT strings of WIDTH characters, O alive and . dead."
  (let ((rows (make-array (pattern-height pattern))))
    (dotimes (y (pattern-height pattern))
      (setf (aref rows y) (make-string (pattern-width pattern) :initial-element #\.)))
    (dolist (cell (pattern-cells pattern))
      (setf (char (aref rows (cdr cell)) (car cell)) #\O))
    (coerce rows 'list)))

(defun write-plaintext (pattern &optional destination)
  "Write PATTERN as plaintext: !Name: X when named, one ! line per comment, then HEIGHT rows of
WIDTH characters using . and O, each ending in a newline. DESTINATION follows FORMAT: NIL returns
the text, T is *STANDARD-OUTPUT*, a stream is written to (then NIL)."
  (%call-with-destination
   destination
   (lambda (stream)
     (when (pattern-name pattern)
       (format stream "!Name: ~A~%" (pattern-name pattern)))
     (dolist (comment (pattern-comments pattern))
       (format stream "!~A~%" comment))
     (dolist (row (%pattern-rows pattern))
       (write-string row stream)
       (terpri stream)))))

;;; ------------------------------------------------------------------------------------------
;;; Life 1.06
;;; ------------------------------------------------------------------------------------------

(defun %parse-integer-or-nil (string)
  "STRING as an integer, or NIL."
  (handler-case (parse-integer string)
    (error () nil)))

(defun parse-life106 (string)
  "The pattern of the Life 1.06 text STRING: the first line is #Life 1.06, other # lines are
ignored, every other non-blank line is x y (two integers); anything else is a
PATTERN-SYNTAX-ERROR."
  (let ((lines (%lines string)) (cells '()))
    (unless (and lines (string-equal "#Life 1.06" (%trim (first lines))))
      (error 'pattern-syntax-error :line 1 :message "a Life 1.06 file starts with #Life 1.06"))
    (loop for line in (rest lines)
          for lineno from 2
          do (let ((trimmed (%trim line)))
               (cond ((zerop (length trimmed)))
                     ((char= (char trimmed 0) #\#))
                     (t (let ((parts (%words trimmed)))
                          (unless (= (length parts) 2)
                            (error 'pattern-syntax-error :line lineno
                                   :message (format nil "expected \"x y\", got ~S" trimmed)))
                          (let ((x (%parse-integer-or-nil (first parts)))
                                (y (%parse-integer-or-nil (second parts))))
                            (unless (and x y)
                              (error 'pattern-syntax-error :line lineno
                                     :message (format nil "expected two integers, got ~S"
                                                      trimmed)))
                            (push (cons x y) cells)))))))
    (make-pattern cells)))

;;; ------------------------------------------------------------------------------------------
;;; Detection and files
;;; ------------------------------------------------------------------------------------------

(defun %rle-chars-only-p (string)
  "True when STRING, ignoring # lines, holds only RLE data characters and blanks."
  (every (lambda (line)
           (or (and (plusp (length line)) (char= (char line 0) #\#))
               (every (lambda (ch)
                        (or (digit-char-p ch)
                            (member ch '(#\b #\o #\B #\O #\$ #\! #\.))
                            (%whitespace-p ch)))
                      line)))
         (%lines string)))

(defun %detect-format (string)
  "The format of the pattern text STRING: :life106, :rle or :plaintext (DESIGN.md §4.5)."
  (let ((lines (%lines string)))
    (cond ((and lines (string-equal "#Life 1.06" (%trim (first lines)))) :life106)
          ((some (lambda (line)
                   (let ((tr (%trim line)))
                     (and (plusp (length tr))
                          (not (member (char tr 0) '(#\# #\!)))
                          (%rle-header-p tr))))
                 lines)
           :rle)
          ((and (find #\! string) (%rle-chars-only-p string)) :rle)
          (t :plaintext))))

(defun parse-pattern (string &key format)
  "The pattern of the text STRING in FORMAT (:rle, :plaintext or :life106), detected from the
content when FORMAT is NIL: a #Life 1.06 first line, else an RLE header line or RLE data with a
!, else plaintext."
  (ecase (or format (%detect-format string))
    (:rle (parse-rle string))
    (:plaintext (parse-plaintext string))
    (:life106 (parse-life106 string))))

(defun %read-file-string (pathname)
  "The UTF-8 text of the file PATHNAME."
  (with-open-file (in pathname :direction :input :external-format :utf-8)
    (with-output-to-string (out)
      (loop for line = (read-line in nil nil)
            while line
            do (write-line line out)))))

(defun read-pattern-file (pathname &key format)
  "The pattern in the file PATHNAME (UTF-8 text in FORMAT, detected when NIL). A pattern without a
name is named after the file."
  (let* ((pathname (pathname pathname))
         (pattern (parse-pattern (%read-file-string pathname) :format format)))
    (if (pattern-name pattern)
        pattern
        (%rename-pattern pattern (pathname-name pathname)))))

(defun write-pattern-file (pattern pathname &key (format :rle) (if-exists :supersede))
  "Write PATTERN to the file PATHNAME as :rle (default) or :plaintext; returns PATHNAME."
  (with-open-file (out pathname :direction :output :if-exists if-exists
                                :if-does-not-exist :create :external-format :utf-8)
    (ecase format
      (:rle (write-rle pattern out))
      (:plaintext (write-plaintext pattern out))))
  pathname)

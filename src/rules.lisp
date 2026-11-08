;;;; src/rules.lisp — the conditions, and Life-like rules: B../S.. parsing and printing, born-p and
;;;; survives-p, the named rules (DESIGN.md §2 "Errors", §4.3).

(in-package :game-of-life)

;;; ------------------------------------------------------------------------------------------
;;; Conditions
;;; ------------------------------------------------------------------------------------------

(define-condition life-error (error)
  ((message :initarg :message :initform "life error" :reader life-error-message))
  (:report (lambda (condition stream)
             (write-string (life-error-message condition) stream)))
  (:documentation "Base class of every error this system signals on purpose; the report is a
complete user-facing message."))

(defun %life-error (control &rest arguments)
  "Signal a LIFE-ERROR whose message is CONTROL formatted with ARGUMENTS."
  (error 'life-error :message (apply #'format nil control arguments)))

(define-condition rule-syntax-error (life-error)
  ((text :initarg :text :initform "" :reader rule-syntax-error-text))
  (:report (lambda (condition stream)
             (format stream "not a Life-like rule: ~S (expected B3/S23, 23/3 or a name such as ~
                             life, highlife or seeds)"
                     (rule-syntax-error-text condition))))
  (:documentation "PARSE-RULE could not read its input."))

(define-condition pattern-syntax-error (life-error)
  ((line :initarg :line :initform nil :reader pattern-syntax-error-line))
  (:report (lambda (condition stream)
             (format stream "~@[line ~D: ~]~A"
                     (pattern-syntax-error-line condition) (life-error-message condition))))
  (:documentation "A pattern text (RLE, plaintext or Life 1.06) is malformed; LINE is 1-based or
NIL when unknown."))

(define-condition unknown-pattern-error (life-error)
  ((name :initarg :name :initform "" :reader unknown-pattern-error-name))
  (:report (lambda (condition stream)
             (format stream "no built-in pattern or file named ~S (try --list)"
                     (unknown-pattern-error-name condition))))
  (:documentation "PATTERN was given a name that is neither a library entry nor an existing file."))

(define-condition usage-error (life-error) ()
  (:documentation "A command-line mistake; MAIN prints the message and returns 2."))

(defun %usage-error (control &rest arguments)
  "Signal a USAGE-ERROR whose message is CONTROL formatted with ARGUMENTS."
  (error 'usage-error :message (apply #'format nil control arguments)))

;;; ------------------------------------------------------------------------------------------
;;; Rules
;;; ------------------------------------------------------------------------------------------

(defstruct (rule (:constructor %make-rule) (:copier nil))
  "A Life-like rule: bit N of BIRTH is set when a dead cell with N live neighbors is born, bit N of
SURVIVAL when a live cell with N live neighbors survives; STRING is the canonical text (B3/S23)."
  (birth 0 :type (unsigned-byte 9))
  (survival 0 :type (unsigned-byte 9))
  (string "" :type string))

(defmethod print-object ((rule rule) stream)
  (print-unreadable-object (rule stream :type t)
    (write-string (rule-string rule) stream)))

(defparameter *rule-names*
  '(("life"               "Life"               "B3/S23")
    ("highlife"           "HighLife"           "B36/S23")
    ("seeds"              "Seeds"              "B2/S")
    ("day-and-night"      "Day & Night"        "B3678/S34678")
    ("diamoeba"           "Diamoeba"           "B35678/S5678")
    ("anneal"             "Anneal"             "B4678/S35678")
    ("2x2"                "2x2"                "B36/S125")
    ("life-without-death" "Life without Death" "B3/S012345678")
    ("morley"             "Morley"             "B368/S245")
    ("replicator"         "Replicator"         "B1357/S1357")
    ("maze"               "Maze"               "B3/S12345"))
  "Known rules: (key display-name rulestring). PARSE-RULE accepts the keys (case-insensitive; -, _
and space are interchangeable); RULE-NICKNAME returns the display name.")

(defun %normalize-name (text)
  "TEXT lowercased with _ and space mapped to -, the key form of rule and pattern names."
  (map 'string (lambda (c) (if (or (char= c #\_) (char= c #\Space)) #\- c))
       (string-downcase text)))

(defun %mask-string (mask)
  "The ascending digits of the neighbor counts set in MASK."
  (with-output-to-string (s)
    (loop for n from 0 to 8 when (logbitp n mask) do (format s "~D" n))))

(defun %digits-mask (digits text)
  "The mask for DIGITS, a string of neighbor counts 0..8 (a repeated digit counts once); anything
else signals RULE-SYNTAX-ERROR quoting TEXT."
  (let ((mask 0))
    (loop for ch across digits
          do (let ((d (digit-char-p ch)))
               (unless (and d (<= d 8))
                 (error 'rule-syntax-error :text text))
               (setf mask (logior mask (ash 1 d)))))
    mask))

(defun %make-rule-from (births survivals text)
  "A rule from the digit strings BIRTHS and SURVIVALS; TEXT is quoted in errors."
  (let ((b (%digits-mask births text))
        (s (%digits-mask survivals text)))
    (%make-rule :birth b :survival s
                :string (format nil "B~A/S~A" (%mask-string b) (%mask-string s)))))

(defun %parse-rule-string (original)
  "PARSE-RULE for a string (DESIGN.md §4.3): B3/S23, B3S23, 23/3 (the old S/B order), a key of
*RULE-NAMES*; whitespace trimmed; anything from the first colon on (Golly's bounded-grid suffix)
dropped."
  (let* ((text (string-trim '(#\Space #\Tab #\Newline #\Return) original))
         (colon (position #\: text))
         (text (if colon (string-right-trim '(#\Space #\Tab) (subseq text 0 colon)) text))
         (lower (string-downcase text))
         (named (assoc (%normalize-name lower) *rule-names* :test #'string=)))
    (cond (named (%parse-rule-string (third named)))
          ((zerop (length lower)) (error 'rule-syntax-error :text original))
          ((char= (char lower 0) #\b)
           (let ((s (position #\s lower)))
             (unless s (error 'rule-syntax-error :text original))
             (let* ((births (subseq lower 1 s))
                    (slash (position #\/ births))
                    (births (cond ((null slash) births)
                                  ((= slash (1- (length births))) (subseq births 0 slash))
                                  (t (error 'rule-syntax-error :text original)))))
               (%make-rule-from births (subseq lower (1+ s)) original))))
          ((or (digit-char-p (char lower 0)) (char= (char lower 0) #\/))
           (let ((slash (position #\/ lower)))
             (unless (and slash (null (position #\/ lower :start (1+ slash))))
               (error 'rule-syntax-error :text original))
             (%make-rule-from (subseq lower (1+ slash)) (subseq lower 0 slash) original)))
          (t (error 'rule-syntax-error :text original)))))

(defun parse-rule (designator)
  "The rule DESIGNATOR names: a RULE is returned as is; a string or symbol is read as B3/S23,
b3/s23, B3S23, 23/3 (S/B order), a Golly rule with a :T100,100 suffix, or a key of *RULE-NAMES*
(life, highlife, seeds, ...). Anything else signals RULE-SYNTAX-ERROR."
  (cond ((rule-p designator) designator)
        ((stringp designator) (%parse-rule-string designator))
        ((symbolp designator) (%parse-rule-string (symbol-name designator)))
        (t (error 'rule-syntax-error :text (princ-to-string designator)))))

(declaim (inline born-p survives-p))
(defun born-p (rule n)
  "True when a dead cell with N live neighbors is born under RULE."
  (logbitp n (rule-birth rule)))

(defun survives-p (rule n)
  "True when a live cell with N live neighbors survives under RULE."
  (logbitp n (rule-survival rule)))

(defun next-state (rule alive-p n)
  "True when a cell that is alive (ALIVE-P) or dead, with N live neighbors, is alive next generation."
  (if alive-p (survives-p rule n) (born-p rule n)))

(defun rule-births (rule)
  "The ascending list of neighbor counts at which RULE gives birth, e.g. (3)."
  (loop for n from 0 to 8 when (logbitp n (rule-birth rule)) collect n))

(defun rule-survivals (rule)
  "The ascending list of neighbor counts at which RULE lets a cell survive, e.g. (2 3)."
  (loop for n from 0 to 8 when (logbitp n (rule-survival rule)) collect n))

(defun rule-equal (a b)
  "True when rules A and B have the same birth and survival sets."
  (and (= (rule-birth a) (rule-birth b))
       (= (rule-survival a) (rule-survival b))))

(defun rule-nickname (rule)
  "The display name of RULE from *RULE-NAMES* (\"Life\", \"HighLife\", ...), or NIL."
  (let ((entry (find-if (lambda (e) (rule-equal rule (%parse-rule-string (third e))))
                        *rule-names*)))
    (and entry (second entry))))

(defparameter *life-rule* (parse-rule "B3/S23")
  "Conway's Life, B3/S23: the default rule everywhere.")

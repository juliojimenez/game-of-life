;;;; tests/test-rules.lisp — tests for src/rules.lisp (DESIGN.md §5.2).

(in-package :game-of-life-test)

(deftest rules/parse-canonical
  (dolist (designator (list "B3/S23" "b3/s23" "B3S23" "23/3" " B3/S23 " "B3/S23:T100,100"
                            :life "Life" "LIFE" "life"))
    (let ((r (parse-rule designator)))
      (is (rule-p r) "~S parses to a rule" designator)
      (is (string= "B3/S23" (rule-string r)) "~S is canonical B3/S23, got ~S"
          designator (rule-string r))
      (is-equal '(3) (rule-births r))
      (is-equal '(2 3) (rule-survivals r)))))

(deftest rules/parse-others
  (let ((seeds (parse-rule "B2/S")))
    (is-equal '(2) (rule-births seeds))
    (is-equal '() (rule-survivals seeds))
    (is-equal "B2/S" (rule-string seeds))
    (is-equal "Seeds" (rule-nickname seeds)))
  (is-equal "HighLife" (rule-nickname (parse-rule "B36/S23")))
  (is-equal "Life without Death" (rule-nickname (parse-rule "B3/S012345678")))
  (is-equal "B23/S2" (rule-string (parse-rule "B332/S2")))
  (is-equal '(2 3) (rule-births (parse-rule "B332/S2")))
  (is-equal "Life" (rule-nickname (parse-rule "B3/S23")))
  (is-equal nil (rule-nickname (parse-rule "B3/S2")))
  ;; digits come out ascending whatever the input order
  (is-equal "B3/S23" (rule-string (parse-rule "B3/S32")))
  (is-equal '(2 3) (rule-survivals (parse-rule "B3/S32")))
  ;; names: case-insensitive, '-', '_' and space interchangeable
  (is-equal "B3678/S34678" (rule-string (parse-rule "day_and_night")))
  (is-equal "Day & Night" (rule-nickname (parse-rule "Day and Night")))
  (is-equal "B36/S125" (rule-string (parse-rule "2x2")))
  (is-equal "B3/S012345678" (rule-string (parse-rule "life_without_death")))
  (is-equal "B3/S12345" (rule-string (parse-rule :maze)))
  ;; the old S/B order and the slashless form
  (is-equal "B36/S23" (rule-string (parse-rule "23/36")))
  (is-equal "B36/S23" (rule-string (parse-rule "B36S23")))
  ;; a Golly bounded-grid suffix is dropped
  (is-equal "B36/S23" (rule-string (parse-rule "b36/s23:T40,40")))
  ;; every entry of *rule-names* parses to its own rulestring and nickname
  (dolist (entry *rule-names*)
    (destructuring-bind (key name rulestring) entry
      (is (string= rulestring (rule-string (parse-rule key))) "~A -> ~A" key rulestring)
      (is (string= name (rule-nickname (parse-rule rulestring))) "~A is nicknamed ~A"
          rulestring name))))

(deftest rules/parse-errors
  (dolist (bad (list "B9/S23" "B3" "S23/B3" "B3/S23x" "" "nosuchrule" "B3/" "/S23" "B3//S23"
                     "   " "B3/S23/" "Bx/S23" "3" "B-3/S23"))
    (signals rule-syntax-error (parse-rule bad)))
  (signals rule-syntax-error (parse-rule :nosuchrule))
  ;; a rule-syntax-error is a life-error whose report quotes the input
  (let ((e (handler-case (progn (parse-rule "nosuchrule") nil)
             (rule-syntax-error (c) c))))
    (is (typep e 'life-error))
    (is (and e (search "nosuchrule" (princ-to-string e))) "the report quotes the input")))

(deftest rules/predicates
  (let ((life (parse-rule "B3/S23"))
        (seeds (parse-rule "seeds")))
    (dotimes (n 9)
      (is (eq (= n 3) (born-p life n)) "Life born-p at ~D" n)
      (is (eq (or (= n 2) (= n 3)) (survives-p life n)) "Life survives-p at ~D" n)
      (is (eq (or (= n 2) (= n 3)) (next-state life t n)) "Life next-state alive at ~D" n)
      (is (eq (= n 3) (next-state life nil n)) "Life next-state dead at ~D" n)
      (is (eq nil (survives-p seeds n)) "Seeds never survives (~D)" n)
      (is (eq (= n 2) (born-p seeds n)) "Seeds born-p at ~D" n)
      (is (eq (= n 2) (next-state seeds nil n)) "Seeds next-state dead at ~D" n)
      (is (eq nil (next-state seeds t n)) "Seeds next-state alive at ~D" n))
    ;; booleans, not generalized booleans
    (is (eq t (born-p life 3)))
    (is (eq t (survives-p life 2)))
    (is (eq t (next-state life t 2)))
    (is (eq t (next-state life nil 3)))
    (is (eq nil (next-state life nil 2))))
  ;; a rule with every survival count keeps a live cell alive for any n
  (let ((lwd (parse-rule "life-without-death")))
    (dotimes (n 9)
      (is (survives-p lwd n) "Life without Death survives at ~D" n))))

(deftest rules/equal-and-identity
  (let ((r (parse-rule "B3/S23")))
    (is (eq r (parse-rule r)) "a rule parses to itself")
    (is (rule-equal r (parse-rule "23/3")))
    (is (rule-equal r (parse-rule "b3s23")))
    (is (rule-equal (parse-rule "B36/S23") (parse-rule "highlife")))
    (is (not (rule-equal r (parse-rule "B36/S23"))))
    (is (not (rule-equal r (parse-rule "B3/S2"))))
    (is (rule-p *life-rule*))
    (is (rule-equal *life-rule* r))
    (is-equal "B3/S23" (rule-string *life-rule*))
    (is (eq *life-rule* (parse-rule *life-rule*)))
    (is-equal 11 (length *rule-names*))
    (is (search "B3/S23" (princ-to-string r)) "the printed rule shows its string")))

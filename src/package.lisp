;;;; src/package.lisp — the GAME-OF-LIFE package and its complete public API (DESIGN.md §4.1).
;;;;
;;;; This file is authoritative: a symbol is public if and only if it is exported here.
;;;; Implementers do not edit it; an API change is made in DESIGN.md and here together.
;;;; Sections mirror DESIGN.md §4.

(defpackage :game-of-life
  (:nicknames :life)
  (:use :cl)
  (:export
   ;; ---- conditions -------------------------------------------------------------
   #:life-error #:rule-syntax-error #:pattern-syntax-error #:pattern-syntax-error-line
   #:unknown-pattern-error #:unknown-pattern-error-name #:usage-error
   ;; ---- 4.3 rules --------------------------------------------------------------
   #:rule #:rule-p #:parse-rule #:rule-string #:rule-nickname #:rule-births #:rule-survivals
   #:born-p #:survives-p #:next-state #:rule-equal #:*life-rule* #:*rule-names*
   ;; ---- 4.4 world --------------------------------------------------------------
   #:coordinate #:world #:world-p #:make-world #:copy-world #:world-rule #:world-topology
   #:world-width #:world-height #:world-generation #:world-births #:world-deaths
   #:alive-p #:in-bounds-p #:population #:live-cells #:clear-world #:bounding-box
   #:neighbor-count #:step-world #:place #:randomize #:world-equal #:world-fingerprint
   #:rng #:make-rng #:rng-p #:rng-next #:rng-unit #:rng-chance
   ;; ---- 4.5 formats ------------------------------------------------------------
   #:pattern #:pattern-p #:make-pattern #:pattern-name #:pattern-cells #:pattern-width
   #:pattern-height #:pattern-rule #:pattern-comments #:pattern-population #:pattern-equal
   #:rotate-pattern #:flip-pattern #:pattern-from-world
   #:parse-rle #:write-rle #:parse-plaintext #:write-plaintext #:parse-life106
   #:parse-pattern #:read-pattern-file #:write-pattern-file
   ;; ---- 4.6 patterns -----------------------------------------------------------
   #:pattern-entry #:pattern-entry-p #:pattern-entry-key #:pattern-entry-name
   #:pattern-entry-category #:pattern-entry-period #:pattern-entry-description
   #:define-pattern #:find-pattern-entry #:list-patterns #:print-pattern-list
   ;; ---- 4.7 terminal -----------------------------------------------------------
   #:terminal-size #:parse-terminal-size #:utf8-output-p #:read-key
   #:with-raw-keyboard #:with-terminal-ui
   #:ansi-clear #:ansi-home #:ansi-hide-cursor #:ansi-show-cursor
   #:ansi-enter-alternate-screen #:ansi-leave-alternate-screen
   ;; ---- 4.8 render -------------------------------------------------------------
   #:viewport #:make-viewport #:viewport-p #:viewport-x #:viewport-y
   #:viewport-width #:viewport-height
   #:default-viewport #:following-viewport #:frame-rows #:cells-per-row
   #:render-frame #:status-line #:draw
   ;; ---- 4.9 run ----------------------------------------------------------------
   #:stability-detector #:make-stability-detector #:observe #:simulate #:run #:*fps-steps*
   ;; ---- 4.10 cli ---------------------------------------------------------------
   #:*version* #:parse-arguments #:usage #:summary-line #:main #:main-entry))

(defpackage :game-of-life-test
  (:use :cl :game-of-life)
  (:export #:run-all-tests #:run-test))

;;;; game-of-life.asd — Conway's Game of Life in pure Common Lisp (SBCL first; loads and passes its
;;;; suite on ECL and CCL too; no dependencies beyond ASDF's own uiop).
;;;;
;;;; Load:  sbcl --non-interactive --load game-of-life.asd --eval '(asdf:load-system :game-of-life)'
;;;; Test:  sbcl --non-interactive --load game-of-life.asd --eval '(asdf:test-system :game-of-life)'
;;;; Build: sbcl --non-interactive --load game-of-life.asd --eval '(asdf:make :game-of-life)'  => bin/life
;;;;
;;;; The two forms below let this file be loaded directly with --load (outside asdf:load-asd),
;;;; which is how the command lines above work. They are harmless under load-asd.
(require :asdf)
(in-package :asdf-user)

(defsystem "game-of-life"
  :description "Conway's Game of Life in pure Common Lisp: engine, patterns, RLE, terminal viewer"
  :author "Julio Jimenez"
  :license "Apache-2.0"
  :version "0.1.0"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")    ; 4.1  exports (do not edit)
                             (:file "compat")     ; 4.2  implementation-specific primitives
                             (:file "rules")      ; 4.3  Life-like rules
                             (:file "world")      ; 4.4  world, step, place, randomize
                             (:file "formats")    ; 4.5  patterns, RLE / plaintext / Life 1.06
                             (:file "patterns")   ; 4.6  built-in pattern library
                             (:file "terminal")   ; 4.7  ANSI, terminal size, raw keyboard
                             (:file "render")     ; 4.8  viewport, frames, status line
                             (:file "run")        ; 4.9  simulate (headless) and run (interactive)
                             (:file "cli"))))     ; 4.10 arguments, main, main-entry
  :build-operation "program-op"
  :build-pathname "bin/life"
  :entry-point "game-of-life:main-entry"
  :in-order-to ((test-op (test-op "game-of-life/tests"))))

(defsystem "game-of-life/tests"
  :description "Game of Life test suite (hand-written harness, zero dependencies)"
  :depends-on ("game-of-life")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "harness")
                             (:file "test-rules")
                             (:file "test-world")
                             (:file "test-patterns")
                             (:file "test-formats")
                             (:file "test-render")
                             (:file "test-run")
                             (:file "test-terminal")
                             (:file "test-cli"))))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :game-of-life-test :run-all-tests)
               (error "Game of Life test suite failed"))))

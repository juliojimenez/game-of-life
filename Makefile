# Game of Life — build, test and run (DESIGN.md §7).
#
#   make test        the suite on SBCL (LIFE_LONG_TESTS=1 make test adds the slow oracles)
#   make test-all    the suite on SBCL, ECL and CCL
#   make bin         bin/life, the standalone executable (SBCL)
#   make run ARGS="gosper-glider-gun"
#   make smoke       drives bin/life through a pseudo-terminal: keys, screen, terminal restore

SBCL ?= sbcl
ECL  ?= ecl
CCL  ?= ccl
ASD  := game-of-life.asd
SRC  := $(ASD) $(wildcard src/*.lisp)

# ECL: turn an unhandled error into a message and a non-zero exit instead of a debugger prompt on stdin.
ECL_HOOK := (setf *debugger-hook* (lambda (c h) (declare (ignore h)) (format t "~&ERROR: ~a~%" c) (finish-output) (ext:quit 1)))

.PHONY: build build-ecl build-ccl test test-ecl test-ccl test-all bin run patterns smoke clean

## build: a forced compile on SBCL; any WARNING fails (DESIGN.md §2)
build:
	$(SBCL) --non-interactive --load $(ASD) --eval '(asdf:load-system :game-of-life :force t)' 2>&1 | tee build.log
	@if grep -q -i 'WARNING' build.log; then echo "error: the forced build produced a warning (see build.log)"; exit 1; fi

build-ecl:
	$(ECL) --norc --eval '$(ECL_HOOK)' --eval '(require :asdf)' --eval '(load "$(ASD)")' \
	  --eval '(asdf:load-system :game-of-life :force t)' --eval '(ext:quit 0)' 2>&1 | tee build-ecl.log
	@if grep -q -i 'WARNING' build-ecl.log; then echo "error: the forced ECL build produced a warning (see build-ecl.log)"; exit 1; fi

build-ccl:
	$(CCL) --batch --quiet --eval '(require :asdf)' --eval '(load "$(ASD)")' \
	  --eval '(asdf:load-system :game-of-life :force t)' --eval '(ccl:quit 0)' 2>&1 | tee build-ccl.log
	@if grep -q -i 'WARNING' build-ccl.log; then echo "error: the forced CCL build produced a warning (see build-ccl.log)"; exit 1; fi

## test: the suite on SBCL
test:
	$(SBCL) --non-interactive --load $(ASD) --eval '(asdf:test-system :game-of-life)'

test-ecl:
	LIFE_NON_INTERACTIVE=1 $(ECL) --norc --eval '$(ECL_HOOK)' --eval '(require :asdf)' --eval '(load "$(ASD)")' \
	  --eval '(asdf:test-system :game-of-life)' --eval '(ext:quit 0)'

test-ccl:
	LIFE_NON_INTERACTIVE=1 $(CCL) --batch --quiet --eval '(require :asdf)' --eval '(load "$(ASD)")' \
	  --eval '(asdf:test-system :game-of-life)' --eval '(ccl:quit 0)'

test-all: test test-ecl test-ccl

## bin: the bin/life executable (SBCL; the image keeps its runtime options, so bin/life --help is ours)
bin: bin/life

bin/life: $(SRC)
	mkdir -p bin
	$(SBCL) --non-interactive --load $(ASD) --eval '(asdf:make :game-of-life)'

## run: bin/life $(ARGS)
run: bin/life
	bin/life $(ARGS)

## patterns: write every built-in pattern as patterns/<key>.rle
patterns:
	mkdir -p patterns
	$(SBCL) --non-interactive --load $(ASD) --eval '(asdf:load-system :game-of-life)' \
	  --eval '(dolist (e (life:list-patterns)) (life:write-pattern-file (life:pattern (life:pattern-entry-key e)) (format nil "patterns/~A.rle" (life:pattern-entry-key e))))'

## smoke: the interactive smoke test through a pseudo-terminal (DESIGN.md §5.10)
smoke: bin/life
	python3 tests/pty-smoke.py bin/life

clean:
	rm -rf bin build.log build-ecl.log build-ccl.log

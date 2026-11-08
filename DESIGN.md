# Game of Life — Design (authoritative)

John Conway's Game of Life in pure Common Lisp. SBCL 2.6.10 / macOS arm64 is the reference
platform; the system also loads and passes its suite on ECL 26.5 and CCL 1.14 (every
implementation-specific primitive lives in `src/compat.lisp`, §4.2). No third-party libraries
beyond ASDF's own uiop. No FFI.

Where this document and the code disagree, this document wins. Where this document is wrong,
fix it here first, then the code. Signatures below are exact: names, argument order, keyword
names, defaults and return values. Every public symbol is exported in `src/package.lisp`
(§4.1); nothing else is public.

## Table of contents

1. Overview and scope
2. Conventions (package, coordinates, errors, declarations, style)
3. Core algorithm (the sparse step, topologies, keys, stability detection)
4. Modules (load order; one subsection per file, exact public API)
   - 4.1 src/package.lisp
   - 4.2 src/compat.lisp
   - 4.3 src/rules.lisp
   - 4.4 src/world.lisp
   - 4.5 src/formats.lisp
   - 4.6 src/patterns.lisp
   - 4.7 src/terminal.lisp
   - 4.8 src/render.lisp
   - 4.9 src/run.lisp
   - 4.10 src/cli.lisp
5. Tests: harness API and the tests per module
6. README outline
7. Build, Makefile, CI
8. Known facts used as oracles, risks, later work

## 1. Overview and scope

The product is three things sharing one engine:

- **A library** you use at the REPL: `(life:make-world)`, `(life:place w "glider")`,
  `(life:step-world w 4)`, `(life:live-cells w)`. Any Life-like rule (`B3/S23`, `B36/S23`,
  `B2/S`, ...). Three topologies: the infinite plane, a torus (edges wrap) and a box (dead
  beyond the edges). Patterns come from a built-in library or from RLE / plaintext / Life 1.06
  files, and can be written back out.
- **A terminal viewer**: `bin/life glider`, `bin/life` (a random soup), `bin/life -r highlife`.
  Half-block characters give two cells per character row so the grid looks square; a status
  line shows generation, population, rule, topology, speed and seed; keys pause, single-step,
  change speed, follow the pattern, clear and re-seed. The alternate screen is used so the
  user's terminal is intact when the program exits.
- **A headless CLI**: `bin/life r-pentomino --headless -g 1103` prints
  `R-pentomino: generation 1103, population 116`. Stability (exact repetition) and extinction
  are detected and reported. `--write FILE` saves the final world as RLE.

Architecture in one paragraph. A `world` is a hash table of live cells keyed by a packed
fixnum (§3.1) plus a `rule`, a `topology` and optional dimensions. `step-world` is the only
algorithm: one pass over the live cells writes neighbor counts (and an "alive" mark) into a
scratch table, one pass over the scratch table rewrites the live set; topology is applied
where neighbor coordinates are formed, so one function serves the plane, the torus and the
box. A `pattern` is a normalized, immutable cell list with a name, an optional rule and
comments; `formats.lisp` converts patterns to and from RLE, plaintext and Life 1.06 text;
`patterns.lisp` is the built-in library (drawings in plaintext in the source). `render.lisp`
turns a `viewport` of a world into text; `terminal.lisp` owns ANSI sequences, the terminal
size and the raw keyboard (through `stty`, no FFI); `run.lisp` has the headless `simulate`
loop with a `stability-detector`, and the interactive `run` loop; `cli.lisp` parses
arguments and is the executable's entry point.

Non-goals for v0.1: Hashlife or any other acceleration, colors or cell ages, mouse editing,
multi-state rules, Life 1.05 / MCell / macrocell formats, a GUI. §8 lists what to do next.

Source files (load order, all `:serial t`):

```
src/package.lisp     exports only (the public API; implementers do not edit it)
src/compat.lisp      every implementation-specific primitive (SBCL, ECL, CCL; uiop elsewhere)
src/rules.lisp       rule struct, rulestring parsing/printing, born-p / survives-p, named rules
src/world.lisp       world struct, cells, topology, step-world, place, randomize, rng, equality
src/formats.lisp     pattern struct, RLE / plaintext / Life 1.06 readers and writers, files
src/patterns.lisp    built-in pattern library (define-pattern), lookup, listing
src/terminal.lisp    ANSI strings, terminal size, raw keyboard, with-terminal-ui
src/render.lisp      viewport, render-frame, status-line, draw
src/run.lisp         stability-detector, simulate (headless), run (interactive)
src/cli.lisp         argument parsing, usage, summary-line, main, main-entry
```

## 2. Conventions

**Package.** `game-of-life`, nickname `life`, `(:use :cl)`. A symbol is public if and only if
it is exported in `src/package.lisp`. Internal helpers are prefixed `%`. The test package is
`game-of-life-test`, defined at the bottom of `src/package.lisp`, `(:use :cl :game-of-life)`.

**Coordinates.** `x` grows to the right, `y` grows downward (screen and file order: row 0 of
an RLE is the top row). A cell is written `(x . y)` (a cons) in every public API. The type
`coordinate` is `(signed-byte 30)`: −536870912 to 536870911. Internally a cell is one
non-negative fixnum key (§3.1).

**Topologies.** `:plane` (unbounded; `width`/`height` are `nil`), `:torus` (coordinates wrap
modulo `width` and `height`), `:box` (cells outside `0 ≤ x < width`, `0 ≤ y < height` are
dead and cannot be set). Torus and box need positive integer dimensions.

**Rules.** A Life-like rule is a set of birth counts and a set of survival counts, each a
subset of 0..8. Canonical text is `B3/S23` (digits ascending, uppercase). Conway's Life is
`B3/S23` and the default everywhere.

**Patterns.** Immutable after construction. Cells are normalized so that the smallest `x` and
the smallest `y` are both 0; sorted by `y` then `x`; no duplicates. `width`/`height` are the
bounding box (0×0 for the empty pattern).

**Errors.** `life-error` (subclass of `error`) is the base. Subclasses: `rule-syntax-error`,
`pattern-syntax-error` (reader `pattern-syntax-error-line`, an integer or `nil`),
`unknown-pattern-error` (reader `unknown-pattern-error-name`), `usage-error` (CLI). Every
`life-error` has a readable `report` that stands alone as a user-facing message
(`"no built-in pattern or file named \"gilder\" (try --list)"`). Programmer mistakes
(wrong types) may signal ordinary `type-error`s.

**Declarations and warnings.** A forced compile (`(asdf:load-system :game-of-life :force t)`)
must produce no `WARNING` and no `STYLE-WARNING` on SBCL, ECL and CCL; CI greps the build log
case-insensitively (`grep -q -i warning`): SBCL prints `caught WARNING` / `caught STYLE-WARNING`,
ECL prints `;;; Warning:` and `;;; Style warning:`, CCL prints `;Compiler warnings for "file" :`
with one line per problem, so a case-sensitive grep would pass ECL and CCL builds that warn. SBCL optimization notes are muffled per file with `%muffle-compiler-notes`
(§4.2). `step-world` and the key helpers carry `(declare (type ...))` and `(optimize (speed 2))`
or similar; nothing else needs tuning. Rules that keep the three compilers quiet (each verified
to warn otherwise): put every `(declaim (inline ...))` before the function's definition and before
its first call in the file; macros that bind a caller-named variable (`with-raw-keyboard`,
`with-terminal-ui`, `with-captured-output`) emit `(declare (ignorable ,var))` right after the
binding; never leave a parameter, `multiple-value-bind` variable or `handler-case` variable
unused (declare it `ignore`, or omit the variable in `handler-case`); never combine
`(declare (ignore x))` with a type declaration for the same variable (ECL warns); never `defun`
a name that a `defstruct` already defines as an accessor (`rule-string`, `world-width`,
`pattern-name`, ...); define every special variable (`defvar`/`defparameter`) in a file loaded
before, or earlier in the same file than, its first use; do not mix `&optional` and `&key` in
one lambda list; `defconstant` only integers and characters (SBCL fails the forced build with
`DEFCONSTANT-UNEQL` on a list or string; ECL and CCL accept it, so SBCL is the only one that
catches it); strings and lists go in `defparameter`. Forward references to functions defined in
later files are fine on all three (ASDF wraps the build in one compilation unit); forward
references to macros are not, which is what the load order protects.

**Style.** US spelling in identifiers (`neighbor`). Docstrings on every public function,
macro, variable and condition. `print-object` methods for `rule`, `world`, `pattern` and
`viewport` so the REPL is pleasant: `#<RULE B3/S23>`, `#<WORLD plane gen 12 pop 5>`,
`#<WORLD torus 80x46 gen 0 pop 1104>`, `#<PATTERN "Glider" 3x3 5 cells>`,
`#<VIEWPORT 80x46 at (-40,-23)>`. Portable Common Lisp only outside `compat.lisp`
(no `sb-ext:` elsewhere). Lines ≤ 100 columns.

**Output streams.** Library functions never print except the ones whose job it is (`draw`,
`print-pattern-list`, `usage`, `main`), and those print to `*standard-output*` /
`*error-output*` (or an explicit `stream` argument) so tests can capture them by binding the
specials. `main` never calls `exit`; `main-entry` does.

## 3. Core algorithm

### 3.1 Cell keys

```lisp
(deftype coordinate () '(signed-byte 30))
(deftype cell-key () '(unsigned-byte 60))
(declaim (inline %pack %unpack-x %unpack-y))
(defun %pack (x y)            ; -> cell-key
  (logior (ash (ldb (byte 30 0) y) 30) (ldb (byte 30 0) x)))
(defun %unpack-x (key) ...)   ; sign-extend (ldb (byte 30 0) key)
(defun %unpack-y (key) ...)   ; sign-extend (ldb (byte 30 30) key)
```

60 bits because CCL's fixnums are 60 bits wide (SBCL 62, ECL 61): a key is a non-negative
fixnum on all three, so the `eql` hash tables never see bignums and never cons a key.
Sign extension: `(if (logbitp 29 v) (- v (ash 1 30)) v)`.

### 3.2 The step

`world-cells` is an `eql` hash table `key -> t`; `world-scratch` is an `eql` hash table
`key -> fixnum` that is empty between steps. One generation:

```
for each live key k (x, y):
    scratch[k] |= 16                               ; mark "was alive"
    for each (dx, dy) in the 8 offsets:
        nk = (%neighbor-key world x y dx dy)       ; nil outside a :box; wrapped on a :torus
        when nk: scratch[nk] += 1
clrhash cells; births = deaths = 0
for each (k . v) in scratch:
    alive = (logtest v 16); n = (logand v 15)
    if alive:  if (survives-p rule n) cells[k] = t  else deaths += 1
    else:      if (born-p rule n)     cells[k] = t, births += 1
clrhash scratch; generation += 1
```

Only two tables exist per world; nothing is allocated per generation except what the hash
tables grow into. A torus of width or height 1 or 2 makes a cell its own neighbor or counts a
neighbor twice; that is the correct arithmetic for such a torus and is not special-cased. The
count in the low four bits never exceeds 8 on any topology or size: each of the 8 offsets adds at
most one to a given target cell (its source is the wrapped `target − offset`), so the count never
reaches bit 4 and `(logand v 15)` is exact; a 1×1 torus with its cell alive counts 8.
`%neighbor-key` on a torus wraps with `mod`; on a box returns `nil` when the neighbor is
outside; on the plane just packs. Births and deaths of the last step are kept on the world.

Cost is proportional to the number of live cells, not the area: a glider on the infinite plane
costs the same as on a 10×10 torus. A 200×100 soup at density 0.3 steps in a few
milliseconds on SBCL.

### 3.3 Stability detection

A `stability-detector` keeps the last `depth` (default 64) generations as *snapshots*: a
snapshot is the sorted `simple-vector` of cell keys plus its `fingerprint`
(§4.4 `world-fingerprint`: an order-independent 60-bit mix of the keys, so two equal cell
sets always have equal fingerprints). `observe` compares the current snapshot with the stored
ones, most recent first, fingerprint first and full vector only on a fingerprint match, and
returns the smallest period `p` such that the state equals the state `p` steps ago, or `nil`;
only after the comparison is the current snapshot stored, so the ring holds the `depth` states
*before* the current one and a period equal to `depth` is still found (a DEPTH-slot ring that
stores first can only find periods up to DEPTH-1). Depth 64 detects every oscillator of period
≤ 64 and still lifes (period 1); a glider on a torus of side 5 to 16 is detected too (period
4·side; on a side-4 torus the glider collapses into a block and on side 3 it dies). Spaceships
on the plane never repeat exactly, so a glider stream is never "stable"; `--generations` bounds
those runs (§4.10). Extinction is detected separately (population 0) so an empty world reports
`:extinct`, not "period 1".

## 4. Modules

### 4.1 src/package.lisp

The file is exactly this (plus the header comment). Implementers do not edit it; if the API
must change, change this document and this file together.

```lisp
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
```

### 4.2 src/compat.lisp

The only file with reader conditionals on the implementation. SBCL gets its native call; ECL
and CCL theirs; everything else uiop or portable CL.

```lisp
(defmacro %muffle-compiler-notes ())
  ;; at top level: SBCL (declaim (sb-ext:muffle-conditions sb-ext:compiler-note)); nil elsewhere
(defun %getenv (name))                       ; string or nil (uiop:getenv)
(defun %command-line-arguments ())           ; user arguments, program name excluded (uiop:command-line-arguments)
(defun %raw-command-line-arguments ())       ; whole argv (uiop:raw-command-line-arguments)
(defun %debugger-disabled-p ())              ; SBCL: *invoke-debugger-hook* is sb-debug::debugger-disabled-hook; else nil
(defun %exit (code))                         ; ends the process with exit status CODE; the caller flushes the
                                             ; streams first. SBCL (sb-ext:exit :code code :abort t) skips
                                             ; unwinding (an unwinding exit from inside ASDF's compilation unit
                                             ; prints a spurious notice); ECL (ext:quit code) and CCL (ccl:quit
                                             ; code) do unwind (unwind-protect cleanups run) and that is accepted:
                                             ; nothing relies on skipping them. Else (uiop:quit code).
(defmacro %catch-interrupt (form &body on-interrupt))
  ;; Evaluates FORM; when Ctrl-C (SIGINT) arrives during it, abandons FORM (unwind-protect cleanups
  ;; run) and returns the values of ON-INTERRUPT. SBCL: (handler-case form (sb-sys:interactive-interrupt
  ;; () ...)); ECL: the same with ext:interactive-interrupt (both are signaled through ERROR, and neither
  ;; is an ERROR subtype: a plain (error (e)) clause does not see them). CCL never signals
  ;; ccl:interrupt-signal-condition: its SIGINT handler calls %break-in-frame directly, so handler-case
  ;; cannot catch it; bind ccl:*break-hook* (exported) to a function of (condition hook) that THROWs to
  ;; a CATCH established around FORM when CONDITION is of type ccl:interrupt-signal-condition, and
  ;; otherwise returns so other BREAKs behave as before. Elsewhere: FORM alone, Ctrl-C is not caught.
(defun %run-program-output (command))        ; COMMAND is a list of strings. Runs it with the process's own
                                             ; stdin (uiop :input :interactive), captures stdout as a string,
                                             ; discards stderr. Returns (values output-string exit-code);
                                             ; on ANY error (no such program, no tty, uiop limitation) returns
                                             ; (values "" nil). Never signals.
(defun %stream-external-format-name (stream)); a string naming the external format of STREAM after
                                             ; following synonym streams (symbol-value of the symbol,
                                             ; repeatedly) and two-way streams (output side); NIL for a
                                             ; string-stream (ECL reports :UCS-4 and CCL ISO-8859-1 for
                                             ; string streams, SBCL NIL: none says anything about the
                                             ; terminal) and NIL when unknown or on error. Otherwise
                                             ; (princ-to-string (stream-external-format s)): looks like
                                             ; "(UTF-8 REPLACEMENT ...)" on SBCL, "(UTF-8 LF)" on ECL,
                                             ; "#<EXTERNAL-FORMAT :UTF-8/:UNIX ...>" on CCL.
(defun %real-time-seconds ())                ; (/ (get-internal-real-time) internal-time-units-per-second) as a double-float
```

### 4.3 src/rules.lisp

```lisp
(defstruct (rule (:constructor %make-rule) (:copier nil))
  (birth    0  :type (unsigned-byte 9))   ; bit n set: a dead cell with n live neighbors is born
  (survival 0  :type (unsigned-byte 9))   ; bit n set: a live cell with n live neighbors survives
  (string "" :type string))               ; canonical text, e.g. "B3/S23"

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
  "Known rules: (key display-name rulestring). PARSE-RULE accepts the keys (case-insensitive;
'-', '_' and space are interchangeable); RULE-NICKNAME returns the display name.")

(defun parse-rule (designator))   ; -> rule
```

`parse-rule` accepts: a `rule` (returned as is); a string or symbol (its `symbol-name`).
Text handling: trim whitespace; drop everything from the first `:` (Golly's bounded-grid suffix
`B3/S23:T100,100`); match case-insensitively one of
- `B<digits>/S<digits>` (either digit set may be empty: `B2/S`),
- `B<digits>S<digits>` (no slash),
- `<digits>/<digits>` meaning `S<digits>/B<digits>` (the old S/B order: `23/3` is Life),
- a key in `*rule-names*` (after lowercasing and mapping `_` and space to `-`).
Digits are 0..8; a repeated digit is accepted once; anything else (`9`, letters, missing
parts, trailing garbage) signals `rule-syntax-error` whose report quotes the input. The
returned struct's `string` slot is canonical: `"B" + ascending birth digits + "/S" + ascending
survival digits.

```lisp
rule-string (rule)                    ; the defstruct accessor of the STRING slot (no DEFUN: SBCL/CCL warn)
(defun rule-nickname (rule))          ; display name from *rule-names* when the rule matches one, else nil
(defun rule-births (rule))            ; ascending list of integers, e.g. (3)
(defun rule-survivals (rule))         ; ascending list, e.g. (2 3)
(defun born-p (rule n))               ; n in 0..8 -> boolean
(defun survives-p (rule n))           ; n in 0..8 -> boolean
(defun next-state (rule alive-p n))   ; -> t when the cell is alive next generation
(defun rule-equal (a b))              ; same birth and survival masks
(defparameter *life-rule* (parse-rule "B3/S23"))   ; the default rule everywhere
```

`born-p` and `survives-p` are `(declaim (inline ...))`.

### 4.4 src/world.lisp

```lisp
(defstruct (rng (:constructor %make-rng) (:copier nil))
  (state 0 :type (unsigned-byte 64)))
(defun make-rng (&optional seed))   ; seed: any integer (masked to 64 bits); nil -> from the clock
(defun rng-next (rng))              ; splitmix64: state += #x9E3779B97F4A7C15; z = state;
                                    ; z = (z ^ z>>30) * #xBF58476D1CE4E5B9; z = (z ^ z>>27) * #x94D049BB133111EB;
                                    ; return z ^ z>>31, all modulo 2^64 -> (unsigned-byte 64)
(defun rng-unit (rng))              ; double-float in [0,1): (/ (ash (rng-next rng) -11) (expt 2d0 53))
(defun rng-chance (rng probability)); -> (< (rng-unit rng) probability)
```

Pure integer arithmetic, so a seed gives the same soup on every implementation.

```lisp
(defstruct (world (:constructor %make-world) (:copier nil))
  (cells      (make-hash-table) :type hash-table)   ; cell-key -> t
  (scratch    (make-hash-table) :type hash-table)   ; cell-key -> fixnum; empty between steps
  (rule       *life-rule*       :type rule)
  (topology   :plane            :type (member :plane :torus :box))
  (width      nil)                                  ; positive integer for :torus/:box, nil for :plane
  (height     nil)
  (generation 0 :type (integer 0))
  (births     0 :type (integer 0))                  ; of the most recent step
  (deaths     0 :type (integer 0)))

(defun make-world (&key (rule *life-rule*) (topology :plane) width height))
```

`rule` is any `parse-rule` designator. `:torus`/`:box` require `width` and `height` to be
positive integers, else `life-error`; for `:plane` they must be `nil` (given dimensions are
an error so a caller who meant a torus notices). Accessors `world-rule`, `world-topology`,
`world-width`, `world-height`, `world-generation`, `world-births`, `world-deaths` are the
struct readers (not setf-able in the public API except through the functions below).

```lisp
(defun copy-world (world))                 ; deep copy: new tables, same rule/topology/size/counters
(defun in-bounds-p (world x y))            ; plane: t; torus: t; box: 0<=x<w and 0<=y<h
(defun alive-p (world x y))                ; boolean; torus coordinates wrap; outside a box -> nil
(defun (setf alive-p) (value world x y))   ; sets (generalized boolean); torus wraps; outside a box: no-op.
                                           ; Returns VALUE.
(defun population (world))                 ; number of live cells
(defun live-cells (world))                 ; fresh list of (x . y), sorted by y then x
(defun clear-world (world))                ; removes every cell; keeps generation, rule, topology;
                                           ; births/deaths := 0. Returns the world.
(defun bounding-box (world))               ; (values min-x min-y max-x max-y), or nil when empty
(defun neighbor-count (world x y))         ; 0..8 live neighbors of (x,y) under the topology
(defun step-world (world &optional (n 1))) ; advances N generations (§3.2); returns the world
(defun place (world pattern &key x y))     ; see below; returns the world
(defun randomize (world &key (density 0.3) seed x y width height)) ; see below; returns the seed used
(defun world-equal (a b))                  ; t iff the two live-cell sets are identical (coordinates
                                           ; compared as given; rule/topology/generation ignored)
(defun world-fingerprint (world))          ; non-negative fixnum, order-independent, equal for
                                           ; world-equal worlds; see §3.3
```

`place`: `pattern` is a `pattern` struct, a built-in name (string or symbol, resolved with
`pattern`, §4.6), or a list of `(x . y)` cells (used as is, not normalized). `x`,`y` is
where the pattern's `(0,0)` lands. When both are `nil` the pattern is centered: torus/box at
`(floor (- width pw) 2)`, `(floor (- height ph) 2)`; plane at `(- (floor pw 2))`,
`(- (floor ph 2))`, where `pw`/`ph` are the pattern's width and height (for a cell list, its
bounding box). Giving only one of `x`,`y` is a `life-error`. Cells are set with
`(setf alive-p)`, so on a torus they wrap and on a box the part outside is dropped.

`randomize`: every cell of the rectangle `x,y,width,height` is set alive with probability
`density` (a real in [0,1]) using `(make-rng seed)`; cells outside the rectangle are
untouched. On a torus/box the rectangle defaults to the whole world; on the plane all four
must be given (else `life-error`). Returns the seed actually used (so a clock-derived seed
can be printed and replayed).

`world-fingerprint`: for each key `k`, `m = (ldb (byte 60 0) (* (logxor k (ash k -29)) #x9E3779B97F4A7C15))`
(or any similar mix); the fingerprint is the sum of the `m` modulo 2^60. Internal
`%snapshot` returns a fresh `simple-vector` of the keys sorted ascending; `%snapshot-equal`
compares two snapshots.

### 4.5 src/formats.lisp

```lisp
(defstruct (pattern (:constructor %make-pattern) (:copier nil))
  (name     nil)       ; string or nil
  (cells    '()  :type list)   ; (x . y), normalized (§2), sorted by y then x
  (width    0    :type (integer 0))
  (height   0    :type (integer 0))
  (rule     nil)       ; rule or nil (nil = "not stated", callers use *life-rule*)
  (comments '()  :type list))  ; strings

(defun make-pattern (cells &key name rule comments))   ; normalizes CELLS (any order, duplicates ok)
(defun pattern-population (pattern))                   ; (length cells)
(defun pattern-equal (a b))                            ; same cells (names, rules, comments ignored)
(defun rotate-pattern (pattern &optional (quarter-turns 1)))  ; clockwise; result normalized; keeps name/rule/comments
(defun flip-pattern (pattern &key horizontal vertical))       ; mirror left-right and/or top-bottom; normalized
(defun pattern-from-world (world &key name))           ; the world's live cells as a pattern; rule := (world-rule world)
```

Readers take a string and return a pattern. Writers take a pattern and a `destination` with
`format` semantics: `nil` returns a string, `t` writes to `*standard-output*`, a stream
writes to it; when writing to a stream they return `nil`. All readers strip `#\Return`
(CRLF files) and accept a final line without a newline.

**RLE** (`parse-rle string`), as Golly reads it:
- `#` lines: `#N text` sets the name (trimmed); `#C text`, `#c text`, `#O text` add a comment
  (text after the tag, trimmed); other `#` lines are ignored.
- The header line `x = W, y = H` optionally followed by `, rule = R` (keys case-insensitive,
  whitespace anywhere around `=` and `,`). `W`,`H` are read but the pattern's size is always
  its own bounding box (so leading blank rows/columns do not matter). `R` goes through
  `parse-rule`; if that fails the rule is `nil` and the string `"rule: R"` is added to the
  comments (patterns from the web with multi-state rules still load as cells).
- Data: digits accumulate a run count (default 1); `b`, `B` and `.` are dead runs; `o`, `O`
  and any other letter are live runs (multi-state files load with every state alive); `$` ends
  `count` rows; `!` ends the pattern (anything after it is ignored); whitespace is ignored
  between tokens; any other character signals `pattern-syntax-error` with the 1-based line.
  A count with no tag before `!` or end of text is ignored. Missing `!` is accepted. Missing
  header is accepted (cells inferred).
- Returns `(make-pattern cells :name name :rule rule :comments comments)`.

`write-rle pattern &optional destination`: `#N name` when the name is non-nil, one `#C`
line per comment, the header `x = W, y = H, rule = R` with `R` the canonical string of the
pattern's rule or of `*life-rule*` when `nil`, then the data: per row, runs of `b` and `o`
with trailing dead cells omitted, rows separated by `$` with consecutive empty rows collapsed
into `N$`, the last row ending in `!`; runs of length 1 have no count; data lines are at most
70 characters, broken only between tokens. The glider is
`x = 3, y = 3, rule = B3/S23` + newline + `bo$2bo$3o!` + newline. The empty pattern is
`x = 0, y = 0, rule = B3/S23` + newline + `!` + newline.

**Plaintext** (`parse-plaintext string`): lines starting with `!` are metadata: `!Name: X`
sets the name (case-insensitive key, trimmed value), any other `!` line is a comment (text
after `!`, trimmed). Other lines are rows: `.`, space, `-` and `0` are dead; any other
non-whitespace character is alive; rows may be ragged; blank lines are empty rows.
`write-plaintext pattern &optional destination`: `!Name: ...` when named, `!comment` lines,
then `height` rows of exactly `width` characters using `.` and `O`, each ending in a newline.
The empty pattern writes only its metadata lines (possibly nothing).

**Life 1.06** (`parse-life106 string`): the first line is `#Life 1.06`; `#` lines are
ignored; every other non-blank line is `x y` (two integers, may be negative, separated by
whitespace), anything else is a `pattern-syntax-error`. Returns a normalized pattern without
name.

```lisp
(defun parse-pattern (string &key format))   ; format :rle | :plaintext | :life106 | nil (detect)
(defun read-pattern-file (pathname &key format))     ; reads the file as UTF-8 text, then parse-pattern.
                                                     ; When the pattern has no name, the file's name
                                                     ; (pathname-name) becomes the name.
(defun write-pattern-file (pattern pathname &key (format :rle) (if-exists :supersede)))  ; :rle or :plaintext
```

Detection in `parse-pattern`: the text starts with `#Life 1.06` → Life 1.06; else if any line
that does not start with `#` or `!` matches the RLE header (`x` then optional space then `=`)
→ RLE; else if the text contains `!` and every non-`#` character is in `0-9 b o B O $ ! .`
plus whitespace → RLE; else plaintext. Formats are tried exactly once; errors propagate.

### 4.6 src/patterns.lisp

```lisp
(defstruct (pattern-entry (:copier nil))
  key name category period description text)   ; text is the plaintext drawing

(defmacro define-pattern (key name category period description text))
  ;; Registers (or replaces, by key) an entry at the end of the library. CATEGORY is one of
  ;; :still-life :oscillator :spaceship :methuselah :gun. PERIOD is an integer or nil.
(defun find-pattern-entry (name))   ; entry or nil; NAME string or symbol; case-insensitive;
                                    ; '-', '_' and space interchangeable ("Gosper glider gun" works)
(defun list-patterns ())            ; the entries in library order (a fresh list)
(defun print-pattern-list (&optional (stream *standard-output*)))
  ;; one line per entry: key, padded; category; "period N" or "-"; cells; description. Example:
  ;; glider              spaceship    period 4    5 cells  The smallest spaceship; moves one cell diagonally every four generations.
(defun pattern (designator))        ; -> pattern
```

`pattern` resolves: a `pattern` → itself; a `pathname` → `read-pattern-file`; a string or
symbol → the library entry (parsed from its drawing with `parse-plaintext`, `name` set to the
entry's display name, cached in the entry after first use), else if a file by that name exists
→ `read-pattern-file`, else `unknown-pattern-error`.

The library (keys, categories, periods, drawings; `O` alive, `.` dead). Every entry below is
checked by the tests in §5.4 (still lifes unchanged after a step; oscillators return exactly
at their period and not before; spaceships translate; methuselahs hit their known numbers;
the gun emits). An implementer who finds a drawing wrong fixes the drawing, not the test.

Still lifes (period 1):
```
block      OO          beehive  .OO.      loaf   .OO.     boat  OO.    tub  .O.    ship  OO.    pond  .OO.
           OO                   O..O             O..O           O.O         O.O          O.O         O..O
                                .OO.             .O.O           .O.         .O.          .OO         O..O
                                                 ..O.                                                .OO.
```
Oscillators:
```
blinker (2)   OOO
toad (2)      .OOO          beacon (2)  OO..        clock (2)  ..O.       figure-eight (8)  OOO...
              OOO.                      O...                   O.O.                         OOO...
                                        ...O                   .O.O                         OOO...
                                        ..OO                   .O..                         ...OOO
                                                                                            ...OOO
                                                                                            ...OOO
pentadecathlon (15)   ..O....O..
                      OO.OOOO.OO
                      ..O....O..
pulsar (3)            ..OOO...OOO..
                      .............
                      O....O.O....O
                      O....O.O....O
                      O....O.O....O
                      ..OOO...OOO..
                      .............
                      ..OOO...OOO..
                      O....O.O....O
                      O....O.O....O
                      O....O.O....O
                      .............
                      ..OOO...OOO..
galaxy (8), Kok's     OOOOOO.OO
                      OOOOOO.OO
                      .......OO
                      OO.....OO
                      OO.....OO
                      OO.....OO
                      OO.......
                      OO.OOOOOO
                      OO.OOOOOO
tumbler (14)          .O.....O.
                      O.O...O.O
                      O..O.O..O
                      ..O...O..
                      ..OO.OO..
```
Spaceships (period 4; the tests check |dx|,|dy| not direction):
```
glider  .O.      lwss  .O..O     mwss  ...O..     hwss  ...OO..
        ..O            O....           .O...O           .O....O
        OOO            O...O           O.....           O......
                       OOOO.           O....O           O.....O
                                       OOOOO.           OOOOOO.
```
Methuselahs (period nil):
```
r-pentomino  .OO     diehard  ......O.     acorn  .O.....
             OO.              OO......            ...O...
             .O.              .O...OOO            OO..OOO
```
Gun:
```
gosper-glider-gun (30)
........................O...........
......................O.O...........
............OO......OO............OO
...........O...O....OO............OO
OO........O.....O...OO..............
OO........O...O.OO....O.O...........
..........O.....O.......O...........
...........O...O....................
............OO......................
```
Display names: "Block", "Beehive", "Loaf", "Boat", "Tub", "Ship", "Pond", "Blinker", "Toad",
"Beacon", "Clock", "Figure eight", "Pentadecathlon", "Pulsar", "Kok's galaxy", "Tumbler",
"Glider", "Lightweight spaceship", "Middleweight spaceship", "Heavyweight spaceship",
"R-pentomino", "Diehard", "Acorn", "Gosper glider gun". Descriptions are one sentence each
(the gun: "The first known gun; emits a glider every 30 generations.").

### 4.7 src/terminal.lisp

```lisp
(defun ansi-clear ())                   ; "\e[2J"
(defun ansi-home ())                    ; "\e[H"
(defun ansi-hide-cursor ())             ; "\e[?25l"
(defun ansi-show-cursor ())             ; "\e[?25h"
(defun ansi-enter-alternate-screen ())  ; "\e[?1049h"
(defun ansi-leave-alternate-screen ())  ; "\e[?1049l"
  ;; all return fresh strings; nothing here writes
(defun %stty-command (&rest args))      ; ("sh" "-c" "trap '' TTOU; exec \"$0\" \"$@\"" "stty" . args); the only
                                        ; way this file runs stty (see below)
(defun parse-terminal-size (string))    ; "24 80" (stty's "rows cols") -> (values 80 24); nil if not two positive integers
(defun terminal-size ())                ; (values columns rows). Tries (%run-program-output (%stty-command "size")) and
                                        ; parse-terminal-size; then the COLUMNS and LINES environment variables;
                                        ; else 80 24. Never signals. (Not tput: with stdout captured it says 80.)
(defun utf8-output-p (&optional (stream *standard-output*)))
  ;; t when the stream can show the block characters: the external format name (§4.2) contains "UTF"
  ;; (case-insensitive); nil when a name is known and lacks it; when no name is known, LC_ALL, then
  ;; LC_CTYPE, then LANG decide the same way; when none is set, t. A string stream has no name by
  ;; construction (§4.2), so there the environment decides. On SBCL 2.6.10, ECL 26.5 and CCL 1.14 the
  ;; default external format is UTF-8 whatever LANG/LC_* say, so this is in practice t unless the Lisp
  ;; was started with a non-UTF-8 default; --ascii is the real escape hatch.
(defun read-key (&optional (stream *standard-input*)))
  ;; Non-blocking: nil when no byte is waiting ((read-char-no-hang stream nil nil); pass nil nil, with
  ;; the default eof-error-p all three implementations signal end-of-file at end of file). A lone ESC,
  ;; or ESC followed by more bytes (an arrow key), drains what is waiting and returns :escape.
  ;; Otherwise the character. Returns nil on end of file.
(defmacro with-raw-keyboard ((available-var) &body body))
  ;; Saves the terminal settings with `stty -g`, puts the terminal in non-canonical no-echo mode
  ;; (`stty -icanon -echo min 1 time 0`), binds AVAILABLE-VAR to t and runs BODY; restores the saved
  ;; settings in an unwind-protect cleanup (`stty <saved>`). When `stty -g` fails (no tty, no stty),
  ;; binds AVAILABLE-VAR to nil, changes nothing and runs BODY. AVAILABLE-VAR is declared ignorable
  ;; in the expansion.
(defmacro with-terminal-ui ((keys-var &key (stream '*standard-output*) (alternate-screen t) (keyboard t))
                            &body body))
  ;; Writes to STREAM: alternate screen on (when ALTERNATE-SCREEN), hide cursor, clear; runs BODY inside
  ;; with-raw-keyboard when KEYBOARD (else KEYS-VAR is nil); in the cleanup: show cursor, alternate
  ;; screen off (when it was turned on), finish-output. Returns BODY's values. KEYS-VAR is declared
  ;; ignorable in the expansion.
```

`stty` is run with the process's stdin (`:input :interactive`) so it acts on the user's terminal,
and always through `sh` with SIGTTOU ignored: `%stty-command` returns
`("sh" "-c" "trap '' TTOU; exec \"$0\" \"$@\"" "stty" arg ...)`, and `terminal-size` and
`with-raw-keyboard` reach `stty` only through it, on every implementation. Reason: CCL's
`run-program` puts the child in its own process group (`setpgid(0,0)` in
`exec-with-io-redirection`), so a child that changes terminal settings (`stty -icanon ...`,
`stty <saved>`) is stopped by SIGTTOU and `run-program` waits forever; reading (`stty -g`,
`stty size`) is unaffected. With SIGTTOU ignored the child's `tcsetattr` succeeds. SBCL and
ECL keep the child in the foreground process group, so the wrapper changes nothing there;
using it everywhere means the one code path is exercised by all three suites. The saved
`stty -g` string is one shell word on macOS and Linux (`gfmt1:cflag=...` / `500:5:bf:...`);
trim the trailing newline before passing it back. `read-key` never blocks: with `min 1 time 0`
the tty hands over bytes as they arrive and `(read-char-no-hang stream nil nil)` returns `nil`
when nothing is waiting. Arrow keys are ignored on purpose (returned as `:escape`, which the
run loop ignores; the plain Escape key is not bound either).

### 4.8 src/render.lisp

```lisp
(defstruct (viewport (:copier nil))
  (x 0 :type integer) (y 0 :type integer)              ; world coordinates of the top-left cell
  (width 1 :type (integer 1)) (height 1 :type (integer 1)))   ; in cells

(defun default-viewport (world columns rows))
  ;; torus/box: top-left (0,0), width (min world-width columns), height (min world-height rows).
  ;; plane: width COLUMNS, height ROWS, centered on the origin: x = (- (floor columns 2)), y = (- (floor rows 2)).
(defun following-viewport (world columns rows))
  ;; plane: COLUMNS x ROWS centered on the center of the bounding box (origin when empty);
  ;; torus/box: same as default-viewport.
(defun cells-per-row (style))           ; :blocks -> 2; :ascii, :dots -> 1
(defun frame-rows (style height))       ; text lines for HEIGHT cells: (ceiling height 2) for :blocks, else height
(defun render-frame (world viewport &key (style :blocks)))
  ;; -> string: (frame-rows style height) lines of exactly (viewport-width) characters, joined by
  ;; #\Newline, no trailing newline. :blocks pairs rows (2k, 2k+1): both live U+2588 FULL BLOCK,
  ;; top only U+2580 UPPER HALF BLOCK, bottom only U+2584 LOWER HALF BLOCK, neither #\Space; an odd
  ;; last row has a dead bottom half. :ascii uses #\# and #\Space; :dots uses #\O and #\. .
(defun status-line (world &key (width 80) fps paused seed follow (keys t)))
  ;; -> string of exactly WIDTH characters (padded with spaces, or truncated). Content, separated by
  ;; two spaces: "PAUSED" when PAUSED; "gen N"; "pop N"; the rule string; the topology with size
  ;; ("torus 80x46", "box 20x20", "plane"); "N fps" when FPS (an integer prints as is, another real with
  ;; one decimal: "2.5 fps"); "seed N" when SEED; "follow" when FOLLOW;
  ;; and when KEYS: "space pause  n step  +/- speed  f follow  r reseed  c clear  q quit".
(defun draw (world viewport &key (style :blocks) fps paused seed follow (keys t) (stream *standard-output*)))
  ;; Writes (ansi-home), the frame, a newline, and the status line (width = viewport width) to STREAM
  ;; with no trailing newline, then finish-output. Builds the whole text first and writes it with one
  ;; write-string (no flicker). Returns nil.
```

### 4.9 src/run.lisp

```lisp
(defstruct (stability-detector (:constructor %make-stability-detector) (:copier nil))
  (depth 64) (fingerprints ...) (snapshots ...) (count 0))   ; a ring of the DEPTH states before the current one
(defun make-stability-detector (&key (depth 64)))
(defun observe (detector world))
  ;; Compares the world's current state with the stored snapshots and returns the smallest p in
  ;; 1..depth such that the state equals the state recorded p observations ago (§3.3), or nil; only
  ;; then records the current state. Compare before storing (or keep depth+1 slots) so a period equal
  ;; to DEPTH is found; a DEPTH-slot ring that stores first can only find periods up to DEPTH-1. The
  ;; caller observes once per generation, after each step, and once for the initial state.

(defun simulate (world &key generations (stop-when-stable t) (history 64) on-step))
  ;; Headless loop. Returns (values outcome period):
  ;;   :extinct   population is 0 (checked before the first step and after every step; period nil)
  ;;   :periodic  STOP-WHEN-STABLE and the detector found period p (returns p); the world is at the
  ;;              generation where the repetition was detected
  ;;   :limit     GENERATIONS steps were taken (period nil)
  ;; ON-STEP, when given, is called with the world after each step. After each step the checks run in
  ;; this order: extinction, then stability (when STOP-WHEN-STABLE), then the GENERATIONS limit, so a
  ;; blinker with :generations 2 returns (values :periodic 2), not :limit. GENERATIONS nil with
  ;; STOP-WHEN-STABLE nil signals life-error ("would never return"). HISTORY is the detector depth.

(defparameter *fps-steps* #(1 2 4 8 15 20 30 60 120)
  "Speeds the + and - keys move between. A starting FPS not in the vector steps to the nearest entry.")

(defun run (world &key generations (fps 20) (style :blocks) viewport follow (stop-when-stable nil)
                       (history 64) reset seed (keyboard t) (alternate-screen t) (stream *standard-output*)))
  ;; Interactive loop inside with-terminal-ui. VIEWPORT defaults to (default-viewport world cols rows)
  ;; where (cols, rows) come from terminal-size with one row kept for the status line and rows
  ;; multiplied by (cells-per-row style). Each iteration: recompute the viewport when FOLLOW (plane only);
  ;; draw; handle every waiting key; unless paused, step once, then check extinction, then stability
  ;; when STOP-WHEN-STABLE, then the GENERATIONS limit (the same order as simulate); then pace.
  ;; Pacing: frames are paced against a running deadline, not the frame start. Before the loop
  ;; deadline := (%real-time-seconds); after each frame deadline += 1/fps and remaining := deadline - now;
  ;; when remaining > 0 sleep it (never call sleep with a negative number: all three implementations
  ;; signal a type error); when remaining < -1/fps (more than a frame behind, e.g. after a slow frame)
  ;; reset deadline := now so the loop does not try to catch up; when a key changes fps, deadline :=
  ;; now + 1/fps. Reason: sleep overshoots by 0.5-3 ms on all three implementations, so sleeping the
  ;; remainder measured from the frame start gives 18/46/88 fps for 20/60/120; the deadline scheme
  ;; gives the asked rate (and ~995 at the tests' :fps 1000).
  ;; Keys: space pause/resume; n or . step once (and pause); + or = faster, - slower (along *fps-steps*);
  ;; f toggle follow (plane only); c clear the world (and pause); r call RESET with the world when RESET
  ;; is non-nil (a reseed closure from the CLI; the new seed it returns, if an integer, replaces SEED in
  ;; the status line); q or Q quit. Ctrl-C is caught by wrapping the whole loop in %catch-interrupt
  ;; (outcome :interrupted); the with-terminal-ui cleanup still restores the terminal because the
  ;; interrupt unwinds through it.
  ;; Returns (values outcome period) with outcome :limit | :extinct | :periodic | :quit | :interrupted.
  ;; The final frame is drawn before returning so a bounded run ends on its last state.
```

When the keyboard is unavailable (no tty), the loop runs with the same pacing and stops on
`generations`, stability (if asked), extinction or Ctrl-C. `fps` must be a positive real.

### 4.10 src/cli.lisp

```lisp
(defparameter *version* "0.1.0")

(defun usage (&optional (stream *standard-output*)))   ; prints the help text below
(defun parse-arguments (args))   ; list of strings -> property list; signals usage-error
(defun summary-line (name world outcome period))       ; -> string, see below
(defun main (args))              ; -> exit code 0 (ok), 1 (life-error), 2 (usage-error); never exits
(defun main-entry ())            ; (%exit (main (%command-line-arguments))); the executable's entry point
```

Help text (exact option set; wording may be polished but every option must appear):

```
Usage: life [options] [PATTERN]

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
```

Parsing rules: `--opt value` and `--opt=value` both work; short options take the next
argument (`-g 100`); options and the positional may be in any order; `--` ends options; a
second positional, an unknown option, a missing or malformed value (`-W abc`, `-W 0`,
`-d 1.5`, `-f 0`) is a `usage-error` (exit 2, message plus `Try 'life --help'.` on
`*error-output*`). `random` and `soup` as PATTERN mean a soup.

`parse-arguments` returns a property list with exactly these keys (an option not given is
absent, which `getf` reads as `nil`): `:pattern` (string, or `nil` for a soup; `random` and
`soup` give `nil`), `:rule` (string), `:topology` (`:plane` | `:torus` | `:box`), `:width` and
`:height` (positive integers), `:density` (real in [0,1]), `:seed` (integer), `:generations`
(integer ≥ 0), `:fps` (positive real), `:style` (`:ascii` | `:dots`), `:follow`,
`:stop-when-stable`, `:headless`, `:list`, `:help`, `:version` (`t`), `:write` and `:show`
(strings). Numbers are parsed by the internal `%parse-integer` (optional sign, digits) and
`%parse-real` (digits with at most one `.`; an integer when there is no `.`, else a
`double-float`); anything else is a `usage-error`.

`--show P` prints one header line, then the pattern's rows exactly as `write-plaintext` writes
them (the `.`/`O` grid only, no `!` metadata lines). The header is
`Name (category, period N, M cells)` for a library pattern, with the category keyword
lowercased and `-` replaced by a space (`still life`, `oscillator`, `spaceship`, `methuselah`,
`gun`) and `, period N` omitted when the period is `nil`: `Glider (spaceship, period 4, 5 cells)`,
`Acorn (methuselah, 7 cells)`; for a file pattern it is `Name (M cells)`.

Edge cases: `--generations 0` is valid (no step is taken; the summary says `generation 0`, or
`extinct at generation 0` for an empty world). `--seed` and `--density` given with a pattern are
ignored (a pattern has no soup). `--follow` is ignored when headless and on a torus or box (then
it is neither shown in the status line nor passed to `run`). A pattern that does not fit the
torus or box (`pattern-width` > width or `pattern-height` > height) is a `life-error`:
`pattern 36x9 does not fit the 20x10 torus (use --width/--height or -t plane)`. On the plane a
pattern wider than the viewport is simply cut off at the edges (the world is infinite; `--follow`
recenters it). A file name with spaces is one positional argument, quoted by the shell.
`--write` with an empty world writes the empty pattern. A pattern file whose name has no `#N`
is named after the file (§4.5), so `life ./my glider.rle` reports `my glider: generation ...`.

Behavior of `main`:
1. `--help` → usage on `*standard-output*`, return 0. `--version` → `life 0.1.0`, 0.
   `--list` → `print-pattern-list`, 0. `--show P` → the header line and the rows described
   below, 0.
2. Resolve the rule (`parse-rule`; a `rule-syntax-error` → 1). Resolve the pattern with
   `pattern` (a file path or a name; errors → 1). A pattern file with its own rule uses that
   rule unless `--rule` was given.
3. Style: `--dots` → `:dots`; `--ascii` → `:ascii`; else `:blocks` when `(utf8-output-p)`,
   else `:ascii`. Terminal: `(terminal-size)` → columns, rows; viewport rows =
   `(* (1- rows) (cells-per-row style))` (the last line is the status line); `--width` and
   `--height` override the cell counts.
4. World: topology from `--topology` or the default (plane for a pattern, torus for a soup).
   Torus/box dimensions are the viewport cell counts. A pattern is placed centered
   (`place` with no `x`,`y`). A soup is `randomize` over the viewport rectangle (the plane
   uses the default viewport's rectangle) with `--density` and `--seed`; the seed used is
   kept for the status line and summary. The `reset` closure re-randomizes the same
   rectangle with a fresh clock seed and returns it.
5. Headless: `simulate` with `generations` (default 1000) and `stop-when-stable t`; print the
   summary line. Interactive: `run` with the options; after it returns (the terminal is
   restored), print the summary line.
6. `--write FILE`: `write-pattern-file (pattern-from-world world :name NAME) FILE`.
7. Return 0. Any `usage-error` → message, 2. Any other `life-error` → `life: <message>` on
   `*error-output*`, 1. Any other `error` → `life: <message>`, 1. Ctrl-C anywhere in steps 2-6,
   headless runs included, is caught by wrapping them in `%catch-interrupt` (§4.2): print
   `life: interrupted` on `*error-output*` and return 130 (`sb-sys:interactive-interrupt` and
   `ext:interactive-interrupt` are serious-conditions, not errors, and CCL never signals its
   condition at all, so the `error` clause does not see Ctrl-C; the executable would otherwise
   print a backtrace and exit 1).

`summary-line name world outcome period` where `name` is the pattern's display name or
`soup WxH density D seed S`:
```
:limit        "Glider: generation 4, population 5"
:extinct      "Diehard: extinct at generation 130"
:periodic     "Blinker: period 2 detected at generation 2, population 3"
:quit         "Glider: generation 240, population 5 (quit)"
:interrupted  "Glider: generation 240, population 5 (interrupted)"
```
Density prints with two decimals (`density 0.30`).

## 5. Tests

### 5.1 Harness (tests/harness.lisp)

Zero dependencies, modelled on JUJU's: `deftest`, `is`, `is-equal` (expected first),
`is-close`, `signals`, `run-all-tests (&key (verbose t))`, `run-test (name)`. Each test runs
under `handler-case`; an unhandled error is a failure. `run-all-tests` prints
`name ... ok | FAIL: reason` lines and `N checks, M failures`, returns `t` iff no failures,
and when non-interactive (`LIFE_NON_INTERACTIVE` set, `--non-interactive` in the raw argv,
or `%debugger-disabled-p`) flushes the streams and `%exit`s with 0 or 1 without unwinding.
Helpers: `(long-tests-p)` → `LIFE_LONG_TESTS` is set; `(with-captured-output (out err) &body)`
binds `*standard-output*` / `*error-output*` to string streams and returns
`(values body-value out-string err-string)`; `(temp-file name)` → a pathname under a fresh
directory in `(uiop:temporary-directory)`; `(cells-of pattern-name)`.

### 5.2 tests/test-rules.lisp

- `rules/parse-canonical`: `"B3/S23"`, `"b3/s23"`, `"B3S23"`, `"23/3"`, `" B3/S23 "`,
  `"B3/S23:T100,100"`, `:life`, `"Life"`, `"LIFE"` all → `rule-string` `"B3/S23"`.
- `rules/parse-others`: `"B2/S"` → births (2), survivals (); `"B36/S23"` → nickname
  `"HighLife"`; `"B3/S012345678"` nickname `"Life without Death"`; `"B332/S2"` → `"B23/S2"`
  (a repeated digit is accepted once); `"B3/S23"` has nickname `"Life"`, `"B3/S2"` has none.
- `rules/parse-errors`: `signals rule-syntax-error` for `"B9/S23"`, `"B3"`, `"S23/B3"`,
  `"B3/S23x"`, `""`, `"nosuchrule"`.
- `rules/predicates`: Life: born-p only at 3; survives-p at 2 and 3; `next-state`
  table for all n and both states; Seeds: survives-p never.
- `rules/equal-and-identity`: `(eq r (parse-rule r))`; `rule-equal` of `"B3/S23"` and
  `"23/3"`.

### 5.3 tests/test-world.lisp

- `world/make`: defaults (plane, nil dims, gen 0, pop 0); torus 10×5; `signals life-error`
  for torus without dims, box with width 0, plane with width.
- `world/set-get`: set cells, read back, negative coordinates on the plane; `(setf alive-p)`
  returns its value; clearing a cell with nil; population and live-cells sorted by y then x.
- `world/torus-wrap`: 10×10 torus: `(setf (alive-p w -1 -1) t)` is cell (9,9); `(alive-p w 19 9)`.
- `world/box-bounds`: `in-bounds-p`; setting outside is a no-op and population stays 0;
  `(alive-p w -1 0)` nil.
- `world/neighbor-count`: plane, torus (corner cell of a 5×5 torus with cells across the
  seam), box corner.
- `world/step-blinker`: horizontal blinker becomes vertical then horizontal; births 2 deaths 2;
  generation increments; `step-world w 2` returns the world.
- `world/step-block-still`: block unchanged; births 0 deaths 0.
- `world/glider-plane`: after 4 steps the live cells equal the original translated by (1,1)
  (compute translation from bounding boxes; check |dx| = |dy| = 1).
- `world/glider-torus-8`: 8×8 torus, glider: `world-equal` to a copy after 32 steps and not
  after 4, 8, 16.
- `world/box-glider-stays-inside`: 12×12 box, glider at (1,1), 100 steps: every live cell has
  0 ≤ x,y < 12 after each step.
- `world/seeds-rule`: B2/S soup 20×20 torus seed 1: no cell alive before a step is alive after it.
- `world/life-without-death`: B3/S012345678 soup: population never decreases over 20 steps.
- `world/randomize`: deterministic with the same seed (two worlds `world-equal`); different
  seeds differ; density 0 → empty; density 1 → full; returns the seed; plane without a
  rectangle signals; the rectangle bounds are respected (cells outside untouched).
- `world/rng`: splitmix64 reference: `(make-rng 0)` → first output `#xE220A8397B1DCDAF`,
  second `#x6E789E6AA1B965F4`; `rng-unit` in [0,1); `(make-rng 1234)` on two instances agree.
- `world/copy-equal-fingerprint`: copy is `world-equal` and has the same fingerprint; mutate
  the copy → not equal, fingerprint differs; fingerprint is independent of insertion order.
- `world/place`: `place` with a pattern struct, a name, a cell list; explicit x,y; centered on
  a 10×10 torus (glider's top-left at (3,3)); centered on the plane (top-left at (-1,-1));
  only-one-coordinate signals.
- `world/print-object`: `(princ-to-string w)` contains "plane" and "pop".

### 5.4 tests/test-patterns.lisp

For every entry of `(list-patterns)`:
- `patterns/library-parses`: `pattern` returns a pattern with the entry's name, population > 0.
- `patterns/still-lifes`: category `:still-life` → after one step `world-equal` to the start.
- `patterns/oscillators`: category `:oscillator` with period p → equals the start after p steps
  and differs at every step 1..p-1.
- `patterns/spaceships`: period 4; after 4 steps the cells are a translation of the start with
  (|dx|,|dy|) = (1,1) for glider and (2,0) for lwss/mwss/hwss (compare via bounding boxes).
- `patterns/populations`: glider 5, lwss 9, mwss 11, hwss 13, pulsar 48, pentadecathlon 12,
  galaxy 48, gosper-glider-gun 36, r-pentomino 5, diehard 7, acorn 7, block 4, beehive 6.
- `patterns/diehard`: plane; population 0 at generation 130 and > 0 at 129.
- `patterns/r-pentomino`: plane; population 116 at generation 1103 and at every generation
  1104..1120.
- `patterns/acorn` (only when `long-tests-p`, otherwise prints `skipped`): plane; population
  633 at generation 5206.
- `patterns/gosper-gun`: plane; populations at generations 30,60,...,180 increase by exactly 5
  each time.
- `patterns/lookup`: `find-pattern-entry` with `"Gosper glider gun"`, `"gosper_glider_gun"`,
  `:glider`; `(pattern "nosuch")` signals `unknown-pattern-error` whose report mentions `--list`.
- `patterns/print-list`: output contains every key and the word `spaceship`.

### 5.5 tests/test-formats.lisp

- `formats/make-pattern-normalizes`: offset, duplicated, unsorted cells → normalized, 3×3.
- `formats/rle-glider`: `parse-rle` of this text, embedded in the test as a string (the LifeWiki /
  Golly glider file): `#N Glider` / `#O Richard K. Guy` / `#C The smallest, most common, and first
  discovered spaceship. Diagonal, has period 4 and speed c/4.` /
  `#C www.conwaylife.com/wiki/index.php?title=Glider` / `x = 3, y = 3, rule = B3/S23` / `bob$2bo$3o!`
  → name `"Glider"`, three comments in file order (the `#O` line first), rule B3/S23, the glider's
  cells (the trailing dead cell of `bob$` is dropped); `write-rle` of that pattern → exactly these six
  lines, each ending in a newline: `#N Glider`, `#C Richard K. Guy`, `#C The smallest, most common,
  and first discovered spaceship. Diagonal, has period 4 and speed c/4.`,
  `#C www.conwaylife.com/wiki/index.php?title=Glider`, `x = 3, y = 3, rule = B3/S23`, `bo$2bo$3o!`.
- `formats/rle-round-trip`: every library pattern: `(pattern-equal p (parse-rle (write-rle p)))`;
  the pulsar's data wraps at ≤ 70 columns.
- `formats/rle-edge-cases`: no header; no `!`; multi-row `3$`; CRLF; `rule = B36/S23` →
  HighLife; `rule = LifeHistory` → rule nil and a comment; count before `!` ignored; uppercase
  `O`/`B`; `signals pattern-syntax-error` for `bo$2bo$3%!` and the line number is 1 (or the
  right line when preceded by header lines); empty pattern writes `x = 0, y = 0, rule = B3/S23`
  and `!`.
- `formats/plaintext`: parse with `!Name: Glider` and a comment; ragged rows; `*` and `#`
  alive; round trip through `write-plaintext`; exact output for the glider:
  `!Name: Glider` newline `.O.` newline `..O` newline `OOO` newline.
- `formats/life106`: `#Life 1.06` with negative coordinates → normalized glider;
  bad line signals.
- `formats/detect`: `parse-pattern` picks each format by content; `read-pattern-file` on three
  temp files (`.rle`, `.cells`, `.lif`) and `write-pattern-file` in both formats; a file
  without `#N` gets the file name.
- `formats/rotate-flip`: rotating the glider 4 times gives the glider; 2 quarter turns equals
  flipping both ways; `flip-pattern :horizontal t` of `.O.`/`..O`/`OOO` is `.O.`/`O..`/`OOO`.
- `formats/from-world`: `pattern-from-world` of a torus with a glider → pattern-equal to the
  glider, rule = the world's rule.

### 5.6 tests/test-render.lisp

- `render/blinker-dots`: 3×3 world with a horizontal blinker in row 1 → `"...\nOOO\n..."`.
- `render/blinker-ascii`: `"   \n###\n   "`.
- `render/blinker-blocks`: rows (0,1) → three LOWER HALF BLOCKs; row 2 alone → three spaces;
  a vertical blinker in column 1, rows 0..2 → line 1 `" █ "`, line 2 `" ▀ "`.
- `render/viewport-offsets`: plane with a cell at (-5,-5) and a viewport at (-6,-6) 3×3 → the
  cell shows at column 1 row 1; `default-viewport` for a torus is clamped to the world;
  `following-viewport` centers on the bounding box.
- `render/frame-rows`: `(frame-rows :blocks 5)` → 3; `(frame-rows :ascii 5)` → 5.
- `render/status-line`: exactly `width` characters; contains `gen 0`, `pop 3`, `B3/S23`,
  `plane`, `20 fps`, `seed 7`, `PAUSED` when paused; truncation at width 10.
- `render/draw`: to a string stream: starts with `ESC[H`, contains the frame and the status
  line, no trailing newline.

### 5.7 tests/test-run.lisp

- `run/simulate-outcomes`: blinker → `(values :periodic 2)` at generation 2; block → `:periodic 1`
  at generation 1; diehard → `:extinct` at 130; glider `:generations 8` → `:limit` at 8 (the
  glider never repeats on the plane); empty world → `:extinct` at generation 0; `generations nil`
  + `stop-when-stable nil` signals life-error; `on-step` called `generations` times.
- `run/detector`: `observe` on a hand-driven world finds period 2 for a blinker (returned by the
  third observation), nil for a glider within 20 steps, and respects `depth`: a period-3 pulsar is
  not found with depth 2 and is found (period 3, by the fourth observation) with depth 3.
- `run/run-headless-stream`: `run` on a string stream with `:keyboard nil :alternate-screen nil
  :generations 3 :fps 1000` → `(values :limit nil)`; output contains `ESC[?25l`, `ESC[H`, the
  status text `gen 3`, and ends with `ESC[?25h`; the alternate-screen sequences are absent.
- `run/run-alternate-screen`: same with `:alternate-screen t` → starts with `ESC[?1049h`, ends
  with `ESC[?1049l`.
- `run/run-stop-when-stable`: blinker, `:stop-when-stable t`, no generations → `:periodic 2`.
- `run/fps-steps`: `*fps-steps*` is ascending.

### 5.8 tests/test-terminal.lisp

- `terminal/ansi`: the six strings are exactly as specified.
- `terminal/parse-size`: `"24 80"` → 80 24; `"24 80\n"`; `"x"` → nil; `"0 80"` → nil.
- `terminal/size-never-fails`: `terminal-size` returns two positive integers (no tty here).
- `terminal/utf8-output-p`: returns a boolean; on a string stream (no external format)
  the environment decides.
- `terminal/read-key`: on a string stream with `"q"` → `#\q`; `""` → nil; `(format nil
  "~C[A" #\Esc)` → `:escape`.
- `terminal/with-raw-keyboard-no-tty`: `with-raw-keyboard` binds `available` to nil here
  (stdin is not a tty in the test run) and runs the body.

### 5.9 tests/test-cli.lisp

Every test binds the output streams with `with-captured-output`.
- `cli/help-version-list`: `--help` → 0, output has `Usage:` and `--headless`; `--version` → 0,
  `life 0.1.0`; `--list` → 0, output has `glider` and `gosper-glider-gun`; `-l` same.
- `cli/show`: `--show glider` → 0, output contains `Glider (spaceship, period 4, 5 cells)` and
  `.O.` / `..O` / `OOO`.
- `cli/usage-errors`: `--bogus`, `-W abc`, `-W 0`, `-d 2`, `-f 0`, two positionals,
  `-t sphere` → 2 and stderr contains `Try 'life --help'`.
- `cli/unknown-pattern`: `nosuchpattern --headless -g 1` → 1 and stderr mentions `--list`.
- `cli/headless-facts`: `r-pentomino --headless -g 1103` → 0, stdout
  `R-pentomino: generation 1103, population 116`; `diehard --headless` → `Diehard: extinct at
  generation 130`; `blinker --headless` → `Blinker: period 2 detected at generation 2, population 3`;
  `glider --headless -g 8` → `Glider: generation 8, population 5`.
- `cli/headless-soup`: `--headless -g 5 -s 7 -W 20 -H 10` → 0, stdout starts with
  `soup 20x10 density 0.30 seed 7:`; the same arguments twice give identical output; `-d 0`
  → `extinct at generation 0`.
- `cli/rule-and-topology`: `blinker --headless -r seeds` → `Blinker: extinct at generation 5` (Seeds
  has no survival; the blinker's populations under it are 3, 4, 8, 8, 20, 0); `glider --headless -t
  torus -W 8 -H 8 -g 40` → `period 32 detected at generation 32`; `--rule B9` → 1.
- `cli/write`: `glider --headless -g 4 --write <temp>.rle` → the file parses to a glider.
- `cli/parse-arguments`: `--opt=value` and `-g 100` forms; `--` ends options; `random` → soup.
- `cli/file-pattern`: write a plaintext glider to a temp file; `main` with that path
  `--headless -g 4` → `population 5`, name from the file.

### 5.10 Portability and build checks (not in the suite)

Run by the Makefile / CI: forced build with no `WARNING` on SBCL, ECL, CCL; the suite on all
three; `make bin`; `bin/life --list`; `bin/life r-pentomino --headless -g 1103`; and an
interactive smoke test through a pseudo-terminal (`python3 -c 'import pty,...'`) that starts
`bin/life glider -g 30 -f 200`, sends `q`, and checks the output contains the alternate-screen
and cursor sequences and the summary line, and that the terminal is back in canonical, echoing
mode afterwards (the pty's termios has ICANON and ECHO set again). Do not compare `stty -g`
strings or whole termios structures: on macOS the kernel sets the transient `pendin` flag when
ICANON is turned back on (lflag `5cb` becomes `200005cb` until the next read), so they differ
although every setting was restored. The pty must be given a window size (TIOCSWINSZ) or
`stty size` reports `0 0` and the program falls back to 80x24.

## 6. README outline

1. Title, one-paragraph pitch, a screenshot-like text block of a running gun.
2. Requirements (SBCL; ECL and CCL work too; `stty` for keys; a UTF-8 terminal for blocks).
3. Quick start: `make bin`, `bin/life`, `bin/life gosper-glider-gun`, `bin/life -r highlife`,
   `bin/life acorn --headless -g 5206`; the keys.
4. At the REPL: load, make a world, place, step, inspect; a torus; a custom rule; load a file;
   write a file; rotate/flip.
5. Patterns table (from `--list`), formats accepted and written, rules and names, topologies.
6. Tests: `make test`, `make test-ecl`, `make test-ccl`; `LIFE_LONG_TESTS=1`.
7. Design pointer (DESIGN.md), license.

## 7. Build, Makefile, CI

`game-of-life.asd` starts with `(require :asdf)` `(in-package :asdf-user)` so it can be
`--load`ed directly. System `game-of-life`: `:serial t`, a `(:module "src" ...)` component with
the files in load order, `:build-operation "program-op"`, `:build-pathname "bin/life"`,
`:entry-point "game-of-life:main-entry"`, `:in-order-to ((test-op (test-op "game-of-life/tests")))`.
System `game-of-life/tests`: `(:module "tests" ...)` with harness first; `:perform (test-op ...)`
calls `game-of-life-test:run-all-tests` and errors when it returns nil. Both systems work with
ASDF 3.1.8 (ECL's bundled version): no features newer than that.

Makefile targets: `build`, `build-ecl`, `build-ccl` (forced compiles failing when the log matches `grep -i warning`),
`test`, `test-ecl`, `test-ccl`, `test-all`, `bin` (`mkdir -p bin` then `(asdf:make
:game-of-life)` on SBCL), `run` (`bin/life $(ARGS)`), `patterns` (writes every built-in as
`patterns/<key>.rle` through `write-pattern-file`), `clean`. ECL runs get the debugger hook
from JUJU's CI so an unhandled error exits non-zero instead of waiting on stdin; CCL runs use
`--batch`.

CI (`.github/workflows/ci.yml`): SBCL on ubuntu-latest and macos-latest (forced build with the
case-insensitive warning grep, suite with `LIFE_LONG_TESTS=1`, `make bin`, `bin/life --list`,
`bin/life r-pentomino --headless -g 1103 | grep "population 116"`); ECL on macos-latest
(forced build, suite). `.gitignore`: `*.fasl`, `*.fas`, `*.lib`, `*.o`, `bin/`, `.DS_Store`.
License Apache-2.0, `Copyright 2026 Julio Jimenez`.

## 8. Oracles, risks, later work

Oracles (infinite plane, B3/S23): R-pentomino stabilizes at generation 1103 with 116 cells and
the population then stays 116; Diehard vanishes at generation 130; Acorn stabilizes at
generation 5206 with 633 cells; the Gosper glider gun has period 30 and adds one glider
(5 cells) per period; a glider on an 8×8 torus has period 32; splitmix64 from seed 0 yields
E220A8397B1DCDAF then 6E789E6AA1B965F4.

Risks: `read-char-no-hang` under `stty -icanon -echo min 1 time 0` behaves identically on SBCL,
ECL and CCL (nil when idle, the character when one is waiting, an arrow key drains as ESC [ A);
the CCL-specific risks are its `run-program` process group (handled by `%stty-command`) and its
Ctrl-C delivery (handled by `%catch-interrupt`, §4.2). ECL's bundled ASDF is 3.1.8. A terminal
without UTF-8 is not detectable from the Lisp (all three default to UTF-8 whatever the locale),
so `--ascii` is the escape hatch. `stty` is POSIX only (Windows gets no keys).

Later: cell ages / colors (half blocks with foreground and background colors), Hashlife,
a `--step N` option for drawing every Nth generation, pattern search by population,
mouse editing, Life 1.05 and macrocell formats, an RLE `#P`/`#R` position tag.

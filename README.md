# Game of Life

**Conway's Game of Life in pure Common Lisp: a library for the REPL, a terminal viewer and a
headless command line, all on one engine.** A world is a hash table of live cells, so a step costs
in proportion to the population, not the area. Any Life-like rule (`B3/S23`, `B36/S23`, `B2/S`),
three topologies (plane, torus, box), a built-in pattern library, and RLE, plaintext and Life 1.06
files in and out. SBCL is the reference platform; ECL and CCL pass the same suite. No FFI.

```
                                              ▄
                                  ▄▄      ▄▄▀ ▀         ▄▄
                      ▄▄        ▄▀   ▀▄   ██            ▀▀
                      ▀▀        █   ▀ █▀    ▀ █
                                 ▀▄▄ ▀
                                             ▀▄▄
                                             ▀▀


                                                    ▀▄█
                                                     ▀

                                                            ▄
                                                            ▄█▀
gen 120  pop 56  B3/S23  plane  20 fps  space pause  n step  +/- speed  f follow
```

`bin/life gosper-glider-gun` at generation 120, cropped above the gun. Half blocks pack two cell
rows into one character row so cells look square; the status line is cut at the terminal width.

## Requirements

- SBCL 2.6.10 (ASDF is bundled): the reference platform, developed on macOS arm64, CI on Ubuntu
  and macOS. ECL 26.5 and CCL 1.14 load the system and pass the whole suite; everything
  implementation-specific lives in `src/compat.lisp`. `bin/life` is built with SBCL.
- `stty` (POSIX) for the keys and the terminal size; there is no FFI. Without it, or without a tty,
  the viewer still runs and stops on `--generations`, `--stop-when-stable`, extinction or Ctrl-C.
- A UTF-8 terminal for the half blocks (`▀ ▄ █`), else `--ascii` (`#` and space) or `--dots` (`O`
  and `.`); the Lisp cannot detect a non-UTF-8 terminal, so `--ascii` is the escape hatch.
- `make`; `python3` only for `make smoke`. No Quicklisp, no third-party libraries (only ASDF's
  own uiop): `game-of-life.asd` and `src/` are all you need.

## Quick start

```sh
make bin                             # builds bin/life with SBCL
bin/life                             # a random soup on a torus the size of the terminal
bin/life gosper-glider-gun           # a built-in pattern on the infinite plane
bin/life -r highlife                 # a soup under HighLife (B36/S23)
bin/life acorn --headless -g 5206    # Acorn: generation 5206, population 633
```

Keys: `space` pause/resume, `n` or `.` step one generation (and pause), `+` or `=` faster and `-`
slower (20 generations per second to start; the steps are 1 2 4 8 15 20 30 60 120), `f` follow the
live cells (plane only), `c` clear the world (and pause), `r` reseed the soup, `q` or `Q` quit.
Ctrl-C quits too. A soup's seed is in the status line; `-s N` replays it on every implementation.

`--headless` runs without a display and prints one summary line. It implies `--stop-when-stable`:
the run ends at `--generations` (default 1000), when the world repeats (period up to 64) or dies out:

```sh
bin/life r-pentomino --headless -g 1103               # R-pentomino: generation 1103, population 116
bin/life diehard --headless                           # Diehard: extinct at generation 130
bin/life blinker --headless                           # Blinker: period 2 detected at generation 2, population 3
bin/life glider -t torus -W 8 -H 8 --headless -g 40   # Glider: period 32 detected at generation 32, population 5
```

Options, each as `--opt value` or `--opt=value`: `-r/--rule`, `-t/--topology` (`plane`, `torus` or
`box`; default plane for a pattern, torus for a soup), `-W/--width` and `-H/--height` (world size on
a torus or box, viewport size on the plane; default the terminal), `-d/--density` (default 0.3),
`-s/--seed`, `-g/--generations`, `-f/--fps` (default 20), `--ascii`, `--dots`, `--follow`,
`--stop-when-stable`, `--headless`, `--write FILE` (the final world as RLE), `-l/--list`,
`--show PATTERN`, `--version`, `-h/--help`. PATTERN is a built-in key or a path to an RLE, plaintext
or Life 1.06 file; `random` or `soup` means a soup. Exit status is 0, 1 for a Life error (unknown
pattern, bad rule, a pattern too big for its torus), 2 for a usage error.

## At the REPL

Start `sbcl` (or `ecl`, or `ccl`) in the checkout, `(load "game-of-life.asd")`, then
`(asdf:load-system :game-of-life)`. The package is `game-of-life`, nickname `life`. A cell is an
`(x . y)` cons; `x` grows to the right and `y` downward, as in a file. `simulate` is the headless
loop: it returns `:extinct`, `:periodic` with the period, or `:limit`.

```lisp
(defparameter w (life:make-world))   ; the infinite plane: #<WORLD plane gen 0 pop 0>
(life:place w "glider")              ; => #<WORLD plane gen 0 pop 5>, centered: top-left at (-1,-1)
(life:step-world w 4)                ; => #<WORLD plane gen 4 pop 5>
(life:live-cells w)                  ; => ((1 . 0) (2 . 1) (0 . 2) (1 . 2) (2 . 2)), one cell down-right
(life:population w)                  ; => 5
(life:alive-p w 1 0)                 ; => T
(life:bounding-box w)                ; => 0, 0, 2, 2
(life:simulate w :generations 100)   ; => :LIMIT, NIL  (a glider never repeats on the plane)
(defparameter d (life:place (life:make-world) "diehard"))
(life:simulate d)                    ; => :EXTINCT, NIL
(life:world-generation d)            ; => 130
(life:simulate (life:place (life:make-world :topology :torus :width 8 :height 8) "glider"))
                                     ; => :PERIODIC, 32
```

A torus wraps (a `:box` of the same size instead treats everything outside it as dead):

```lisp
(defparameter torus (life:make-world :topology :torus :width 40 :height 20))
(life:place torus "glider")          ; centered: top-left at (18,8)
(life:world-equal torus (life:step-world (life:copy-world torus) 160))   ; => T, back after 160
(setf (life:alive-p torus -1 -1) t)  ; wraps to (39,19)
(life:alive-p torus 39 19)           ; => T
```

Rules are any `parse-rule` designator; `:rule` of `make-world` takes the same thing:

```lisp
(life:parse-rule "B36/S23")                        ; => #<RULE B36/S23>; "B36S23", "23/36", "highlife" too
(life:rule-nickname (life:parse-rule "B36/S23"))   ; => "HighLife"
(life:world-rule (life:make-world :rule "seeds"))  ; => #<RULE B2/S>
```

Files, both ways: reading detects the format from the content, writing is RLE unless
`:format :plaintext` is given, and `pattern-from-world` carries the world's rule along.

```lisp
(life:read-pattern-file #p"my.rle")                      ; RLE, plaintext or Life 1.06
(life:write-pattern-file (life:pattern-from-world w) #p"out.rle")
(life:write-pattern-file (life:pattern-from-world w :name "Mine") #p"out.cells" :format :plaintext)
(life:write-rle (life:pattern "glider") t)               ; to *standard-output*; nil returns a string
;; #N Glider
;; x = 3, y = 3, rule = B3/S23
;; bo$2bo$3o!
```

`rotate-pattern` (quarter turns clockwise) and `flip-pattern` return new patterns and keep the name.

```lisp
(life:write-plaintext (life:rotate-pattern (life:pattern "glider")) t)
;; !Name: Glider
;; O..
;; O.O
;; OO.
(life:flip-pattern (life:pattern "glider") :horizontal t)   ; mirror left-right: .O. / O.. / OOO
```

## Patterns, formats, rules, topologies

The built-in library, as `bin/life --list` and `(life:print-pattern-list)` print it. Keys are
case-insensitive and `-`, `_` and space are interchangeable (`"Gosper glider gun"` works); a key
that is not in the library is tried as a file path. `make patterns` writes every entry to
`patterns/<key>.rle`. The methuselahs are the tests' oracles: R-pentomino 116 cells from generation
1103 on, Diehard gone at 130, Acorn 633 cells at 5206. The gun adds a glider every 30 generations.

| Key | Name | Category | Period | Cells |
|-----|------|----------|--------|-------|
| `block` | Block | still life | 1 | 4 |
| `beehive` | Beehive | still life | 1 | 6 |
| `loaf` | Loaf | still life | 1 | 7 |
| `boat` | Boat | still life | 1 | 5 |
| `tub` | Tub | still life | 1 | 4 |
| `ship` | Ship | still life | 1 | 6 |
| `pond` | Pond | still life | 1 | 8 |
| `blinker` | Blinker | oscillator | 2 | 3 |
| `toad` | Toad | oscillator | 2 | 6 |
| `beacon` | Beacon | oscillator | 2 | 6 |
| `clock` | Clock | oscillator | 2 | 6 |
| `figure-eight` | Figure eight | oscillator | 8 | 18 |
| `pentadecathlon` | Pentadecathlon | oscillator | 15 | 12 |
| `pulsar` | Pulsar | oscillator | 3 | 48 |
| `galaxy` | Kok's galaxy | oscillator | 8 | 48 |
| `tumbler` | Tumbler | oscillator | 14 | 16 |
| `glider` | Glider | spaceship | 4 | 5 |
| `lwss` | Lightweight spaceship | spaceship | 4 | 9 |
| `mwss` | Middleweight spaceship | spaceship | 4 | 11 |
| `hwss` | Heavyweight spaceship | spaceship | 4 | 13 |
| `r-pentomino` | R-pentomino | methuselah | - | 5 |
| `diehard` | Diehard | methuselah | - | 7 |
| `acorn` | Acorn | methuselah | - | 7 |
| `gosper-glider-gun` | Gosper glider gun | gun | 30 | 36 |

Formats. **RLE** (`.rle`), as Golly reads it: `#N` name, `#C` comments, an optional
`x = W, y = H, rule = R` header, `b`/`o`/`$`/`!` data; an unknown rule is kept as a comment. Written
by `--write` and `write-pattern-file`, data lines wrapped at 70 columns. **Plaintext** (`.cells`):
`!Name:` and `!` comment lines, then rows of `.` and `O`; read and written. **Life 1.06** (`.lif`):
`#Life 1.06`, then `x y` pairs, negative allowed; read only. Unnamed patterns take the file's name.

Rules. A Life-like rule is a set of birth counts and a set of survival counts, each from 0..8; the
canonical text is `B3/S23`. `parse-rule` and `--rule` accept `B3/S23`, `b3/s23`, `B3S23`, `23/3`
(the old S/B order), Golly's `B3/S23:T100,100` (the suffix is dropped) and these names,
case-insensitive, with `-`, `_` and space interchangeable:

| Name | Rule | | Name | Rule |
|------|------|-|------|------|
| `life` (Life) | B3/S23 | | `2x2` (2x2) | B36/S125 |
| `highlife` (HighLife) | B36/S23 | | `life-without-death` (Life without Death) | B3/S012345678 |
| `seeds` (Seeds) | B2/S | | `morley` (Morley) | B368/S245 |
| `day-and-night` (Day & Night) | B3678/S34678 | | `replicator` (Replicator) | B1357/S1357 |
| `diamoeba` (Diamoeba) | B35678/S5678 | | `maze` (Maze) | B3/S12345 |
| `anneal` (Anneal) | B4678/S35678 | | | |

Topologies. `:plane` is unbounded (`width` and `height` are `nil`; `-W`/`-H` size the viewport and
`--follow` keeps it on the live cells). `:torus` wraps coordinates modulo `width` and `height`.
`:box` treats everything outside `0 ≤ x < width`, `0 ≤ y < height` as dead and unsettable. Both need
positive dimensions, and a pattern that does not fit one is an error; the plane just cuts it off.

## Tests

```sh
make test                      # the suite on SBCL
make test-ecl                  # the suite on ECL
make test-ccl                  # the suite on CCL
LIFE_LONG_TESTS=1 make test    # adds the slow oracle (Acorn: 633 cells at generation 5206)
make smoke                     # drives bin/life through a pseudo-terminal: keys, screen, terminal restore
```

The suite is a hand-written harness (`tests/harness.lisp`) with no dependencies, one test file per
module; every built-in pattern is checked (still lifes do not change, oscillators return exactly at
their period and not before, spaceships translate, methuselahs hit their numbers, the gun emits).
`make test-all` runs all three Lisps; `make build` is a forced compile that fails on any compiler
warning. A failing test exits non-zero (`LIFE_NON_INTERACTIVE=1` on ECL and CCL; SBCL's
`--non-interactive` implies it). CI does the forced build, the suite with `LIFE_LONG_TESTS=1`,
`make bin` and the R-pentomino check on SBCL (Ubuntu and macOS), and the build and suite on ECL.

## Design and license

`DESIGN.md` is the specification and wins over the code: cell keys and the sparse step, stability
detection, every public signature with its defaults and return values, the tests and the build.
Where it is wrong, it is fixed first, then the code. License: [Apache 2.0](LICENSE).

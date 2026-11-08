;;;; src/world.lisp — the world: packed cell keys, the splitmix64 generator, the sparse step for the
;;;; plane, the torus and the box, place, randomize, equality and fingerprints (DESIGN.md §3, §4.4).

(in-package :game-of-life)

(%muffle-compiler-notes)

;;; ------------------------------------------------------------------------------------------
;;; Cell keys (§3.1)
;;; ------------------------------------------------------------------------------------------

(deftype coordinate ()
  "A cell coordinate: 30 bits, so two of them pack into one 60-bit fixnum on every implementation."
  '(signed-byte 30))

(deftype cell-key ()
  "A packed (x, y) pair: y in the high 30 bits, x in the low 30, both two's complement."
  '(unsigned-byte 60))

(declaim (inline %sign-extend %pack %unpack-x %unpack-y))

(defun %sign-extend (v)
  "The 30-bit two's complement field V as a signed integer."
  (declare (type (unsigned-byte 30) v))
  (if (logbitp 29 v) (- v (ash 1 30)) v))

(defun %pack (x y)
  "The cell key of (X, Y)."
  (declare (type coordinate x y))
  (logior (ash (ldb (byte 30 0) y) 30) (ldb (byte 30 0) x)))

(defun %unpack-x (key)
  "The x coordinate of KEY."
  (declare (type cell-key key))
  (%sign-extend (ldb (byte 30 0) key)))

(defun %unpack-y (key)
  "The y coordinate of KEY."
  (declare (type cell-key key))
  (%sign-extend (ldb (byte 30 30) key)))

(defun %sort-cells (cells)
  "CELLS, a list of (x . y), sorted destructively by y then x."
  (sort cells (lambda (a b)
                (or (< (cdr a) (cdr b))
                    (and (= (cdr a) (cdr b)) (< (car a) (car b)))))))

;;; ------------------------------------------------------------------------------------------
;;; Random numbers: splitmix64
;;; ------------------------------------------------------------------------------------------

(defstruct (rng (:constructor %make-rng) (:copier nil))
  "A splitmix64 generator; pure integer arithmetic, so a seed gives the same stream everywhere."
  (state 0 :type (unsigned-byte 64)))

(defun make-rng (&optional seed)
  "A generator seeded with SEED (any integer, taken modulo 2^64); NIL seeds it from the clock."
  (%make-rng :state (ldb (byte 64 0)
                         (or seed (logxor (* (get-universal-time) 1000003)
                                          (get-internal-real-time))))))

(defun rng-next (rng)
  "The next 64-bit output of RNG (splitmix64)."
  (let* ((state (ldb (byte 64 0) (+ (rng-state rng) #x9E3779B97F4A7C15)))
         (z state))
    (declare (type (unsigned-byte 64) state z))
    (setf (rng-state rng) state)
    (setf z (ldb (byte 64 0) (* (logxor z (ash z -30)) #xBF58476D1CE4E5B9)))
    (setf z (ldb (byte 64 0) (* (logxor z (ash z -27)) #x94D049BB133111EB)))
    (logxor z (ash z -31))))

(defun rng-unit (rng)
  "A double-float in [0, 1) from RNG."
  (/ (ash (rng-next rng) -11) (expt 2d0 53)))

(defun rng-chance (rng probability)
  "True with PROBABILITY (a real in [0, 1])."
  (< (rng-unit rng) probability))

;;; ------------------------------------------------------------------------------------------
;;; The world
;;; ------------------------------------------------------------------------------------------

(defstruct (world (:constructor %make-world) (:copier nil))
  "A Life world: the live cells (keys -> T), a scratch table for the step, the rule, the topology
and its dimensions, and the counters."
  (cells (make-hash-table) :type hash-table)
  (scratch (make-hash-table) :type hash-table)
  (rule *life-rule* :type rule)
  (topology :plane :type (member :plane :torus :box))
  (width nil)
  (height nil)
  (generation 0 :type (integer 0))
  (births 0 :type (integer 0))
  (deaths 0 :type (integer 0)))

(defmethod print-object ((world world) stream)
  (print-unreadable-object (world stream :type t)
    (if (eq (world-topology world) :plane)
        (format stream "plane gen ~D pop ~D" (world-generation world) (population world))
        (format stream "~(~A~) ~Dx~D gen ~D pop ~D" (world-topology world) (world-width world)
                (world-height world) (world-generation world) (population world)))))

(defun make-world (&key (rule *life-rule*) (topology :plane) width height)
  "A new empty world. RULE is any PARSE-RULE designator. TOPOLOGY is :plane (unbounded; WIDTH and
HEIGHT must be NIL), :torus (edges wrap) or :box (dead beyond the edges); the last two need
positive integer WIDTH and HEIGHT."
  (unless (member topology '(:plane :torus :box))
    (%life-error "unknown topology ~S (expected :plane, :torus or :box)" topology))
  (if (eq topology :plane)
      (when (or width height)
        (%life-error "a plane world has no width or height (use :torus or :box for a bounded world)"))
      (unless (and (integerp width) (plusp width) (integerp height) (plusp height))
        (%life-error "a ~(~A~) needs positive integer :width and :height, got ~S and ~S"
                     topology width height)))
  (%make-world :rule (parse-rule rule) :topology topology :width width :height height))

(defun copy-world (world)
  "A deep copy of WORLD: new tables, same cells, rule, topology, size and counters."
  (let ((new (%make-world :rule (world-rule world) :topology (world-topology world)
                          :width (world-width world) :height (world-height world)
                          :generation (world-generation world)
                          :births (world-births world) :deaths (world-deaths world))))
    (loop for key being the hash-keys of (world-cells world)
          do (setf (gethash key (world-cells new)) t))
    new))

(declaim (inline %normalize))
(defun %normalize (world x y)
  "(X, Y) under WORLD's topology: wrapped on a torus, unchanged on the plane, (values NIL NIL)
outside a box."
  (ecase (world-topology world)
    (:plane (values x y))
    (:torus (values (mod x (world-width world)) (mod y (world-height world))))
    (:box (if (and (<= 0 x) (< x (world-width world)) (<= 0 y) (< y (world-height world)))
              (values x y)
              (values nil nil)))))

(defun in-bounds-p (world x y)
  "True when (X, Y) is a cell of WORLD: always on the plane and the torus, inside the box otherwise."
  (or (not (eq (world-topology world) :box))
      (and (<= 0 x) (< x (world-width world)) (<= 0 y) (< y (world-height world)))))

(defun alive-p (world x y)
  "True when the cell (X, Y) is alive. Torus coordinates wrap; outside a box the answer is NIL."
  (multiple-value-bind (nx ny) (%normalize world x y)
    (and nx (gethash (%pack nx ny) (world-cells world)) t)))

(defun (setf alive-p) (value world x y)
  "Make the cell (X, Y) alive (VALUE true) or dead. Torus coordinates wrap; outside a box nothing
happens. Returns VALUE."
  (multiple-value-bind (nx ny) (%normalize world x y)
    (when nx
      (let ((key (%pack nx ny)))
        (if value
            (setf (gethash key (world-cells world)) t)
            (remhash key (world-cells world))))))
  value)

(defun population (world)
  "The number of live cells."
  (hash-table-count (world-cells world)))

(defun live-cells (world)
  "A fresh list of the live cells as (x . y), sorted by y then x."
  (%sort-cells (loop for key being the hash-keys of (world-cells world)
                     collect (cons (%unpack-x key) (%unpack-y key)))))

(defun clear-world (world)
  "Remove every cell; the generation, rule and topology stay, births and deaths become 0."
  (clrhash (world-cells world))
  (setf (world-births world) 0
        (world-deaths world) 0)
  world)

(defun bounding-box (world)
  "(values min-x min-y max-x max-y) of the live cells, or NIL when the world is empty."
  (let ((min-x nil) (min-y nil) (max-x nil) (max-y nil))
    (loop for key being the hash-keys of (world-cells world)
          do (let ((x (%unpack-x key)) (y (%unpack-y key)))
               (when (or (null min-x) (< x min-x)) (setf min-x x))
               (when (or (null max-x) (> x max-x)) (setf max-x x))
               (when (or (null min-y) (< y min-y)) (setf min-y y))
               (when (or (null max-y) (> y max-y)) (setf max-y y))))
    (if min-x (values min-x min-y max-x max-y) nil)))

(defun neighbor-count (world x y)
  "The number (0..8) of live neighbors of (X, Y) under WORLD's topology."
  (let ((n 0))
    (loop for dy from -1 to 1
          do (loop for dx from -1 to 1
                   unless (and (zerop dx) (zerop dy))
                     do (when (alive-p world (+ x dx) (+ y dy)) (incf n))))
    n))

;;; ------------------------------------------------------------------------------------------
;;; The step (§3.2)
;;; ------------------------------------------------------------------------------------------

(defun %step-once (world)
  "One generation. Pass 1 marks every live cell in SCRATCH (bit 4) and counts it into its eight
neighbors (low bits, never above 8). Pass 2 rebuilds CELLS from SCRATCH under the rule."
  (let* ((cells (world-cells world))
         (scratch (world-scratch world))
         (rule (world-rule world))
         (topology (world-topology world))
         (width (or (world-width world) 0))
         (height (or (world-height world) 0))
         (births 0)
         (deaths 0))
    (declare (type hash-table cells scratch) (type fixnum width height births deaths))
    (flet ((bump (x y)
             (declare (type fixnum x y))
             (case topology
               (:torus (setf x (mod x width)
                             y (mod y height)))
               (:box (when (or (< x 0) (>= x width) (< y 0) (>= y height))
                       (return-from bump nil))))
             (incf (gethash (%pack x y) scratch 0))))
      (loop for key being the hash-keys of cells
            do (let ((x (%unpack-x key)) (y (%unpack-y key)))
                 (declare (type fixnum x y))
                 (setf (gethash key scratch) (logior (gethash key scratch 0) 16))
                 (bump (1- x) (1- y)) (bump x (1- y)) (bump (1+ x) (1- y))
                 (bump (1- x) y)                      (bump (1+ x) y)
                 (bump (1- x) (1+ y)) (bump x (1+ y)) (bump (1+ x) (1+ y))))
      (clrhash cells)
      (loop for key being the hash-keys of scratch using (hash-value v)
            do (let ((n (logand v 15)))
                 (if (logtest v 16)
                     (if (survives-p rule n)
                         (setf (gethash key cells) t)
                         (incf deaths))
                     (when (born-p rule n)
                       (setf (gethash key cells) t)
                       (incf births)))))
      (clrhash scratch))
    (setf (world-births world) births
          (world-deaths world) deaths)
    (incf (world-generation world))
    world))

(defun step-world (world &optional (n 1))
  "Advance WORLD by N generations (default 1); returns WORLD. WORLD-BIRTHS and WORLD-DEATHS
describe the last generation."
  (check-type n (integer 0))
  (loop repeat n do (%step-once world))
  world)

;;; ------------------------------------------------------------------------------------------
;;; Placing patterns and soups
;;; ------------------------------------------------------------------------------------------

;;; %cells-of-designator, which PLACE calls, lives in formats.lisp after the PATTERN struct it reads.

(defun place (world pattern &key x y)
  "Put PATTERN (a PATTERN, a built-in name, or a list of (x . y) cells) on WORLD with its (0,0) at
(X, Y). With neither X nor Y the pattern is centered: on a torus or box in the middle of the world,
on the plane around the origin. Cells wrap on a torus and are dropped outside a box. Returns WORLD."
  (let ((cells (%cells-of-designator pattern)))
    (cond ((and x y))
          ((or x y) (%life-error "place needs both :x and :y, or neither"))
          ((null cells) (setf x 0 y 0))
          (t (let* ((min-x (reduce #'min cells :key #'car))
                    (max-x (reduce #'max cells :key #'car))
                    (min-y (reduce #'min cells :key #'cdr))
                    (max-y (reduce #'max cells :key #'cdr))
                    (pw (1+ (- max-x min-x)))
                    (ph (1+ (- max-y min-y))))
               (if (eq (world-topology world) :plane)
                   (setf x (- (- (floor pw 2)) min-x)
                         y (- (- (floor ph 2)) min-y))
                   (setf x (- (floor (- (world-width world) pw) 2) min-x)
                         y (- (floor (- (world-height world) ph) 2) min-y))))))
    (dolist (cell cells world)
      (setf (alive-p world (+ x (car cell)) (+ y (cdr cell))) t))))

(defun randomize (world &key (density 0.3) seed x y width height)
  "Set every cell of the rectangle X, Y, WIDTH, HEIGHT alive with probability DENSITY (a real in
[0, 1]) and dead otherwise, drawing from (make-rng SEED); cells outside the rectangle are untouched.
On a torus or box the rectangle defaults to the whole world; on the plane all four must be given.
Returns the seed used, so a clock-derived seed can be shown and replayed."
  (unless (and (realp density) (<= 0 density 1))
    (%life-error "density must be a real between 0 and 1, got ~S" density))
  (if (eq (world-topology world) :plane)
      (unless (and x y width height)
        (%life-error "randomize on the plane needs :x, :y, :width and :height"))
      (setf x (or x 0)
            y (or y 0)
            width (or width (world-width world))
            height (or height (world-height world))))
  (let* ((rng (make-rng seed))
         (used (rng-state rng)))
    (loop for cy from y below (+ y height)
          do (loop for cx from x below (+ x width)
                   do (setf (alive-p world cx cy) (rng-chance rng density))))
    used))

;;; ------------------------------------------------------------------------------------------
;;; Equality, fingerprints, snapshots (§3.3)
;;; ------------------------------------------------------------------------------------------

(defun world-equal (a b)
  "True when A and B have exactly the same live cells (rule, topology and generation ignored)."
  (let ((ca (world-cells a)) (cb (world-cells b)))
    (and (= (hash-table-count ca) (hash-table-count cb))
         (loop for key being the hash-keys of ca always (gethash key cb)))))

(declaim (inline %mix-key))
(defun %mix-key (key)
  "A 60-bit mix of KEY, summed into fingerprints."
  (declare (type cell-key key))
  (ldb (byte 60 0) (* (logxor key (ash key -29)) #x9E3779B97F4A7C15)))

(defun world-fingerprint (world)
  "A non-negative fixnum that depends only on the set of live cells (equal for WORLD-EQUAL worlds)."
  (let ((h 0))
    (declare (type (unsigned-byte 60) h))
    (loop for key being the hash-keys of (world-cells world)
          do (setf h (ldb (byte 60 0) (+ h (%mix-key key)))))
    h))

(defun %snapshot (world)
  "The live cell keys as a fresh ascending SIMPLE-VECTOR."
  (let ((keys (make-array (population world)))
        (i 0))
    (loop for key being the hash-keys of (world-cells world)
          do (setf (svref keys i) key)
             (incf i))
    (sort keys #'<)))

(defun %snapshot-equal (a b)
  "True when the two snapshots hold the same keys."
  (and (= (length a) (length b))
       (loop for x across a for y across b always (= x y))))

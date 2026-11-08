;;;; src/run.lisp — stability-detector, simulate (headless), run (interactive) (DESIGN.md §4.9).
;;;;
;;;; SIMULATE steps a world until it dies out, repeats itself or reaches a generation limit; RUN
;;;; does the same inside WITH-TERMINAL-UI, drawing every generation, pacing frames against a
;;;; running deadline and handling the keys. Both check extinction, then stability, then the
;;;; generation limit after each step, and extinction before the first one.

(in-package :game-of-life)

(%muffle-compiler-notes)

;;; ---- Stability detection -------------------------------------------------------------------

(defstruct (stability-detector (:constructor %make-stability-detector) (:copier nil))
  "A ring of the DEPTH world states before the current one: FINGERPRINTS holds their
WORLD-FINGERPRINTs and SNAPSHOTS their sorted key vectors, both indexed by observation number
modulo DEPTH; COUNT is the number of observations so far."
  (depth 64 :type (integer 1))
  (fingerprints #() :type simple-vector)
  (snapshots #() :type simple-vector)
  (count 0 :type (integer 0)))

(defun make-stability-detector (&key (depth 64))
  "A detector that finds periods from 1 to DEPTH (§3.3)."
  (check-type depth (integer 1))
  (%make-stability-detector :depth depth
                            :fingerprints (make-array depth :initial-element nil)
                            :snapshots (make-array depth :initial-element nil)))

(defun observe (detector world)
  "Compares WORLD's current state with the states recorded by the previous observations, most
recent first, and returns the smallest period p in 1..depth such that the state equals the one
recorded p observations ago, or NIL. Only then records the current state, so the ring holds the
DEPTH states before the current one and a period equal to DEPTH is still found. Fingerprints are
compared first; the full key vectors only on a fingerprint match."
  (let* ((depth (stability-detector-depth detector))
         (count (stability-detector-count detector))
         (fingerprints (stability-detector-fingerprints detector))
         (snapshots (stability-detector-snapshots detector))
         (fingerprint (world-fingerprint world))
         (snapshot (%snapshot world))
         (period (loop for p from 1 to (min count depth)
                       for index = (mod (- count p) depth)
                       when (and (eql fingerprint (svref fingerprints index))
                                 (%snapshot-equal snapshot (svref snapshots index)))
                         return p))
         (slot (mod count depth)))
    (setf (svref fingerprints slot) fingerprint
          (svref snapshots slot) snapshot
          (stability-detector-count detector) (1+ count))
    period))

;;; ---- Headless loop -------------------------------------------------------------------------

(defun simulate (world &key generations (stop-when-stable t) (history 64) on-step)
  "Steps WORLD until it is finished and returns (values outcome period):
  :extinct   the population is 0 (checked before the first step and after every step; period NIL)
  :periodic  STOP-WHEN-STABLE and the state repeats one seen p steps ago (period p); the world is
             at the generation where the repetition was detected
  :limit     GENERATIONS steps were taken (period NIL)
ON-STEP, when given, is called with the world after each step. After each step the checks run in
this order: extinction, stability (when STOP-WHEN-STABLE), the GENERATIONS limit. HISTORY is the
detector depth. GENERATIONS NIL with STOP-WHEN-STABLE NIL signals LIFE-ERROR: it would never
return."
  (when (and (null generations) (not stop-when-stable))
    (%life-error "simulate without a generation limit or stability check would never return"))
  (let ((detector (and stop-when-stable (make-stability-detector :depth history)))
        (steps 0))
    (when (zerop (population world))
      (return-from simulate (values :extinct nil)))
    (when detector (observe detector world))
    (loop
      (when (and generations (>= steps generations))
        (return (values :limit nil)))
      (step-world world)
      (incf steps)
      (when on-step (funcall on-step world))
      (when (zerop (population world))
        (return (values :extinct nil)))
      (when detector
        (let ((period (observe detector world)))
          (when period
            (return (values :periodic period))))))))

;;; ---- Interactive loop ----------------------------------------------------------------------

(defparameter *fps-steps* #(1 2 4 8 15 20 30 60 120)
  "Speeds the + and - keys move between. A starting FPS not in the vector steps to the nearest
entry.")

(defun %run-next-fps (fps direction)
  "The entry of *FPS-STEPS* just above FPS when DIRECTION is positive, just below it when
negative; FPS itself when there is none."
  (or (if (plusp direction)
          (find-if (lambda (step) (> step fps)) *fps-steps*)
          (find-if (lambda (step) (< step fps)) *fps-steps* :from-end t))
      fps))

(defun %run-terminal-viewport (world style)
  "The default viewport for WORLD on the terminal: its columns, and its rows minus the status line
multiplied by the cell rows one text line shows in STYLE."
  (multiple-value-bind (columns rows) (terminal-size)
    (default-viewport world (max 1 columns) (max 1 (* (1- rows) (cells-per-row style))))))

(defun run (world &key generations (fps 20) (style :blocks) viewport follow
                       (stop-when-stable nil) (history 64) reset seed (keyboard t)
                       (alternate-screen t) (stream *standard-output*))
  "The interactive loop, inside WITH-TERMINAL-UI on STREAM. VIEWPORT defaults to the terminal's
size with one line kept for the status line. Each iteration recomputes the viewport when FOLLOW
(plane only), draws, handles every waiting key, steps once unless paused and then checks
extinction, stability (when STOP-WHEN-STABLE, with a detector of depth HISTORY) and the
GENERATIONS limit, in that order, then paces the frame against a running deadline of 1/FPS.
Keys: space pauses, n or . steps once and pauses, + or = and - change the speed along
*FPS-STEPS*, f toggles follow (plane only), c clears the world and pauses, r calls RESET with the
world (an integer it returns replaces SEED in the status line), q or Q quits. Ctrl-C ends the loop
with outcome :interrupted; the terminal is restored in every case. The final frame is drawn
before returning. Returns (values outcome period), the outcome being :limit, :extinct,
:periodic, :quit or :interrupted."
  (check-type fps (real (0)))
  (let* ((viewport (or viewport (%run-terminal-viewport world style)))
         (plane (eq (world-topology world) :plane))
         (follow (and follow plane))
         (detector (and stop-when-stable (make-stability-detector :depth history)))
         (frame-seconds (/ 1d0 fps))
         (deadline 0d0)
         (steps 0)
         (paused nil)
         (outcome nil)
         (period nil))
    (labels ((advance ()
               (step-world world)
               (incf steps)
               (cond ((zerop (population world)) (setf outcome :extinct))
                     ((and detector (setf period (observe detector world)))
                      (setf outcome :periodic))
                     ((and generations (>= steps generations)) (setf outcome :limit))))
             (change-fps (new-fps)
               (setf fps new-fps
                     frame-seconds (/ 1d0 new-fps)
                     deadline (%real-time-seconds)))
             (handle-key (key)
               (case key
                 (#\Space (setf paused (not paused)))
                 ((#\n #\.) (setf paused t) (advance))
                 ((#\+ #\=) (change-fps (%run-next-fps fps 1)))
                 (#\- (change-fps (%run-next-fps fps -1)))
                 (#\f (when plane (setf follow (not follow))))
                 (#\c (clear-world world) (setf paused t))
                 (#\r (when reset
                        (let ((new-seed (funcall reset world)))
                          (when (integerp new-seed) (setf seed new-seed)))))
                 ((#\q #\Q) (setf outcome :quit))))
             (pace ()
               (incf deadline frame-seconds)
               (let ((remaining (- deadline (%real-time-seconds))))
                 (cond ((plusp remaining) (sleep remaining))
                       ((< remaining (- frame-seconds))
                        (setf deadline (%real-time-seconds)))))))
      (%catch-interrupt
          (with-terminal-ui (keys :stream stream :alternate-screen alternate-screen
                                  :keyboard keyboard)
            (when detector (observe detector world))
            (cond ((zerop (population world)) (setf outcome :extinct))
                  ((and generations (<= generations 0)) (setf outcome :limit)))
            (setf deadline (%real-time-seconds))
            (loop
              (when follow
                (setf viewport (following-viewport world (viewport-width viewport)
                                                   (viewport-height viewport))))
              (draw world viewport :style style :fps fps :paused paused :seed seed
                                   :follow follow :keys keys :stream stream)
              (when outcome (return))
              (when keys
                (loop for key = (read-key)
                      while key
                      do (unless outcome (handle-key key))))
              (unless outcome
                (unless paused (advance))
                (unless outcome (pace)))))
        (setf outcome :interrupted)))
    (values outcome period)))

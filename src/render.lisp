;;;; src/render.lisp — viewport, render-frame, status-line, draw (DESIGN.md §4.8).
;;;;
;;;; Turns a rectangle of a world into text. The :blocks style packs two cell rows into one text
;;;; line with the half-block characters so the grid looks square; :ascii and :dots use one line
;;;; per row. DRAW is the only function here that writes.

(in-package :game-of-life)

(%muffle-compiler-notes)

;;; ---- Viewport ------------------------------------------------------------------------------

(defstruct (viewport (:copier nil))
  "A rectangle of world coordinates: X,Y is the top-left cell, WIDTH and HEIGHT are in cells."
  (x 0 :type integer)
  (y 0 :type integer)
  (width 1 :type (integer 1))
  (height 1 :type (integer 1)))

(defmethod print-object ((viewport viewport) stream)
  (print-unreadable-object (viewport stream :type t)
    (format stream "~Dx~D at (~D,~D)"
            (viewport-width viewport) (viewport-height viewport)
            (viewport-x viewport) (viewport-y viewport)))
  viewport)

(defun default-viewport (world columns rows)
  "The viewport a fresh display of WORLD gets in COLUMNS x ROWS cells: on a torus or box the
top-left corner (0,0) clamped to the world's size; on the plane COLUMNS x ROWS centered on the
origin, x = -(floor columns 2), y = -(floor rows 2)."
  (ecase (world-topology world)
    (:plane
     (make-viewport :x (- (floor columns 2)) :y (- (floor rows 2))
                    :width columns :height rows))
    ((:torus :box)
     (make-viewport :x 0 :y 0
                    :width (min (world-width world) columns)
                    :height (min (world-height world) rows)))))

(defun following-viewport (world columns rows)
  "On the plane, a COLUMNS x ROWS viewport centered on the center of WORLD's bounding box (on the
origin when the world is empty); on a torus or box the same as DEFAULT-VIEWPORT."
  (if (eq (world-topology world) :plane)
      (multiple-value-bind (min-x min-y max-x max-y) (bounding-box world)
        (if min-x
            (make-viewport :x (- (floor (+ min-x max-x) 2) (floor columns 2))
                           :y (- (floor (+ min-y max-y) 2) (floor rows 2))
                           :width columns :height rows)
            (default-viewport world columns rows)))
      (default-viewport world columns rows)))

;;; ---- Frames --------------------------------------------------------------------------------

(defun cells-per-row (style)
  "How many cell rows one text line shows in STYLE: 2 for :blocks, 1 for :ascii and :dots."
  (ecase style
    (:blocks 2)
    ((:ascii :dots) 1)))

(defun frame-rows (style height)
  "The number of text lines that show HEIGHT cell rows in STYLE: (ceiling height 2) for :blocks,
HEIGHT for :ascii and :dots."
  (ecase style
    (:blocks (ceiling height 2))
    ((:ascii :dots) height)))

(defun %render-block-char (top bottom)
  "The half-block character for a cell pair: both alive FULL BLOCK, top only UPPER HALF BLOCK,
bottom only LOWER HALF BLOCK, neither a space."
  (code-char (cond ((and top bottom) #x2588)
                   (top #x2580)
                   (bottom #x2584)
                   (t 32))))

(defun render-frame (world viewport &key (style :blocks))
  "WORLD seen through VIEWPORT as text: (frame-rows STYLE height) lines of exactly the viewport's
width in characters, joined by newlines, with no trailing newline. :blocks pairs rows (2k, 2k+1)
into half-block characters (an odd last row has a dead bottom half); :ascii uses # and space;
:dots uses O and period."
  (let* ((x0 (viewport-x viewport))
         (y0 (viewport-y viewport))
         (width (viewport-width viewport))
         (height (viewport-height viewport))
         (lines (frame-rows style height))
         (text (make-string (+ (* lines width) (max 0 (1- lines))) :initial-element #\Space))
         (position 0))
    (flet ((live (column row)
             (and (< row height) (alive-p world (+ x0 column) (+ y0 row)))))
      (dotimes (line lines)
        (when (plusp line)
          (setf (char text position) #\Newline)
          (incf position))
        (dotimes (column width)
          (setf (char text position)
                (ecase style
                  (:blocks (%render-block-char (live column (* 2 line))
                                               (live column (1+ (* 2 line)))))
                  (:ascii (if (live column line) #\# #\Space))
                  (:dots (if (live column line) #\O #\.))))
          (incf position))))
    text))

;;; ---- Status line ---------------------------------------------------------------------------

(defun %render-topology-text (world)
  "\"plane\", or the topology with its size: \"torus 80x46\", \"box 20x20\"."
  (if (eq (world-topology world) :plane)
      "plane"
      (format nil "~(~A~) ~Dx~D" (world-topology world) (world-width world) (world-height world))))

(defun %render-fps-text (fps)
  "\"N fps\": an integer as is, any other real with one decimal (\"2.5 fps\")."
  (if (integerp fps)
      (format nil "~D fps" fps)
      (format nil "~,1F fps" fps)))

(defun %render-fit (string width)
  "STRING padded with spaces or truncated to exactly WIDTH characters."
  (let ((length (length string)))
    (cond ((= length width) string)
          ((< length width)
           (concatenate 'string string (make-string (- width length) :initial-element #\Space)))
          (t (subseq string 0 width)))))

(defun status-line (world &key (width 80) fps paused seed follow (keys t))
  "One line of exactly WIDTH characters describing WORLD: \"PAUSED\" when PAUSED, \"gen N\",
\"pop N\", the rule string, the topology with its size, \"N fps\" when FPS, \"seed N\" when SEED,
\"follow\" when FOLLOW and the key help when KEYS, separated by two spaces; padded or truncated."
  (let ((parts '()))
    (when paused (push "PAUSED" parts))
    (push (format nil "gen ~D" (world-generation world)) parts)
    (push (format nil "pop ~D" (population world)) parts)
    (push (rule-string (world-rule world)) parts)
    (push (%render-topology-text world) parts)
    (when fps (push (%render-fps-text fps) parts))
    (when seed (push (format nil "seed ~D" seed) parts))
    (when follow (push "follow" parts))
    (when keys (push "space pause  n step  +/- speed  f follow  r reseed  c clear  q quit" parts))
    (%render-fit (format nil "~{~A~^  ~}" (nreverse parts)) width)))

(defun draw (world viewport &key (style :blocks) fps paused seed follow (keys t)
                                 (stream *standard-output*))
  "Writes one frame to STREAM: the home sequence, the rendered frame, a newline and the status
line (as wide as the viewport), with no trailing newline, then finishes the output. The whole
text is built first and written with one write-string so the screen does not flicker. Returns
NIL."
  (let ((text (concatenate 'string
                           (ansi-home)
                           (render-frame world viewport :style style)
                           (string #\Newline)
                           (status-line world :width (viewport-width viewport) :fps fps
                                              :paused paused :seed seed :follow follow
                                              :keys keys))))
    (write-string text stream)
    (finish-output stream)
    nil))

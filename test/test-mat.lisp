(in-package :mgl-mat)

;;;; Test utilities

(defmacro do-foreign-array-strategies (() &body body)
  `(dolist (*foreign-array-strategy*
            (if (pinning-supported-p)
                (list :pin-backing-array :static-backing-array :dynamic)
                (list :static-backing-array :dynamic)))
     ,@body))

(defmacro do-cuda (() &body body)
  `(loop for enabled in (if (and *cuda-enabled* (cl-cuda:cuda-available-p))
                            '(nil t)
                            '(nil))
         do (with-cuda (:enabled enabled) ,@body)))

(defmacro do-configurations ((name &key (ctypes ''(:float :double))) &body body)
  `(progn
     (format *trace-output* "* testing ~S~%" ',name)
     (dolist (*default-mat-ctype* ,ctypes)
       (format *trace-output* "** ctype: ~S~%" *default-mat-ctype*)
       (do-cuda ()
         (format *trace-output* "*** cuda enabled: ~S~%" *cuda-enabled*)
         (do-foreign-array-strategies ()
           (format *trace-output* "**** foreign array strategy: ~S~%"
                   *foreign-array-strategy*)
           ,@body)))))

(defun ~= (x y)
  (< (abs (- x y)) 0.00001))


;;;; Tests

(defun test-initial-element ()
  (do-configurations (initial-element)
    (dolist (facet-name (if (use-cuda-p)
                            '(array backing-array cuda-array foreign-array)
                            '(array backing-array foreign-array)))
      (let ((mat (make-mat 6 :initial-element 1)))
        ;; Reshaping must not affect what gets filled with the initial
        ;; element.
        (reshape-and-displace! mat '(1 3) 1)
        (with-facet (array (mat facet-name :direction :input))
          (declare (ignore array)))
        (with-facets ((array (mat 'backing-array :direction :input)))
          (dotimes (i 6)
            (assert (= (aref array i) (coerce-to-ctype 1)))))))))

(defun test-fill! ()
  (do-configurations (fill!)
    (let ((mat (make-mat 6)))
      (reshape-and-displace! mat '(1 3) 1)
      (fill! 1 mat)
      (with-facets ((array (mat 'backing-array :direction :input)))
        (dotimes (i 6)
          (assert (= (aref array i)
                     (coerce-to-ctype (if (<= 1 i 3) 1 0)))))))))

(defun test-asum ()
  (do-configurations (asum)
    (let ((x (make-mat 6)))
      (reshape-and-displace! x 3 1)
      (fill! 1 x)
      (assert (~= (coerce-to-ctype 3) (asum x))))))

(defun test-axpy! ()
  (do-configurations (axpy!)
    (let ((x (make-mat 6))
          (y (make-mat 6)))
      (reshape-and-displace! x 3 1)
      (reshape-and-displace! y 3 2)
      (fill! 1 x)
      (fill! 1 y)
      (axpy! 2 x y)
      (with-facets ((array (y 'backing-array :direction :input)))
        (dotimes (i 6)
          (assert (= (aref array i)
                     (coerce-to-ctype (if (<= 2 i 4) 3 0)))))))))

(defun test-copy! ()
  (do-configurations (copy!)
    (let ((x (make-mat 6))
          (y (make-mat 6)))
      (reshape-and-displace! x 3 1)
      (reshape-and-displace! y 3 2)
      (fill! 1 x)
      (copy! x y)
      (with-facets ((array (y 'backing-array :direction :input)))
        (dotimes (i 6)
          (assert (= (aref array i)
                     (coerce-to-ctype (if (<= 2 i 4) 1 0)))))))))

(defun test-nrm2 ()
  (do-configurations (nrm2)
    (let ((x (make-mat 6)))
      (reshape-and-displace! x 3 1)
      (fill! 1 x)
      (assert (~= (sqrt (coerce-to-ctype 3)) (nrm2 x))))))

(defun submatrix (matrix height width)
  (let ((a (make-array (list height width)
                       :element-type (array-element-type matrix))))
    (dotimes (row height)
      (dotimes (col width)
        (setf (aref a row col) (aref matrix row col))))
    a))

(defun random-array (type &rest dimensions)
  "Random array for testing."
  (aops:generate* type
                  (if (subtypep type 'complex)
                      (lambda () (coerce (complex (random 100)
                                                  (random 100))
                                         type))
                      (lambda () (coerce (random 100) type)))
                  dimensions))

(defun sloppy-random-array (type height width)
  (let ((displacement (random 3)))
    (if (zerop displacement)
        ;; non-displaced array
        (let ((a* (apply #'random-array type (mapcar (lambda (dim)
                                                       (+ dim (random 3)))
                                                     (list height width)))))
          (values (submatrix a* height width) a*))
        ;; displaced array
        (let* ((dimensions (mapcar (lambda (dim)
                                     (+ dim (random 3)))
                                   (list height width)))
               (size (+ displacement (reduce #'* dimensions)))
               (backing-array (random-array type size))
               (a* (make-array dimensions :element-type type
                               :displaced-to backing-array
                               :displaced-index-offset displacement)))
          (values (submatrix a* height width) a*)))))

(defun test-gemm! ()
  (do-configurations (gemm!)
    (loop repeat 100 do
      (let-plus:let+
          ((m (1+ (random 10)))
           (n (1+ (random 10)))
           (k (1+ (random 10)))
           (transpose-a? (if (zerop (random 2)) t nil))
           (transpose-b? (if (zerop (random 2)) t nil))
           ((let-plus:&values a a*)
            (if transpose-a?
                (sloppy-random-array 'double-float k m)
                (sloppy-random-array 'double-float m k)))
           ((let-plus:&values b b*)
            (if transpose-b?
                (sloppy-random-array 'double-float n k)
                (sloppy-random-array 'double-float k n)))
           ((let-plus:&values c c*)
            (sloppy-random-array 'double-float m n))
           (alpha (random 10d0))
           (beta (random 10d0))
           (result (clnu:e+ (clnu:e* alpha
                                     (lla:mm
                                      (if transpose-a? (clnu:transpose a) a)
                                      (if transpose-b? (clnu:transpose b) b)))
                            (clnu:e* beta c)))
           (mat-a (array-to-mat a*))
           (mat-b (array-to-mat b*))
           (mat-c (array-to-mat c*)))
        (gemm! alpha mat-a mat-b
               beta mat-c
               :transpose-a? transpose-a?
               :transpose-b? transpose-b?
               :m m :n n :k k)
        (assert (clnu:num= (apply #'submatrix (mat-to-array mat-c)
                                  (array-dimensions c))
                           result))))))

(defun test-.<! ()
  (do-configurations (.<!)
    (let ((x (make-mat 5 :initial-contents '(0 1 2 3 4)))
          (y (make-mat 5 :initial-contents '(4 3 2 1 0))))
      (.<! x y)
      (assert (m= y (make-mat 5 :initial-contents '(1 1 0 0 0)))))))

(defun test-sum! ()
  (do-configurations (sum!)
    (let ((x (make-mat 8)))
      (reshape-and-displace! x '(2 3) 1)
      (replace! x '((1 2 3) (4 5 6)))
      (let ((y (make-mat 6 :initial-element 2)))
        (reshape-and-displace! y 3 1)
        (sum! x y :axis 0 :alpha 2 :beta 0.5)
        (with-facets ((array (y 'backing-array :direction :input)))
          (dotimes (i 6)
            (assert (= (aref array i)
                       (coerce-to-ctype (cond ((= i 1) 11)
                                              ((= i 2) 15)
                                              ((= i 3) 19)
                                              (t 2))))))))
      (let ((y (make-mat 6 :initial-element 2)))
        (reshape-and-displace! y 2 1)
        (sum! x y :axis 1 :alpha 2 :beta 0.5)
        (with-facets ((array (y 'backing-array :direction :input)))
          (dotimes (i 6)
            (assert (= (aref array i)
                       (coerce-to-ctype (cond ((= i 1) 13)
                                              ((= i 2) 31)
                                              (t 2)))))))))))

(defun test-convolve! ()
  (do-configurations (convolve!)
    (let ((x (make-mat 25
                       :initial-contents
                       (append (list 0)
                               (alexandria:iota 12 :start 1)
                               (alexandria:iota 12 :start -1 :step -1))))
          (w (make-mat '(2 2) :initial-contents '((2 -1) (-3 5))))
          (y (make-mat '(2 3 2))))
      (reshape-and-displace! x '(2 3 4) 1)
      (convolve! x w y :start '(0 0) :stride '(1 2) :anchor '(1 0) :batched t)
      (assert (m= y (make-mat '(2 3 2)
                              :initial-contents
                              '(((7.0 11.0)
                                 (15.0 21.0)
                                 (27.0 33.0))
                                ((-7.0 -11.0)
                                 (-15.0 -21.0)
                                 (-27.0 -33.0))))))
      (let ((yd (make-mat 17))
            (xd (make-mat 37))
            (wd (make-mat 45)))
        (reshape-and-displace! yd (mat-dimensions y) 4)
        (reshape-and-displace! xd (mat-dimensions x) 12)
        (reshape-and-displace! wd (mat-dimensions w) 16)
        (with-shape-and-displacement (yd (mat-size y))
          (replace! yd (loop for i below (mat-size yd) collect i)))
        (derive-convolve! x xd w wd yd :start '(0 0) :stride '(1 2)
                          :anchor '(1 0) :batched t)
        (assert (m= xd (make-mat (mat-dimensions xd)
                                 :initial-contents
                                 (list (list (list (+ (* -3 0) (* 2 2))
                                                   (+ (* 5 0) (* -1 2))
                                                   (+ (* -3 1) (* 2 3))
                                                   (+ (* 5 1) (* -1 3)))
                                             (list (+ (* -3 2) (* 2 4))
                                                   (+ (* 5 2) (* -1 4))
                                                   (+ (* -3 3) (* 2 5))
                                                   (+ (* 5 3) (* -1 5)))
                                             (list (* -3 4)
                                                   (* 5 4)
                                                   (* -3 5)
                                                   (* 5 5)))
                                       (list (list (+ (* -3 6) (* 2 8))
                                                   (+ (* 5 6) (* -1 8))
                                                   (+ (* -3 7) (* 2 9))
                                                   (+ (* 5 7) (* -1 9)))
                                             (list (+ (* -3 8) (* 2 10))
                                                   (+ (* 5 8) (* -1 10))
                                                   (+ (* -3 9) (* 2 11))
                                                   (+ (* 5 9) (* -1 11)))
                                             (list (* -3 10)
                                                   (* 5 10)
                                                   (* -3 11)
                                                   (* 5 11)))))))))))

(defun test-max-pool! ()
  (do-configurations (max-pool!)
    (let ((x (make-mat 25
                       :initial-contents
                       (append (list 0)
                               (alexandria:iota 12 :start 1)
                               (alexandria:iota 12 :start -1 :step -1))))
          (y (make-mat '(2 3 2))))
      (reshape-and-displace! x '(2 3 4) 1)
      (max-pool! x y :start '(0 0) :stride '(1 2) :anchor '(1 0) :batched t
                 :pool-dimensions '(2 2))
      (assert (m= y (make-mat '(2 3 2)
                              :initial-contents
                              '(((2.0 4.0)
                                 (6.0 8.0)
                                 (10 12))
                                ((-1.0 -3.0)
                                 (-1.0 -3.0)
                                 (-5.0 -7.0))))))
      (let ((yd (make-mat 17))
            (xd (make-mat 37)))
        (reshape-and-displace! yd (mat-dimensions y) 4)
        (reshape-and-displace! xd (mat-dimensions x) 12)
        (with-shape-and-displacement (yd (mat-size y))
          (replace! yd (append (alexandria:iota 6 :start 1)
                               (alexandria:iota 6 :start -1 :step -1))))
        (derive-max-pool! x xd y yd :start '(0 0) :stride '(1 2)
                          :anchor '(1 0) :batched t :pool-dimensions '(2 2))
        (assert (m= xd (make-mat (mat-dimensions xd)
                                 :initial-contents
                                 (list (list (list 0 1 0 2)
                                             (list 0 3 0 4)
                                             (list 0 5 0 6))
                                       (list (list -4 0 -6 0)
                                             (list -5 0 -6 0)
                                             (list 0 0 0 0))))))))))

(defun check-no-duplicates (mat)
  (with-facets ((a (mat 'backing-array :direction :input)))
    (assert (= (length (remove-duplicates a))
               (length a)))))

(defun vector= (vectors)
  (apply #'every #'= vectors))

(defun test-uniform-random! ()
  (flet ((foo ()
           (let ((n (1+ (random 1024))))
             (let ((a (make-mat n)))
               (uniform-random! a)
               (check-no-duplicates a)
               (mat-to-array a)))))
    ;; Don't test with single floats, because the chance of collision
    ;; is too high.
    (do-configurations (uniform-random! :ctypes '(:double))
      (if *cuda-enabled*
          (loop for n-states in '(1 7 11 100 234 788 1234)
                do (with-curand-state ((make-xorwow-state/simple
                                        1234 n-states))
                     (foo)))
          (foo)))))

(defun test-pool ()
  (when (and *cuda-enabled* (cuda-available-p))
    (let* ((stop-gc-thread nil)
           (gc-thread (bordeaux-threads:make-thread
                       (lambda ()
                         ;; Freeing cuda arrays (by the finalizers) in
                         ;; other threads must be safe.
                         (loop until stop-gc-thread do
                           (tg:gc :full t)
                           (sleep 0.2))))))
      (with-cuda ()
        ;; Allocate 8MiB worth of double floats 1000 times.
        ;; Garbage should be collected.
        (loop for i below 1000 do
          (when (zerop (mod i 100))
            (format *trace-output* "allocated ~S arrays~%" i))
          (let ((m (make-mat (* 1 (expt 2 20)))))
            (with-facets ((m (m 'cuda-array :direction :output)))
              (setq m m)))))
      (setq stop-gc-thread t)
      (bordeaux-threads:join-thread gc-thread))))

(defun test ()
  (test-initial-element)
  (test-fill!)
  (test-asum)
  (test-axpy!)
  (test-copy!)
  (test-nrm2)
  (test-gemm!)
  (test-.<!)
  (test-sum!)
  (test-convolve!)
  (test-max-pool!)
  (test-uniform-random!)
  (test-pool))

#|

(test)

;;; Test only without cuda even if it seems available.
(let ((*cuda-enabled* nil))
  (test))

|#
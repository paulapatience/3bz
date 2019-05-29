(in-package #:3bz)

(deftype octet () '(unsigned-byte 8))
(deftype octet-vector () '(simple-array octet (*)))
;; we restrict size of these types a bit more on 64 bit platforms to
;; ensure intermediate results stay in reasonable range for
;; performance. 32bit probably needs tuned, might want to allow larger
;; than fixnum offsets for FFI use with implementations with small
;; fixnums?
(deftype size-t () (if (= 8 (cffi:foreign-type-size :pointer))
                       `(unsigned-byte
                         ,(min 60 (1- (integer-length most-positive-fixnum))))
                       `(unsigned-byte
                         ,(min 30 (integer-length most-positive-fixnum)))))
;; slightly larger so incrementing a size-t still fits
(deftype offset-t () (if (= 8 (cffi:foreign-type-size :pointer))
                         `(unsigned-byte
                           ,(min 61 (integer-length most-positive-fixnum)))
                         `(unsigned-byte
                           ,(min 31 (integer-length most-positive-fixnum)))))

;; typed container for offsets and bounds of current input source, and
;; remaining bits of partially read octets
(defstruct (context-boxes (:conc-name cb-))
  ;; start of 'active' region of buffer
  (start 0 :type size-t)
  ;; end of 'active' region of buffer
  (end 0 :type size-t)
  ;; offset of next unread byte, (<= start offset end)
  (offset 0 :type size-t))


(defmacro context-common ((boxes) &body body)
  `(macrolet ((pos ()
                `(cb-offset ,',boxes))
              (end ()
                `(cb-end ,',boxes))
              (%octet (read-form
                       &optional (eob-form
                                  '(error "read past end of buffer")))
                `(progn
                   (when (>= (pos) (end))
                     ,eob-form)
                   (prog1
                       ,read-form
                     (incf (pos)))))
              (octets-left ()
                `(- (cb-end ,',boxes) (pos))))
     ,@body))


(defclass octet-vector-context ()
  ((octet-vector :reader octet-vector :initarg :octet-vector)
   (boxes :reader boxes :initarg :boxes)))

(defun make-octet-vector-context (vector &key (start 0) (offset 0)
                                           (end (length vector)))
  (make-instance 'octet-vector-context
                 :octet-vector vector
                 :boxes (make-context-boxes
                         :start start :offset offset :end end)))

(defclass octet-stream-context ()
  ((octet-stream :reader octet-stream :initarg :octet-stream)
   (boxes :reader boxes :initarg :boxes)))

(defun make-octet-stream-context (file-stream &key (start 0) (offset 0)
                                                (end (file-length file-stream)))
  (make-instance 'octet-stream-context
                 :octet-stream file-stream
                 :boxes (make-context-boxes
                         :start start :offset offset :end end)))

;; hack to allow storing parts of a file to use as context later. call
;; before using context
(defmethod %resync-file-stream (context))
(defmethod %resync-file-stream ((context octet-stream-context))
  (file-position (octet-stream context)
                 (cb-offset (boxes context))))

(defun valid-octet-stream (os)
  (and (typep os 'stream)
       (subtypep (stream-element-type os) 'octet)
       (open-stream-p os)
       (input-stream-p os)))

(defclass octet-pointer ()
  ((base :reader base :initarg :base)
   (size :reader size :initarg :size) ;; end?
   (scope :reader scope :initarg :scope)))

(defmacro with-octet-pointer ((var pointer size) &body body)
  (with-gensyms (scope)
    (once-only (pointer size)
     `(let* ((,scope (cons t ',var)))
        (unwind-protect
             (let ((,var (make-instance 'octet-pointer :base ,pointer
                                                       :size ,size
                                                       :scope ,scope)))
               ,@body)
          (setf (car ,scope) nil))))))

(defun valid-octet-pointer (op)
  (and (car (scope op))
       (not (cffi:null-pointer-p (base op)))
       (plusp (size op))))

(defclass octet-pointer-context ()
  ((op :reader op :initarg :op)
   (pointer :reader %pointer :initarg :pointer)
   (boxes :reader boxes :initarg :boxes)))

(defun make-octet-pointer-context (octet-pointer
                                   &key (start 0) (offset 0)
                                     (end (size octet-pointer)))
  (make-instance 'octet-pointer-context
                 :op octet-pointer
                 :pointer (base octet-pointer)
                 :boxes (make-context-boxes
                         :start start :offset offset :end end)))

(defmacro with-vector-context ((context) &body body)
  (with-gensyms (boxes vector)
    (once-only (context)
      `(let* ((,boxes (boxes ,context))
              (,vector (octet-vector ,context)))
         (declare (optimize speed)
                  (ignorable ,vector ,boxes)
                  (type context-boxes ,boxes))
         (check-type ,vector octet-vector)
         (locally (declare (type octet-vector ,vector))
           (context-common (,boxes)
             (macrolet (;; read up to 8 octets in LE order, return
                        ;; result + # of octets read as multiple
                        ;; values
                        (word64 ()
                          (with-gensyms (available result)
                            `(let ((,available (octets-left)))
                               (if (>= ,available 8)
                                   (let ((,result (nibbles:ub64ref/le
                                                   ,',vector (pos))))
                                     (incf (pos) 8)
                                     (values ,result 8))
                                   (let ((,result 0))
                                     (loop
                                       for i fixnum below ,available
                                       do (setf ,result
                                                (ldb (byte 64 0)
                                                     (logior
                                                      ,result
                                                      (ash
                                                       (aref ,',vector
                                                             (+ (pos) i))
                                                       (* i 8))))))
                                     (incf (pos) ,available)
                                     (values ,result ,available))))))
                        (word32 ()
                          (with-gensyms (available result)
                            `(let ((,available (octets-left)))
                               (if (>= ,available 4)
                                   (let ((,result (nibbles:ub32ref/le
                                                   ,',vector (pos))))
                                     (incf (pos) 4)
                                     (values ,result 4))
                                   (let ((,result 0))
                                     (loop
                                       for i fixnum below ,available
                                       do (setf ,result
                                                (ldb (byte 32 0)
                                                     (logior
                                                      ,result
                                                      (ash
                                                       (aref ,',vector
                                                             (+ (pos) i))
                                                       (* i 8))))))
                                     (incf (pos) ,available)
                                     (values ,result ,available)))))))
               ,@body)))))))

(defmacro with-stream-context ((context) &body body)
  (with-gensyms (boxes stream)
    (once-only (context)
      `(let* ((,boxes (boxes ,context))
              (,stream (octet-stream ,context)))
         (declare (optimize speed)
                  (ignorable ,stream ,boxes)
                  (type context-boxes ,boxes))
         (assert (valid-octet-stream ,stream))
         (context-common (,boxes)
           (macrolet (;; override POS/SET-POS for streams
                      (pos ()
                        `(file-position ,',stream))
                      (word64 ()
                        (with-gensyms (available result)
                          `(locally (declare (optimize (speed 1)))
                             (let ((,available (- (end) (pos))))
                               (if (>= ,available 8)
                                   (values (nibbles:read-ub64/le ,',stream) 8)
                                   (let ((,result 0))
                                     (declare (type (unsigned-byte 64) ,result)
                                              (type (mod 8) ,available))
                                     (loop
                                       for i fixnum below (min 8 ,available)
                                       do (setf (ldb (byte 8 (* i 8))
                                                     ,result)
                                                (octet)))
                                     (values ,result ,available)))))))
                      (word32 ()
                        (with-gensyms (available result)
                          `(locally (declare (optimize (speed 1)))
                             (let ((,available (- (end) (pos))))
                               (if (>= ,available 4)
                                   (values (nibbles:read-ub32/le ,',stream) 4)
                                   (let ((,result 0))
                                     (declare (type (unsigned-byte 64) ,result)
                                              (type (mod 4) ,available))
                                     (loop
                                       for i fixnum below (min 4 ,available)
                                       do (setf (ldb (byte 8 (* i 8))
                                                     ,result)
                                                (octet)))
                                     (values ,result ,available))))))))
             ,@body))))))

(defmacro with-pointer-context ((context) &body body)
  (with-gensyms (boxes pointer)
    (once-only (context)
      `(let* ((,boxes (boxes ,context))
              (,pointer (base (op ,context))))
         (declare (optimize speed)
                  (ignorable ,pointer ,boxes)
                  (type context-boxes ,boxes))
         (assert (valid-octet-pointer (op ,context)))
         (context-common (,boxes)
           (macrolet ((word64 ()
                        (with-gensyms (available result)
                          `(let ((,available (octets-left)))
                             (if (>= ,available 8)
                                 (let ((,result (cffi:mem-ref
                                                 ,',pointer :uint64 (pos))))
                                   (incf (pos) 8)
                                   (values ,result 8))
                                 (let ((,result 0))
                                   (declare (type (unsigned-byte 64) ,result))
                                   (loop
                                     for i fixnum below (min 8 ,available)
                                     do (setf ,result
                                              (ldb (byte 64 0)
                                                   (logior
                                                    ,result
                                                    (ash
                                                     (cffi:mem-ref
                                                      ,',pointer
                                                      :uint8
                                                      (+ (pos) i))
                                                     (* i 8))))))
                                   (incf (pos) ,available)
                                   (values ,result ,available))))))
                      (word32 ()
                        (with-gensyms (available result)
                          `(let ((,available (octets-left)))
                             (if (>= ,available 4)
                                 (let ((,result (cffi:mem-ref
                                                 ,',pointer :uint32 (pos))))
                                   (incf (pos) 4)
                                   (values ,result 4))
                                 (let ((,result 0))
                                   (declare (type (unsigned-byte 32) ,result))
                                   (loop
                                     for i fixnum below (min 4 ,available)
                                     do (setf ,result
                                              (ldb (byte 32 0)
                                                   (logior
                                                    ,result
                                                    (ash
                                                     (cffi:mem-ref
                                                      ,',pointer
                                                      :uint8
                                                      (+ (pos) i))
                                                     (* i 8))))))
                                   (incf (pos) ,available)
                                   (values ,result ,available)))))))
             ,@body))))))

(defmacro defun-with-reader-contexts (base-name lambda-list (in) &body body)
  `(progn
     ,@(loop for cc in '(vector stream pointer)
             for w = (find-symbol (format nil "~a-~a-~a" 'with cc 'context)
                                  (find-package :3bz))
             for n = (intern (format nil "~a/~a" base-name cc)
                             (find-package :3bz))
             collect `(defun ,n ,lambda-list
                        (,w (,in)
                            (let ()
                              ,@body))))
     (defun ,base-name ,lambda-list
       (etypecase ,in
         ,@(loop for cc in '(vector stream pointer)
                 for ct = (find-symbol (format nil "~a-~a-~a" 'octet cc 'context)
                                       (find-package :3bz))
                 for n = (find-symbol (format nil "~a/~a" base-name cc)
                                      (find-package :3bz))
                 collect `(,ct (,n ,@lambda-list)))))))

(defmacro with-reader-contexts ((context) &body body)
  `(etypecase ,context
     (octet-vector-context
      (with-vector-context (,context)
        ,@body))
     (octet-pointer-context
      (with-pointer-context (,context)
        ,@body))
     (octet-stream-context
      (with-stream-context (,context)
        ,@body))))

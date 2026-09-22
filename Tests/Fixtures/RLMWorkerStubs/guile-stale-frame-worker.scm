;;; Test stub worker: emits a stale-run `evaluated` frame before the real one.
;;;
;;; The session must drop the stale frame on its run identity and return the
;;; value from the matching frame. Used by the Guile session fencing tests; it
;;; is not a runtime component.

(use-modules (ice-9 binary-ports)
             (rnrs bytevectors))

(define input-port (current-input-port))
(define output-port (current-output-port))

(define (read-exact port count)
  (let ((bytes (get-bytevector-n port count)))
    (if (or (eof-object? bytes) (< (bytevector-length bytes) count))
        #f
        bytes)))

(define (read-frame)
  (let ((header (read-exact input-port 4)))
    (if (not header)
        #f
        (let* ((length (bytevector-u32-ref header 0 (endianness big)))
               (payload (read-exact input-port length)))
          (if (not payload)
              #f
              (read (open-input-string (utf8->string payload))))))))

(define (write-frame frame)
  (let* ((text (call-with-output-string (lambda (port) (write frame port))))
         (payload (string->utf8 text))
         (length (bytevector-length payload))
         (header (make-bytevector 4 0)))
    (bytevector-u32-set! header 0 length (endianness big))
    (put-bytevector output-port header)
    (put-bytevector output-port payload)
    (force-output output-port)))

(define (frame-type frame) (car frame))

(define (frame-field frame key)
  (let loop ((fields (cdr frame)))
    (cond ((null? fields) #f)
          ((eq? (car fields) key) (cadr fields))
          (else (loop (cddr fields))))))

(define current-run-id #f)

(define (main)
  (let loop ()
    (let ((frame (read-frame)))
      (if (not frame)
          #t
          (case (frame-type frame)
            ((initialize)
             (set! current-run-id (frame-field frame 'runID))
             (write-frame (list 'ready
                                'runID current-run-id
                                'environmentKeys '()
                                'openFileDescriptorCount -1
                                'cpuLimitSeconds -1
                                'addressSpaceBytes -1))
             (loop))
            ((evaluate)
             (let ((cell-id (frame-field frame 'cellID)))
               ;; A frame from a different run carrying the same cell id. The
               ;; session must ignore it rather than answer with 1.
               (write-frame (list 'evaluated
                                  'runID "stale-run-identity"
                                  'cellID cell-id
                                  'output ""
                                  'value 1))
               (write-frame (list 'evaluated
                                  'runID current-run-id
                                  'cellID cell-id
                                  'output ""
                                  'value 42)))
             (loop))
            ((cancel shutdown) #t)
            (else (loop)))))))

(main)

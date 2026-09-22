;;; Gnostic RLM Scheme 0 reference worker (GNU Guile 3.0).
;;;
;;; This worker is an experiment. It reads length-prefixed frames from stdin,
;;; evaluates validated cells in one run-local sandbox module, and services
;;; bounded host calls over the same framed channel. It is not enabled in any
;;; production composition.

(use-modules (ice-9 sandbox)
             (ice-9 binary-ports)
             (rnrs bytevectors))

(define (parse-options args)
  (if (null? args)
      '()
      (cons (cons (car args)
                  (if (null? (cdr args)) "" (cadr args)))
            (parse-options (if (null? (cdr args)) '() (cddr args))))))

(define options (parse-options (cdr (command-line))))

(define (option-number key default)
  (let ((entry (assoc key options)))
    (if entry (string->number (cdr entry)) default)))

(define (apply-limit resource value)
  (catch #t
    (lambda () (setrlimit resource value value))
    (lambda args #f)))

(apply-limit 'as (option-number "--max-address-space" 268435456))
(apply-limit 'cpu (option-number "--max-cpu" 30))

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

(define (make-frame type . fields)
  (cons type fields))

(define (frame-type frame)
  (car frame))

(define (frame-field frame key)
  (let loop ((fields (cdr frame)))
    (cond ((null? fields) #f)
          ((eq? (car fields) key) (cadr fields))
          (else (loop (cddr fields))))))

(define current-run-id #f)
(define current-call-id 0)
(define cell-time-limit 0.25)
(define cell-allocation-limit 33554432)

(define (next-call-id)
  (set! current-call-id (+ current-call-id 1))
  current-call-id)

(define (call-host name arguments)
  (let ((call-id (next-call-id)))
    (write-frame (make-frame 'hostCall
                             'runID (wire-string current-run-id)
                             'callID call-id
                             'name (wire-string (symbol->string name))
                             'arguments (scm->wire arguments)))
    (let loop ()
      (let ((frame (read-frame)))
        (cond
          ((not frame) (error "host channel closed"))
          ((eq? (frame-type frame) 'hostResult)
           (if (and (equal? (frame-field frame 'runID) current-run-id)
                    (equal? (frame-field frame 'callID) call-id))
               (frame-field frame 'value)
               (loop)))
          ((eq? (frame-type frame) 'hostError)
           (error "host call failed" (frame-field frame 'message)))
          (else (loop)))))))

(define (hit->alist hit)
  (list (cons 'chunk-id (list-ref hit 0))
        (cons 'path (list-ref hit 1))
        (cons 'start-line (list-ref hit 2))
        (cons 'end-line (list-ref hit 3))
        (cons 'preview (list-ref hit 4))))

(define (corpus-search query limit)
  (map hit->alist (call-host 'corpus-search (list query limit))))

(define (corpus-read chunk-id)
  (let ((chunks (call-host 'corpus-read (list chunk-id))))
    (if (null? chunks)
        (error "unknown chunk" chunk-id)
        (list-ref (car chunks) 4))))

(define (corpus-read-many chunk-ids)
  (map (lambda (chunk) (list-ref chunk 4))
       (call-host 'corpus-read-many (list chunk-ids))))

(define (lm-query prompt . tier)
  (car (call-host 'lm-query
                  (if (null? tier) (list prompt) (list prompt (car tier))))))

(define (lm-query-batched prompts . tier)
  (call-host 'lm-query-batched
             (if (null? tier) (list prompts) (list prompts (car tier)))))

(define (progress message)
  (call-host 'progress (list message))
  #f)

(define (finish answer evidence)
  (if (not (string? answer))
      (error "finish answer must be a string"))
  (if (not (list? evidence))
      (error "finish evidence must be a list of chunk identifiers"))
  (for-each (lambda (identifier)
              (if (not (string? identifier))
                  (error "finish evidence entries must be chunk identifier strings")))
            evidence)
  (throw 'gnostic-finish answer evidence))

(define (wire-string value)
  (let ((result (string-copy value)))
    (let loop ((index 0))
      (if (< index (string-length result))
          (let* ((character (string-ref result index))
                 (code (char->integer character)))
            (if (not (or (and (>= code 32) (<= code 126))
                         (memv code '(9 10 13))))
                (string-set! result index #\?))
            (loop (+ index 1)))
          result))))

(define marker-unsupported (integer->char 33))
(define marker-truncated (integer->char 63))
(define marker-symbol (integer->char 126))

(define (fits-integer? value)
  (and (<= value 9223372036854775807)
       (>= value -9223372036854775808)))

(define (finite-real? value)
  (and (= value value)
       (not (= value (+ value 1e308)))))

(define (ascii-letter? character)
  (let ((code (char->integer character)))
    (or (and (>= code 65) (<= code 90))
        (and (>= code 97) (<= code 122)))))

(define (ascii-digit? character)
  (let ((code (char->integer character)))
    (and (>= code 48) (<= code 57))))

(define (valid-wire-symbol? name)
  (and (> (string-length name) 0)
       (ascii-letter? (string-ref name 0))
       (let loop ((index 1))
         (if (>= index (string-length name))
             #t
             (let ((character (string-ref name index)))
               (and (or (ascii-letter? character)
                        (ascii-digit? character)
                        (char=? character #\-))
                    (loop (+ index 1))))))))

(define (wire-symbol value)
  (let ((name (symbol->string value)))
    (if (valid-wire-symbol? name)
        (string->symbol name)
        marker-symbol)))

(define (scm->wire value)
  (let ((budget 4096))
    (define (convert datum depth)
      (cond
        ((<= budget 0) marker-truncated)
        ((> depth 32) marker-truncated)
        ((boolean? datum)
         (set! budget (- budget 1)) datum)
        ((and (real? datum) (inexact? datum))
         (set! budget (- budget 1))
         (if (finite-real? datum) datum marker-unsupported))
        ((integer? datum)
         (set! budget (- budget 1))
         (if (fits-integer? datum) datum marker-unsupported))
        ((number? datum)
         (set! budget (- budget 1)) marker-unsupported)
        ((string? datum)
         (set! budget (- budget 1))
         (wire-string datum))
        ((symbol? datum)
         (set! budget (- budget 1)) (wire-symbol datum))
        ((null? datum)
         (set! budget (- budget 1)) '())
        ((unspecified? datum)
         (set! budget (- budget 1)) '())
        ((pair? datum)
         (set! budget (- budget 1))
         (cons (convert (car datum) (+ depth 1)) (convert (cdr datum) depth)))
        ((vector? datum)
         (set! budget (- budget 1))
         (map (lambda (element) (convert element (+ depth 1))) (vector->list datum)))
        (else
         (set! budget (- budget 1)) marker-unsupported)))
    (convert value 0)))

(define (make-run-module)
  (let ((module (make-sandbox-module allowed-bindings)))
    (module-define! module 'corpus-search corpus-search)
    (module-define! module 'corpus-read corpus-read)
    (module-define! module 'corpus-read-many corpus-read-many)
    (module-define! module 'lm-query lm-query)
    (module-define! module 'lm-query-batched lm-query-batched)
    (module-define! module 'progress progress)
    (module-define! module 'finish finish)
    module))

(define (names-of binding-set)
  (cdr (car binding-set)))

(define (entry-name binding)
  (if (pair? binding) (cdr binding) binding))

(define disallowed-names
  (append (names-of macro-bindings)
          (names-of clock-bindings)
          (names-of regexp-bindings)
          '(throw catch values call-with-values
            call-with-prompt abort-to-prompt
            call-with-composable-continuation
            call-with-escape-continuation
            with-exception-handler
            raise raise-exception
            dynamic-wind
            call/cc call-with-current-continuation
            scm-error with-throw-handler abort-to-prompt* make-prompt-tag)))

(define allowed-bindings
  (map (lambda (binding-set)
         (cons (car binding-set)
               (filter (lambda (binding)
                         (not (memq (entry-name binding) disallowed-names)))
                       (cdr binding-set))))
       all-pure-bindings))

(define run-module #f)

(define (eval-forms source module)
  (call-with-input-string
   source
   (lambda (port)
     (let loop ((value #f))
       (let ((form (read port)))
         (if (eof-object? form)
             value
             (loop (eval form module))))))))

(define (string-list? value)
  (and (list? value)
       (let loop ((rest value))
         (cond ((null? rest) #t)
               ((string? (car rest)) (loop (cdr rest)))
               (else #f)))))

(define (valid-finish? answer evidence)
  (and (string? answer) (string-list? evidence)))

(define (eval-cell source)
  (catch #t
    (lambda ()
      (let ((value (call-with-time-and-allocation-limits
                    cell-time-limit
                    cell-allocation-limit
                    (lambda () (eval-forms source run-module)))))
        (list 'value (scm->wire value))))
    (lambda (key . args)
      (cond
        ((eq? key 'limit-exceeded)
         (list 'failed (wire-string "resource limit exceeded")))
        ((eq? key 'gnostic-finish)
         (list 'finished
               (if (>= (length args) 1) (car args) #f)
               (if (>= (length args) 2) (cadr args) '())))
        (else
         (list 'failed (wire-string (format #f "~a: ~a" key args))))))))

(define (environment-keys)
  (map (lambda (entry) (car (string-split entry #\=))) (environ)))

(define (count-directory-entries path)
  (let ((directory (opendir path)))
    (let loop ((count 0))
      (let ((entry (readdir directory)))
        (if (eof-object? entry)
            (begin (closedir directory) count)
            (loop (+ count 1)))))))

(define (open-file-descriptor-count)
  (catch #t
    (lambda ()
      (cond
        ((file-exists? "/proc/self/fd") (count-directory-entries "/proc/self/fd"))
        ((file-exists? "/dev/fd") (count-directory-entries "/dev/fd"))
        (else -1)))
    (lambda args -1)))

(define (limit-number resource)
  (catch #t
    (lambda ()
      (let ((value (getrlimit resource)))
        (let ((soft (if (pair? value) (car value) value)))
          (if (> soft 4611686018427387904) -1 soft))))
    (lambda args -1)))

(define (handle-evaluate frame)
  (let ((cell-id (frame-field frame 'cellID))
        (source (frame-field frame 'source)))
    (let ((result (eval-cell source)))
      (case (car result)
        ((value)
         (write-frame (make-frame 'evaluated
                                  'runID (wire-string current-run-id)
                                  'cellID cell-id
                                  'output ""
                                  'value (cadr result))))
        ((finished)
         (let ((answer (cadr result))
               (evidence (caddr result)))
           (if (valid-finish? answer evidence)
               (write-frame (make-frame 'finished
                                        'runID (wire-string current-run-id)
                                        'answer (wire-string answer)
                                        'evidenceIDs (map wire-string evidence)))
               (write-frame (make-frame 'failed
                                        'runID (wire-string current-run-id)
                                        'cellID cell-id
                                        'message (wire-string "finish arguments must be a string and a list of strings"))))))
        (else
         (write-frame (make-frame 'failed
                                  'runID (wire-string current-run-id)
                                  'cellID cell-id
                                  'message (wire-string (cadr result)))))))))

(define (main)
  (let loop ()
    (let ((frame (read-frame)))
      (if (not frame)
          (exit 0)
          (case (frame-type frame)
            ((initialize)
             (set! current-run-id (frame-field frame 'runID))
             (set! cell-time-limit
                   (let ((value (frame-field frame 'timeLimitSeconds)))
                     (if value value cell-time-limit)))
             (set! cell-allocation-limit
                   (let ((value (frame-field frame 'allocationLimitBytes)))
                     (if value value cell-allocation-limit)))
             (set! run-module (make-run-module))
             (write-frame (make-frame 'ready
                                      'runID (wire-string current-run-id)
                                      'environmentKeys (map wire-string (environment-keys))
                                      'openFileDescriptorCount (open-file-descriptor-count)
                                      'cpuLimitSeconds (limit-number 'cpu)
                                      'addressSpaceBytes (limit-number 'as)))
             (loop))
            ((evaluate)
             (handle-evaluate frame)
             (loop))
            ((cancel shutdown)
             (exit 0))
            (else
             (loop)))))))

(main)

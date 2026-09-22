;;; Gnostic RLM Scheme 0 worker (Chibi Scheme 0.12).
;;;
;;; This worker is an experiment. It reads length-prefixed frames from stdin,
;;; evaluates validated cells in one run-local restricted environment, and
;;; services bounded host calls over the same framed channel. It is not enabled
;;; in any production composition.

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

(define input-port (current-input-port))
(define output-port (current-output-port))

;;; Frame I/O below reads and writes bytes through the character ports, so it
;;; is correct only while a character is exactly one byte. That holds because
;;; this worker runs against a Chibi built with UTF-8 strings disabled.
;;;
;;; This build cannot be ported to binary ports: `SEXP_USE_MODULES=0` and
;;; `SEXP_USE_STATIC_LIBS_EMPTY=1` leave `read-u8`, `write-u8`,
;;; `read-bytevector`, `write-bytevector`, the bytevector ports and
;;; `string->utf8` out of the image entirely, and re-adding them means
;;; re-opening the sandbox surface those two flags exist to close.
;;;
;;; So the dependency is asserted here instead of assumed. With UTF-8 strings
;;; on, `read-char` rejects a length-prefix byte >= 128 and `write-char`
;;; re-encodes one into a multibyte sequence, which corrupts the 4-byte header
;;; rather than failing visibly. Fail at startup instead: the host sees a
;;; non-zero exit and this message, not a silently mangled frame.
(let* ((probe (string (integer->char 233)))
       (characters (string-length probe))
       (bytes (string-size probe)))
  (if (not (= characters bytes))
      (error
       (string-append
        "Chibi RLM worker requires a build with UTF-8 strings disabled: "
        "frame I/O addresses bytes through character ports. Rebuild with "
        "SEXP_USE_UTF8_STRINGS unset, or port frame I/O to binary ports "
        "(which this build does not provide)."))))

(define (read-byte)
  (let ((character (read-char input-port)))
    (if (eof-object? character) #f (char->integer character))))

(define (write-byte value)
  (write-char (integer->char value) output-port))

(define (read-exact count)
  (let loop ((index 0) (bytes '()))
    (if (= index count)
        (reverse bytes)
        (let ((byte (read-byte)))
          (if (not byte) #f (loop (+ index 1) (cons byte bytes)))))))

(define (read-frame)
  (let ((header (read-exact 4)))
    (if (not header)
        #f
        (let* ((length (+ (* (list-ref header 0) 16777216)
                          (* (list-ref header 1) 65536)
                          (* (list-ref header 2) 256)
                          (list-ref header 3)))
               (payload (read-exact length)))
          (if (not payload)
              #f
              (read (open-input-string (list->string (map integer->char payload)))))))))

(define (write-frame frame)
  (let* ((port (open-output-string))
         (text (begin (write frame port) (get-output-string port)))
         (length (string-length text)))
    (write-byte (modulo (quotient length 16777216) 256))
    (write-byte (modulo (quotient length 65536) 256))
    (write-byte (modulo (quotient length 256) 256))
    (write-byte (modulo length 256))
    (let loop ((index 0))
      (if (< index length)
          (begin
            (write-char (string-ref text index) output-port)
            (loop (+ index 1)))))
    (flush-output output-port)))

(define (make-frame type . fields) (cons type fields))

(define (frame-type frame) (car frame))

(define (frame-field frame key)
  (let loop ((fields (cdr frame)))
    (cond ((null? fields) #f)
          ((eq? (car fields) key) (cadr fields))
          (else (loop (cddr fields))))))

(define current-run-id #f)
(define current-call-id 0)

(define (next-call-id)
  (set! current-call-id (+ current-call-id 1))
  current-call-id)

(define marker-unsupported (integer->char 33))
(define marker-truncated (integer->char 63))
(define marker-symbol (integer->char 126))

(define (wire-string value)
  (list->string
   (map (lambda (character)
          (let ((code (char->integer character)))
            (if (or (and (>= code 32) (<= code 126))
                    (= code 9) (= code 10) (= code 13))
                character
                #\?)))
        (string->list value))))

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

(define (wire-symbol-value value)
  (let ((name (symbol->string value)))
    (if (valid-wire-symbol? name)
        (string->symbol name)
        marker-symbol)))

(define (fits-integer? value)
  (and (<= value 9223372036854775807)
       (>= value -9223372036854775808)))

(define (finite-flonum? value)
  (and (= value value)
       (not (= value (+ value 1e308)))))

(define (scm->wire value)
  (let ((budget 4096))
    (define (take-budget?)
      (if (<= budget 0)
          #f
          (begin (set! budget (- budget 1)) #t)))
    (define (convert datum depth)
      (cond
        ((not (take-budget?)) marker-truncated)
        ((> depth 32) marker-truncated)
        ((boolean? datum) datum)
        ((flonum? datum)
         (if (finite-flonum? datum) datum marker-unsupported))
        ((integer? datum)
         (if (fits-integer? datum) datum marker-unsupported))
        ((number? datum) marker-unsupported)
        ((string? datum) (wire-string datum))
        ((symbol? datum) (wire-symbol-value datum))
        ((null? datum) '())
        ((eq? datum (if #f #f)) '())
        ((pair? datum) (convert-list datum depth))
        ((vector? datum) (convert-vector datum depth))
        (else marker-unsupported)))
    (define (rebuild-list reversed-elements tail)
      (let loop ((remaining reversed-elements) (result tail))
        (if (null? remaining)
            result
            (loop (cdr remaining) (cons (car remaining) result)))))
    (define (convert-list datum depth)
      (let loop ((rest datum) (elements '()))
        (cond
          ((null? rest) (reverse elements))
          ((not (pair? rest))
           (rebuild-list elements (convert rest (+ depth 1))))
          ((<= budget 0)
           (reverse (cons marker-truncated elements)))
          (else
           (loop (cdr rest) (cons (convert (car rest) (+ depth 1)) elements))))))
    (define (convert-vector datum depth)
      (let ((length (vector-length datum)))
        (let loop ((index 0) (elements '()))
          (cond
            ((>= index length) (reverse elements))
            ((<= budget 0)
             (reverse (cons marker-truncated elements)))
            (else
             (loop (+ index 1)
                   (cons (convert (vector-ref datum index) (+ depth 1)) elements)))))))
    (convert value 0)))

(define (gnostic-raise message)
  (raise (list 'gnostic-error message)))

(define (render-exception error)
  (call-with-current-continuation
   (lambda (escape)
     (with-exception-handler
      (lambda (ignored) (escape "scheme evaluation failed"))
      (lambda ()
        (let ((port (open-output-string)))
          (print-exception error port)
          (get-output-string port)))))))

(define (error-message error)
  (if (and (pair? error) (eq? (car error) 'gnostic-error))
      (cadr error)
      (let ((text (render-exception error)))
        (if (and (string? text) (string-contains text "out of memory"))
            "resource limit exceeded"
            text))))

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
          ((not frame) (gnostic-raise "host channel closed"))
          ((eq? (frame-type frame) 'hostResult)
           (if (and (equal? (frame-field frame 'runID) current-run-id)
                    (equal? (frame-field frame 'callID) call-id))
               (frame-field frame 'value)
               (loop)))
          ((eq? (frame-type frame) 'hostError)
           (gnostic-raise
            (string-append "host call failed: "
                           (let ((message (frame-field frame 'message)))
                             (if (string? message) message "")))))
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
        (gnostic-raise "unknown chunk")
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

(define finish-continuation #f)

(define (finish answer evidence)
  (if (not (string? answer))
      (gnostic-raise "finish answer must be a string"))
  (if (not (list? evidence))
      (gnostic-raise "finish evidence must be a list of chunk identifiers"))
  (for-each (lambda (identifier)
              (if (not (string? identifier))
                  (gnostic-raise "finish evidence entries must be chunk identifier strings")))
            evidence)
  (if finish-continuation
      (finish-continuation (list 'finished answer evidence))
      (gnostic-raise "finish is not available")))

(define (caddr value) (car (cddr value)))

(define (cadddr value) (car (cddr (cdr value))))

(define (filter predicate values)
  (cond ((null? values) '())
        ((predicate (car values)) (cons (car values) (filter predicate (cdr values))))
        (else (filter predicate (cdr values)))))

(define (string-upcase value)
  (list->string (map char-upcase (string->list value))))

(define (string-downcase value)
  (list->string (map char-downcase (string->list value))))

(define (string-join values . separator)
  (let ((delimiter (if (null? separator) " " (car separator))))
    (if (null? values)
        ""
        (let loop ((result (car values)) (rest (cdr values)))
          (if (null? rest)
              result
              (loop (string-append result delimiter (car rest)) (cdr rest)))))))

(define (string-split value delimiter)
  (let loop ((index 0) (start 0) (parts '()))
    (if (>= index (string-length value))
        (reverse (cons (substring value start index) parts))
        (if (char=? (string-ref value index) delimiter)
            (loop (+ index 1) (+ index 1) (cons (substring value start index) parts))
            (loop (+ index 1) start parts)))))

(define (string-contains value needle)
  (let ((value-length (string-length value))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (cond ((> (+ index needle-length) value-length) #f)
            ((string=? (substring value index (+ index needle-length)) needle) index)
            (else (loop (+ index 1)))))))

(define (sort values less?)
  (define (merge left right)
    (cond ((null? left) right)
          ((null? right) left)
          ((less? (car right) (car left)) (cons (car right) (merge left (cdr right))))
          (else (cons (car left) (merge (cdr left) right)))))
  (define (halve values)
    (if (or (null? values) (null? (cdr values)))
        (list values '())
        (let ((rest (halve (cddr values))))
          (list (cons (car values) (car rest))
                (cons (cadr values) (cadr rest))))))
  (if (or (null? values) (null? (cdr values)))
      values
      (let ((halves (halve values)))
        (merge (sort (car halves) less?) (sort (cadr halves) less?)))))

(define (read-characters path)
  (call-with-current-continuation
   (lambda (escape)
     (with-exception-handler
      (lambda (ignored) (escape #f))
      (lambda ()
        (let ((port (open-input-file path)))
          (let loop ((characters '()))
            (let ((character (read-char port)))
              (if (eof-object? character)
                  (begin (close-input-port port) (reverse characters))
                  (loop (cons character characters)))))))))))

(define (split-on-null characters)
  (let loop ((rest characters) (current '()) (parts '()))
    (cond ((null? rest) (reverse (cons (reverse current) parts)))
          ((= (char->integer (car rest)) 0)
           (loop (cdr rest) '() (cons (reverse current) parts)))
          (else (loop (cdr rest) (cons (car rest) current) parts)))))

(define (entry-key characters)
  (let loop ((rest characters) (current '()))
    (cond ((null? rest) (list->string (reverse current)))
          ((= (char->integer (car rest)) 61) (list->string (reverse current)))
          (else (loop (cdr rest) (cons (car rest) current))))))

(define (environment-keys)
  (let ((characters (read-characters "/proc/self/environ")))
    (if (not characters)
        '()
        (map entry-key
             (filter (lambda (entry) (not (null? entry)))
                     (split-on-null characters))))))

(define pure-operation-names
  '(+ - * / quotient remainder modulo abs min max
    expt sqrt gcd lcm floor ceiling round truncate
    = < > <= >= zero? positive? negative? odd? even?
    number? integer? exact? inexact? not
    eq? eqv? equal?
    string? string-append string-length string-ref substring
    string=? string<? string>? string<=? string>=?
    string-contains string-split string-join
    string-upcase string-downcase string->list list->string
    make-string number->string string->number
    symbol? symbol->string string->symbol
    list list? pair? null? cons car cdr
    caar cadr cdar cddr caddr cadddr
    length append reverse list-ref list-tail make-list
    member memq memv assoc assq assv
    map for-each filter sort apply
    vector? vector vector-length vector-ref
    vector->list list->vector make-vector))

(define special-form-names
  '(quote if cond and or begin lambda let let* letrec define))

(define host-call-names
  '(corpus-search corpus-read corpus-read-many lm-query lm-query-batched progress finish))

(define run-environment #f)

(define (make-run-environment)
  (let ((environment (make-environment)))
    (%import environment (interaction-environment)
             (append pure-operation-names special-form-names host-call-names)
             #f)
    environment))

(define (eval-forms source environment)
  (let ((port (open-input-string source)))
    (let loop ((value #f))
      (let ((form (read port)))
        (if (eof-object? form)
            value
            (loop (eval form environment)))))))

(define (eval-cell source)
  (call-with-current-continuation
   (lambda (escape)
     (set! finish-continuation escape)
     (with-exception-handler
      (lambda (condition) (escape (list 'failed (error-message condition))))
      (lambda ()
        (escape (list 'value (scm->wire (eval-forms source run-environment)))))))))

(define (valid-finish? answer evidence)
  (and (string? answer)
       (list? evidence)
       (let loop ((rest evidence))
         (cond ((null? rest) #t)
               ((string? (car rest)) (loop (cdr rest)))
               (else #f)))))

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
          #t
          (case (frame-type frame)
            ((initialize)
             (set! current-run-id (frame-field frame 'runID))
             (set! run-environment (make-run-environment))
             (write-frame (make-frame 'ready
                                      'runID (wire-string current-run-id)
                                      'environmentKeys (map wire-string (environment-keys))
                                      'openFileDescriptorCount -1
                                      'cpuLimitSeconds (option-number "--max-cpu" -1)
                                      'addressSpaceBytes (option-number "--max-address-space" -1)))
             (loop))
            ((evaluate)
             (handle-evaluate frame)
             (loop))
            ((cancel shutdown)
             #t)
            (else (loop)))))))

(main)

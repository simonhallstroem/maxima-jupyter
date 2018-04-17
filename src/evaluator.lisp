(in-package #:maxima-jupyter)

(defvar *kernel* nil)
(defvar *message* nil)
(defvar *payload* nil)
(defvar *page-output* nil)

#|

# Evaluator #

The evaluator is where the "interesting stuff" takes place :
 user expressions are evaluated here.

The history of evaluations is also saved by the evaluator.

|#

(defclass evaluator ()
  ((history-in :initform (make-array 64 :fill-pointer 0 :adjustable t)
               :reader evaluator-history-in)
   (history-out :initform (make-array 64 :fill-pointer 0 :adjustable t)
                :reader evaluator-history-out)
   (in-maxima :initform t
              :accessor evaluator-in-maxima)))

(defun make-evaluator ()
  (make-instance 'evaluator))

(defun make-eval-error (err msg &key (quit nil))
  (let ((name (symbol-name (class-name (class-of err)))))
    (write-string msg *error-output*)
    (make-error-result name msg :quit quit)))

(define-condition quit (error)
  ()
  (:documentation "A quit condition for identifying a request for kernel shutdown.")
  (:report (lambda (c stream))))

(define-condition maxima-syntax-error (error)
  ((message :initarg :message
            :reader maxima-syntax-error-message))
  (:documentation "Maxima syntax error.")
  (:report (lambda (condition stream)
             (write-string (maxima-syntax-error-message condition) stream))))

;;; Based on macro taken from: http://www.cliki.net/REPL
(defmacro handling-errors (&body body)
  `(catch 'maxima::return-from-debugger
    (catch 'maxima::macsyma-quit
    (handler-case (progn ,@body)
       (quit (err)
         (make-eval-error err (format nil "~A" err) :quit t))
       (simple-condition (err)
         (make-eval-error err
           (apply #'format nil (simple-condition-format-control err)
                               (simple-condition-format-arguments err))))
       (condition (err)
         (make-eval-error err (format nil "~A" err)))))))

(defun my-mread (input)
  (when (and (open-stream-p input) (peek-char nil input nil))
    (let ((maxima::*mread-prompt* "")
          (maxima::*prompt-on-read-hang*))
      (declare (special maxima::*mread-prompt*
                        maxima::*prompt-on-read-hang*))
      (maxima::dbm-read input nil))))

(defun my-lread (input)
  (when (and (open-stream-p input) (peek-char nil input nil))
    (read input)))

(defun eval-error-p (result)
  (typep result 'error-result))

(defun quit-eval-error-p (result)
  (and (typep result 'error-result) (error-result-quit result)))

(defun keyword-lisp-p (code)
  (and (consp code)
       (or (equal ':lisp (car code)) (equal ':lisp-quiet (car code)))))

(defun keyword-command-p (code)
  (and (consp code) (keywordp (car code))))

(defun my-eval (code)
  (let ((*package* (find-package :maxima)))
    (cond ((keyword-lisp-p code)
           (cons (list (car code))
                 (multiple-value-list (eval (cons 'progn code)))))
          ((keyword-command-p code)
           (cons (list (car code))
                 (maxima::break-call (car code) (cdr code)
                                     'maxima::break-command)))
          (t
           (maxima::meval* code)))))

(defun read-and-eval (input in-maxima)
  (catch 'state-change
    (handling-errors
      (let ((code-to-eval (if in-maxima
                            (my-mread input)
                            (my-lread input))))
        (if code-to-eval
          (progn
            (info "[evaluator] Parsed expression to evaluate: ~W~%" code-to-eval)
            (let ((result (if in-maxima
                            (my-eval code-to-eval)
                            (eval code-to-eval))))
              (info "[evaluator] Evaluated result: ~W~%" result)
              (when (and in-maxima (not (keyword-result-p result)))
                (setq maxima::$% (caddr result)))
              result))
          'no-more-code)))))

(defun evaluate-code (evaluator code)
  (iter
    (initially
      (info "[evaluator] Unparsed input: ~W~%" code)
      (vector-push code (evaluator-history-in evaluator)))
    (with input = (make-string-input-stream code))
    (for in-maxima = (evaluator-in-maxima evaluator))
    (for result = (read-and-eval input in-maxima))
    (until (eq result 'no-more-code))
    (for wrapped-result = (if in-maxima
                            (make-maxima-result result)
                            (make-lisp-result result)))
    (when wrapped-result
      (send-result wrapped-result)
      (collect wrapped-result into results))
    (until (quit-eval-error-p wrapped-result))
    (finally
      (vector-push results (evaluator-history-out evaluator))
      (return
        (values (length (evaluator-history-in evaluator))
                results)))))

(defun send-result (result)
  (let ((iopub (kernel-iopub *kernel*))
        (execute-count (+ 1 (length (evaluator-history-in (kernel-evaluator *kernel*))))))
    (if (typep result 'error-result)
      (send-execute-error iopub *message* execute-count
                          (error-result-ename result)
                          (error-result-evalue result))
      (let ((data (render result)))
        (when data
          (if (result-display result)
            (send-display-data iopub *message* data)
            (send-execute-result iopub *message* execute-count data)))))))

(defun state-change-p (expr)
  (and (listp expr)
       (or (eq (car expr) 'maxima::$to_lisp)
           (eq (car expr) 'maxima::to-maxima)
           (some #'state-change-p expr))))

(defun is-complete (evaluator code)
  (handler-case
    (iter
      (with *standard-output* = (make-string-output-stream))
      (with *error-output* = (make-string-output-stream))
      (with input = (make-string-input-stream code))
      (with in-maxima = (evaluator-in-maxima evaluator))
      (for char = (peek-char nil input nil))
      (while char)
      (for parsed = (if in-maxima (maxima::dbm-read input nil) (my-lread input)))
      (when (state-change-p parsed)
        (leave +status-unknown+))
      (finally (return +status-complete+)))
    (end-of-file ()
      +status-incomplete+)
    #+sbcl (sb-int:simple-reader-error ()
      +status-incomplete+)
    (simple-condition (err)
      (if (equal (simple-condition-format-control err)
                 "parser: end of file while scanning expression.")
        +status-incomplete+
        +status-invalid+))
    (condition ()
      +status-invalid+)
    (simple-error ()
      +status-invalid+)))

(defun to-lisp ()
  (setf (evaluator-in-maxima (kernel-evaluator *kernel*)) nil)
  (throw 'state-change 'no-output))

(defun to-maxima ()
  (setf (evaluator-in-maxima (kernel-evaluator *kernel*)) t)
  (throw 'state-change 'no-output))

(defun set-next-input (text &optional (replace nil))
  (vector-push-extend (jsown:new-js
                        ("source" "set_next_input")
                        ("text" text))
                      *payload*))

(defun page (result &optional (start 0))
  (vector-push-extend (jsown:new-js
                        ("source" "page")
                        ("data" (render result))
                        ("start" start))
                      *payload*))

(defun enqueue-input (text)
  (cl-containers:enqueue (kernel-input-queue *kernel*) text))

(defun display-and-eval (expr)
  (send-result
    (make-inline-result
      (with-output-to-string (f)
        (maxima::mgrind (third expr) f)
        (write-char #\; f))
      :display t))
  (let* ((res (maxima::meval* expr))
         (result (make-maxima-result res)))
   (setq maxima::$% (third res))
   (when result
     (send-result result))))

(defun my-displa (form)
  (send-result
    (make-maxima-result
      `((maxima::displayinput) nil ,form)
      :display t)))

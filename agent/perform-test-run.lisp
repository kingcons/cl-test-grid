;;;; -*- Mode: LISP; Syntax: COMMON-LISP; indent-tabs-mode: nil; coding: utf-8; show-trailing-whitespace: t -*-
;;;; Copyright (C) 2011 Anton Vodonosov (avodonosov@yandex.ru)
;;;; See LICENSE for details.

(in-package #:test-grid-agent)

(defun make-run-descr (lib-world lisp-implementation-identifier user-email)
  "Generate a description for a test run which might be
performed in the current lisp system."
  (list :lisp lisp-implementation-identifier
        :lib-world lib-world
        :time (get-universal-time)
        :run-duration :unknown
        :contact (list :email user-email)))

(defun fmt-time (universal-time &optional destination)
  "The preferred time format used in the cl-test-grid project."
  (multiple-value-bind (sec min hour date month year)
      (decode-universal-time universal-time 0)
    (funcall #'format
             destination
             "~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D"
             year month date hour min sec)))

(defun name-run-directory (run-descr)
  "Generate name for the directory where test run
data (libraries test suites output and the run results) will be saved."
  (format nil
          "~A-~A"
          (fmt-time (getf run-descr :time))
          (getf run-descr :lisp)))

(defun run-directory (run-descr base-dir)
  (merge-pathnames (make-pathname
                    :directory (list :relative (name-run-directory run-descr))
                    :name      nil
                    :type      nil)
                   base-dir))

(defun make-run (description lib-results)
  (list :descr description :results lib-results))

(defun run-info-file (test-run-directory)
  (merge-pathnames "test-run-info.lisp"
                   test-run-directory))

(defun save-run-info (test-run directory)
  (let ((run-file (run-info-file directory)))
    (with-open-file (out run-file
                         :direction :output
                         :element-type 'character ;'(unsigned-byte 8) + flexi-stream
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (test-grid::print-test-run out test-run))))

(defun lib-log-file (test-run-directory lib-name)
  (merge-pathnames (string-downcase lib-name)
                   test-run-directory))

(defun proc-run-libtest (lisp-exe libname run-descr logfile)
  "Runs test-grid::run-libtest in a separate process and returns result."
  (with-response-file (response-file)
    (let* ((code `(progn
                    (load ,(workdir-file "quicklisp/setup.lisp"))
                    (load ,(src-file "proc-run-libtest.lisp"))
                    (cl-user::run-libtest-with-response-to-file ,libname
                                                                (quote ,run-descr)
                                                                ,logfile
                                                                ,response-file))))
      (log:info "preparing to start separate lisp process with code: ~S" code)
      (run-lisp-process lisp-exe code))))

(defun perform-test-run (lib-world lisp-exe-ex libs output-base-dir user-email)
  (let* ((run-descr (make-run-descr lib-world
                                    (implementation-identifier lisp-exe-ex)
                                    user-email))
         (run-dir (run-directory run-descr output-base-dir))
         (lib-results))
    (ensure-directories-exist run-dir)
    (dolist (lib libs)
      (let ((lib-result (proc-run-libtest (exe lisp-exe-ex) lib run-descr (lib-log-file run-dir lib))))
        (push lib-result lib-results)))
    (setf (getf run-descr :run-duration)
          (- (get-universal-time)
             (getf run-descr :time)))
    (let ((run (make-run run-descr lib-results)))
      (save-run-info run run-dir)
      (log:info "The test results were saved to: ~%~A." (truename run-dir))
      run-dir)))

(defun submit-logs (blobstore test-run-dir)
  (let* ((run-info (test-grid::safe-read-file (run-info-file test-run-dir)))
         ;; prepare parameters for the SUBMIT-FILES blobstore function
         (submit-params (mapcar #'(lambda (lib-result)
                                    (let ((libname (getf lib-result :libname)))
                                      (cons libname
                                            (lib-log-file test-run-dir libname))))
                                (test-grid::run-results run-info))))
    ;; submit files to the blobstore and receive
    ;; their blobkeys in response
    (let ((libname-to-blobkey-alist
           (test-grid-blobstore:submit-files blobstore
                                             submit-params)))
      ;; Now store the blobkeys for every library in the run-info.
      ;; Note, we destructively modify parts of the previously
      ;; read run-info.
      (flet ((get-blob-key (lib)
               (or (cdr (assoc lib libname-to-blobkey-alist))
                   (error "blobstore didn't returned blob key for the log of the ~A libary" lib))))
        (setf (test-grid::run-results run-info)
              (mapcar #'(lambda (lib-result)
                          (setf (getf lib-result :log-blob-key)
                                (get-blob-key (getf lib-result :libname)))
                          lib-result)
                      (test-grid::run-results run-info))))
      ;; finally, save the updated run-info with blobkeys
      ;; to the file. Returns the run-info.
      (save-run-info run-info test-run-dir)
      run-info)))

(defun submit-results (blobstore test-run-dir)
  (let* ((run-info (submit-logs blobstore test-run-dir)))
    (log:info "The log files are submitted. Submitting the test run info...")
    (test-grid-blobstore:submit-run-info blobstore run-info)
    (log:info "Done. The test results are submitted. They will be reviewed by admin soon and added to the central database.")
    run-info))

(defun submit-test-run (blobstore test-run-dir)
  (log:info "~%Submitting the test results to the server...")
  (handler-case (submit-results blobstore test-run-dir)
    (error (e) (log:error "Error occured while uploading the test results to the server: ~A: ~A.
You can submit manually the full content of the results directory
   ~A
to the cl-test-grid issue tracker:
   https://github.com/cl-test-grid/cl-test-grid/issues~%"
                       (type-of e)
                       e
                       (truename test-run-dir)))))


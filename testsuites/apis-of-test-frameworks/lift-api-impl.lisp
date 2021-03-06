(defpackage #:lift-api-impl
  (:use #:cl :lift-api))

(in-package #:lift-api-impl)

;; Limitations in the Lift support:
;; - Lift allows the test developer to leave
;;   the test name unspecified, in which case the name
;;   is generated automatically: test-1, test-2 and so on.
;;   If the testsuite is modified later (tests are removed/added),
;;   the autogenerated names will change: a test previsously 
;;   named test-1 might become test-3 now. And we are unable
;;   to know what tests to mach between old test
;;   results and new test results. It is the
;;   worst problem we have in the Lift support.
;;   For now we just hope no one creates unnamed
;;   tests in their test suites (at least the
;;   test suites of Gary King's libraries always
;;   name the tests).
;; - We do not distinguish failures from errors.
;;   For example, if some test-1 is marked as
;;   :expected-failure, but during the execution
;;   an error happens (e.g. division by zero),
;;   then Lift recognizes this is not what is expected
;;   by :expected-failure and puts the test 
;;   result into errors list, but not into expected-errors or
;;   expected-failures. But test-grid will just
;;   consider this test as failed, and will also
;;   have the test in the known-to-fail list, 
;;   therefore from the test-grid point of view
;;   we have just what was expected - the test was expected
;;   to fail in some way and it has failed. We accept
;;   this limitation in favor of simplicity.
;;   At the level of detalization we chosen for
;;   test grid, this problem will pass unnoticed.
;; - Lift allows to mark whole test suite as
;;   an expected failure - there is a generic
;;   function lift::testsuite-expects-failure
;;   which may be overriden for particular test suite.
;;   We do not support this; moreover the function
;;   is not exported from the Lift package, 
;;   therefore in practice it should never be used.

(defun run-test-suite (test-suite-name)
  (let* ((lift:*lift-debug-output* *standard-output*)
	 (result (lift:run-tests :suite test-suite-name)))
    (describe result *standard-output*)
    result))

(defun fmt-test-case (test-suite-name test-case-name)
  (format nil "~(~A.~A~)" test-suite-name test-case-name))

(defun failed-tests (test-suite-result)
  (let ((all-problems (append (lift:failures test-suite-result)
			      (lift:expected-failures test-suite-result)
			      (lift:errors test-suite-result)
			      (lift:expected-errors test-suite-result))))
    
    ;; When a test marked as :expected-error or :expected-failure
    ;; passes without error/failure, Lift automaticall puts
    ;; it into failures list - success which should not happen
    ;; is a problem. But we want to represent this information
    ;; differently, therefore will keep only tests which
    ;; really failed or signalled an error. 
    ;; 
    ;; Remove the "unexpected OKs" from the problem list.
    (setf all-problems (remove-if #'(lambda (problem)
				      (typep (lift:test-condition problem)
					     'lift:unexpected-success-failure))
				  all-problems))
    
    (mapcar #'(lambda (test-problem)
		(fmt-test-case (lift::testsuite test-problem)
			       (lift::test-method test-problem)))
	    all-problems)))

(defun known-to-fail (test-suite-name)
  (let ((real-test-suite-name (lift:find-testsuite test-suite-name :errorp t)))
    (flet ((has-option (test-case-name option)
	     (lift::test-case-option real-test-suite-name 
				     test-case-name 
				     option))) 
      (mapcar #'(lambda (test-case-name)
		  (fmt-test-case real-test-suite-name test-case-name))
	      (remove-if-not #'(lambda (test-case-name)
				 (or (has-option test-case-name :expected-error)
				     (has-option test-case-name :expected-failure)
				     (has-option test-case-name :expected-problem)))
			     (lift:testsuite-tests real-test-suite-name))))))
  

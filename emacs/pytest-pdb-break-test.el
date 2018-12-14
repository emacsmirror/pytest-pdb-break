;;; pytest-pdb-break-test.el ---- tests -*- lexical-binding: t -*-

;;; Commentary:
;;
;; This leaves around 40M of junk under /tmp/pytest-pdb-break-test/

(require 'ert)
(require 'pytest-pdb-break)

(defvar pytest-pdb-break-test-tests
  '(pytest-pdb-break-test-ert-setup
    pytest-pdb-break-test-upstream-env-updaters
    pytest-pdb-break-test-homer
    pytest-pdb-break-test-homer-symlink
    pytest-pdb-break-test-homer-missing
    pytest-pdb-break-test-query-helper-unregistered
    pytest-pdb-break-test-query-helper-registered
    pytest-pdb-break-test-query-helper-error
    pytest-pdb-break-test-get-config-info-error
    pytest-pdb-break-test-get-config-info-unregistered))

(defvar pytest-pdb-break-test-repo-root
  (file-name-as-directory
   (file-truename (getenv "PYTEST_PDB_BREAK_TEST_REPO_ROOT"))))

(defvar pytest-pdb-break-test-lisp-root
  (concat pytest-pdb-break-test-repo-root "emacs/"))

(defvar pytest-pdb-break-test-pytest-plugin
  (concat pytest-pdb-break-test-repo-root "pytest_pdb_break.py"))

(defvar pytest-pdb-break-test-lisp-main
  (concat pytest-pdb-break-test-lisp-root "pytest-pdb-break.el"))

(defvar pytest-pdb-break-test-lisp-this
  (concat pytest-pdb-break-test-lisp-root "pytest-pdb-break-test.el"))

(ert-deftest pytest-pdb-break-test-ert-setup ()
  (should-not (seq-difference pytest-pdb-break-test-tests
                              (mapcar 'ert-test-name (ert-select-tests t t))))
  (should (file-exists-p pytest-pdb-break-test-repo-root))
  (should (file-exists-p pytest-pdb-break-test-lisp-root))
  (should (file-exists-p pytest-pdb-break-test-pytest-plugin))
  (should (file-exists-p pytest-pdb-break-test-lisp-main))
  (should (file-exists-p pytest-pdb-break-test-lisp-this)))

(eval-when-compile ; BEG

  (defvar pytest-pdb-break-test-temp
    (file-name-as-directory (concat (temporary-file-directory)
                                    "pytest-pdb-break-test")))

  (defun pytest-pdb-break-test--unprefix (name)
    "Return truncated test NAME (string)."
    (when (symbolp name) (setq name (symbol-name name)))
    (replace-regexp-in-string
     (regexp-quote "pytest-pdb-break-test-") "" name))

  (defun pytest-pdb-break-test--name-to-envvar (name)
    (setq name (pytest-pdb-break-test--unprefix name)
          name (concat "pytest-pdb-break-test-" name))
    (upcase (replace-regexp-in-string "-" "_" name)))

  ) ; e-w-c--------- END

(defmacro pytest-pdb-break-test-with-environment (&rest body)
  ;; Covers PATH, PYTHONPATH, VIRTUAL_ENV
  ;; Consider unsetting all known PYTHON* env vars
  `(let (($orig (sxhash-equal (list process-environment exec-path))))
     (let ((process-environment (append process-environment nil))
           (exec-path (append exec-path nil)))
       ,@body)
     (should (= $orig (sxhash-equal (list process-environment exec-path))))))

(defmacro pytest-pdb-break-test-with-tmpdir (tail &rest body)
  "Run BODY in a temp directory, clobbering existing files.
The directory inherits the test's name, minus the feature prefix, with
an optional TAIL appended. To create a subdir, TAIL should start with a
dir sep."
  (let ((name '(pytest-pdb-break-test--unprefix
                (ert-test-name (ert-running-test)))))
    (if (stringp tail)
        (setq name `(concat ,name ,tail))
      (push tail body))
    `(let (($tmpdir (file-name-as-directory
                     (concat pytest-pdb-break-test-temp ,name))))
       (when (file-exists-p $tmpdir) (delete-directory $tmpdir t))
       (make-directory $tmpdir t)
       (let ((default-directory $tmpdir)) ,@body))))

(defmacro pytest-pdb-break-test-with-python-buffer (&rest body)
  `(pytest-pdb-break-test-with-environment
    (with-temp-buffer
      (let (python-indent-guess-indent-offset)
        (python-mode))
      ,@body)))

(ert-deftest pytest-pdb-break-test-upstream-env-updaters ()
  "Describe expected behavior of built-in `python-mode' interface.
Show that it doesn't restore environment to previous state. Certain
options are idiosyncratic and unintuitive."
  (cl-macrolet ((before (&rest rest) `(ert-info ("Before") ,@rest))
                (during (&rest rest) `(ert-info ("During") ,@rest))
                (after (&rest rest) `(ert-info ("After") ,@rest))
                (both (m b x y z)
                      `(ert-info (,m)
                         (pytest-pdb-break-test-with-python-buffer
                          ,x (let (,b) ,y) ,z)
                         (pytest-pdb-break-test-with-python-buffer
                          ,x (python-shell-with-environment ,y) ,z))))
    (ert-info ((concat "`python-shell-calculate-process-environment', "
                       "called by `python-shell-with-environment', "
                       "only mutates existing environment variables"))
      ;; First two don't use well-knowns (baseline)
      (both "Already present"
            (process-environment (python-shell-calculate-process-environment))
            (before (setenv "FOOVAR" "1"))
            (during (setenv "FOOVAR" "2")
                    (should (string= (getenv "FOOVAR") "2")))
            (after (should (string= (getenv "FOOVAR") "2"))))
      (both "Non-existent"
            (process-environment (python-shell-calculate-process-environment))
            (before (should-not (getenv "FOOVAR")))
            (during (setenv "FOOVAR" "1")
                    (should (string= (getenv "FOOVAR") "1")))
            (after (should-not (getenv "FOOVAR"))))
      (let ((python-shell-virtualenv-root "/tmp/pytest-pdb-break-test/foo"))
        (both
         "Setting `python-shell-virtualenv-root' sets VIRTUAL_ENV env var"
         (process-environment (python-shell-calculate-process-environment))
         (before (should-not (getenv "VIRTUAL_ENV")))
         (during (should (getenv "VIRTUAL_ENV")))
         (after (should-not (getenv "VIRTUAL_ENV")))))
      (let ((python-shell-process-environment '("VIRTUAL_ENV=/tmp/foo"
                                                "PATH=/tmp/foo:/the/rest")))
        (both
         "Only mutates PATH because it's present already in env"
         (process-environment (python-shell-calculate-process-environment))
         (before (should-not (getenv "VIRTUAL_ENV"))
                 (should (getenv "PATH"))) ; obvious but affirsm claim
         (during (should (string= (getenv "PATH") "/tmp/foo:/the/rest"))
                 (should (string= (getenv "VIRTUAL_ENV") "/tmp/foo")))
         (after (should-not (getenv "VIRTUAL_ENV"))
                (should (string= (getenv "PATH") "/tmp/foo:/the/rest"))))))
    (ert-info ("`py-sh-calc-exec-path' doesn't mutate `exec-path' (safe)")
      (let ((orig (sxhash-equal exec-path))
            (new "/tmp/pytest-pdb-break-test/foo"))
        (both "Arbitrary changes to `exec-path' only present during interim"
              (exec-path (python-shell-calculate-exec-path))
              (before (should-not (string= (caddr exec-path) new)))
              (during (setcar (cddr exec-path) new) ; don't use setf in test
                      (should (string= (caddr exec-path) new)))
              (after (should (= (sxhash-equal exec-path) orig)))))
      (let ((python-shell-virtualenv-root "/tmp/pytest-pdb-break-test/foo")
            (binned  "/tmp/pytest-pdb-break-test/foo/bin"))
        (both "Sets VIRTUAL_ENV env var from `python-shell-virtualenv-root'"
              (exec-path (python-shell-calculate-exec-path))
              (should-not (member binned exec-path))
              (during (should (string= binned (car exec-path))))
              (should-not (member binned exec-path))))
      (let ((python-shell-process-environment '("VIRTUAL_ENV=/tmp/foo"
                                                "PATH=/tmp/foo:/the/rest"))
            (orig (sxhash-equal exec-path)))
        (should-not (member "/tmp/foo" exec-path))
        (should-not (member "/tmp/foo/" exec-path))
        (both "Env vars not added to `exec-path'"
              (exec-path (python-shell-calculate-exec-path))
              (before (should (= (sxhash-equal exec-path) orig)))
              (during (should (= (sxhash-equal exec-path) orig)))
              (after (should (= (sxhash-equal exec-path) orig))))))))

(defmacro pytest-pdb-break-test-homer-fixture ()
  '(pytest-pdb-break-test-with-tmpdir
    (should-not pytest-pdb-break--home)
    (should (string= (pytest-pdb-break--homer)
                     pytest-pdb-break-test-repo-root))
    (should (directory-name-p pytest-pdb-break--home)) ; ends in /
    (should (string= pytest-pdb-break--home
                     pytest-pdb-break-test-repo-root))))

;; TODO link ffip
(ert-deftest pytest-pdb-break-test-homer ()
  (ert-info ("Find cloned repo containing pytest plugin")
    (should-not (fboundp 'ffip-project-root))
    (pytest-pdb-break-test-homer-fixture)))

(defmacro pytest-pdb-break-test-homer-setup-fixture (subform dir-body info-msg)
  "Run SUBFORM as this test in an Emacs subprocess.
DIR-BODY sets up build dir. Spit INFO-MSG."
  `(let* ((test-sym (ert-test-name (ert-running-test)))
          (env-var (pytest-pdb-break-test--name-to-envvar test-sym)))
     (if (getenv env-var)
         ,subform
       (pytest-pdb-break-test-with-tmpdir
        "-setup"
        (let* ((dir (pytest-pdb-break-test-with-tmpdir
                     "-setup/build"
                     ,dir-body
                     (byte-compile-file "./pytest-pdb-break.el")
                     default-directory))
               (file (pytest-pdb-break-test-with-tmpdir
                      "-setup/script"
                      (copy-file pytest-pdb-break-test-lisp-this "./")
                      (file-truename "./pytest-pdb-break-test.el")))
               (logfile (file-truename "test.out"))
               (script `(ert-run-tests-batch-and-exit ',test-sym))
               (args (list "-Q" "--batch" "-L" dir "-l" file
                           "--eval" (format "%S" script)))
               (process-environment (append process-environment nil))
               ec)
          (ert-info (,info-msg)
            (setenv env-var "1")
            (setq ec (apply #'call-process "emacs" nil
                            (list :file logfile) nil args))
            (should (zerop ec))))))))

(ert-deftest pytest-pdb-break-test-homer-symlink ()
  (pytest-pdb-break-test-homer-setup-fixture
   ;; subform
   (progn
     (should-not (fboundp 'ffip-project-root))
     (should (file-symlink-p (find-library-name "pytest-pdb-break")))
     (pytest-pdb-break-test-homer-fixture))
   ;; dir-body
   (make-symbolic-link pytest-pdb-break-test-lisp-main "./")
   ;; info-msg
   "Find home, resolving symlinks"))

(ert-deftest pytest-pdb-break-test-homer-missing ()
  (pytest-pdb-break-test-homer-setup-fixture
   ;; subform
   (let ((exc (should-error (pytest-pdb-break-test-homer-fixture)))
         (case-fold-search t))
     (should (string-match-p "cannot find.*home" (cadr exc)))
     (should-not pytest-pdb-break--home))
   ;; dir-body
   (copy-file pytest-pdb-break-test-lisp-main "./")
   ;; info-msg
   "No cloned repo (pytest plugin) found"))

(defvar pytest-pdb-break-test--requirements
  `((bare)
    (base "pytest")
    (pdbpp "pytest" "pdbpp")
    (self ,pytest-pdb-break-test-repo-root)
    (self_pdbpp "pdbpp" ,pytest-pdb-break-test-repo-root)))

(defun pytest-pdb-break-test--get-venv-path (name)
  (cl-assert (symbolp name))
  (cl-assert (assq name pytest-pdb-break-test--requirements))
  (concat pytest-pdb-break-test-temp
          (format ".venv_%s" (symbol-name name)) "/"))

(defun pytest-pdb-break-test--get-requirements (name)
  (cl-assert (symbolp name))
  (cdr (assq name pytest-pdb-break-test--requirements)))

(defmacro pytest-pdb-break-test-ensure-venv (name &rest body)
  "Run BODY in a temp directory with a modified environment.
NAME is a venv from --get-requirements Does not modify `PATH' or
`VIRTUAL_ENV' or `python-shell-interpreter'. Binds `$pyexe', `$venvbin',
and `$venv'. Doesn't use pip3 or python3 because venvs are all
created with python3."
  `(pytest-pdb-break-test-with-tmpdir
    (pytest-pdb-break-test-with-environment
     (let* (($venv (pytest-pdb-break-test--get-venv-path ,name))
            ($venvbin (concat $venv "bin/"))
            ($pyexe (concat $venvbin "python"))
            pipexe logfile requirements)
       (unless (file-exists-p $venv) ; trailing/ ok
         (setq pipexe (concat $venvbin "pip")
               logfile (concat default-directory "pip.out")
               requirements (pytest-pdb-break-test--get-requirements ,name))
         (should (file-name-absolute-p logfile))
         (should (zerop (call-process "python3" nil (list :file logfile) nil
                                      "-mvenv" $venv)))
         (should (file-executable-p pipexe))
         (should (file-executable-p $pyexe))
         (should-not (equal (executable-find "pip") pipexe))
         (should-not (equal (executable-find "python") $pyexe))
         (unless (eq ,name 'bare)
           (should (zerop (apply #'call-process pipexe nil
                                 (list :file logfile) nil
                                 "install" requirements)))))
       ,@body))))

(defmacro pytest-pdb-break-test--query-wrap (&rest body)
  `(let (($rootdir (directory-file-name default-directory))
         ($rv (gensym)))
     (cl-flet (($callit () (setq $rv (pytest-pdb-break--query-config))))
       ,@body)
     (should (json-plist-p $rv))
     (should (= 4 (length $rv)))
     (should (string= $rootdir (plist-get $rv :rootdir)))))

(ert-deftest pytest-pdb-break-test-query-helper-unregistered ()
  (pytest-pdb-break-test-ensure-venv
   'base
   (with-temp-buffer
     (insert "[pytest]\n")
     (write-file "setup.cfg"))
   (let ((python-shell-interpreter $pyexe))
     (ert-info ("Explicit py-shell-int, unreg, curdir")
       (pytest-pdb-break-test--query-wrap
        ($callit)
        (should-not (plist-get $rv :registered))))
     (ert-info ("Explicit py-shell-int, unreg, subdir")
       (pytest-pdb-break-test--query-wrap
        (pytest-pdb-break-test-with-tmpdir
         "/tests"
         (should-not (string= $rootdir default-directory))
         (with-temp-buffer
           (insert "def test_foo():" "\n\t" "assert True")
           (write-file "test_subdir.py"))
         ($callit))
        (should-not (plist-get $rv :registered)))))
   (ert-info ("PATH, exec-path, unreg, curdir, no explicit py-shell-int")
     (pytest-pdb-break-test--query-wrap
      (pytest-pdb-break-test-with-environment
       (setenv "PATH" (format "%s:%s" $venvbin (getenv "PATH")))
       (setq exec-path (cons $venvbin exec-path))
       (should (string= (executable-find python-shell-interpreter) $pyexe))
       ($callit)
       (should-not (plist-get $rv :registered)))))))

(ert-deftest pytest-pdb-break-test-query-helper-registered ()
  (pytest-pdb-break-test-ensure-venv
   'self
   (let ((python-shell-interpreter $pyexe))
     (ert-info ("Explicit py-shell-int, curdir")
       (pytest-pdb-break-test--query-wrap
        ($callit)
        (should (plist-get $rv :registered)))))))

(ert-deftest pytest-pdb-break-test-query-helper-error ()
  (pytest-pdb-break-test-ensure-venv
   'bare
   (let ((python-shell-interpreter $pyexe))
     ;; The error is raised by --query-config
     (ert-info ("No packages")
       (let ((exc (should-error (pytest-pdb-break--query-config))))
         (should (string-match-p "Error calling" (cadr exc)))
         (should (string-match-p "No module named '_pytest'" (cadr exc)))
         (with-temp-buffer
           (insert (cadr exc))
           (write-file "error.out")))))))

(ert-deftest pytest-pdb-break-test-get-config-info-error ()
  (cl-macrolet
      ((fails
        (setup logfile)
        `(pytest-pdb-break-test-with-python-buffer
          ,setup
          (should (cl-notany python-shell-extra-pythonpaths
                             python-shell-exec-path
                             python-shell-virtualenv-root
                             ;; ours
                             pytest-pdb-break--config-info))
          (let ((exc (should-error (pytest-pdb-break-get-config-info))))
            (should (eq 'error (car exc)))
            (should (string-match-p "Error calling" (cadr exc)))
            (with-temp-buffer (insert (cadr exc)) (write-file ,logfile)))
          (should-not pytest-pdb-break-config-info-alist)
          (should-not pytest-pdb-break--config-info))))
    (pytest-pdb-break-test-ensure-venv
     'base
     (ert-info ("System Python has no pytest")
       (fails (progn (should-not python-shell-process-environment)
                     (should-not pytest-pdb-break-config-info-alist))
              "error_no_pytest.out"))
     (ert-info ("Manually set VIRTUAL_ENV")
       (fails (progn (should-not python-shell-process-environment)
                     (should-not pytest-pdb-break-config-info-alist)
                     (setenv "VIRTUAL_ENV" $venv))
              "error_virtual_env_manual.out"))
     (ert-info ("Set extra env vars to override")
       (let ((python-shell-process-environment
              (list (format "PATH=%s:%s" $venvbin (getenv "PATH"))
                    (format "VIRTUAL_ENV=%s" $venvbin))))
         (fails (should python-shell-process-environment)
                "error_proc_env_api.out")))
     (ert-info ("Invalid cdr for alist entry")
       (let ((pytest-pdb-break-config-info-alist
              (list (list (executable-find python-shell-interpreter)))))
         (fails (progn
                  (should-not python-shell-process-environment)
                  (should pytest-pdb-break-config-info-alist))
                "error_invalid_cdr.out"))))))

(ert-deftest pytest-pdb-break-test-get-config-info-unregistered ()
  (cl-macrolet
      ((rinse-repeat
        (before after)
        `(pytest-pdb-break-test-with-python-buffer
          (should-not pytest-pdb-break--config-info)
          ,before
          (let ((rv (pytest-pdb-break-get-config-info)))
            (should (= 6 (length pytest-pdb-break--config-info)))
            (should (eq (cdr rv) pytest-pdb-break--config-info))
            (should (eq (car rv)
                        (plist-get pytest-pdb-break--config-info :exe)))
            (should (eq (assoc (car rv) pytest-pdb-break-config-info-alist)
                        rv)))
          ,after)))
    (pytest-pdb-break-test-ensure-venv
     'base
     (ert-info ("Set virtual environment root")
       ;; See upstream test above re -= slash
       (let ((python-shell-virtualenv-root $venv)
             (unslashed (directory-file-name $venvbin)))
         (rinse-repeat
          (should-not (member unslashed exec-path))
          (should-not (member unslashed exec-path)))))
     (ert-info ("Set extra `exec-path' items to prepend")
       (let ((python-shell-exec-path (list $venvbin)))
         (rinse-repeat
          (should-not (member $venvbin exec-path))
          (should-not (member $venvbin exec-path))))))))


(provide 'pytest-pdb-break-test)
;;; pytest-pdb-break-test ends here

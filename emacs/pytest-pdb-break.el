;;; pytest-pdb-break.el ---- integration demo -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "26"))

;;; Commentary:

;; Installation: no MELPA, but `straight.el' users can use this recipe:
;;
;;   '(:host github :repo "poppyschmo/pytest-pdb-break"
;;     :files (:defaults "emacs/*.el"))
;;
;; Usage: `pytest-pdb-break-here'
;;
;; Note: the completion modifications are useless without pdb++. No idea if
;; they hold up when summoned by `company-capf'.
;;
;; TODO: ert

;;; Code:

(require 'find-func)
(require 'subr-x)
(require 'python)

(defvar-local pytest-pdb-break-extra-args nil
  "List of extra args passed to pytest.
May be useful in a `dir-locals-file'. For example, this `python-mode'
entry unsets cmd-line options from a project ini:
\(pytest-pdb-break-extra-args \"-o\" \"addopts=\").")

(defvar-local pytest-pdb-break-interpreter nil
  "If nil, use `python-shell-interpreter'.")

(defvar-local pytest-pdb-break-has-plugin-alist nil
  "An alist resembling ((VIRTUAL_ENV . STATE) ...).
This is set by the main command the first time it's run in a Python
buffer. STATE is non-nil if the interpreter sees the pytest plugin. When
no virtual environment is present, the car should be nil and treated as
a valid key. ")

(defvar pytest-pdb-break-after-functions nil
  "Abnormal hook for adding a process sentinel, etc.
Sole arg is the pytest buffer process PROC, which may be nil upon
failure. Hook is run with process buffer current.")

(defvar pytest-pdb-break--dry-run nil)

(defvar pytest-pdb-break-processes nil
  "List of processes started via `pytest-pdb-break-here'.")

;; FIXME only add this wrapper when pdb++ is detected. These amputee
;; candidates most likely come courtesy of the fancycompleter package.
(defun pytest-pdb-break-ad-around-get-completions (orig process import input)
  "Advice wrapper for ORIG `python-shell-completion-get-completions'.
If PROCESS is ours, prepend INPUT to results. With IMPORT, ignore."
  (let ((rv (funcall orig process import input)))
    (if (or import
            (not (memq process pytest-pdb-break-processes))
            (null rv)
            (string= input "")
            (not (memq ?. (append input nil)))) ; not dotty
        rv
      (when (not (cdr rv)) ; |rv| = 1
        (if (string-match-p "\\.__$" (car rv))
            (setq rv (funcall orig process import (car rv)))
          (setq input "")))
      (when (string-match "^\\(.+\\.\\)[^.]+$" input)
        (setq input (match-string 1 input)))
      (mapcar (apply-partially #'concat input) rv))))

(defun pytest-pdb-break--get-node-id ()
  "Return list of node-id components for test at point."
  (let (file test parts)
    (if (fboundp 'elpy-test-at-point)
        (let ((four (elpy-test-at-point)))
          (setq file (nth 1 four)
                test (nth 3 four)))
      (setq file buffer-file-name
            test (python-info-current-defun)))
    (unless (and test (string-match "[Tt]est" test))
      (error "No test found"))
    (setq parts (split-string test "\\."))
    (when (caddr parts)
      (setq parts (list (pop parts) (pop parts))))
    (cons file parts)))

;; TODO verify this is needed even though we're explicitly naming a node id
;; TODO use root finders from tox, projectile, ggtags, magit, etc.
(defun pytest-pdb--get-default-dir ()
  "Maybe return project root, otherwise `default-directory'."
  (or (and (bound-and-true-p elpy-shell-use-project-root)
           (fboundp 'elpy-project-root)
           (elpy-project-root))
      default-directory))

(defun pytest-pdb-break-buffer-teardown (proc)
  "Cleanup a pytest-pdb-break comint buffer.
PROC is the buffer's current process."
  (setq pytest-pdb-break-processes
        (seq-filter #'process-live-p
                    (remq proc pytest-pdb-break-processes)))
  (unless pytest-pdb-break-processes
    (advice-remove 'python-shell-completion-get-completions
                   'pytest-pdb-break-ad-around-get-completions)))

(defun pytest-pdb-break-buffer-setup (proc)
  "Setup a pytest-pdb-break comint buffer.
PROC is the buffer's current process."
  (add-to-list 'pytest-pdb-break-processes proc)
  (advice-add 'python-shell-completion-get-completions :around
              #'pytest-pdb-break-ad-around-get-completions)
  (with-current-buffer (process-buffer proc)
    (setq-local python-shell-completion-native-enable nil)
    (add-hook 'kill-buffer-hook (apply-partially
                                 #'pytest-pdb-break-buffer-teardown
                                 proc)
              nil t)
    (run-hook-with-args 'pytest-pdb-break-after-functions proc)))

(defun pytest-pdb-break--check-command-p (command)
  "Run COMMAND in Python, return t if exit code is 0, nil otherwise."
  (= 0 (call-process python-shell-interpreter nil nil nil "-c" command)))

(defun pytest-pdb-break--getenv (var)
  "Look up VAR in `process-environment', return nil if unset or empty."
  (and (setq var (getenv var)) (not (string= var "")) var))

(defun pytest-pdb-break-has-plugin-p (&optional force)
  "Return non-nil if plugin is loadable.
With FORCE, always check."
  (let* ((venv (pytest-pdb-break--getenv "VIRTUAL_ENV"))
         (entry (assoc venv pytest-pdb-break-has-plugin-alist)))
    (if (and (not force) entry)
        (cdr entry)
      (unless entry
        (push (setq entry (list venv)) pytest-pdb-break-has-plugin-alist))
      (setcdr entry
              (pytest-pdb-break--check-command-p "import pytest-pdb-break")))))

(defun pytest-pdb-break--find-own-repo ()
  "Return root of plugin repo or nil."
  (let ((drefd (file-truename (find-library-name "pytest-pdb-break")))
        root)
    (if (fboundp 'ffip-project-root)
        (setq root (let ((default-directory drefd)) (ffip-project-root)))
      (setq root (file-name-directory drefd)
            root (and root (directory-file-name root))
            root (and root (file-name-directory root))))
    (when (and root (directory-files root 'full "pytest_pdb_break\\.py$"))
      (file-truename root))))

(defun pytest-pdb-break-add-pythonpath ()
  "Add plugin root to a copy of `process-environment'.
Return the latter."
  (let* ((process-environment (append process-environment nil))
         (existing (pytest-pdb-break--getenv "PYTHONPATH"))
         (existing (and existing (parse-colon-path existing)))
         (found (pytest-pdb-break--find-own-repo)))
    (when found
      (setenv "PYTHONPATH" (string-join (cons found existing) ":")))
    process-environment))

;;;###autoload
(defun pytest-pdb-break-here (lnum node-info root-dir)
  "Drop into pdb after spawning an inferior pytest process, go to LNUM.
NODE-INFO is a list of pytest node-id components. ROOT-DIR is the
project/repo's root directory."
  (interactive (list (line-number-at-pos)
                     (pytest-pdb-break--get-node-id)
                     (pytest-pdb--get-default-dir)))
  (let* ((default-directory root-dir)
         (file (car node-info))
         (argstr (mapconcat #'identity node-info "::"))
         (break (format "--break=%s:%s" file lnum))
         (installed (pytest-pdb-break-has-plugin-p))
         (xtra pytest-pdb-break-extra-args)
         (xtra (if (or installed (member "pytest_pdb_break" xtra))
                   xtra (append '("-p" "pytest_pdb_break") xtra)))
         (args (append (cons "-mpytest" xtra) (list break argstr)))
         (process-environment (if installed process-environment
                                (pytest-pdb-break-add-pythonpath)))
         ;; Make pdb++ prompt trigger non-native-completion fallback
         (python-shell-prompt-pdb-regexp "[(<]*[Ii]?[Pp]db[+>)]+ ")
         (python-shell-interpreter (or pytest-pdb-break-interpreter
                                       python-shell-interpreter))
         (python-shell-interpreter-args (apply #'mapconcat
                                               (list #'identity args " ")))
         (cmd (python-shell-calculate-command))
         (proc (and (not pytest-pdb-break--dry-run) (run-python cmd nil t))))
    (if proc
        (pytest-pdb-break-buffer-setup proc)
      (message "Would've run: %S\nfrom: %S" cmd default-directory))))


(provide 'pytest-pdb-break)

;; Local Variables:
;; flycheck-disabled-checkers: nil
;; End:

;;; pytest-pdb-break ends here
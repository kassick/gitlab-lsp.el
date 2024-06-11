;;; gitlab-lsp.el --- lsp-mode client  gitlab-lsp  -*- lexical-binding: t -*-

;; Copyright (C) 2024 Rodrigo Virote Kassick

;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; Author: Rodrigo Virote Kassick <kassick@gmail.com>
;; Version: 0.1
;; Package-Requires: (lsp-mode secrets s compile dash cl-lib request)
;; Keywords: lsp-mode, generative-ai, code-assistant
;; URL: https://github.com/kassick/gitlab-lsp.el

;; Commentary:

;; LSP client for gitlab-lsp -- https://gitlab.com/gitlab-org/editor-extensions/gitlab-lsp

;; Code:

(require 'lsp-mode)
(require 'cl-lib)
(require 'secrets)
(require 's)
(require 'compile)
(require 'dash)
(require 'request)

(cl-defun lsp--npm-custom-registry-dependency-install (callback error-callback &key package registry-name registry-url &allow-other-keys)
  "Same as lsp--npm-dependency-install, but accepts a `:registry-url' keyword to use as private registry when installing."
  (if-let ((npm-binary (executable-find "npm")))
      (let* ((registry-name (or registry-name "custom-registry"))
             (process-environment (append (list (format "npm_config_@%s:registry=%s" registry-name registry-url))
                                          process-environment))
             (package-with-registry (format "@%s/%s" registry-name package))
             (package-install-prefix (f-join lsp-server-install-dir "npm" package)))
        ;; Explicitly `make-directory' to work around NPM bug in
        ;; versions 7.0.0 through 7.4.1. See
        ;; https://github.com/emacs-lsp/lsp-mode/issues/2364 for
        ;; discussion.
        (make-directory (f-join package-install-prefix "lib") 'parents)
        (lsp-async-start-process (lambda ()
                                   (if (string-empty-p
                                        (string-trim (shell-command-to-string
                                                      (mapconcat #'shell-quote-argument (list npm-binary "view" package-with-registry "peerDependencies") " "))))
                                       (funcall callback)
                                     (let ((default-directory (f-dirname (car (last (directory-files-recursively package-install-prefix "package.json")))))
                                           (process-environment (append '("npm_config_yes=true") process-environment))) ;; Disable prompting for older versions of npx
                                       (when (f-dir-p default-directory)
                                         (lsp-async-start-process callback
                                                                  error-callback
                                                                  (executable-find "npx")
                                                                  "npm-install-peers")))))
                                 error-callback
                                 npm-binary
                                 "-g"
                                 "--prefix"
                                 package-install-prefix
                                 "install"
                                 package-with-registry
                                 ))
    (lsp-log "Unable to install %s via `npm' from %s because it is not present" package registry-url)
    nil))

(plist-put lsp-deps-providers
           :npm-with-registry
           (list :path #'lsp--npm-dependency-path
                 :install #'lsp--npm-custom-registry-dependency-install))


(lsp-dependency 'gitlab-lsp
                '(:system "gitlab-lsp")
                '(:npm-with-registry :package "gitlab-lsp"
                                     :registry-name "gitlab-org"
                                     :registry-url "https://gitlab.com/api/v4/packages/npm/"
                                     :path "gitlab-lsp"))

(lsp-register-custom-settings
 '(
   ;; TODO: add these as custom variables
   ("gitlab-lsp.logLevel" "debug")
   ("gitlab-lsp.telemetry.enabled" json-false)
   ))

(defgroup gitlab-lsp ()
  "Gitlab-lsp configuration"
  ;; :group 'lsp-mode
  :tag "Gitlab LSP"
  :link '(url-link "https://gitlab.com/gitlab-org/editor-extensions/gitlab-lsp"))

(defcustom gitlab-lsp-major-modes '(python-mode python-ts-mode)
  "The major modes for which gitlab-lsp should be used"
  :type '(repeat symbol)
  :group 'gitlab-lsp)

(defun gitlab-lsp--client-active-for-mode-p (fname mode)
  (and gitlab-lsp-enabled (member mode gitlab-lsp-major-modes)))

(defun gitlab-lsp--set-enabled-value (symbol value)
  (when (not (equal (symbol-value symbol) value))
    (set symbol value)
    (if value
        ;; Restart lsp on all relevant buffers
        (cl-loop for buf in (buffer-list) do
                 (with-current-buffer buf
                   (when (and
                          ;; Ignore internal buffers
                          (not (string-prefix-p " " (buffer-name)))

                          ;; Only buffer vising files
                          (buffer-file-name)

                          ;; only for the modes where we should activate gitlab-lsp for
                          (gitlab-lsp--client-active-for-mode-p (buffer-file-name)
                                                                major-mode)

                          ;; only if the client isn't already running
                          (--none? (lsp-find-workspace it (buffer-file-name)) '(gitab-lsp gitlab-lsp-remote)))
                     (lsp--warn "Starting gitlab-lsp LSP for mode %S on %s" major-mode (lsp-workspace-root))
                     (lsp))))

      ;; Globally stop all LSP servers
      (-when-let* ((session (lsp-session))
                   (gitlab-lsp-workspaces (--filter
                                           (member (lsp--client-server-id (lsp--workspace-client it))
                                                   '(gitlab-lsp gitlab-lsp-remote))
                                           (lsp--session-workspaces session))))

        (cl-loop for workspace in gitlab-lsp-workspaces do
                 (lsp--warn "Stopping gitlab-lsp for %s per user request" (lsp--workspace-print workspace))
                 (with-lsp-workspace workspace (lsp-workspace-restart workspace)))))))

(defcustom gitlab-lsp-enabled t
  "Weather the server should be started to provide completions"
  :type 'boolean
  :group 'gitlab-lsp
  :set #'gitlab-lsp--set-enabled-value
  )


(defcustom gitlab-lsp-langserver-command-args '("--stdio")
  "Command to start gitlab-langserver."
  :type '(repeat string)
  :group 'gitlab-lsp)

(defcustom gitlab-lsp-server-url nil
  "The gitlab server instance used by gitlab-lsp"
  :type '(choice (const :tag "Undefined" nil) string)
  :group 'gitlab-lsp)

(defcustom gitlab-lsp-token nil
  "The token (personal-access-token or OAUTH) used when contacting
the gitlab instance defined in gitlab-lsp-server-url."
  :type '(choice (const :tag "Undefined" nil) string)
  :group 'gitlab-lsp)

(defcustom gitlab-lsp-executable "gitlab-lsp"
  "The system-wise executable of gitlab-lsp.
When this executable is not found, you can stil use
lsp-install-server to fetch an emacs-local version of the LSP."
  :type 'string
  :group 'gitlab-lsp)

(defconst gitlab-lsp-secrets-item-key "emacs/gitlab-lsp/global")

;; TODO: fix weidness
;; If I let the url be empty/null, then interactively will always prompt
;; because the variable will have null baseurl and interactivelly will see that the
;; setup is not complete ...

(defun gitlab-lsp--locate-config-with-env ()
  (cons (getenv "GITLAB_LSP_BASE_URL") (getenv "GITLAB_LSP_TOKEN")))

(cl-defun gitlab-lsp--locate-config-with-variables (&key &allow-other-keys)
  (cons gitlab-lsp-server-url gitlab-lsp-token))


(cl-defun gitlab-lsp--locate-config-with-secrets (&key &allow-other-keys)
  (-when-let (sattr (secrets-get-attributes "login" gitlab-lsp-secrets-item-key))
    (let ((baseUrl (alist-get :baseUrl sattr))
          (token (secrets-get-secret "login" gitlab-lsp-secrets-item-key)))
      (cons baseUrl token))))

(defun gitlab-lsp--validate-token (baseUrl token)
  "The token must have the API scope"
  (let* ((response (request (concat baseUrl "/api/v4/personal_access_tokens/self")
                     :headers `(("Authorization" . ,(concat "Bearer " token)))
                     :sync t
                     :parser 'json-read))
         (response-data (request-response-data response)))

    (cond
     ((/= 200 (request-response-status-code response))
      `(nil . ,(alist-get 'message response-data)))

     ((not (seq-contains (alist-get 'scopes response-data) "api"))
      '(nil . "token does not contain the api scope"))

     (t '(t nil)))))

(cl-defun gitlab-lsp--locate-config-interactively (&key force-store &allow-other-keys)
  (let ((baseUrl (string-trim (read-string "Gitlab Base URL (empty for default): ")))
        (token (read-passwd "Token (PAT or OAUTH): "))
        (store-values (or force-store (yes-or-no-p "Remember secret?"))))

    (-let* ((url (if (length= baseUrl 0)
                     "https://gitlab.com"
                   baseUrl))
            ((valid . err) (gitlab-lsp--validate-token url token)))
      (unless valid
        (error (format "Invalid Token: %s" err))))

    (when store-values
      ;; item key does not need to be unique, but we want a single entry here
      (when (secrets-get-attributes "login" gitlab-lsp-secrets-item-key)
        (secrets-delete-item "login" gitlab-lsp-secrets-item-key))

      (secrets-create-item "login" gitlab-lsp-secrets-item-key token :baseUrl baseUrl))

    (cons baseUrl token)))


(defcustom gitlab-lsp-locate-token-fn-list
  '(gitlab-lsp--locate-config-with-env
    gitlab-lsp--locate-config-with-variables
    gitlab-lsp--locate-config-with-secrets
    gitlab-lsp--locate-config-interactively)
  "List of functions used to locate values for the server baseUrl and Token"
  :type '(repeat function)
  :group 'gitlab-lsp)

(defun gitlab-lsp-locate-config ()
  "Returns (baseUrl . token) using the functions in gitlab-lsp-locate-token-fn-list.

When any of the functions returns a non-nil baseUrl, this value
will be used. Ditto for token. When both values are non nil, the
function returns.

This means that you can the token `xpto' for url
`https://internal.server/' stored in secrets, but if you setenv
GITLAB_LSP_BASE_URL for emacs, it will ignore the value obtained
via secrets, as long as gitlab-lsp--locate-config-with-env
appears before gitlab-lsp--locate-config-with-secrets.
"
  (let (baseUrl token)
    (catch 'break
      (dolist (fn gitlab-lsp-locate-token-fn-list)
        (-let (((url . tk) (apply fn '())))

          (when (and (not baseUrl) url)
            (setq baseUrl url))

          (when (and (not token ) tk)
            (setq token tk))

          (when (and baseUrl token)
            (throw 'break nil)))))

    (cons baseUrl token)))

(defun gitlab-lsp-token-check-callback (workspace result &rest args)
  (let ((message (ht-get result "message")))
    (display-warning 'gitlab-lsp message :error)
    (lsp--error message)))

(defun kzk/around-lsp--start-workspace (fn &rest args)
  "Ensure we do not use the build time in the client id"

  ;; Gitlab LSP will use the client id as part of the headers -- and headers can not contain newlines and stuff
  (let ((emacs-build-time nil))
    (apply fn args)))

(advice-add 'lsp--start-workspace :around #'kzk/around-lsp--start-workspace)


(defun gitlab-lsp--server-initialization-options ()
  (list :settings (list :logLevel "info"
                        :version "0.1.0"
                        :clientType "emacs"
                        :clientVersion (symbol-value 'emacs-version))))

(defun gitlab-lsp--server-initialized-fn (workspace)
  (-let* (
          ;; in emacs, the configuration is stored under `gitlab-lsp.key' but
          ;; gitlab-lsp does not handle the prefix, so we must drop the
          ;; prefix...
          (config-ht (ht-get (lsp-configuration-section "gitlab-lsp")
                             "gitlab-lsp"))
          ((baseUrl . token) (gitlab-lsp-locate-config)))

    ;; Empty string -- let the server use whatever default it wants
    (when (length> (string-trim (or baseUrl "")) 0)
      (ht-set config-ht "baseUrl" baseUrl))

    (when token
      (ht-set config-ht "token" token))

    (with-lsp-workspace workspace
      (lsp--set-configuration config-ht))))

;; Server installed by emacs
(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection (lambda ()
                                          (cons
                                           (lsp-package-path 'gitlab-lsp)
                                           gitlab-lsp-langserver-command-args)))
  :activation-fn #'gitlab-lsp--client-active-for-mode-p
  :server-id 'gitlab-lsp
  :multi-root nil
  :priority -2
  :add-on? t
  :completion-in-comments? t
  :initialization-options #'gitlab-lsp--server-initialization-options
  :initialized-fn #'gitlab-lsp--server-initialized-fn
  :download-server-fn (lambda (_client callback error-callback _update?)
                        (lsp-package-ensure 'gitlab-lsp callback error-callback))
  :notification-handlers (lsp-ht ("$/gitlab/token/check" 'gitlab-lsp-token-check-callback))
  :action-handlers (lsp-ht
                    ;; This results in a key error, so let's just ignore it ...
                    ("gitlab.ls.codeSuggestionAccepted" #'ignore))))

;; Server found in PATH
(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection (lambda ()
                                          (cons
                                           (executable-find gitlab-lsp-executable)
                                           gitlab-lsp-langserver-command-args)))
  :activation-fn #'gitlab-lsp--client-active-for-mode-p
  :server-id 'gitlab-lsp-remote
  :multi-root nil
  :priority -2
  :add-on? t
  :completion-in-comments? t
  :initialization-options #'gitlab-lsp--server-initialization-options
  :initialized-fn #'gitlab-lsp--server-initialized-fn
  :download-server-fn (lambda (_client callback error-callback _update?)
                        (lsp-package-ensure 'gitlab-lsp callback error-callback))
  :notification-handlers (lsp-ht ("$/gitlab/token/check" 'gitlab-lsp-token-check-callback))
  :action-handlers (lsp-ht
                    ;; This results in a key error, so let's just ignore it ...
                    ("gitlab.ls.codeSuggestionAccepted" #'ignore))))


;;;###autoload
(defun gitlab-lsp-setup ()
  "Configures the access token for gitlab-lsp"
  (interactive)

  (gitlab-lsp--locate-config-interactively :force-store t)

  nil)

;;;###autoload
(defun gitlab-lsp-complete ()
  "Completes with gitlab-lsp"
  (interactive)

  (let ((workspace (--some (lsp-find-workspace it (buffer-file-name))
                           '(gitlab-lsp gitlab-lsp-remote)))
        (company--capf-cache nil)
        (lsp-completion-no-cache t))
    (if workspace
        (with-lsp-workspace workspace
          (company-manual-begin))
      (message "No gitlab-lsp active for this workspace"))))

;;;###autoload
(defun gitlab-lsp-enable ()
  "Enables gitlab-lsp"
  (interactive)
  (setopt gitlab-lsp-enabled t)
  (message "Server Enabled"))

;;;###autoload
(defun gitlab-lsp-disable ()
  "Disables gitlab-lsp"
  (interactive)
  (setopt gitlab-lsp-enabled nil)
  (message "Server Disabled"))

;;;###autoload
(defun gitlab-lsp-toggle ()
  "Tottle whether gitlab-lsp is enabled"
  (interactive)

  (if gitlab-lsp-enabled
      (gitlab-lsp-disable)
    (gitlab-lsp-enable)))


(provide 'gitlab-lsp)

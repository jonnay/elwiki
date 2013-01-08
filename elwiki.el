;;; elwiki.el --- An Elnode-powered wiki engine.  -*- lexical-binding: t -*-

;; Copyright (C) 2012  Nic Ferrier, Aidan Gauland

;; Author: Nic Ferrier <nferrier@ferrier.me.uk>
;; Maintainer: Aidan Gauland <aidalgol@no8wireless.co.nz>
;; Created: 5th October 2010
;; Keywords: lisp, http, hypermedia

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This is a Wiki Engine completely written in EmacsLisp, using Elnode
;; as a server.
;;
;;; Source code
;;
;; elnode's code can be found here:
;;   http://github.com/nicferrier/elnode

;;; Style note
;;
;; This codes uses the Emacs style of:
;;
;;    elwiki--private-function
;;
;; for private functions.


;;; Code:

(elnode-app elwiki-dir
    creole esxml)

(defgroup elwiki nil
  "A Wiki server written with Elnode."
  :group 'elnode)

;;;###autoload
(defcustom elwiki-wikiroot
  elwiki-dir
  "The root for the Elnode wiki files.

This is where elwiki serves wiki files from.  You
should change this."
  :type '(directory)
  :group 'elwiki)

(defun elwiki-page (httpcon wikipage &optional pageinfo)
  "Creole render a WIKIPAGE back to the HTTPCON."
  (elnode-http-start httpcon 200 `("Content-type" . "text/html"))
  (with-stdout-to-elnode httpcon
    (creole-wiki
     wikipage
     :destination t
     :variables (list (cons 'page (or pageinfo
                                      (elnode-http-pathinfo httpcon)))))))

(defun elwiki-edit-page (httpcon wikipage &optional pageinfo preview)
  "Return an editor for WIKIPAGE via HTTPCON."
  (elnode-http-start httpcon 200 `("Content-type" . "text/html"))
  (with-stdout-to-elnode httpcon
    (let* ((page-info (or pageinfo (elnode-http-pathinfo httpcon)))
           (comment (elnode-http-param httpcon "comment"))
           (username (elnode-http-param httpcon "username"))
           (editor
            (esxml-to-xml
             `(form
               ((action . ,page-info)
                (method . "POST"))
               (fieldset ()
                         (legend () ,(format "Edit %s" (file-name-nondirectory page-info)))
                         (textarea ((cols . "80")
                                    (rows . "20")
                                    (name . "wikitext"))
                                   ,(with-temp-buffer
                                      (insert-file-contents wikipage)
                                      (buffer-string)))
                         (br ())
                         (label () "Edit comment:"
                                (input ((type . "text")
                                        (name . "comment")
                                        (value . ,(or comment "")))))
                         (br ())
                         (label () "Username:"
                                (input ((type . "text")
                                        (name . "username")
                                        (value . ,(or username "")))))
                         (br ())
                         (input ((type . "submit")
                                 (name . "save")
                                 (value . "save")))
                         (input ((type . "submit")
                                 (name . "preview")
                                 (value . "preview")
                                 (formaction . ,(format "%s?action=edit" page-info)))))))))
      (if preview
          (creole-wiki
           wikipage
           :destination t
           :variables (list (cons 'page (or pageinfo
                                            (elnode-http-pathinfo httpcon))))
           :body-footer (concat "<div id=editor>" editor "</div>"))
        (princ editor)))))

(defun elwiki--text-param (httpcon)
  "Get the text parameter from HTTPCON and convert the line endings."
  (replace-regexp-in-string
   "\r" "" ; browsers send text in DOS line ending format
   (elnode-http-param httpcon "wikitext")))

(defun elwiki--save-request (httpcon wikiroot path text)
  "Process a page-save request."
  (let* ((page-name (save-match-data
                      (string-match "/wiki/\\(.*\\)$" path)
                      (match-string 1 path)))
         (comment (elnode-http-param httpcon "comment"))
         (username (elnode-http-param httpcon "username"))
         (file-name (expand-file-name (concat (file-name-as-directory wikiroot)
                                              path ".creole")))
         (buffer (find-file-noselect file-name)))
    (elnode-error "Saving page %s, edited by %s" page-name username)
    (with-current-buffer buffer
      (erase-buffer)
      (insert text)
      (save-buffer)
      (let ((git-buf
             (get-buffer-create
              (generate-new-buffer-name
               "* elnode wiki commit buf *"))))
        (shell-command
         (format "git commit -m 'username:%s\n%s' %s" username comment file-name)
         git-buf)
        (kill-buffer git-buf))
      (elnode-send-redirect httpcon path))))

(defun elwiki--router (httpcon)
  "Dispatch to a handler depending on the URL.

So, for example, a handler for wiki pages, a separate handler for
images, and so on."
  (let ((webserver (elnode-webserver-handler-maker
                    (concat elwiki-dir "/static/"))))
    (elnode-hostpath-dispatcher httpcon
     `(("^[^/]*//wiki/\\(.*\\)" . elwiki--handler)
       ("^[^/]*//static/\\(.*\\)$" . ,webserver)))))

(defun elwiki--handler (httpcon)
  "A low level handler for wiki operations.

Send the wiki page requested, which must be a file existing under
ELWIKI-WIKIROOT, back to the HTTPCON.  The extension \".creole\"
is appended to the page name requested, so the request should not
include the extension.

Update operations are NOT protected by authentication.  Soft
security is used."
  (let ((targetfile (elnode-http-mapping httpcon 1))
        (action (intern (or (elnode-http-param httpcon "action")
                            "none"))))
   (flet ((elnode-http-mapping (httpcon which)
            (concat targetfile ".creole")))
     (elnode-method httpcon
       (GET
        (elnode-docroot-for (concat elwiki-wikiroot "/wiki/")
          with target-path
          on httpcon
          do
          (case action
           ((none)
            (elwiki-page httpcon target-path))
           ((edit)
            (elwiki-edit-page httpcon target-path)))))
       (POST
        (let ((path (elnode-http-pathinfo httpcon))
               (text (elwiki--text-param httpcon)))
          (cond
           ((elnode-http-param httpcon "save")
            ;; A save request in which case save the new text and then
            ;; send the wiki text.
            (elwiki--save-request httpcon elwiki-wikiroot path text))
           ((and (elnode-http-param httpcon "preview")
                 (eq action 'edit))
            ;; A preview request in which case send back the WIKI text
            ;; that's been sent.
            (let ((preview-file-name "/tmp/preview"))
              (with-temp-file preview-file-name
                (insert text))
              (elwiki-edit-page httpcon preview-file-name path t))))))))))

;;;###autoload
(defun elwiki-server (httpcon)
  "Serve wiki pages from `elwiki-wikiroot'.

HTTPCON is the request.

The wiki server is only available if the `creole' package is
provided. Otherwise it will just error."
  (if (not (featurep 'creole))
      (elnode-send-500 httpcon "The Emacs feature 'creole is required.")
    (elwiki--router httpcon)))

(provide 'elwiki)

;;; elwiki.el ends here

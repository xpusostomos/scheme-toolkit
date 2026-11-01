;;; (scheme-toolkit services workspace) -- workspaces, compositor-agnostically (AstalWorkspace)
;;;
;;; ext-workspace-v1: workspaces and outputs without knowing the compositor.
;;; The bar uses Hyprland's instead, so this is here for a compositor-
;;; agnostic path that has not been needed yet.

(define-module (scheme-toolkit services workspace)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)
  #:export (workspace-manager))

(define (workspace-manager) (service-instance 'workspace-manager))

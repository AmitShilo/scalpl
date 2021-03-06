;;;; actor.lisp

(defpackage #:scalpl.actor
  (:use #:cl #:local-time #:scalpl.util #:chanl)
  (:export #:actor #:perform #:halt #:name #:control))

(in-package #:scalpl.actor)

;;;
;;; Actor
;;;

;;; TODO: Incorporate weak references and finalizers into the whole CSPSM model
;;; so they get garbage collected when there are no more references to the
;;; output channels

;;; actor afterthought - maybe actors should be explicit, channels just an
;;; implementation detail? "API methods" on the actor object serve as the
;;; client, and state machine on the channel side serves as the server

(defclass actor ()
  ((name :initform (gensym "") :initarg :name :accessor name
         :documentation "Name for identifying this actor and its tasks")
   (tasks :initform nil :documentation "Tasks performing this actor's behavior")
   (control :initform (make-instance 'channel)
            :documentation "Channel for controlling this actor")))

(defgeneric execute (actor command)
  (:method ((actor actor) (command function)) (funcall command actor))
  (:method ((actor actor) (command (eql :halt))) (throw :halt actor)))

(defgeneric enqueue (actor)
  (:method ((actor actor))
    (pexec (:name (format nil "~A~S" (name actor) (now)))
      (catch :halt (perform actor)))))

(defgeneric perform (actor)
  (:documentation "Implement actor's behavior, executing commands by default")
  (:method ((actor actor))
    (execute actor (recv (slot-value actor 'control))))
  (:method :after ((actor actor))
    (with-slots (name tasks) actor
      (setf tasks (cons (enqueue actor)
                        (remove :terminated tasks :key #'task-status))))))

(defgeneric ensure-running (actor)
  (:method ((actor actor))
    (with-slots (name tasks) actor
      (unless (find :alive tasks :key #'task-status)
        (push (enqueue actor) tasks)))))

(defgeneric halt (actor)
  (:documentation "Signals `actor' to terminate")
  (:method ((actor actor)) (send (slot-value actor 'control) :halt)))

(defmethod shared-initialize :after ((actor actor) slot-names &key)
  (ensure-running actor))

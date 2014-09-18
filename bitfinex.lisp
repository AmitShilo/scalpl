(defpackage #:scalpl.bitfinex
  (:use #:cl #:anaphora #:local-time #:st-json #:base64 #:scalpl.util #:scalpl.exchange)
  (:export #:get-request
           #:post-request
           #:find-market #:*bitfinex*
           #:make-key #:make-signer))

(in-package #:scalpl.bitfinex)

;;; General Parameters
(defparameter +base-path+ "https://api.bitfinex.com/v1/")

(defun hmac-sha384 (message secret)
  (let ((hmac (ironclad:make-hmac secret 'ironclad:sha384)))
    (ironclad:update-hmac hmac (string-octets message))
    (ironclad:octets-to-integer (ironclad:hmac-digest hmac))))

;;; X-BFX-APIKEY = API key
;;; X-BFX-PAYLOAD = base64(json(request path, nonce, parameters...))
;;; X-BFX-SIGNATURE = Message signature using HMAC-SHA384 of payload and base64 decoded secret

;;; generate max 1 nonce per second
(defvar *last-nonce* (now))

(defun nonce (&aux (now (now)) (delta (timestamp-difference now *last-nonce*)))
  (when (> 1 delta) (sleep (- 1 delta)))
  (princ-to-string (+ (floor (nsec-of now) 1000)
                      (* 1000000 (timestamp-to-unix now)))))

(defun make-payload (data &optional path)
  (let ((payload (if (null path) (jso) (jso "request" path "nonce" (nonce)))))
    (dolist (pair data (string-to-base64-string (write-json-to-string payload)))
      (destructuring-bind (key . val) pair (setf (getjso key payload) val)))))

(defgeneric make-signer (secret)
  (:method ((secret simple-array))
    (lambda (payload) (format nil "~(~96,'0X~)" (hmac-sha384 payload secret))))
  (:method ((secret string)) (make-signer (string-octets secret)))
  (:method ((stream stream)) (make-signer (read-line stream)))
  (:method ((path pathname)) (with-open-file (stream path) (make-signer stream))))

(defgeneric make-key (key)
  (:method ((key string)) key)
  (:method ((stream stream)) (read-line stream))
  (:method ((path pathname))
    (with-open-file (stream path)
      (make-key stream))))

(defun decode-json (arg)
  (st-json:read-json (map 'string 'code-char arg)))

(defun raw-request (path &rest keys)
  (handler-case
      (multiple-value-bind (body status)
          (apply #'drakma:http-request
                 (concatenate 'string +base-path+ path)
                 ;; Mystery crash on the morning of 2014-06-04
                 ;; entered an infinite loop of usocket:timeout-error
                 ;; lasted for hours, continued upon restart
                 ;; other programs on the same computer not affected - just sbcl
                 :connection-timeout 60
                 keys)
        (case status
          (200 (decode-json body))
          ((400 404) (values nil (decode-json body)))
          (t (cerror "Retry request" "HTTP Error ~D" status)
             (apply #'raw-request path keys))))
    (drakma::drakma-simple-error ()
      (format t "~&Retrying after drakma SIMPLE crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (drakma::simple-error ()
      (format t "~&Retrying after drakma crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (cl+ssl::ssl-error-zero-return ()
      (format t "~&Retrying after cl+ssl crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (cl+ssl::ssl-error-syscall ()
      (format t "~&Retrying after cl+ssl crap...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:ns-host-not-found-error ()
      (format t "~&Retrying after nameserver crappage...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:deadline-timeout-error ()
      (format t "~&Retrying after deadline timeout...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    (usocket:timeout-error ()
      (format t "~&Retrying after regular timeout...~%")
      (sleep 1)
      (apply #'raw-request path keys))
    ))

(defun get-request (path &optional data)
  (raw-request path :additional-headers `(("X-BFX-PAYLOAD" ,(make-payload data)))))

(defun post-request (method key signer &optional data)
  (let* ((path (concatenate 'string "/v1/" method))
         (payload (make-payload data path)))
    (raw-request method :method :post
                 :additional-headers `(("X-BFX-APIKEY"  . ,key)
                                       ("X-BFX-PAYLOAD" . ,payload)
                                       ("X-BFX-SIGNATURE" . ,(funcall signer payload))))))

(defun get-assets ()
  (mapcar (lambda (name) (make-instance 'asset :name name :decimals 8))
          (delete-duplicates (mapcan (lambda (sym)
                                       (list (subseq sym 0 3) (subseq sym 3)))
                                     (get-request "symbols"))
                             :test #'string=)))

(defun detect-market-precision (name)
  (reduce 'max (with-json-slots (asks bids)
                   (get-request (format nil "book/~A" name))
                 (mapcar (lambda (offer &aux (price (getjso "price" offer)))
                           (- (length price) (position #\. price) 1))
                         (append (subseq bids 0 (floor (length bids) 2))
                                 (subseq asks 0 (floor (length asks) 2)))))))

(defun get-markets (assets &aux markets)
  (dolist (name (get-request "symbols") markets)
    (push (make-instance
           'market :name name
           :base (find-asset (subseq name 0 3) assets)
           :quote (find-asset (subseq name 3) assets)
           :decimals (detect-market-precision name))
          markets)))

(defvar *bitfinex*
  (let ((assets (get-assets)))
    (make-instance 'exchange :name "Bitfinex"
                   :assets assets :markets (get-markets assets))))

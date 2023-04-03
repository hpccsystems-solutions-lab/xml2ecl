;;;; xml2ecl.lisp

(in-package #:xml2ecl)

(declaim (optimize (debug 3)))

;;;

(defvar *layout-names* nil
  "Used while ECL record definitions are being emitted.  Tracks the names
of the record definitions created, so that subsequent creations don't reuse
previously-defined names.")

(defparameter *ecl-string-type* "UTF8"
  "The ECL data type to be used for XML string types.  Can be overridden
with an option.")

;;;

(defclass object-item ()
  ((children :accessor children :initform (make-hash-table :test 'equalp :size 25))
   (attrs :accessor attrs :initform (make-hash-table :test 'equalp :size 10))))

;;;

(defun is-ecl-keyword-p (name)
  "Test if NAME (which should be a lowercase string) is an ECL keyword."
  (member name *ecl-keywords* :test 'equalp))

(defun remove-illegal-chars (name &key (replacement-char #\_) (keep-char-list '()))
  "Return a copy of NAME with characters illegal for ECL attribute names
substituted with a replacment character, then reducing runs of those
replacement characters down to a single occurrence."
  (let* ((keep-chars (reduce 'cons keep-char-list
                             :initial-value (list #\_ replacement-char)
                             :from-end t))
         (initial (substitute-if replacement-char
                                 (lambda (c) (not (or (alphanumericp c) (member c keep-chars))))
                                 name))
         (skip nil)
         (result (with-output-to-string (s)
                   (loop for c across initial
                         do (progn
                              (unless (and (eql c replacement-char) skip)
                                (format s "~A" c))
                              (setf skip (eql c replacement-char)))))))
    result))

;;;

(defun apply-prefix (name prefix-char)
  (format nil "~A~A~A"
          prefix-char
          (if (char= (elt name 0) #\_) "" "_")
          name))

(defun legal-layout-subname (name)
  "Return a copy of NAME that can be used within a RECORD name."
  (let ((initial (string-upcase (remove-illegal-chars name))))
    (if (not (alpha-char-p (elt initial 0)))
        (apply-prefix initial "F")
        initial)))

(defun register-layout-subname (name)
  "Push layout subname NAME to a special variable list so we can track usage."
  (let ((legal-name (legal-layout-subname name)))
    (push legal-name *layout-names*)))

;;;

(defun as-layout-name (name)
  "Construct a string that is a suitable ECL RECORD attribute, based on NAME."
  (let* ((legal-name (legal-layout-subname name))
         (name-count (count-if #'(lambda (x) (equalp x legal-name)) *layout-names*))
         (interstitial (if (< name-count 2) "" (format nil "_~3,'0D" name-count))))
    (format nil "~A~A_LAYOUT" legal-name interstitial)))

(defun as-ecl-field-name (name)
  "Return a copy of NAME that is suitable to be used as an ECL attribute."
  (let* ((lowername (string-downcase name))
         (no-dashes (remove-illegal-chars lowername))
         (legal (if (or (not (alpha-char-p (elt no-dashes 0)))
                        (is-ecl-keyword-p no-dashes))
                    (apply-prefix no-dashes "f")
                    no-dashes)))
    (if (string= lowername "_text")
        lowername
        legal)))

(defun as-ecl-xpath (name attributep)
  "Construct an ECL XPATH directive for NAME (typically an as-is JSON key)."
  (if (string= name "_text")
      "{XPATH(<>)}"
      (let ((cleaned-name (remove-illegal-chars name :replacement-char #\* :keep-char-list '(#\-)))
            (attr-prefix (if attributep "@" "")))
        (format nil "{XPATH('~A~A')}" attr-prefix cleaned-name))))

(defun as-dataset-type (name)
  "Construct an ECL DATASET datatype, given NAME."
  (format nil "DATASET(~A)" (as-layout-name name)))

(defun as-ecl-type (value-type)
  "Given a symbol representing an internal data type, return the corresponding ECL data type."
  (if (consp value-type)
      (as-ecl-type (reduce-base-type value-type))
      (case value-type
        (boolean "BOOLEAN")
        (null-value "STRING")
        (string "STRING")
        (default-string *ecl-string-type*)
        (pos-number "UNSIGNED")
        (neg-number "INTEGER")
        (float "REAL"))))

(defun as-value-comment (value-type)
  "If VALUE-TYPE is a list of more than one base type, return a string that serves
as an ECL comment describing those types."
  (when (and (consp value-type)
             (or (and (= (length value-type) 1)
                      (eql (car value-type) 'null-value))
                 (and (> (length value-type) 1)
                      (member (as-ecl-type value-type) '(*ecl-string-type* "STRING") :test #'string=))))
    (labels ((desc (v)
               (case v
                 (null-value "null")
                 (default-string "string")
                 (pos-number "unsigned integer")
                 (neg-number "signed integer")
                 (t (format nil "~(~A~)" v)))))
      (format nil "// ~{~A~^, ~}" (mapcar #'desc value-type)))))
;;;

(defun base-type (value)
  "Determine the basic internal data type of VALUE."
  (let ((value-str (format nil "~A" value))
        (neg-char-found-p nil)
        (decimal-char-found-p nil)
        (found-type nil))
    (cond ((string= value-str "")
           (setf found-type 'default-string))
          ((member (string-downcase value-str) '("true" "false" "1" "0") :test #'string=)
           (setf found-type 'boolean))
          (t
           (loop named char-walker
                 for c across value-str
                 do (progn
                      (cond ((and (eql c #\-) (not neg-char-found-p))
                             (setf neg-char-found-p t
                                   found-type (common-type 'neg-number found-type)))
                            ((digit-char-p c)
                             (setf found-type (common-type 'pos-number found-type)))
                            ((and (eql c #\.) (not decimal-char-found-p))
                             (setf decimal-char-found-p t
                                   found-type (common-type 'float found-type)))
                            (t
                             (setf found-type 'default-string)))
                      (when (eql found-type 'default-string)
                        (return-from char-walker))))))
    found-type))

(defun common-type (new-type old-type)
  "Given two internal data types, return an internal type that can encompass both."
  (let ((args (list new-type old-type)))
    (cond ((not old-type)
           new-type)
          ((not new-type)
           old-type)
          ((eql new-type old-type)
           new-type)
          ((member 'default-string args)
           'default-string)
          ((member 'string args)
           'string)
          ((and (member 'neg-number args)
                (member 'pos-number args))
           'neg-number)
          ((and (intersection '(neg-number pos-number) args)
                (member 'float args))
           'float)
          (t
           'string))))

(defun reduce-base-type (types)
  (reduce #'common-type types))

;;;

(defgeneric as-ecl-field-def (value-obj name attributep)
  (:documentation "Create an ECL field definition from an object or array class."))

(defmethod as-ecl-field-def ((value-obj t) name attributep)
  (let* ((ecl-type (as-ecl-type value-obj))
         (xpath (as-ecl-xpath name attributep))
         (comment (as-value-comment value-obj))
         (field-def (with-output-to-string (s)
                      (format s "~4T~A ~A ~A;" ecl-type (as-ecl-field-name name) xpath)
                      (when comment
                        (format s " ~A" comment))
                      (format s "~%"))))
    field-def))

(defmethod as-ecl-field-def ((obj object-item) name attributep)
  (let* ((xpath (as-ecl-xpath name attributep))
         (field-def (with-output-to-string (s)
                      (format s "~4T~A ~A ~A" (as-dataset-type name) (as-ecl-field-name name) xpath)
                      (format s ";~%"))))
    field-def))

;;;

(defgeneric as-ecl-record-def (obj name)
  (:documentation "Create an ECL RECORD definition from an object or array class."))

(defmethod as-ecl-record-def ((obj t) name)
  (declare (ignore obj name))
  "")

(defmethod as-ecl-record-def ((obj object-item) name)
  (let* ((result-str "")
         (my-str (with-output-to-string (s)
                   (register-layout-subname name)
                   (format s "~A := RECORD~%" (as-layout-name name))
                   (loop for field-name being the hash-keys of (attrs obj)
                           using (hash-value field-value)
                         do (format s "~A" (as-ecl-field-def field-value field-name t)))
                   (loop for field-name being the hash-keys of (children obj)
                           using (hash-value field-value)
                         do (let ((child-recdef (as-ecl-record-def field-value field-name)))
                              (when (string/= child-recdef "")
                                (setf result-str (format nil "~A~A" result-str child-recdef)))
                              (format s "~A" (as-ecl-field-def field-value field-name nil))))
                   (format s "END;~%~%")
                   )))
    (format nil "~A~A" result-str my-str)))

;;;

(defmacro reuse-object (place classname)
  "Return object found in PLACE if it is an instance of CLASSNAME, or create a
new instance of CLASSNAME in place and return that."
  `(progn
     (cond ((or (null ,place) (not ,place) (eql ,place 'null-value))
            (setf ,place (make-instance ,classname)))
           ((and (consp ,place) (eql (car ,place) 'null-value))
            (setf ,place (make-instance ,classname)))
           ((not (typep ,place ,classname))
            (error "xml2ecl: Mismatching object types; expected ~A but found ~A"
                   (type-of ,place)
                   ,classname)))
     ,place))

(defmacro parse-simple (place value)
  "Pushes the base type of VALUE onto the sequence PLACE."
  `(unless (typep ,place 'object-item)
     (pushnew (base-type ,value) ,place)))

(defmacro parse-complex (place classname source)
  "Reuse object in PLACE if possible, or create a new instance of CLASSNAME,
then kick off a new depth of parsing with the result."
  `(progn
     (reuse-object ,place ,classname)
     (parse-obj ,place ,source)))

;;;

(defgeneric parse-attrs (obj source)
  (:documentation "Parses XML attributes and inserts base data types into OBJ."))

(defmethod parse-attrs ((obj object-item) source)
  (labels ((handle-attrs (ns local-name qualified-name value explicitp)
             (declare (ignore ns qualified-name))
             (when explicitp
               (parse-simple (gethash local-name (attrs obj)) value))))
    (fxml.klacks:map-attributes #'handle-attrs source)))

(defgeneric parse-obj (obj source)
  (:documentation "Parses XML tokens into an internal object representation."))

(defmethod parse-obj ((obj object-item) source)
  (loop named parse
        do (multiple-value-bind (event chars name) (fxml.klacks:consume source)
             (cond ((null event)
                    (return-from parse))
                   ((eql event :end-document)
                    (return-from parse))
                   ((eql event :start-element)
                    (parse-attrs obj source)
                    (parse-complex (gethash name (children obj)) 'object-item source))
                   ((eql event :end-element)
                    (return-from parse))
                   ((eql event :characters)
                    (let ((text (string-trim '(#\Space #\Tab #\Newline) (format nil "~A" chars))))
                      (parse-simple (gethash "_text" (children obj)) text)))
                   ((member event '(:start-document))
                    ;; stuff to ignore
                    )
                   (t
                    (error "xml2ecl: Unknown event at toplevel: (~A)" event)))))
  obj)

;;;

(defmacro with-wrapped-xml-stream ((s element-name wrapped-stream) &body body)
  "Wrap stream WRAPPED-STREAM, containing XML data, with empty tags named ELEMENT-NAME.
S should be the symbol of the stream that is created and will be referenced in the BODY."
  (let ((begin-tag-stream (gensym "begin_stream_"))
        (end-tag-stream (gensym "end_stream_"))
        (start-tag (gensym "start_tag_"))
        (end-tag (gensym "end_tag_")))
    `(let ((,start-tag (format nil "<~A>" ,element-name))
           (,end-tag (format nil "</~A>" ,element-name)))
       (flexi-streams:with-input-from-sequence (,begin-tag-stream ,start-tag :transformer #'char-code)
         (flexi-streams:with-input-from-sequence (,end-tag-stream ,end-tag :transformer #'char-code)
           (let ((,s (make-concatenated-stream ,begin-tag-stream ,wrapped-stream ,end-tag-stream)))
             ,@body))))))

(defun process-file-or-stream (input)
  (let ((obj (make-instance 'object-item)))
    (with-open-file (file-stream (uiop:probe-file* input)
                                 :direction :input
                                 :element-type '(unsigned-byte 8))
      (with-wrapped-xml-stream (input-stream "bogus2" file-stream)
        (fxml.klacks:with-open-source (source (fxml:make-source input-stream :buffering nil))
          (parse-obj obj source))))
    obj))


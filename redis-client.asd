(asdf:defsystem #:redis-client
  :author "Andrew Danger Lyon <orthecreedence@gmail.com>"
  :licence "MIT"
  :version "0.1.0"
  :description "A simple redis client using usocket. All commands are generic and sent/recieved using the univeral format."
  :depends-on (:usocket)
  :serial t
  :components ((:file "redis-client")
               (:file "commands")))

(in-package :redis-client)

;; NOTE - borken because of namespace shit for now.
#|
(defcmd ping)
(defcmd exists key)
(defcmd del key)
(defcmd type key)
(defcmd lpush key val)
(defcmd rpoplpush key1 key2)
(defcmd randomkey)
(defcmd rename oldkey newkey)
(defcmd renamenx oldkey newkey)
(defcmd dbsize)
(defcmd expire key seconds)
(defcmd persist key)
(defcmd ttl key)
(defcmd select db)
(defcmd move key db)
(defcmd flushdb)
(defcmd flushall)

(defcmd set key val)
(defcmd get)
(defcmd getset key val)
|#

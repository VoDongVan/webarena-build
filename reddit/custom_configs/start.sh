#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf

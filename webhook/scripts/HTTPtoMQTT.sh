#!/bin/sh
MESSAGE=$1
DATETIME=$2

/usr/bin/mosquitto_pub -t 'to-poppy' -m "$1"

echo $MESSAGE
echo $DATETIME

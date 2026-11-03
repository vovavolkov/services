#!/bin/bash

# Check for correct number of arguments
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <start|stop> <service-name>"
  exit 1
fi

ACTION=$1
SERVICE=$(echo "$2" | tr -d '\r' | xargs)
SERVICE_PATH="/home/vova/services/mc-$SERVICE/"

# Validate action
if [[ "$ACTION" != "start" && "$ACTION" != "stop" ]]; then
  echo "Invalid action. Use 'start' or 'stop'."
  exit 1
fi

# Validate service directory
if [ ! -d "$SERVICE_PATH" ]; then
  echo "Service directory $SERVICE_PATH not found."
  exit 1
fi


cd "$SERVICE_PATH" || exit 1

# Execute the action
if [ "$ACTION" == "start" ]; then
  docker compose up -d
else
  docker compose down
fi


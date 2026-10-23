#!/bin/sh
echo "$STORE_ACTION version=$STORE_VERSION previous=${STORE_PREVIOUS_VERSION:-} pwd=$(pwd) token_length=${#TOKEN} greeting=$GREETING" >> "$STORE_DATA/hooks.log"

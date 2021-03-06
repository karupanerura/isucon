#!/bin/bash
APPDIR=$(dirname $0)/..

if [ -f $APPDIR/../standalone/env.sh ]; then
    . $APPDIR/../standalone/env.sh
else
    export PH=$PATH:/home/isucon/.nvm/v0.4.11/bin
    export NODE_PATH=/home/isucon/node_modules/
fi

export NODE_PATH=$NODE_PATH:lib

cd $APPDIR
exec node bench.js "$@"

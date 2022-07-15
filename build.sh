#!/usr/bin/env sh

INSTALL_DIR=$PWD/zig-out/bin
INSTALL_PATH=$INSTALL_DIR/my-finances-app
mkdir -p zig-out/bin

EXE_CACHE_PATH=$(zig build-exe --enable-cache src/main.zig -lsqlite3 -lc)


printf "cp %s/main %s\n" $EXE_CACHE_PATH $INSTALL_PATH
cp $EXE_CACHE_PATH/main $INSTALL_PATH

printf "exec %s\n" $INSTALL_PATH
exec $INSTALL_PATH

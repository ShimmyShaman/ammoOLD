#!/bin/bash

echo
echo Compiling

ODIN=/home/bug/proj/Odin/odin

if ! test -f "$ODIN"; then
    echo "Please Edit compile_run.sh to point to the proper location for $ODIN"
    exit 1
fi

BIN=bin #bin

if ! test -d "$BIN"; then
    mkdir bin
fi

echo "########################################"

# Server
# export LD_LIBRARY_PATH="/home/bug/proj/Odin/vendor/stb/lib"
export LD_LIBRARY_PATH="/usr/local/lib"
# echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
# export PATH="/home/bug/proj/Odin/vendor/stb/lib:$PATH"
# echo $PATH;/home/bug/proj/odin_vulkan_cube/src/odin-vma/external/VulkanMemoryAllocator.lib
# /home/bug/proj/Odin/vendor/stb/lib/stb_image.a
# $ODIN run ./src/kgs -debug -out:$EXE
$ODIN run ./cli/src -extra-linker-flags:"-lstdc++ -lvulkan" -debug -out:$BIN/client \
& \
$ODIN run ./srv/src -extra-linker-flags:"-lstdc++ -lvulkan" -debug -out:$BIN/server

# 

# retval=$?
# if [ $retval -ne 0 ]; then
#     echo "Compilation Failed : $retval"
# else
#     echo "#######################"
#     echo Compilation Succeeded -- Running...
#     echo "#######################"
#     # export EXTRA_CLING_ARGS='-Wmacro-redefined'
#     # set PATH=/home/
#     $BIN/$EXE
#     # -x c
#     retval=$?
#     echo "#######################"
#     echo "Program Exited: $retval"
# fi
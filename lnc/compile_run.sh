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

# Executable
# export LD_LIBRARY_PATH="/home/bug/proj/Odin/vendor/stb/lib"
# export LD_LIBRARY_PATH="/usr/local/lib"
# echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
# export PATH="/home/bug/proj/Odin/vendor/stb/lib:$PATH"
# echo $PATH;/home/bug/proj/odin_vulkan_cube/src/odin-vma/external/VulkanMemoryAllocator.lib
# /home/bug/proj/Odin/vendor/stb/lib/stb_image.a
# $ODIN run ./src/kgs -debug -out:$EXE
$ODIN build ./src -extra-linker-flags:"-lstdc++ -lvulkan" -debug -out:$BIN/launcher
retval=$?
if [ $retval -ne 0 ]; then
    echo "Launcher Compilation Failed : $retval"
else
    echo "#######################"
    echo Launcher Compilation Succeeded -- Running...
    echo "#######################"
    $BIN/launcher
    # valgrind -s 
fi
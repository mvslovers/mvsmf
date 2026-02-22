# Root of the repository (auto-detected)
ROOT_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# Tools path (mvsasm etc.)
export PATH := $(ROOT_DIR)scripts:$(PATH)

# Cross-compiler
CC       := c2asm370 #or classic gccmvs
CFLAGS   := -fverbose-asm -S -O1

# Defines and include paths
DEFS     := -DLUA_USE_C89 -DLUA_USE_JUMPTABLE=0
INC_DIR  := $(ROOT_DIR)inc
INC1     := $(ROOT_DIR)contrib/crent370_sdk/inc
INC2     := $(ROOT_DIR)contrib/httpd_cgi_sdk/inc
INCS     := -I$(INC_DIR) -I$(INC1) -I$(INC2)

CFLAGS   += $(DEFS) $(INCS)

# MVS host dataset configuration
export MAC1               := CRENT370.MACLIB
export MVSASM_PUNCH       := FIX0MIG.MVSMF.OBJECT
export MVSASM_SYSLMOD     := FIX0MIG.MVSMF.NCALIB

# Link-edit configuration
export MVSLINK_SYSLIB     := FIX0MIG.CRENT370.NCALIB
export MVSLINK_NCALIB     := FIX0MIG.MVSMF.NCALIB
export MVSLINK_LOAD       := FIX0MIG.MVSMF.LOAD
export MVSLINK_ENTRY      := @@CRT0
export MVSLINK_NAME       := MVSMF

# Install configuration
export MVSINSTALL_SOURCE  := FIX0MIG.MVSMF.LOAD
export MVSINSTALL_TARGET  := HTTPD.LINKLIB
export MVSINSTALL_MEMBER  := MVSMF

# Package configuration (TRANSMIT + download)
export MVSPACKAGE_SOURCE  := FIX0MIG.MVSMF.LOAD
export MVSPACKAGE_XMIT    := FIX0MIG.MVSMF.XMIT
export MVSPACKAGE_NODE    := GITHUB.COM

# JES job classes
export MVSASM_JOBCLASS    := A
export MVSASM_MSGCLASS    := H

# Keep generated JCL files for debugging (set to 1 to enable)
# export MVSASM_KEEP_JCL := 1

# Warning collection file
export BUILD_WARNINGS := $(ROOT_DIR).build-warnings

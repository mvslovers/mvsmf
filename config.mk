# Root of the repository (auto-detected)
ROOT_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# Load personalizable settings from .env
-include .env

export MVSMF_HOST MVSMF_PORT MVSMF_USER MVSMF_PASS
export MVSMF_JOBCLASS MVSMF_MSGCLASS MVSMF_KEEP_JCL
export MVSMF_ASM_MAC1 MVSMF_ASM_PUNCH MVSMF_ASM_SYSLMOD MVSMF_ASM_LKED_SYSLIB
export MVSMF_LINK_SYSLIB MVSMF_LINK_NCALIB MVSMF_LINK_LOAD MVSMF_LINK_ENTRY MVSMF_LINK_NAME
export MVSMF_INSTALL_SOURCE MVSMF_INSTALL_TARGET MVSMF_INSTALL_MEMBER
export MVSMF_PKG_SOURCE MVSMF_PKG_XMIT MVSMF_PKG_NODE

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

# Warning collection file
export BUILD_WARNINGS := $(ROOT_DIR).build-warnings

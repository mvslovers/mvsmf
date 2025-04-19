INC1 := -I/home/mike/repos/mvsmf/inc
INC2 := -I/home/mike/repos/mvsmf/contrib/crent370_sdk/inc
INC3 := -I/home/mike/repos/mvsmf/contrib/httpd_cgi_sdk/inc
INCS := $(INC1) $(INC2) $(INC3) 
DEF1 := -DLUA_USE_C89
DEF2 := -DLUA_USE_JUMPTABLE=0
DEFS := $(DEF1) $(DEF2)
CC := c2asm370
#CC := i370-mvs-gcc
#CC := gcc370
CFLAGS := -fverbose-asm -S -O1 $(DEFS) $(INCS)

# c source code files
C_FILES := 				\
		src/common.c		\
		src/json.c			\
		src/router.c 		\
		src/mvsmf.c 		\
		src/authmw.c 		\
		src/logmw.c 		\
		src/dsapi.c 		\
		src/infoapi.c 		\
		src/jobsapi.c		\
		src/cgxstart.c

# generated .s assembler source files (one for each source file)
S_FILES := $(foreach filename,$(C_FILES),$(filename:.c=.s))

# object files (one for each .c and .asm source file)
O_FILES := $(foreach filename,$(C_FILES),$(filename:.c=.o)) \
           $(foreach filename,$(A_FILES),$(filename:.asm=.o))

# expoort MSGCLASS
export MSGCLASS=H
# export MACn variables for mvsasm->jobasm script
export MAC1=CRENT370.MACLIB
#export MAC2=SYS1.HASPSRC

# export dataset names used by mvsasm script
export MVSASM_PUNCH=FIX0MIG.MVSMF.OBJECT
export MVSASM_SYSLMOD=FIX0MIG.MVSMF.NCALIB

all: $(S_FILES) $(O_FILES)
	@echo "Done"
# Note: PHONY is important here. Without it, implicit rules will try
#       to build the executable "all", since the prereqs are ".o" files.
.PHONY: all 

# build object files from the generated assembler files (.s)
%.o: %.s
	@echo "mvsasm $(notdir $<)"
	@mvsasm "$<"
	@touch "$@"

# build object files from assembler files (.asm)
%.o: %.asm
	@echo "mvsasm $(notdir $<)"
	@mvsasm "$<"
	@touch "$@"

# compile C source files (.c) into assembler files (.s)
%.s: %.c
	@echo "Compile $(notdir $<)"
	$(CC) $(CFLAGS) -c $< -o $@

# remove generated files
clean:
	@rm -f $(S_FILES) $(O_FILES)

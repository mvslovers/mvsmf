include config.mk

# c source code files
C_FILES := src/common.c  src/json.c    src/router.c   src/mvsmf.c   \
           src/authmw.c  src/logmw.c   src/dsapi.c    src/infoapi.c \
           src/xlate.c   src/jobsapi.c src/cgxstart.c

# assembler source files
A_FILES :=

# Module names derived from C sources (uppercase basenames)
MODULES := $(shell for f in $(C_FILES); do basename $$f .c | tr '[:lower:]' '[:upper:]'; done)

include rules.mk

# link-edit all modules into a load module
link:
	@$(ROOT_DIR)scripts/mvslink $(MODULES)
.PHONY: link

# copy load module into target LINKLIB
install:
	@$(ROOT_DIR)scripts/mvsinstall
.PHONY: install

# TRANSMIT load library to XMIT format and download it
package:
	@$(ROOT_DIR)scripts/mvspackage
.PHONY: package

# generate compile_commands.json for clangd
compiledb:
	@echo "[" > compile_commands.json
	@first=1; \
	for f in $(C_FILES); do \
		if [ $$first -eq 0 ]; then echo "," >> compile_commands.json; fi; \
		first=0; \
		echo "  {" >> compile_commands.json; \
		echo "    \"directory\": \"$(CURDIR)\"," >> compile_commands.json; \
		echo "    \"file\": \"$$f\"," >> compile_commands.json; \
		echo "    \"command\": \"clang -c $(DEFS) $(INCS) -std=c89 $$f\"" >> compile_commands.json; \
		echo "  }" >> compile_commands.json; \
	done
	@echo "]" >> compile_commands.json
	@echo "Generated compile_commands.json"
.PHONY: compiledb

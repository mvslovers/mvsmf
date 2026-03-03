include config.mk

# c source code files
C_FILES := src/common.c  src/json.c    src/router.c   src/mvsmf.c   \
           src/authmw.c  src/logmw.c   src/dsapi.c    src/infoapi.c \
           src/xlate.c   src/jobsapi.c src/cgxstart.c \
           src/testapi.c

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
	@echo "Generating compile_commands.json"
	@{ \
		echo "["; \
		first=1; \
		for f in $(C_FILES); do \
			abs_file="$(CURDIR)/$$f"; \
			if [ $$first -eq 0 ]; then echo ","; fi; \
			first=0; \
			echo "  {"; \
			echo "    \"directory\": \"$(CURDIR)\","; \
			echo "    \"file\": \"$$abs_file\","; \
			echo "    \"arguments\": ["; \
			printf '      "%s",\n' clang; \
			printf '      "%s",\n' -c; \
			printf '      "%s",\n' -std=c89; \
			for d in $(DEFS); do \
				esc=$$(printf '%s' "$$d" | sed 's/\\/\\\\/g; s/"/\\"/g'); \
				printf '      "%s",\n' "$$esc"; \
			done; \
			for i in $(INCS); do \
				esc=$$(printf '%s' "$$i" | sed 's/\\/\\\\/g; s/"/\\"/g'); \
				printf '      "%s",\n' "$$esc"; \
			done; \
			printf '      "%s"\n' "$$abs_file"; \
			echo "    ]"; \
			echo "  }"; \
		done; \
		echo "]"; \
	} > compile_commands.json
.PHONY: compiledb

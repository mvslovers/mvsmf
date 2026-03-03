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
include bootstrap.mk

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

# MVS build container lifecycle
run-mvs:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "ERROR: docker not found"; exit 1; \
	fi; \
	docker network inspect $(DOCKER_NETWORK) >/dev/null 2>&1 || \
		docker network create $(DOCKER_NETWORK) >/dev/null; \
	if docker inspect $(MVS_CONTAINER) >/dev/null 2>&1; then \
		if [ "$$(docker inspect -f '{{.State.Running}}' $(MVS_CONTAINER))" = "true" ]; then \
			echo "$(MVS_CONTAINER) is already running"; \
		else \
			echo "Starting $(MVS_CONTAINER)..."; \
			docker start $(MVS_CONTAINER); \
		fi; \
	else \
		echo "Creating $(MVS_CONTAINER) from $(MVS_IMAGE) (this may take a while)..."; \
		docker run -d --name $(MVS_CONTAINER) --network $(DOCKER_NETWORK) \
			-p 1080:1080 -p 3270:3270 -p 8888:8888 \
			$(MVS_IMAGE); \
		echo ""; \
		echo "Set MVSMF_HOST=$(MVS_CONTAINER) in your .env to connect to this container."; \
	fi; \
	if [ -f /.dockerenv ]; then \
		docker network connect $(DOCKER_NETWORK) $$(hostname) 2>/dev/null || true; \
	fi
.PHONY: run-mvs

stop-mvs:
	@if docker inspect $(MVS_CONTAINER) >/dev/null 2>&1; then \
		echo "Stopping $(MVS_CONTAINER)..."; \
		docker stop $(MVS_CONTAINER); \
	else \
		echo "$(MVS_CONTAINER) does not exist"; \
	fi
.PHONY: stop-mvs

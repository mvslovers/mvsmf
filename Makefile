MBT_ROOT := mbt
include $(MBT_ROOT)/mk/mbt.mk

# --- Build identity (always fresh) ------------------------------------
# Regenerate include/buildid.h with the current git short hash on every
# make.  Rewrite the file ONLY when the hash actually changed, so its mtime
# is preserved otherwise and mbt's -MMD header tracking recompiles the
# marker TU exactly when the build identity moved -- never spuriously.
# Done at parse time so the header always exists before the first compile.
BUILD_ID := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
$(shell printf '#ifndef MVSMF_BUILDID_H\n#define MVSMF_BUILDID_H\n#define BUILD_ID "%s"\n#endif\n' '$(BUILD_ID)' > include/buildid.h.tmp; \
        cmp -s include/buildid.h.tmp include/buildid.h 2>/dev/null \
        || mv include/buildid.h.tmp include/buildid.h; \
        rm -f include/buildid.h.tmp)

# --- Docker infrastructure (project-specific) ---

DOCKER_NETWORK ?= mvs-net
MVS_CONTAINER  ?= mvs
MVS_IMAGE      ?= ghcr.io/mvslovers/mvsce-builder

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

# --- Desktop frontend deploy (project-specific) ---
# Upload static/ (the mvsMF Desktop) to the HTTPD UFS via our own USS REST
# API, dogfooding it. Default matches the HTTPD's default DOCROOT (/www),
# so the desktop is served at /mvsmf/. Override for a custom DOCROOT,
# e.g.  make deploy-desktop DESKTOP_UFS_DIR=/wwwroot/mvsmf
DESKTOP_UFS_DIR ?= /www/mvsmf

deploy-desktop:
	@DESKTOP_UFS_DIR='$(DESKTOP_UFS_DIR)' tools/deploy-desktop.sh
.PHONY: deploy-desktop

deploy-desktop-dry:
	@DESKTOP_UFS_DIR='$(DESKTOP_UFS_DIR)' tools/deploy-desktop.sh --dry-run
.PHONY: deploy-desktop-dry

MBT_ROOT := mbt
include $(MBT_ROOT)/mk/core.mk

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

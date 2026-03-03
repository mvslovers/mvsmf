# bootstrap.mk — Modular bootstrap and doctor targets for mvsMF
#
# Included from Makefile after config.mk.  Provides:
#   make bootstrap          full environment setup (idempotent)
#   make bootstrap PLAN=1   dry-run — shows what would happen
#   make doctor             read-only diagnostics, never fails
#
# Respects NO_COLOR=1 to suppress ANSI colors.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PLAN    ?= 0
BMAKE   := $(MAKE) --no-print-directory

BASE_URL := http://$(MVSMF_HOST):$(MVSMF_PORT)
AUTH     := $(MVSMF_USER):$(MVSMF_PASS)

CURL_OPTS := -s -S --connect-timeout 5 --max-time 10

# Required .env variables (bootstrap validates these)
REQUIRED_VARS := MVSMF_HOST MVSMF_PORT MVSMF_USER MVSMF_PASS \
                 MVSMF_ASM_PUNCH MVSMF_ASM_SYSLMOD MVSMF_LINK_LOAD

# Tools
REQUIRED_TOOLS := curl jq
OPTIONAL_TOOLS := docker zowe

# Docker infrastructure
DOCKER_NETWORK ?= mvs-net
MVS_CONTAINER  ?= mvs
MVS_IMAGE      ?= ghcr.io/mvslovers/mvsce-builder

# Git submodules expected under contrib/
SUBMODULES := contrib/crent370_sdk contrib/httpd_cgi_sdk

# ---------------------------------------------------------------------------
# Output helpers — colored prefixes with tty detection
# ---------------------------------------------------------------------------
_ISATTY := $(shell [ -t 1 ] && echo 1 || echo 0)
ifeq ($(NO_COLOR),1)
  _ISATTY := 0
endif

ifeq ($(_ISATTY),1)
  _RST  := \033[0m
  _BLD  := \033[1m
  _GRN  := \033[32m
  _YLW  := \033[33m
  _RED  := \033[31m
  _CYN  := \033[36m
else
  _RST  :=
  _BLD  :=
  _GRN  :=
  _YLW  :=
  _RED  :=
  _CYN  :=
endif

define _ok
  @printf "$(_GRN)[OK]$(_RST)   %s\n" $(1)
endef
define _warn
  @printf "$(_YLW)[WARN]$(_RST) %s\n" $(1)
endef
define _fail
  @printf "$(_RED)[FAIL]$(_RST) %s\n" $(1)
endef
define _plan
  @printf "$(_CYN)[PLAN]$(_RST) %s\n" $(1)
endef
define _hdr
  @printf "\n$(_BLD)== %s ==$(_RST)\n" $(1)
endef

# ---------------------------------------------------------------------------
# bootstrap (orchestrator)
# ---------------------------------------------------------------------------
.PHONY: bootstrap
bootstrap:
	$(call _hdr,"Bootstrap")
	@$(BMAKE) _bs_env
	@if [ -z "$(MVSMF_HOST)" ] && [ -f .env ]; then \
		exec $(BMAKE) bootstrap; \
	fi
	@$(BMAKE) _bs_toolchain
	@$(BMAKE) _bs_docker
	@$(BMAKE) _bs_runtime
	@$(BMAKE) _bs_datasets
	@if [ "$(PLAN)" = "0" ]; then \
		$(BMAKE) compiledb || true; \
	else \
		printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would generate compile_commands.json"; \
	fi
	$(call _hdr,"Bootstrap complete")

# ---------------------------------------------------------------------------
# doctor (read-only diagnostics — never exits non-zero)
# ---------------------------------------------------------------------------
.PHONY: doctor
doctor:
	$(call _hdr,"Doctor")
	@$(BMAKE) _doc_env      || true
	@$(BMAKE) _doc_tools    || true
	@$(BMAKE) _doc_submod   || true
	@$(BMAKE) _doc_docker   || true
	@$(BMAKE) _doc_compdb   || true
	@$(BMAKE) _doc_connect  || true
	@$(BMAKE) _doc_datasets || true
	$(call _hdr,"Doctor complete")

# ============================= sub-targets ==================================

# ---------------------------------------------------------------------------
# _bs_env — ensure .env exists and required variables are set
# ---------------------------------------------------------------------------
.PHONY: _bs_env
_bs_env:
	$(call _hdr,"Environment")
	@if [ ! -f .env ]; then \
		if [ "$(PLAN)" = "1" ]; then \
			printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would copy .env.example to .env"; \
		elif [ -f .env.example ]; then \
			cp .env.example .env; \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "Copied .env.example to .env — edit it with your values"; \
		else \
			printf "$(_RED)[FAIL]$(_RST) %s\n" ".env missing and no .env.example template found"; \
			exit 1; \
		fi; \
	else \
		printf "$(_GRN)[OK]$(_RST)   %s\n" ".env exists"; \
	fi
	@if [ "$(PLAN)" = "1" ]; then \
		printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would validate required variables"; \
	elif [ -f .env ]; then \
		. ./.env; \
		_fail=0; \
		for v in $(REQUIRED_VARS); do \
			val=$$(eval echo "\$$$$v"); \
			if [ -z "$$val" ]; then \
				printf "$(_RED)[FAIL]$(_RST) %s\n" "$$v is not set in .env"; \
				_fail=1; \
			fi; \
		done; \
		if [ "$$_fail" = "1" ]; then exit 1; fi; \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "All required variables set"; \
	fi

# ---------------------------------------------------------------------------
# _bs_toolchain — check required and optional tools
# ---------------------------------------------------------------------------
.PHONY: _bs_toolchain
_bs_toolchain:
	$(call _hdr,"Toolchain")
	@_fail=0; \
	for t in $(REQUIRED_TOOLS); do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$t found"; \
		else \
			printf "$(_RED)[FAIL]$(_RST) %s\n" "$$t not found (required)"; \
			_fail=1; \
		fi; \
	done; \
	if [ "$$_fail" = "1" ]; then exit 1; fi; \
	if command -v c2asm370 >/dev/null 2>&1; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "c2asm370 found"; \
	else \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "c2asm370 not found (cross-compiler, needed for builds)"; \
	fi; \
	_need_submod=0; \
	for d in $(SUBMODULES); do \
		if [ -d "$$d" ] && [ "$$(ls -A "$$d" 2>/dev/null)" ]; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$d populated"; \
		else \
			_need_submod=1; \
		fi; \
	done; \
	if [ "$$_need_submod" = "1" ]; then \
		if [ "$(PLAN)" = "1" ]; then \
			printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would run git submodule update --init"; \
		else \
			printf "       %s\n" "Fetching submodules..."; \
			git submodule update --init; \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "Submodules initialized"; \
		fi; \
	fi

# ---------------------------------------------------------------------------
# _bs_docker — network + auto-join (container lifecycle via run-mvs/stop-mvs)
# ---------------------------------------------------------------------------
.PHONY: _bs_docker
_bs_docker:
	$(call _hdr,"Docker Infrastructure")
	@if ! command -v docker >/dev/null 2>&1; then \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "docker not found — skipping infrastructure setup"; \
		exit 0; \
	fi; \
	if ! docker info >/dev/null 2>&1; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "Docker daemon not reachable"; \
		exit 1; \
	fi; \
	if [ "$(PLAN)" = "1" ]; then \
		printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would ensure network $(DOCKER_NETWORK)"; \
		if [ -f /.dockerenv ]; then \
			printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would join this container to $(DOCKER_NETWORK)"; \
		fi; \
		exit 0; \
	fi; \
	if docker network inspect $(DOCKER_NETWORK) >/dev/null 2>&1; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "Network $(DOCKER_NETWORK) exists"; \
	else \
		docker network create $(DOCKER_NETWORK) >/dev/null; \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "Network $(DOCKER_NETWORK) created"; \
	fi; \
	if [ -f /.dockerenv ]; then \
		docker network connect $(DOCKER_NETWORK) $$(hostname) 2>/dev/null || true; \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "This container joined $(DOCKER_NETWORK)"; \
	fi

# ---------------------------------------------------------------------------
# _bs_runtime — connectivity and auth checks against mvsMF
# ---------------------------------------------------------------------------
.PHONY: _bs_runtime
_bs_runtime:
	$(call _hdr,"Runtime (mvsMF connectivity)")
	@if [ "$(PLAN)" = "1" ]; then \
		printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would check connectivity and auth to $(BASE_URL)"; \
		exit 0; \
	fi; \
	HTTP=$$(curl $(CURL_OPTS) -o /dev/null -w '%{http_code}' \
		-u "$(AUTH)" \
		"$(BASE_URL)/zosmf/restfiles/ds?dslevel=SYS1.MACLIB" 2>/dev/null) || HTTP=000; \
	if [ "$$HTTP" = "200" ]; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "mvsMF reachable at $(BASE_URL) — auth OK"; \
	elif [ "$$HTTP" = "000" ]; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "Cannot connect to $(BASE_URL) (connection refused or timeout)"; \
		exit 1; \
	elif [ "$$HTTP" = "401" ]; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "mvsMF reachable but auth failed (HTTP 401) — check MVSMF_USER/MVSMF_PASS"; \
		exit 1; \
	else \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "mvsMF returned HTTP $$HTTP"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# _bs_datasets — ensure required datasets exist, create if missing
# ---------------------------------------------------------------------------
.PHONY: _bs_datasets
_bs_datasets:
	$(call _hdr,"Datasets")
	@$(BMAKE) _ds_ensure DS_NAME="$(MVSMF_ASM_PUNCH)" \
		DS_BODY='{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":10,"secondary":5,"dirblk":10}'
	@$(BMAKE) _ds_ensure DS_NAME="$(MVSMF_ASM_SYSLMOD)" \
		DS_BODY='{"dsorg":"PO","recfm":"U","lrecl":0,"blksize":15040,"alcunit":"TRK","primary":50,"secondary":20,"dirblk":10}'
	@$(BMAKE) _ds_ensure DS_NAME="$(MVSMF_LINK_LOAD)" \
		DS_BODY='{"dsorg":"PO","recfm":"U","lrecl":0,"blksize":15040,"alcunit":"TRK","primary":50,"secondary":20,"dirblk":5}'

# Generic helper: ensure a single dataset exists
.PHONY: _ds_ensure
_ds_ensure:
	@if [ -z "$(DS_NAME)" ]; then exit 0; fi; \
	if [ "$(PLAN)" = "1" ]; then \
		printf "$(_CYN)[PLAN]$(_RST) %s\n" "Would ensure dataset $(DS_NAME) exists"; \
		exit 0; \
	fi; \
	RESP=$$(curl $(CURL_OPTS) -u "$(AUTH)" \
		"$(BASE_URL)/zosmf/restfiles/ds?dslevel=$(DS_NAME)" 2>/dev/null) || RESP=""; \
	FOUND=$$(printf '%s' "$$RESP" | jq -r '.items[]?.dsname // empty' 2>/dev/null \
		| grep -Fx "$(DS_NAME)" || true); \
	if [ -n "$$FOUND" ]; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "$(DS_NAME) exists"; \
	else \
		printf "       %s\n" "$(DS_NAME) not found — creating..."; \
		HTTP=$$(curl $(CURL_OPTS) -o /dev/null -w '%{http_code}' \
			-X POST -u "$(AUTH)" \
			-H "Content-Type: application/json" \
			-d '$(DS_BODY)' \
			"$(BASE_URL)/zosmf/restfiles/ds/$(DS_NAME)" 2>/dev/null) || HTTP=000; \
		if [ "$$HTTP" = "201" ]; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$(DS_NAME) created"; \
		else \
			printf "$(_RED)[FAIL]$(_RST) %s\n" "Failed to create $(DS_NAME) (HTTP $$HTTP)"; \
			exit 1; \
		fi; \
	fi

# ===========================================================================
# Doctor sub-targets (all read-only, all || true in caller)
# ===========================================================================

.PHONY: _doc_env
_doc_env:
	$(call _hdr,"Environment")
	@if [ -f .env ]; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" ".env exists"; \
		. ./.env; \
		for v in $(REQUIRED_VARS); do \
			val=$$(eval echo "\$$$$v"); \
			if [ -z "$$val" ]; then \
				printf "$(_RED)[FAIL]$(_RST) %s\n" "$$v is not set"; \
			else \
				printf "$(_GRN)[OK]$(_RST)   %s\n" "$$v set"; \
			fi; \
		done; \
	else \
		printf "$(_RED)[FAIL]$(_RST) %s\n" ".env not found"; \
	fi

.PHONY: _doc_tools
_doc_tools:
	$(call _hdr,"Tools")
	@for t in $(REQUIRED_TOOLS); do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$t"; \
		else \
			printf "$(_RED)[FAIL]$(_RST) %s\n" "$$t not found (required)"; \
		fi; \
	done; \
	for t in c2asm370 git make; do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$t"; \
		else \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "$$t not found"; \
		fi; \
	done; \
	for t in $(OPTIONAL_TOOLS); do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$t (optional)"; \
		else \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "$$t not found (optional)"; \
		fi; \
	done

.PHONY: _doc_submod
_doc_submod:
	$(call _hdr,"Submodules")
	@for d in $(SUBMODULES); do \
		if [ -d "$$d" ] && [ "$$(ls -A "$$d" 2>/dev/null)" ]; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$d populated"; \
		else \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "$$d missing or empty"; \
		fi; \
	done

.PHONY: _doc_docker
_doc_docker:
	$(call _hdr,"Docker Infrastructure")
	@if ! command -v docker >/dev/null 2>&1; then \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "docker not found"; \
		exit 0; \
	fi; \
	if ! docker info >/dev/null 2>&1; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "Docker daemon not reachable"; \
		exit 0; \
	fi; \
	printf "$(_GRN)[OK]$(_RST)   %s\n" "Docker daemon reachable"; \
	if docker network inspect $(DOCKER_NETWORK) >/dev/null 2>&1; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "Network $(DOCKER_NETWORK)"; \
	else \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "Network $(DOCKER_NETWORK) not found"; \
	fi; \
	if docker inspect $(MVS_CONTAINER) >/dev/null 2>&1; then \
		if [ "$$(docker inspect -f '{{.State.Running}}' $(MVS_CONTAINER))" = "true" ]; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "Container $(MVS_CONTAINER) running"; \
		else \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "Container $(MVS_CONTAINER) exists but stopped"; \
		fi; \
	else \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "Container $(MVS_CONTAINER) not found"; \
	fi; \
	if [ -f /.dockerenv ]; then \
		SELF=$$(hostname); \
		if docker inspect "$$SELF" \
			--format '{{range $$k, $$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' 2>/dev/null \
			| grep -q "$(DOCKER_NETWORK)"; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "This container in $(DOCKER_NETWORK)"; \
		else \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "This container not in $(DOCKER_NETWORK)"; \
		fi; \
	fi

.PHONY: _doc_compdb
_doc_compdb:
	$(call _hdr,"Compile Database")
	@if [ -f compile_commands.json ]; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "compile_commands.json exists"; \
	else \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "compile_commands.json missing (run make compiledb)"; \
	fi

.PHONY: _doc_connect
_doc_connect:
	$(call _hdr,"mvsMF Connectivity")
	@if [ -z "$(MVSMF_HOST)" ] || [ -z "$(MVSMF_USER)" ]; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "MVSMF_HOST or MVSMF_USER not set"; \
		exit 0; \
	fi; \
	HTTP=$$(curl $(CURL_OPTS) -o /dev/null -w '%{http_code}' \
		-u "$(AUTH)" \
		"$(BASE_URL)/zosmf/restfiles/ds?dslevel=SYS1.MACLIB" 2>/dev/null) || HTTP=000; \
	if [ "$$HTTP" = "200" ]; then \
		printf "$(_GRN)[OK]$(_RST)   %s\n" "mvsMF reachable at $(BASE_URL) — auth OK"; \
	elif [ "$$HTTP" = "000" ]; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "Cannot connect to $(BASE_URL)"; \
	elif [ "$$HTTP" = "401" ]; then \
		printf "$(_RED)[FAIL]$(_RST) %s\n" "mvsMF reachable but auth failed (HTTP 401)"; \
	else \
		printf "$(_YLW)[WARN]$(_RST) %s\n" "mvsMF returned HTTP $$HTTP"; \
	fi

.PHONY: _doc_datasets
_doc_datasets:
	$(call _hdr,"Datasets")
	@if [ -z "$(MVSMF_HOST)" ] || [ -z "$(MVSMF_USER)" ]; then exit 0; fi; \
	for dsvar in MVSMF_ASM_PUNCH MVSMF_ASM_SYSLMOD MVSMF_LINK_LOAD; do \
		dsname=$$(eval echo "\$$$$dsvar"); \
		if [ -z "$$dsname" ]; then \
			printf "$(_YLW)[WARN]$(_RST) %s\n" "$$dsvar not set"; \
			continue; \
		fi; \
		RESP=$$(curl $(CURL_OPTS) -u "$(AUTH)" \
			"$(BASE_URL)/zosmf/restfiles/ds?dslevel=$$dsname" 2>/dev/null) || RESP=""; \
		FOUND=$$(printf '%s' "$$RESP" | jq -r '.items[]?.dsname // empty' 2>/dev/null \
			| grep -Fx "$$dsname" || true); \
		if [ -n "$$FOUND" ]; then \
			printf "$(_GRN)[OK]$(_RST)   %s\n" "$$dsname"; \
		else \
			printf "$(_RED)[FAIL]$(_RST) %s\n" "$$dsname not found"; \
		fi; \
	done

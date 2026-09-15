# ==============================================================================
# CineClaw — Build & Multi-Architecture Release Automation
# ==============================================================================

SHELL := /bin/bash
REGISTRY ?= ghcr.io/cineclaw
VERSION ?= 1.2.0
PLATFORMS ?= linux/amd64,linux/arm64
BUILDER ?= multiarch

# Android TV Settings
TV_IP ?= 192.168.88.127:5555
TV_PKG := com.cineclaw.tv
TV_ACTIVITY := $(TV_PKG)/.MainActivity

# Colors for terminal output
CYAN  := \033[0;36m
GREEN := \033[0;32m
YELLOW:= \033[0;33m
RED   := \033[0;31m
NC    := \033[0m

.PHONY: help login check-builder prune-cache \
        build-local build-frontend-local build-tracker-local build-indexer-local \
        publish-all publish-frontend publish-tracker publish-indexer publish-ai \
        tv-fast tv-dev tv-release tv-prod tv-build-fast tv-build-release \
        tv-connect tv-logs tv-stop \
        up down restart logs pull status

help: ## Show this help message
	@echo -e "$(CYAN)CineClaw Automation Makefile$(NC)"
	@echo -e "Usage: make [target] [VERSION=1.0.0] [REGISTRY=ghcr.io/cineclaw]"
	@echo ""
	@echo -e "$(YELLOW)Publishing to GHCR (Multi-Arch with Compiler Cache: $(PLATFORMS)):$(NC)"
	@echo -e "  $(GREEN)publish-all$(NC)         - Build and push all 3 services to GHCR"
	@echo -e "  $(GREEN)publish-indexer$(NC)     - Build and push imdb-indexer to GHCR (multi-arch + cargo cache)"
	@echo -e "  $(GREEN)publish-tracker$(NC)     - Build and push tracker-proxy to GHCR (multi-arch + go cache)"
	@echo -e "  $(GREEN)publish-frontend$(NC)    - Build and push frontend to GHCR (multi-arch + npm cache)"
	@echo ""
	@echo -e "$(YELLOW)Local Fast Builds (Host Architecture with Persistent Cache):$(NC)"
	@echo -e "  $(GREEN)build-local$(NC)         - Build all 3 services locally for host arch"
	@echo -e "  $(GREEN)build-indexer-local$(NC) - Build imdb-indexer locally with cargo cache"
	@echo -e "  $(GREEN)build-tracker-local$(NC) - Build tracker-proxy locally with go cache"
	@echo -e "  $(GREEN)build-frontend-local$(NC)- Build frontend locally with npm cache"
	@echo ""
	@echo -e "$(YELLOW)Android TV Client (Device: $(TV_IP)):$(NC)"
	@echo -e "  $(GREEN)tv-fast$(NC)             - Fast incremental build & deploy to TV (Debug, no R8, ~3-5s)"
	@echo -e "  $(GREEN)tv-release$(NC)          - Full heavy build with max optimizations (R8 + Proguard + AOT compile on TV)"
	@echo -e "  $(GREEN)tv-build-fast$(NC)       - Build Debug APK only without deploying"
	@echo -e "  $(GREEN)tv-build-release$(NC)    - Build Release APK only without deploying"
	@echo -e "  $(GREEN)tv-logs$(NC)             - Stream live Android TV logcat"
	@echo -e "  $(GREEN)tv-connect$(NC)          - Connect ADB to TV ($(TV_IP))"
	@echo -e "  $(GREEN)tv-stop$(NC)             - Force-stop CineClaw app on TV"
	@echo ""
	@echo -e "$(YELLOW)Cache & Maintenance:$(NC)"
	@echo -e "  $(GREEN)prune-cache$(NC)         - Clear BuildKit compiler cache volumes"
	@echo ""
	@echo -e "$(YELLOW)Orchestration & Diagnostics:$(NC)"
	@echo -e "  $(GREEN)login$(NC)               - Login to ghcr.io using gh CLI credentials"
	@echo -e "  $(GREEN)up$(NC)                  - Start entire CineClaw stack via docker compose"
	@echo -e "  $(GREEN)down$(NC)                - Stop CineClaw stack"
	@echo -e "  $(GREEN)restart$(NC)             - Restart all containers"
	@echo -e "  $(GREEN)logs$(NC)                - Follow logs of all services"
	@echo -e "  $(GREEN)pull$(NC)                - Pull latest pre-built images from GHCR"
	@echo -e "  $(GREEN)status$(NC)              - Run install.sh --status health checks"

# ------------------------------------------------------------------------------
# Authentication & Builder Setup
# ------------------------------------------------------------------------------

login: ## Log in to GitHub Container Registry using gh CLI auth token
	@echo -e "$(CYAN)Authenticating with GitHub Container Registry...$(NC)"
	@echo $$(gh auth token) | docker login $(REGISTRY) -u $$(gh api user --jq .login) --password-stdin
	@echo -e "$(GREEN)Successfully logged in to $(REGISTRY)$(NC)"

check-builder: ## Verify Docker Buildx multi-arch builder
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || { \
		echo -e "$(YELLOW)Creating multi-arch builder '$(BUILDER)'...$(NC)"; \
		docker buildx create --name $(BUILDER) --driver docker-container --use; \
		docker buildx inspect --bootstrap; \
	}
	@docker buildx use $(BUILDER)

prune-cache: check-builder ## Clear persistent compiler caches (cargo, go, npm)
	@echo -e "$(YELLOW)Pruning BuildKit compilation cache...$(NC)"
	docker buildx prune --builder $(BUILDER) -f
	@echo -e "$(GREEN)✓ Compilation cache cleared$(NC)"

# ------------------------------------------------------------------------------
# Multi-Arch Builds & GHCR Publishing (with Registry Layer Cache + Cache Mounts)
# ------------------------------------------------------------------------------

publish-indexer: check-builder ## Build and push imdb-indexer to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/imdb-indexer:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
		--cache-from type=registry,ref=$(REGISTRY)/imdb-indexer:latest \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/imdb-indexer:$(VERSION) \
		-t $(REGISTRY)/imdb-indexer:latest \
		--push \
		./imdb-indexer
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/imdb-indexer:$(VERSION) and :latest$(NC)"

publish-tracker: check-builder ## Build and push tracker-proxy to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/tracker-proxy:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
		--cache-from type=registry,ref=$(REGISTRY)/tracker-proxy:latest \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/tracker-proxy:$(VERSION) \
		-t $(REGISTRY)/tracker-proxy:latest \
		--push \
		./tracker-proxy
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/tracker-proxy:$(VERSION) and :latest$(NC)"

publish-frontend: check-builder ## Build and push frontend to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/frontend:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
		--cache-from type=registry,ref=$(REGISTRY)/frontend:latest \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/frontend:$(VERSION) \
		-t $(REGISTRY)/frontend:latest \
		--push \
		./frontend
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/frontend:$(VERSION) and :latest$(NC)"

publish-ai: check-builder ## Build and push cineclaw-ai to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/cineclaw-ai:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
		--cache-from type=registry,ref=$(REGISTRY)/cineclaw-ai:latest \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/cineclaw-ai:$(VERSION) \
		-t $(REGISTRY)/cineclaw-ai:latest \
		--push \
		./cineclaw-ai
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/cineclaw-ai:$(VERSION) and :latest$(NC)"

publish-torrserver: check-builder ## Build and push torrserver-gst to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/torrserver-gst:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
		--cache-from type=registry,ref=$(REGISTRY)/torrserver-gst:latest \
		-t $(REGISTRY)/torrserver-gst:$(VERSION) \
		-t $(REGISTRY)/torrserver-gst:latest \
		--push \
		./torrserver-gst
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/torrserver-gst:$(VERSION) and :latest$(NC)"

publish-all: publish-frontend publish-tracker publish-indexer publish-ai publish-torrserver ## Build and push all services to GHCR
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ All CineClaw $(VERSION) microservices successfully published to GHCR$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

# ------------------------------------------------------------------------------
# Fast Local Builds (Single-Arch with Persistent Cache Mounts)
# ------------------------------------------------------------------------------

build-indexer-local: check-builder ## Fast local build for host architecture with persistent cache
	@echo -e "$(CYAN)Building imdb-indexer for host architecture...$(NC)"
	docker buildx build \
		--load \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/imdb-indexer:$(VERSION) \
		-t $(REGISTRY)/imdb-indexer:latest \
		./imdb-indexer

build-tracker-local: check-builder ## Fast local build for host architecture with persistent cache
	@echo -e "$(CYAN)Building tracker-proxy for host architecture...$(NC)"
	docker buildx build \
		--load \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/tracker-proxy:$(VERSION) \
		-t $(REGISTRY)/tracker-proxy:latest \
		./tracker-proxy

build-ai-local: check-builder ## Fast local build for host architecture with persistent cache
	@echo -e "$(CYAN)Building cineclaw-ai for host architecture...$(NC)"
	docker buildx build \
		--load \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/cineclaw-ai:$(VERSION) \
		-t $(REGISTRY)/cineclaw-ai:latest \
		./cineclaw-ai

build-frontend-local: check-builder ## Fast local build for host architecture with persistent cache
	@echo -e "$(CYAN)Building frontend for host architecture...$(NC)"
	docker buildx build \
		--load \
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/frontend:$(VERSION) \
		-t $(REGISTRY)/frontend:latest \
		./frontend

build-local: build-frontend-local build-tracker-local build-indexer-local build-ai-local ## Build all services for host architecture

# ------------------------------------------------------------------------------
# Operations & Orchestration
# ------------------------------------------------------------------------------

up: ## Start stack with pre-built GHCR images
	docker compose up -d

down: ## Stop stack
	docker compose down

restart: ## Restart streaming and backend services
	docker compose restart

logs: ## View streaming logs
	docker compose logs -f

pull: ## Pull updated images from GHCR
	docker compose pull

status: ## Run installation diagnostics
	./install.sh --status

# ------------------------------------------------------------------------------
# Android TV Client Automation
# ------------------------------------------------------------------------------

tv-connect: ## Connect ADB to TV
	@echo -e "$(CYAN)Connecting ADB to TV at $(TV_IP)...$(NC)"
	@adb connect $(TV_IP)

tv-build-fast: ## Fast assemble Debug APK (incremental, no R8)
	@echo -e "$(CYAN)⚡ Building fast Debug APK...$(NC)"
	@cd android-tv && ./gradlew assembleTvDebug
	@echo -e "$(GREEN)✓ Debug APK ready: android-tv/app/build/outputs/apk/tv/debug/app-tv-debug.apk$(NC)"

tv-fast: tv-build-fast ## Fast incremental build & deploy to Android TV (Debug APK, ~3-5s)
	@echo -e "$(CYAN)Ensuring ADB connection to $(TV_IP)...$(NC)"
	@adb connect $(TV_IP) >/dev/null 2>&1 || true
	@echo -e "$(CYAN)Installing fast debug build to TV...$(NC)"
	@adb -s $(TV_IP) install -r android-tv/app/build/outputs/apk/tv/debug/app-tv-debug.apk
	@echo -e "$(CYAN)Launching $(TV_ACTIVITY)...$(NC)"
	@adb -s $(TV_IP) shell am start -n $(TV_ACTIVITY)
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ Fast deploy finished! Running on $(TV_IP)$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

tv-dev: tv-fast ## Alias for tv-fast

tv-build-release: ## Build production Release APK (R8 + resource shrinking + Proguard)
	@echo -e "$(CYAN)🔨 Building fully optimized Release APK (R8, Proguard)...$(NC)"
	@cd android-tv && ./gradlew assembleTvRelease
	@echo -e "$(GREEN)✓ Release APK ready: android-tv/app/build/outputs/apk/tv/release/app-tv-release.apk$(NC)"

tv-release: tv-build-release ## Heavy build with max optimizations + TV install + on-device AOT speed compile
	@echo -e "$(CYAN)Ensuring ADB connection to $(TV_IP)...$(NC)"
	@adb connect $(TV_IP) >/dev/null 2>&1 || true
	@echo -e "$(CYAN)Installing optimized release build to TV...$(NC)"
	@adb -s $(TV_IP) install -r android-tv/app/build/outputs/apk/tv/release/app-tv-release.apk
	@echo -e "$(CYAN)⚡ Compiling on-device AOT machine code (dex2oat speed profile)...$(NC)"
	@adb -s $(TV_IP) shell cmd package compile -m speed -f $(TV_PKG)
	@echo -e "$(CYAN)Launching $(TV_ACTIVITY)...$(NC)"
	@adb -s $(TV_IP) shell am start -n $(TV_ACTIVITY)
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ Heavy release build + AOT compilation complete on $(TV_IP)$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

tv-prod: tv-release ## Alias for tv-release

tv-logs: ## Follow Android TV logcat for CineClaw
	@echo -e "$(CYAN)Streaming live logs for $(TV_PKG) from $(TV_IP)...$(NC)"
	adb -s $(TV_IP) logcat -v time | grep --line-buffered -E "CineClaw|ExoPlayer|MediaCodec|TvPlayer|Retrofit"

tv-stop: ## Force stop CineClaw on TV
	@echo -e "$(YELLOW)Stopping $(TV_PKG) on $(TV_IP)...$(NC)"
	@adb -s $(TV_IP) shell am force-stop $(TV_PKG)
	@echo -e "$(GREEN)✓ App stopped$(NC)"

# ------------------------------------------------------------------------------
# Android Automotive & Car Client Automation (Lynk & Co 900 & Car Boxes)
# ------------------------------------------------------------------------------

AUTO_IP ?= 192.168.88.130:5555
AUTO_PKG := com.cineclaw.auto
AUTO_ACTIVITY := $(AUTO_PKG)/com.cineclaw.tv.MainActivity

auto-connect: ## Connect ADB to Car Infotainment / Car Box
	@echo -e "$(CYAN)Connecting ADB to Car at $(AUTO_IP)...$(NC)"
	@adb connect $(AUTO_IP)

auto-build-fast: ## Fast assemble Auto Debug APK (incremental, no R8)
	@echo -e "$(CYAN)⚡ Building fast Auto Debug APK...$(NC)"
	@cd android-tv && ./gradlew assembleAutoDebug
	@echo -e "$(GREEN)✓ Auto Debug APK ready: android-tv/app/build/outputs/apk/auto/debug/app-auto-debug.apk$(NC)"

auto-fast: auto-build-fast ## Fast incremental build & deploy to Car (Debug APK)
	@echo -e "$(CYAN)Ensuring ADB connection to $(AUTO_IP)...$(NC)"
	@adb connect $(AUTO_IP) >/dev/null 2>&1 || true
	@echo -e "$(CYAN)Installing fast debug build to Car...$(NC)"
	@adb -s $(AUTO_IP) install -r android-tv/app/build/outputs/apk/auto/debug/app-auto-debug.apk
	@echo -e "$(CYAN)Launching $(AUTO_ACTIVITY)...$(NC)"
	@adb -s $(AUTO_IP) shell am start -n $(AUTO_ACTIVITY)
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ Fast deploy finished! Running on $(AUTO_IP)$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

auto-dev: auto-fast ## Alias for auto-fast

auto-build-release: ## Build production Auto Release APK (R8, Lynk & Co 900 / Car Box)
	@echo -e "$(CYAN)🔨 Building fully optimized Auto Release APK (R8, Proguard)...$(NC)"
	@cd android-tv && ./gradlew assembleAutoRelease
	@echo -e "$(GREEN)✓ Auto Release APK ready: android-tv/app/build/outputs/apk/auto/release/app-auto-release.apk$(NC)"

auto-release: auto-build-release ## Heavy build with max optimizations + Car install + on-device AOT speed compile
	@echo -e "$(CYAN)Ensuring ADB connection to $(AUTO_IP)...$(NC)"
	@adb connect $(AUTO_IP) >/dev/null 2>&1 || true
	@echo -e "$(CYAN)Installing optimized auto release build to Car...$(NC)"
	@adb -s $(AUTO_IP) install -r android-tv/app/build/outputs/apk/auto/release/app-auto-release.apk
	@echo -e "$(CYAN)⚡ Compiling on-device AOT machine code (dex2oat speed profile)...$(NC)"
	@adb -s $(AUTO_IP) shell cmd package compile -m speed -f $(AUTO_PKG)
	@echo -e "$(CYAN)Launching $(AUTO_ACTIVITY)...$(NC)"
	@adb -s $(AUTO_IP) shell am start -n $(AUTO_ACTIVITY)
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ Heavy auto release build + AOT compilation complete on $(AUTO_IP)$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

auto-prod: auto-release ## Alias for auto-release

auto-logs: ## Follow Android Automotive logcat for CineClaw
	@echo -e "$(CYAN)Streaming live logs for $(AUTO_PKG) from $(AUTO_IP)...$(NC)"
	adb -s $(AUTO_IP) logcat -v time | grep --line-buffered -E "CineClaw|ExoPlayer|StorageManager|DownloadManager|MediaCodec"

auto-stop: ## Force stop CineClaw on Car
	@echo -e "$(YELLOW)Stopping $(AUTO_PKG) on $(AUTO_IP)...$(NC)"
	@adb -s $(AUTO_IP) shell am force-stop $(AUTO_PKG)
	@echo -e "$(GREEN)✓ App stopped$(NC)"



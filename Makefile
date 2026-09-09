# ==============================================================================
# CineClaw — Build & Multi-Architecture Release Automation
# ==============================================================================

SHELL := /bin/bash
REGISTRY ?= ghcr.io/cineclaw
VERSION ?= 1.0.0
PLATFORMS ?= linux/amd64,linux/arm64
BUILDER ?= multiarch

# Colors for terminal output
CYAN  := \033[0;36m
GREEN := \033[0;32m
YELLOW:= \033[0;33m
NC    := \033[0m

.PHONY: help login check-builder \
        build-local build-frontend-local build-tracker-local build-indexer-local \
        publish-all publish-frontend publish-tracker publish-indexer \
        up down restart logs pull status

help: ## Show this help message
	@echo -e "$(CYAN)CineClaw Automation Makefile$(NC)"
	@echo -e "Usage: make [target] [VERSION=1.0.0] [REGISTRY=ghcr.io/cineclaw]"
	@echo ""
	@echo -e "$(YELLOW)Publishing to GHCR (Multi-Arch: $(PLATFORMS)):$(NC)"
	@echo -e "  $(GREEN)publish-all$(NC)         - Build and push all 3 services to GHCR"
	@echo -e "  $(GREEN)publish-indexer$(NC)     - Build and push imdb-indexer to GHCR (multi-arch)"
	@echo -e "  $(GREEN)publish-tracker$(NC)     - Build and push tracker-proxy to GHCR (multi-arch)"
	@echo -e "  $(GREEN)publish-frontend$(NC)    - Build and push frontend to GHCR (multi-arch)"
	@echo ""
	@echo -e "$(YELLOW)Local Fast Builds (Host Architecture):$(NC)"
	@echo -e "  $(GREEN)build-local$(NC)         - Build all 3 services locally for host arch"
	@echo -e "  $(GREEN)build-indexer-local$(NC) - Build imdb-indexer locally for host arch"
	@echo -e "  $(GREEN)build-tracker-local$(NC) - Build tracker-proxy locally for host arch"
	@echo -e "  $(GREEN)build-frontend-local$(NC)- Build frontend locally for host arch"
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

# ------------------------------------------------------------------------------
# Multi-Arch Builds & GHCR Publishing
# ------------------------------------------------------------------------------

publish-indexer: check-builder ## Build and push imdb-indexer to GHCR (amd64 + arm64)
	@echo -e "$(CYAN)Building and pushing $(REGISTRY)/imdb-indexer:$(VERSION) ($(PLATFORMS))...$(NC)"
	docker buildx build \
		--platform $(PLATFORMS) \
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
		--build-arg VERSION=$(VERSION) \
		-t $(REGISTRY)/frontend:$(VERSION) \
		-t $(REGISTRY)/frontend:latest \
		--push \
		./frontend
	@echo -e "$(GREEN)✓ Published $(REGISTRY)/frontend:$(VERSION) and :latest$(NC)"

publish-all: publish-frontend publish-tracker publish-indexer ## Build and push all services to GHCR
	@echo -e "$(GREEN)========================================================$(NC)"
	@echo -e "$(GREEN)✓ All CineClaw $(VERSION) microservices successfully published to GHCR$(NC)"
	@echo -e "$(GREEN)========================================================$(NC)"

# ------------------------------------------------------------------------------
# Fast Local Builds (Single-Arch for dev)
# ------------------------------------------------------------------------------

build-indexer-local: ## Fast local build for host architecture
	@echo -e "$(CYAN)Building imdb-indexer for host architecture...$(NC)"
	docker build --build-arg VERSION=$(VERSION) -t $(REGISTRY)/imdb-indexer:$(VERSION) -t $(REGISTRY)/imdb-indexer:latest ./imdb-indexer

build-tracker-local: ## Fast local build for host architecture
	@echo -e "$(CYAN)Building tracker-proxy for host architecture...$(NC)"
	docker build --build-arg VERSION=$(VERSION) -t $(REGISTRY)/tracker-proxy:$(VERSION) -t $(REGISTRY)/tracker-proxy:latest ./tracker-proxy

build-frontend-local: ## Fast local build for host architecture
	@echo -e "$(CYAN)Building frontend for host architecture...$(NC)"
	docker build --build-arg VERSION=$(VERSION) -t $(REGISTRY)/frontend:$(VERSION) -t $(REGISTRY)/frontend:latest ./frontend

build-local: build-frontend-local build-tracker-local build-indexer-local ## Build all services for host architecture

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

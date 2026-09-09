package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"cineclaw-ai/pkg/config"
	"cineclaw-ai/pkg/critics"
	"cineclaw-ai/pkg/storage"
)

func main() {
	cfg := config.Load()

	log.Printf("[cineclaw-ai] Starting CineClaw AI Engine on port %s...", cfg.Port)
	log.Printf("[cineclaw-ai] Data dir: %s", cfg.DataDir)
	log.Printf("[cineclaw-ai] Summary model: %s", cfg.SummaryModel)
	if cfg.OpenRouterAPIKey != "" {
		log.Printf("[cineclaw-ai] OpenRouter API key configured (length %d)", len(cfg.OpenRouterAPIKey))
	} else {
		log.Printf("[cineclaw-ai] WARNING: OPENROUTER_API_KEY is not set. LLM synthesis will use fallback mode.")
	}
	if cfg.OmdbAPIKey != "" {
		log.Printf("[cineclaw-ai] OMDb API key configured")
	} else {
		log.Printf("[cineclaw-ai] WARNING: OMDB_API_KEY is not set. Critic scores may be limited.")
	}

	store, err := storage.NewStore(cfg.DataDir)
	if err != nil {
		log.Fatalf("[cineclaw-ai] Failed to initialize storage: %v", err)
	}
	defer store.Close()

	engine := critics.NewEngine(cfg, store)

	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"service": "cineclaw-ai",
			"version": "1.0.0",
		})
	})

	// Critics endpoint: GET /api/critics/{tconst}
	mux.HandleFunc("/api/critics/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		tconst := strings.TrimPrefix(r.URL.Path, "/api/critics/")
		tconst = strings.TrimSpace(tconst)
		if tconst == "" {
			http.Error(w, "Missing tconst parameter", http.StatusBadRequest)
			return
		}

		// Security check: alphanumeric tconst (e.g. tt15398776)
		if !strings.HasPrefix(tconst, "tt") || len(tconst) < 5 {
			http.Error(w, "Invalid tconst format", http.StatusBadRequest)
			return
		}

		summary, err := engine.GetCriticSummary(r.Context(), tconst)
		if err != nil {
			log.Printf("[api] Error getting summary for %s: %v", tconst, err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{
				"error": err.Error(),
			})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		json.NewEncoder(w).Encode(summary)
	})

	server := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      corsMiddleware(mux),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 45 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[cineclaw-ai] HTTP server error: %v", err)
		}
	}()

	log.Printf("[cineclaw-ai] Ready to serve requests on :%s", cfg.Port)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[cineclaw-ai] Shutting down gracefully...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[cineclaw-ai] Server forced to shutdown: %v", err)
	}

	log.Println("[cineclaw-ai] Stopped.")
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

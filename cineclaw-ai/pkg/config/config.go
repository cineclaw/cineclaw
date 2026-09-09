package config

import (
	"os"
	"path/filepath"
)

type Config struct {
	Port             string
	DataDir          string
	OpenRouterAPIKey string
	OmdbAPIKey       string
	TmdbAPIKey       string
	SummaryModel     string
	CompactModel     string
	AgentModel       string
}

func Load() *Config {
	port := os.Getenv("PORT")
	if port == "" {
		port = os.Getenv("PORT_AI")
	}
	if port == "" {
		port = "9120"
	}

	dataDir := os.Getenv("DATA_DIR")
	if dataDir == "" {
		dataDir = "./data/cineclaw-ai"
	} else if filepath.Base(dataDir) != "cineclaw-ai" {
		dataDir = filepath.Join(dataDir, "cineclaw-ai")
	}

	summaryModel := os.Getenv("AI_SUMMARY_MODEL")
	if summaryModel == "" {
		summaryModel = "google/gemini-2.5-flash"
	}

	compactModel := os.Getenv("AI_COMPACT_MODEL")
	if compactModel == "" {
		compactModel = "google/gemini-2.5-flash-lite"
	}

	agentModel := os.Getenv("AI_AGENT_MODEL")
	if agentModel == "" {
		agentModel = "google/gemini-2.5-flash"
	}

	return &Config{
		Port:             port,
		DataDir:          dataDir,
		OpenRouterAPIKey: os.Getenv("OPENROUTER_API_KEY"),
		OmdbAPIKey:       os.Getenv("OMDB_API_KEY"),
		TmdbAPIKey:       os.Getenv("TMDB_API_KEY"),
		SummaryModel:     summaryModel,
		CompactModel:     compactModel,
		AgentModel:       agentModel,
	}
}

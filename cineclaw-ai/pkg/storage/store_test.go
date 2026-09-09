package storage

import (
	"os"
	"testing"
	"time"
)

func TestStore_SaveAndGetSummary(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "cineclaw_ai_test_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	store, err := NewStore(tempDir)
	if err != nil {
		t.Fatalf("failed to create store: %v", err)
	}
	defer store.Close()

	rt := 95
	meta := 89
	imdb := 8.5
	summary := &CriticSummaryResponse{
		Tconst:         "tt0111161",
		Verdict:        "Культовая драма о надежде и дружбе.",
		Tone:           "strongly_positive",
		Scores: Scores{
			RottenTomatoes: &rt,
			Metacritic:     &meta,
			Imdb:           &imdb,
			ImdbVotes:      "2,800,000",
			Awards:         "Nominated for 7 Oscars",
		},
		Pros:           []string{"Превосходный сценарий", "Великолепная игра актеров"},
		Cons:           []string{"Неторопливый темп"},
		TargetAudience: "Всем ценителям классического кино",
		GeneratedAt:    time.Now().UTC(),
		Model:          "google/gemini-2.5-flash",
	}

	// Should be empty initially
	got, err := store.GetSummary("tt0111161")
	if err != nil {
		t.Fatalf("unexpected error on get: %v", err)
	}
	if got != nil {
		t.Fatalf("expected nil summary, got %+v", got)
	}

	// Save summary
	if err := store.SaveSummary("tt0111161", summary); err != nil {
		t.Fatalf("failed to save summary: %v", err)
	}

	// Retrieve summary
	got, err = store.GetSummary("tt0111161")
	if err != nil {
		t.Fatalf("failed to get summary: %v", err)
	}
	if got == nil {
		t.Fatalf("expected non-nil summary")
	}
	if !got.Cached {
		t.Errorf("expected Cached=true")
	}
	if got.Tconst != "tt0111161" {
		t.Errorf("expected tconst tt0111161, got %s", got.Tconst)
	}
	if got.Verdict != summary.Verdict {
		t.Errorf("verdict mismatch: got %q, want %q", got.Verdict, summary.Verdict)
	}
	if got.Scores.RottenTomatoes == nil || *got.Scores.RottenTomatoes != 95 {
		t.Errorf("expected RT 95, got %v", got.Scores.RottenTomatoes)
	}
}

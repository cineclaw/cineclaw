package storage

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

const (
	BucketCritics      = "critic_summaries"
	BucketChatSessions = "chat_sessions"
	BucketUserProfiles = "user_profiles"
)

type Scores struct {
	RottenTomatoes *int     `json:"rotten_tomatoes,omitempty"`
	Metacritic     *int     `json:"metacritic,omitempty"`
	Imdb           *float64 `json:"imdb,omitempty"`
	ImdbVotes      string   `json:"imdb_votes,omitempty"`
	Awards         string   `json:"awards,omitempty"`
}

type CriticSummaryResponse struct {
	Tconst         string    `json:"tconst"`
	Verdict        string    `json:"verdict"`
	Tone           string    `json:"tone"` // strongly_positive, positive, mixed, negative
	Scores         Scores    `json:"scores"`
	Pros           []string  `json:"pros"`
	Cons           []string  `json:"cons"`
	TargetAudience string    `json:"target_audience"`
	GeneratedAt    time.Time `json:"generated_at"`
	Model          string    `json:"model"`
	Cached         bool      `json:"cached,omitempty"`
}

type Store struct {
	db *bolt.DB
}

func NewStore(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "ai_store.db")
	db, err := bolt.Open(dbPath, 0600, &bolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("failed to open bbolt db at %s: %w", dbPath, err)
	}

	// Initialize buckets
	err = db.Update(func(tx *bolt.Tx) error {
		buckets := []string{BucketCritics, BucketChatSessions, BucketUserProfiles}
		for _, b := range buckets {
			if _, err := tx.CreateBucketIfNotExists([]byte(b)); err != nil {
				return fmt.Errorf("failed to create bucket %s: %w", b, err)
			}
		}
		return nil
	})
	if err != nil {
		db.Close()
		return nil, err
	}

	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

func (s *Store) GetSummary(tconst string) (*CriticSummaryResponse, error) {
	var summary *CriticSummaryResponse
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(BucketCritics))
		if b == nil {
			return nil
		}
		data := b.Get([]byte(tconst))
		if data == nil {
			return nil
		}
		var item CriticSummaryResponse
		if err := json.Unmarshal(data, &item); err != nil {
			return err
		}
		summary = &item
		summary.Cached = true
		return nil
	})
	return summary, err
}

func (s *Store) SaveSummary(tconst string, summary *CriticSummaryResponse) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(BucketCritics))
		if b == nil {
			return fmt.Errorf("bucket %s not found", BucketCritics)
		}
		data, err := json.Marshal(summary)
		if err != nil {
			return err
		}
		return b.Put([]byte(tconst), data)
	})
}

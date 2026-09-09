package omdb

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFetchScores(t *testing.T) {
	mockResponse := `{
		"Title": "Oppenheimer",
		"Year": "2023",
		"Ratings": [
			{"Source": "Internet Movie Database", "Value": "8.9/10"},
			{"Source": "Rotten Tomatoes", "Value": "93%"},
			{"Source": "Metacritic", "Value": "88/100"}
		],
		"Metascore": "88",
		"imdbRating": "8.9",
		"imdbVotes": "750,000",
		"Awards": "Won 7 Oscars",
		"Response": "True"
	}`

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("i") != "tt15398776" || r.URL.Query().Get("apikey") != "test_key" {
			http.Error(w, "invalid query", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(mockResponse))
	}))
	defer server.Close()

	client := NewClient("test_key")
	client.SetBaseURL(server.URL)
	client.httpClient = server.Client()

	scores, raw, err := client.FetchScores(context.Background(), "tt15398776")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if raw.Title != "Oppenheimer" {
		t.Errorf("expected Title Oppenheimer, got %s", raw.Title)
	}
	if scores.RottenTomatoes == nil || *scores.RottenTomatoes != 93 {
		t.Errorf("expected RT 93, got %v", scores.RottenTomatoes)
	}
	if scores.Metacritic == nil || *scores.Metacritic != 88 {
		t.Errorf("expected Metacritic 88, got %v", scores.Metacritic)
	}
	if scores.Imdb == nil || *scores.Imdb != 8.9 {
		t.Errorf("expected IMDb 8.9, got %v", scores.Imdb)
	}
	if scores.ImdbVotes != "750,000" {
		t.Errorf("expected IMDb votes 750,000, got %s", scores.ImdbVotes)
	}
	if scores.Awards != "Won 7 Oscars" {
		t.Errorf("expected Awards 'Won 7 Oscars', got %s", scores.Awards)
	}
}

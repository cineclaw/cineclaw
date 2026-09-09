package omdb

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"cineclaw-ai/pkg/httputil"
	"cineclaw-ai/pkg/storage"
)

type OmdbRating struct {
	Source string `json:"Source"`
	Value  string `json:"Value"`
}

type OmdbResponse struct {
	Title      string       `json:"Title"`
	Year       string       `json:"Year"`
	Ratings    []OmdbRating `json:"Ratings"`
	Metascore  string       `json:"Metascore"`
	ImdbRating string       `json:"imdbRating"`
	ImdbVotes  string       `json:"imdbVotes"`
	Awards     string       `json:"Awards"`
	Response   string       `json:"Response"`
	Error      string       `json:"Error"`
}

type Client struct {
	apiKey     string
	baseURL    string
	httpClient *http.Client
}

func NewClient(apiKey string) *Client {
	return &Client{
		apiKey:     apiKey,
		baseURL:    "http://www.omdbapi.com",
		httpClient: httputil.NewClient(8 * time.Second),
	}
}

func (c *Client) SetBaseURL(url string) {
	c.baseURL = url
}

func (c *Client) FetchScores(ctx context.Context, tconst string) (*storage.Scores, *OmdbResponse, error) {
	if c.apiKey == "" {
		return nil, nil, fmt.Errorf("omdb api key not configured")
	}

	url := fmt.Sprintf("%s/?i=%s&apikey=%s", c.baseURL, tconst, c.apiKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("omdb returned status %d", resp.StatusCode)
	}

	var data OmdbResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, nil, err
	}

	if data.Response == "False" {
		return nil, nil, fmt.Errorf("omdb error: %s", data.Error)
	}

	scores := &storage.Scores{
		ImdbVotes: data.ImdbVotes,
		Awards:    data.Awards,
	}

	// Parse ratings array
	for _, r := range data.Ratings {
		switch r.Source {
		case "Rotten Tomatoes":
			clean := strings.TrimSpace(strings.TrimSuffix(r.Value, "%"))
			if val, err := strconv.Atoi(clean); err == nil {
				scores.RottenTomatoes = &val
			}
		case "Metacritic":
			parts := strings.Split(r.Value, "/")
			if len(parts) > 0 {
				if val, err := strconv.Atoi(strings.TrimSpace(parts[0])); err == nil {
					scores.Metacritic = &val
				}
			}
		case "Internet Movie Database":
			parts := strings.Split(r.Value, "/")
			if len(parts) > 0 {
				if val, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64); err == nil {
					scores.Imdb = &val
				}
			}
		}
	}

	// Fallback to top-level fields if missing from array
	if scores.Metacritic == nil && data.Metascore != "" && data.Metascore != "N/A" {
		if val, err := strconv.Atoi(strings.TrimSpace(data.Metascore)); err == nil {
			scores.Metacritic = &val
		}
	}

	if scores.Imdb == nil && data.ImdbRating != "" && data.ImdbRating != "N/A" {
		if val, err := strconv.ParseFloat(strings.TrimSpace(data.ImdbRating), 64); err == nil {
			scores.Imdb = &val
		}
	}

	return scores, &data, nil
}

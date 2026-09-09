package tmdb

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"cineclaw-ai/pkg/httputil"
)

type TmdbFindResult struct {
	ID        int64  `json:"id"`
	MediaType string `json:"media_type"`
}

type TmdbFindResponse struct {
	MovieResults []TmdbFindResult `json:"movie_results"`
	TvResults    []TmdbFindResult `json:"tv_results"`
}

type TmdbAuthorDetails struct {
	Name     string   `json:"name"`
	Username string   `json:"username"`
	Rating   *float64 `json:"rating"`
}

type TmdbReviewItem struct {
	Author        string            `json:"author"`
	AuthorDetails TmdbAuthorDetails `json:"author_details"`
	Content       string            `json:"content"`
	CreatedAt     string            `json:"created_at"`
	URL           string            `json:"url"`
}

type TmdbReviewsResponse struct {
	ID           int64            `json:"id"`
	Results      []TmdbReviewItem `json:"results"`
	TotalResults int              `json:"total_results"`
}

type Client struct {
	apiKey     string
	httpClient *http.Client
}

func NewClient(apiKey string) *Client {
	return &Client{
		apiKey:     apiKey,
		httpClient: httputil.NewClient(8 * time.Second),
	}
}

func (c *Client) addAuth(req *http.Request) {
	if len(c.apiKey) > 40 {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	} else {
		q := req.URL.Query()
		q.Set("api_key", c.apiKey)
		req.URL.RawQuery = q.Encode()
	}
}

func (c *Client) FetchReviews(ctx context.Context, tconst string) ([]TmdbReviewItem, error) {
	if c.apiKey == "" {
		return nil, fmt.Errorf("tmdb api key not configured")
	}

	// 1. Find TMDB media by IMDb ID
	findURL := fmt.Sprintf("https://api.themoviedb.org/3/find/%s?external_source=imdb_id", tconst)
	findReq, err := http.NewRequestWithContext(ctx, http.MethodGet, findURL, nil)
	if err != nil {
		return nil, err
	}
	c.addAuth(findReq)

	findResp, err := c.httpClient.Do(findReq)
	if err != nil {
		return nil, err
	}
	defer findResp.Body.Close()

	if findResp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("tmdb find returned status %d", findResp.StatusCode)
	}

	var findData TmdbFindResponse
	if err := json.NewDecoder(findResp.Body).Decode(&findData); err != nil {
		return nil, err
	}

	var mediaID int64
	mediaType := "movie"

	if len(findData.MovieResults) > 0 {
		mediaID = findData.MovieResults[0].ID
	} else if len(findData.TvResults) > 0 {
		mediaID = findData.TvResults[0].ID
		mediaType = "tv"
	} else {
		return nil, fmt.Errorf("media not found on tmdb for %s", tconst)
	}

	// 2. Fetch reviews
	reviewsURL := fmt.Sprintf("https://api.themoviedb.org/3/%s/%d/reviews", mediaType, mediaID)
	reviewsReq, err := http.NewRequestWithContext(ctx, http.MethodGet, reviewsURL, nil)
	if err != nil {
		return nil, err
	}
	c.addAuth(reviewsReq)

	reviewsResp, err := c.httpClient.Do(reviewsReq)
	if err != nil {
		return nil, err
	}
	defer reviewsResp.Body.Close()

	if reviewsResp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("tmdb reviews returned status %d", reviewsResp.StatusCode)
	}

	var reviewsData TmdbReviewsResponse
	if err := json.NewDecoder(reviewsResp.Body).Decode(&reviewsData); err != nil {
		return nil, err
	}

	// Take up to 5 reviews
	results := reviewsData.Results
	if len(results) > 5 {
		results = results[:5]
	}

	return results, nil
}

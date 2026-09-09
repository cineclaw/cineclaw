package critics

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"cineclaw-ai/pkg/config"
	"cineclaw-ai/pkg/httputil"
	"cineclaw-ai/pkg/sources/omdb"
	"cineclaw-ai/pkg/sources/tmdb"
	"cineclaw-ai/pkg/storage"
)

type LLMOutput struct {
	Verdict        string   `json:"verdict"`
	Tone           string   `json:"tone"` // strongly_positive, positive, mixed, negative
	Pros           []string `json:"pros"`
	Cons           []string `json:"cons"`
	TargetAudience string   `json:"target_audience"`
}

type Engine struct {
	cfg        *config.Config
	store      *storage.Store
	omdbClient *omdb.Client
	tmdbClient *tmdb.Client
	httpClient *http.Client
}

func NewEngine(cfg *config.Config, store *storage.Store) *Engine {
	return &Engine{
		cfg:        cfg,
		store:      store,
		omdbClient: omdb.NewClient(cfg.OmdbAPIKey),
		tmdbClient: tmdb.NewClient(cfg.TmdbAPIKey),
		httpClient: httputil.NewClient(30 * time.Second),
	}
}

func (e *Engine) GetCriticSummary(ctx context.Context, tconst string) (*storage.CriticSummaryResponse, error) {
	// 1. Check bbolt cache first
	if cached, err := e.store.GetSummary(tconst); err == nil && cached != nil {
		return cached, nil
	}

	// 2. Fetch OMDb and TMDB in parallel
	var (
		wg         sync.WaitGroup
		scores     *storage.Scores
		omdbData   *omdb.OmdbResponse
		omdbErr    error
		reviews    []tmdb.TmdbReviewItem
		reviewsErr error
	)

	wg.Add(2)
	go func() {
		defer wg.Done()
		scores, omdbData, omdbErr = e.omdbClient.FetchScores(ctx, tconst)
		if omdbErr != nil {
			log.Printf("[omdb] Error fetching scores for %s: %v", tconst, omdbErr)
		}
	}()

	go func() {
		defer wg.Done()
		reviews, reviewsErr = e.tmdbClient.FetchReviews(ctx, tconst)
		if reviewsErr != nil {
			log.Printf("[tmdb] Error fetching reviews for %s: %v", tconst, reviewsErr)
		}
	}()

	wg.Wait()

	if scores == nil {
		scores = &storage.Scores{}
	}

	title := tconst
	year := ""
	if omdbData != nil {
		title = omdbData.Title
		year = omdbData.Year
	}

	// 3. Synthesize summary via OpenRouter if key is provided
	var llmOut *LLMOutput
	if e.cfg.OpenRouterAPIKey != "" {
		out, err := e.callOpenRouter(ctx, tconst, title, year, scores, reviews)
		if err != nil {
			log.Printf("[openrouter] Synthesis error for %s: %v", tconst, err)
		} else {
			llmOut = out
		}
	}

	// Fallback if LLM is unavailable or key not configured
	if llmOut == nil {
		llmOut = fallbackSummary(scores, title, year)
	}

	resp := &storage.CriticSummaryResponse{
		Tconst:         tconst,
		Verdict:        llmOut.Verdict,
		Tone:           llmOut.Tone,
		Scores:         *scores,
		Pros:           llmOut.Pros,
		Cons:           llmOut.Cons,
		TargetAudience: llmOut.TargetAudience,
		GeneratedAt:    time.Now().UTC(),
		Model:          e.cfg.SummaryModel,
		Cached:         false,
	}

	// 4. Save to bbolt cache
	if err := e.store.SaveSummary(tconst, resp); err != nil {
		log.Printf("[storage] Failed to cache summary for %s: %v", tconst, err)
	}

	return resp, nil
}

func (e *Engine) callOpenRouter(
	ctx context.Context,
	tconst, title, year string,
	scores *storage.Scores,
	reviews []tmdb.TmdbReviewItem,
) (*LLMOutput, error) {
	sysPrompt := `Ты — ведущий русскоязычный кинокритик и киноаналитик.
Твоя задача — объективно проанализировать фильм на основе оценок прессы и мнений зрителей, и составить емкую, профессиональную выжимку консенсуса.
Отвечай СТРОГО валидным JSON-объектом по следующей схеме:
{
  "verdict": "Емкий, точный вердикт фильму от лица кинокритики (1-2 сильных предложения)",
  "tone": "strongly_positive" | "positive" | "mixed" | "negative",
  "pros": ["Главное достоинство 1", "Достоинство 2", "Достоинство 3"],
  "cons": ["Слабое место 1", "Слабое место 2"],
  "target_audience": "Кому фильм обязательно понравится, а кому лучше пропустить (1-2 предложения)"
}
Пиши живым, выразительным литературным языком без пустых штампов и спойлеров.`

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("Фильм: %s (%s)\nIMDb ID: %s\n", title, year, tconst))

	if scores.RottenTomatoes != nil {
		sb.WriteString(fmt.Sprintf("Rotten Tomatoes: %d%%\n", *scores.RottenTomatoes))
	}
	if scores.Metacritic != nil {
		sb.WriteString(fmt.Sprintf("Metacritic: %d/100\n", *scores.Metacritic))
	}
	if scores.Imdb != nil {
		sb.WriteString(fmt.Sprintf("IMDb: %.1f/10\n", *scores.Imdb))
	}
	if scores.Awards != "" && scores.Awards != "N/A" {
		sb.WriteString(fmt.Sprintf("Награды: %s\n", scores.Awards))
	}

	if len(reviews) > 0 {
		sb.WriteString("\nВыдержки из рецензий:\n")
		for i, r := range reviews {
			content := strings.TrimSpace(r.Content)
			if len(content) > 600 {
				content = content[:600] + "..."
			}
			sb.WriteString(fmt.Sprintf("--- Рецензия %d (%s) ---\n%s\n", i+1, r.Author, content))
		}
	} else {
		sb.WriteString("\n(Тексты сторонних рецензий отсутствуют. Используй свои глубокие энциклопедические знания о восприятии этого фильма критиками и зрителями).\n")
	}

	reqPayload := map[string]any{
		"model": e.cfg.SummaryModel,
		"messages": []map[string]string{
			{"role": "system", "content": sysPrompt},
			{"role": "user", "content": sb.String()},
		},
		"max_tokens": 1500,
		"response_format": map[string]string{
			"type": "json_object",
		},
	}

	bodyBytes, err := json.Marshal(reqPayload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://openrouter.ai/api/v1/chat/completions", bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+e.cfg.OpenRouterAPIKey)
	req.Header.Set("HTTP-Referer", "https://cineclaw.app")
	req.Header.Set("X-Title", "CineClaw")
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read openrouter response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("openrouter error (HTTP %d): %s", resp.StatusCode, string(respBytes))
	}

	var chatResp struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}

	if err := json.Unmarshal(respBytes, &chatResp); err != nil {
		return nil, fmt.Errorf("failed to decode chat response: %w (body: %s)", err, string(respBytes))
	}

	if len(chatResp.Choices) == 0 {
		return nil, fmt.Errorf("openrouter returned empty choices")
	}

	rawContent := strings.TrimSpace(chatResp.Choices[0].Message.Content)
	if strings.HasPrefix(rawContent, "```json") {
		rawContent = strings.TrimPrefix(rawContent, "```json")
	} else if strings.HasPrefix(rawContent, "```") {
		rawContent = strings.TrimPrefix(rawContent, "```")
	}
	rawContent = strings.TrimSuffix(rawContent, "```")
	rawContent = strings.TrimSpace(rawContent)

	var output LLMOutput
	if err := json.Unmarshal([]byte(rawContent), &output); err != nil {
		return nil, fmt.Errorf("failed to parse LLM JSON: %w (content: %s)", err, rawContent)
	}

	return &output, nil
}

func fallbackSummary(scores *storage.Scores, title, year string) *LLMOutput {
	tone := "positive"
	if scores.RottenTomatoes != nil {
		if *scores.RottenTomatoes >= 85 {
			tone = "strongly_positive"
		} else if *scores.RottenTomatoes >= 60 {
			tone = "positive"
		} else if *scores.RottenTomatoes >= 40 {
			tone = "mixed"
		} else {
			tone = "negative"
		}
	}

	verdict := fmt.Sprintf("%s (%s) получил признание зрителей и критиков.", title, year)
	if scores.RottenTomatoes != nil && scores.Metacritic != nil {
		verdict = fmt.Sprintf("Рейтинг одобрения Rotten Tomatoes: %d%%, оценка Metacritic: %d/100.", *scores.RottenTomatoes, *scores.Metacritic)
	}

	return &LLMOutput{
		Verdict:        verdict,
		Tone:           tone,
		Pros:           []string{"Высокие оценки зрителей", "Признание критиков"},
		Cons:           []string{"Восприятие зависит от жанровых предпочтений"},
		TargetAudience: "Рекомендуется любителям качественного жанрового кинематографа.",
	}
}

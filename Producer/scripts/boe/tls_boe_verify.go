package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	kitlog "github.com/go-kit/kit/log"
	"github.com/volcengine/volc-sdk-golang/service/tls"
	"github.com/volcengine/volc-sdk-golang/service/tls/innerlogger"
)

type verifyConfig struct {
	endpoint        string
	region          string
	ak              string
	sk              string
	token           string
	topic           string
	runID           string
	profile         string
	expectCount     int
	startMS         int64
	endMS           int64
	timeout         time.Duration
	duplicatePolicy string
}

type observedLogs struct {
	matches      int
	bySequence   map[int]int
	shards       int
	pages        int
	metadataSeen int
}

func requiredEnvironment(name string) (string, error) {
	value := os.Getenv(name)
	if value == "" {
		return "", fmt.Errorf("missing environment variable: %s", name)
	}
	return value, nil
}

func environmentInt(name string) (int, error) {
	value, err := requiredEnvironment(name)
	if err != nil {
		return 0, err
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return parsed, nil
}

func environmentInt64(name string) (int64, error) {
	value, err := requiredEnvironment(name)
	if err != nil {
		return 0, err
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return parsed, nil
}

func loadConfig() (verifyConfig, error) {
	var config verifyConfig
	var err error
	if config.endpoint, err = requiredEnvironment("LOG_SERVICE_ENDPOINT"); err != nil {
		return config, err
	}
	if config.region, err = requiredEnvironment("LOG_SERVICE_REGION"); err != nil {
		return config, err
	}
	if config.ak, err = requiredEnvironment("LOG_SERVICE_AK"); err != nil {
		return config, err
	}
	if config.sk, err = requiredEnvironment("LOG_SERVICE_SK"); err != nil {
		return config, err
	}
	if config.topic, err = requiredEnvironment("LOG_SERVICE_TOPIC"); err != nil {
		return config, err
	}
	if config.runID, err = requiredEnvironment("BOE_VERIFY_RUN_ID"); err != nil {
		return config, err
	}
	if config.expectCount, err = environmentInt("BOE_VERIFY_EXPECT_COUNT"); err != nil {
		return config, err
	}
	if config.startMS, err = environmentInt64("BOE_VERIFY_START_MS"); err != nil {
		return config, err
	}
	if config.endMS, err = environmentInt64("BOE_VERIFY_END_MS"); err != nil {
		return config, err
	}
	config.token = os.Getenv("LOG_SERVICE_TOKEN")
	config.profile = os.Getenv("BOE_VERIFY_PROFILE")
	if config.profile == "" {
		config.profile = "field_fidelity"
	}
	config.duplicatePolicy = os.Getenv("BOE_VERIFY_DUPLICATE_POLICY")
	if config.duplicatePolicy == "" {
		config.duplicatePolicy = "forbid"
	}
	timeoutMS := int64(120000)
	if value := os.Getenv("BOE_VERIFY_TIMEOUT_MS"); value != "" {
		timeoutMS, err = strconv.ParseInt(value, 10, 64)
		if err != nil || timeoutMS <= 0 {
			return config, errors.New("BOE_VERIFY_TIMEOUT_MS must be positive")
		}
	}
	config.timeout = time.Duration(timeoutMS) * time.Millisecond
	if config.expectCount <= 0 || config.startMS <= 0 || config.endMS <= config.startMS {
		return config, errors.New("invalid expected count or time range")
	}
	if config.profile != "field_fidelity" && config.profile != "recovery" && config.profile != "large_payload" {
		return config, errors.New("BOE_VERIFY_PROFILE must be field_fidelity, recovery, or large_payload")
	}
	if config.duplicatePolicy != "forbid" && config.duplicatePolicy != "allow" && config.duplicatePolicy != "require" {
		return config, errors.New("BOE_VERIFY_DUPLICATE_POLICY must be forbid, allow, or require")
	}
	return config, nil
}

func stringValue(values map[string]interface{}, key string) string {
	value, ok := values[key]
	if !ok || value == nil {
		return ""
	}
	return fmt.Sprint(value)
}

func expectedFieldValues(sequence int, config verifyConfig) map[string]string {
	values := map[string]string{
		"run_id": config.runID,
		"seq":    strconv.Itoa(sequence),
	}
	if config.profile == "recovery" {
		values["scenario"] = os.Getenv("BOE_VERIFY_EXPECT_SCENARIO")
		return values
	}
	if config.profile == "large_payload" {
		const maxRawBytes = 19 * 512 * 1024
		const scenario = "near_9_5_mib"
		fixedRawBytes := len("run_id") + len(config.runID) +
			len("scenario") + len(scenario) +
			len("seq") + len("0") + len("payload")
		values["scenario"] = scenario
		values["payload"] = strings.Repeat("x", maxRawBytes-fixedRawBytes)
		return values
	}
	values["scenario"] = "field_fidelity"
	values["field_string"] = fmt.Sprintf("hello-中文-🙂-%d", sequence)
	values["field_signed"] = strconv.FormatInt(int64(-1<<63)+int64(sequence), 10)
	values["field_unsigned"] = strconv.FormatUint(^uint64(0)-uint64(sequence), 10)
	values["field_double"] = strconv.FormatFloat(12345.625+float64(sequence), 'f', -1, 64)
	values["field_bool"] = strconv.FormatBool(sequence%2 == 0)
	values["field_null"] = "null"
	values["field_array"] = fmt.Sprintf("[\"a\\\"b\",%d,true,null]", sequence)
	values["field_dictionary"] = fmt.Sprintf("{\"a\":%d,\"z\":\"line1\\nline2\\\\tail\"}", sequence)
	values["field_utf8"] = fmt.Sprintf("raw-你好-%d", sequence)
	values["field_empty"] = ""
	return values
}

func validateFields(fields map[string]string, config verifyConfig) (int, error) {
	if fields["run_id"] != config.runID {
		return 0, errors.New("run_id mismatch")
	}
	sequence, err := strconv.Atoi(fields["seq"])
	if err != nil || sequence < 0 || sequence >= config.expectCount {
		return 0, errors.New("seq is missing or outside expected range")
	}
	for key, expected := range expectedFieldValues(sequence, config) {
		actual, exists := fields[key]
		if !exists {
			return 0, fmt.Errorf("seq=%d missing field=%s", sequence, key)
		}
		if actual != expected {
			return 0, fmt.Errorf("seq=%d field mismatch=%s", sequence, key)
		}
	}
	return sequence, nil
}

func validateObserved(observed observedLogs, config verifyConfig) error {
	if len(observed.bySequence) != config.expectCount {
		return fmt.Errorf("unique sequence count=%d expected=%d", len(observed.bySequence), config.expectCount)
	}
	duplicates := observed.matches - len(observed.bySequence)
	switch config.duplicatePolicy {
	case "forbid":
		if duplicates != 0 {
			return fmt.Errorf("duplicates=%d expected=0", duplicates)
		}
	case "require":
		if duplicates <= 0 {
			return errors.New("duplicates are required but none were observed")
		}
	}
	for sequence := 0; sequence < config.expectCount; sequence++ {
		if observed.bySequence[sequence] == 0 {
			return fmt.Errorf("missing seq=%d", sequence)
		}
	}
	return nil
}

func verifySearch(client tls.Client, config verifyConfig) (observedLogs, error) {
	deadline := time.Now().Add(config.timeout)
	for {
		observed := observedLogs{bySequence: map[int]int{}}
		request := &tls.SearchLogsRequest{
			TopicID:   config.topic,
			Query:     "*",
			StartTime: config.startMS,
			EndTime:   config.endMS,
			Limit:     500,
			Sort:      "asc",
		}
		for {
			response, err := client.SearchLogsV2(request)
			if err != nil {
				return observed, fmt.Errorf("SearchLogsV2 failed: %T", err)
			}
			observed.pages++
			for _, item := range response.Logs {
				if stringValue(item, "run_id") != config.runID {
					continue
				}
				fields := make(map[string]string, len(item))
				for key := range item {
					fields[key] = stringValue(item, key)
				}
				sequence, err := validateFields(fields, config)
				if err != nil {
					return observed, err
				}
				observed.matches++
				observed.bySequence[sequence]++
			}
			if response.ListOver || len(response.Logs) == 0 || response.Context == "" {
				break
			}
			request.Context = response.Context
		}
		if err := validateObserved(observed, config); err == nil {
			return observed, nil
		} else if time.Now().After(deadline) {
			return observed, err
		}
		time.Sleep(time.Second)
	}
}

func normalizeTimestampMilliseconds(value int64) int64 {
	if value > 0 && value < 10000000000 {
		return value * 1000
	}
	if value >= 1000000000000000 {
		return value / 1000000
	}
	return value
}

func validateGroupMetadata(source, fileName string, tags map[string]string, config verifyConfig) error {
	if config.profile == "recovery" {
		if source != "simulator-recovery" {
			return errors.New("recovery source metadata mismatch")
		}
		return nil
	}
	if config.profile == "large_payload" {
		if source != "ios-boe-large" || fileName != "producer-large.log" {
			return errors.New("large-payload source/file metadata mismatch")
		}
		if tags["sdk"] != "ios" || tags["suite"] != "boe-large" {
			return errors.New("large-payload tags mismatch")
		}
		return nil
	}
	if source != "ios-boe-business" || fileName != "producer-e2e.log" {
		return errors.New("field-fidelity source/file metadata mismatch")
	}
	if tags["sdk"] != "ios" || tags["suite"] != "boe-business" {
		return errors.New("field-fidelity tags mismatch")
	}
	return nil
}

func verifyConsume(client tls.Client, config verifyConfig) (observedLogs, error) {
	observed := observedLogs{bySequence: map[int]int{}}
	shards, err := client.DescribeShards(&tls.DescribeShardsRequest{
		TopicID:  config.topic,
		PageSize: 100,
	})
	if err != nil {
		return observed, fmt.Errorf("DescribeShards failed: %T", err)
	}
	observed.shards = len(shards.Shards)
	for _, shard := range shards.Shards {
		if shard == nil || strings.ToLower(shard.Status) != "readwrite" {
			continue
		}
		start, err := client.DescribeCursor(&tls.DescribeCursorRequest{
			TopicID: config.topic,
			ShardID: int(shard.ShardID),
			From:    strconv.FormatInt(config.startMS/1000-1, 10),
		})
		if err != nil {
			return observed, fmt.Errorf("DescribeCursor(start) failed: %T", err)
		}
		end, err := client.DescribeCursor(&tls.DescribeCursorRequest{
			TopicID: config.topic,
			ShardID: int(shard.ShardID),
			From:    strconv.FormatInt(config.endMS/1000+1, 10),
		})
		if err != nil {
			return observed, fmt.Errorf("DescribeCursor(end) failed: %T", err)
		}
		cursor := start.Cursor
		for page := 0; cursor != end.Cursor && page < 10000; page++ {
			groupLimit := 1000
			compression := tls.LZ4Compression
			response, err := client.ConsumeLogs(&tls.ConsumeLogsRequest{
				TopicID:       config.topic,
				ShardID:       int(shard.ShardID),
				Cursor:        cursor,
				EndCursor:     &end.Cursor,
				LogGroupCount: &groupLimit,
				Compression:   &compression,
			})
			if err != nil {
				return observed, fmt.Errorf("ConsumeLogs failed: %T", err)
			}
			observed.pages++
			if response.Logs != nil {
				for _, group := range response.Logs.GetLogGroups() {
					if group == nil {
						continue
					}
					tags := map[string]string{}
					for _, tag := range group.GetLogTags() {
						if tag != nil {
							tags[tag.GetKey()] = tag.GetValue()
						}
					}
					groupMatched := false
					for _, logItem := range group.GetLogs() {
						if logItem == nil {
							continue
						}
						fields := map[string]string{}
						for _, content := range logItem.GetContents() {
							if content != nil {
								fields[content.GetKey()] = content.GetValue()
							}
						}
						if fields["run_id"] != config.runID {
							continue
						}
						sequence, err := validateFields(fields, config)
						if err != nil {
							return observed, err
						}
						timestampMS := normalizeTimestampMilliseconds(logItem.GetTime())
						if timestampMS < config.startMS-60000 || timestampMS > config.endMS+60000 {
							return observed, fmt.Errorf("seq=%d timestamp outside expected window", sequence)
						}
						groupMatched = true
						observed.matches++
						observed.bySequence[sequence]++
					}
					if groupMatched {
						if err := validateGroupMetadata(group.GetSource(), group.GetFileName(), tags, config); err != nil {
							return observed, err
						}
						observed.metadataSeen++
					}
				}
			}
			if response.Cursor == "" || response.Cursor == cursor {
				if response.Count == 0 {
					break
				}
				return observed, errors.New("ConsumeLogs cursor did not advance")
			}
			cursor = response.Cursor
			if response.Count == 0 {
				break
			}
		}
	}
	if err := validateObserved(observed, config); err != nil {
		return observed, err
	}
	if observed.metadataSeen == 0 {
		return observed, errors.New("no matching LogGroup metadata was observed")
	}
	return observed, nil
}

func main() {
	innerlogger.DefaultLogger.Logger = kitlog.NewNopLogger()
	config, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "BOE_VERIFY_CONFIG_ERROR reason=%s\n", err)
		os.Exit(2)
	}
	client := tls.NewClient(config.endpoint, config.ak, config.sk, config.token, config.region)
	search, err := verifySearch(client, config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "BOE_SEARCH_VERIFY_FAILED reason=%s matches=%d unique=%d\n", err, search.matches, len(search.bySequence))
		os.Exit(3)
	}
	fmt.Printf("BOE_SEARCH_VERIFY_OK run_id=%s matches=%d unique=%d duplicates=%d pages=%d\n",
		config.runID, search.matches, len(search.bySequence), search.matches-len(search.bySequence), search.pages)
	consume, err := verifyConsume(client, config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "BOE_CONSUME_VERIFY_FAILED reason=%s matches=%d unique=%d shards=%d pages=%d\n",
			err, consume.matches, len(consume.bySequence), consume.shards, consume.pages)
		os.Exit(4)
	}
	fmt.Printf("BOE_CONSUME_VERIFY_OK run_id=%s matches=%d unique=%d duplicates=%d shards=%d pages=%d metadata_groups=%d\n",
		config.runID, consume.matches, len(consume.bySequence), consume.matches-len(consume.bySequence), consume.shards, consume.pages, consume.metadataSeen)
}

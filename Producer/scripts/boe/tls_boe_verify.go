package main

import (
	"encoding/json"
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
	endpoint         string
	region           string
	ak               string
	sk               string
	token            string
	topic            string
	runID            string
	profile          string
	scenario         string
	persistence      string
	expectCount      int
	startMS          int64
	endMS            int64
	timeout          time.Duration
	duplicatePolicy  string
	minMatchedShards int
}

type observedLogs struct {
	matches        int
	bySequence     map[int]int
	shards         int
	pages          int
	metadataSeen   int
	matchedShards  map[int]struct{}
	hashSlotShards map[int]int
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

func optionalEnvironment(name, alias string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return os.Getenv(alias)
}

func safeIdentifier(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if (character < 'a' || character > 'z') &&
			(character < '0' || character > '9') &&
			character != '_' && character != '-' {
			return false
		}
	}
	return true
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
	config.scenario = optionalEnvironment("BOE_VERIFY_EXPECT_SCENARIO", "BOE_VERIFY_SCENARIO")
	config.persistence = optionalEnvironment("BOE_VERIFY_EXPECT_PERSISTENCE", "BOE_VERIFY_PERSISTENCE")
	// Accept both forms for the new verifier: the explicit `volume` profile
	// plus a scenario, and a direct volume profile name. The latter is useful
	// when the summary row already supplies the profile as its only selector.
	if config.profile != "volume" {
		if _, ok := volumePayloadLength(config.profile); ok {
			if config.scenario != "" && config.scenario != config.profile {
				return config, errors.New("volume profile and scenario must identify the same profile")
			}
			config.scenario = config.profile
			config.profile = "volume"
		}
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
	if value := optionalEnvironment("BOE_VERIFY_MIN_MATCHED_SHARDS", "BOE_VERIFY_MIN_SHARDS"); value != "" {
		config.minMatchedShards, err = strconv.Atoi(value)
		if err != nil || config.minMatchedShards < 0 {
			return config, errors.New("BOE_VERIFY_MIN_MATCHED_SHARDS must be non-negative")
		}
	}
	if config.expectCount <= 0 || config.startMS <= 0 || config.endMS <= config.startMS {
		return config, errors.New("invalid expected count or time range")
	}
	if config.profile != "field_fidelity" && config.profile != "recovery" && config.profile != "large_payload" && config.profile != "volume" {
		return config, errors.New("BOE_VERIFY_PROFILE must be field_fidelity, recovery, large_payload, or volume")
	}
	if config.duplicatePolicy != "forbid" && config.duplicatePolicy != "allow" && config.duplicatePolicy != "require" {
		return config, errors.New("BOE_VERIFY_DUPLICATE_POLICY must be forbid, allow, or require")
	}
	if config.profile == "volume" {
		if !safeIdentifier(config.runID) {
			return config, errors.New("BOE_VERIFY_RUN_ID must be a lowercase safe identifier for volume")
		}
		if config.scenario == "" {
			return config, errors.New("BOE_VERIFY_EXPECT_SCENARIO is required for volume")
		}
		if !safeIdentifier(config.scenario) {
			return config, errors.New("BOE_VERIFY_EXPECT_SCENARIO must be a lowercase safe identifier for volume")
		}
		if _, ok := volumePayloadLength(config.scenario); !ok {
			return config, errors.New("BOE_VERIFY_EXPECT_SCENARIO is not a supported volume profile")
		}
		switch config.persistence {
		case "disabled", "memory", "buffered", "sync":
		default:
			return config, errors.New("BOE_VERIFY_EXPECT_PERSISTENCE must be disabled, memory, buffered, or sync for volume")
		}
		if config.profile == "volume" && config.scenario == "hash-routing" && config.minMatchedShards == 0 {
			// Hash routing is meaningful only when the run proves distribution.
			config.minMatchedShards = 8
		}
	}
	return config, nil
}

func stringValue(values map[string]interface{}, key string) string {
	value, ok := values[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	case json.Number:
		return string(typed)
	case []byte:
		return string(typed)
	default:
		// SearchLogsV2 normally returns log values as strings. Keep a
		// deterministic fallback for a service deployment that decodes a
		// structured value instead; do not print this value in diagnostics.
		if encoded, err := json.Marshal(typed); err == nil {
			return string(encoded)
		}
		return fmt.Sprint(value)
	}
}

const (
	volumeHashSlotCount            = 256
	volumePayloadMultiplier uint64 = 6364136223846793005
	volumePayloadIncrement  uint64 = 1442695040888963407
)

var volumePayloadAlphabet = []byte("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_")

func volumePayload(sequence, length int) string {
	state := uint64(sequence) + uint64(0x9E3779B97F4A7C15)
	result := make([]byte, length)
	for index := range result {
		state = state*volumePayloadMultiplier + volumePayloadIncrement
		result[index] = volumePayloadAlphabet[state%uint64(len(volumePayloadAlphabet))]
	}
	return string(result)
}

func volumeComplexValue(sequence int) string {
	boolean := "false"
	if sequence%2 == 0 {
		boolean = "true"
	}
	return fmt.Sprintf(
		`{"array":["元素🙂",%d,%s,null],"bytes":"字节-🙂-%d","count":%d,"nested":{"a":3.14159,"区域":"华东"}}`,
		sequence, boolean, sequence, sequence)
}

func volumePayloadLength(profile string) (int, bool) {
	switch profile {
	case "default-lz4":
		return 1024, true
	case "no-compression-count":
		return 2048, true
	case "buffered-high-concurrency", "sync-max-count", "complex-data-default", "complex-data-custom", "hash-routing":
		return 512, true
	case "hot-update", "auth-retain-bulk":
		return 768, true
	case "mixed-immediate":
		return 256, true
	default:
		return 0, false
	}
}

func expectedFieldValues(sequence int, config verifyConfig) map[string]string {
	values := map[string]string{
		"run_id": config.runID,
		"seq":    strconv.Itoa(sequence),
	}
	if config.profile == "recovery" {
		values["scenario"] = config.scenario
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
	if config.profile == "volume" {
		payloadLength, _ := volumePayloadLength(config.scenario)
		values["scenario"] = config.scenario
		values["persistence"] = config.persistence
		values["profile"] = config.scenario
		values["payload_size"] = strconv.Itoa(payloadLength)
		values["payload"] = volumePayload(sequence, payloadLength)
		switch config.scenario {
		case "hash-routing":
			values["hash_slot"] = strconv.Itoa(sequence % volumeHashSlotCount)
		case "mixed-immediate":
			if sequence%2 == 0 {
				values["admission_mode"] = "immediate"
			} else {
				values["admission_mode"] = "normal"
			}
		case "complex-data-default", "complex-data-custom":
			values["unicode"] = fmt.Sprintf("业务-日志-🙂-%d", sequence)
			values["complex"] = volumeComplexValue(sequence)
		case "hot-update":
			if sequence < config.expectCount/2 {
				values["update_phase"] = "before"
			} else {
				values["update_phase"] = "after"
			}
		case "auth-retain-bulk":
			values["auth_phase"] = "retain-bulk"
		}
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
	if config.profile == "volume" {
		eventTime, err := strconv.ParseInt(fields["event_time_ms"], 10, 64)
		if err != nil || eventTime <= 0 || eventTime%1000 != 0 {
			return 0, fmt.Errorf("seq=%d event_time_ms is invalid", sequence)
		}
		if eventTime < config.startMS-60000 || eventTime > config.endMS+60000 {
			return 0, fmt.Errorf("seq=%d event_time_ms is outside expected window", sequence)
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

func validateMatchedShardTopology(observed observedLogs, config verifyConfig) error {
	if config.minMatchedShards > 0 && len(observed.matchedShards) < config.minMatchedShards {
		return fmt.Errorf("matched shard count=%d expected at least=%d",
			len(observed.matchedShards), config.minMatchedShards)
	}
	if config.profile != "volume" || config.scenario != "hash-routing" {
		return nil
	}
	// The harness emits every slot in order for the 256-key routing run. A
	// missing slot would mean that the service silently dropped or rerouted a
	// subset even if the sequence count happened to be complete.
	requiredSlots := config.expectCount
	if requiredSlots > volumeHashSlotCount {
		requiredSlots = volumeHashSlotCount
	}
	if len(observed.hashSlotShards) < requiredSlots {
		return fmt.Errorf("hash slot mappings=%d expected at least=%d",
			len(observed.hashSlotShards), requiredSlots)
	}
	for slot := 0; slot < requiredSlots; slot++ {
		if _, ok := observed.hashSlotShards[slot]; !ok {
			return fmt.Errorf("missing hash slot=%d mapping", slot)
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
	if config.profile == "volume" {
		expectedSource := "ios-boe-volume"
		expectedFileName := "producer-volume.log"
		expectedTags := map[string]string{
			"sdk":     "ios",
			"suite":   "boe-volume",
			"profile": config.scenario,
		}
		if config.scenario == "complex-data-default" {
			expectedSource = "iOS"
			expectedFileName = ""
			expectedTags = map[string]string{}
		} else if config.scenario == "complex-data-custom" {
			expectedSource = "iOS-业务-🙂"
			expectedFileName = "业务/volume.log"
			expectedTags["locale"] = "zh-CN"
		}
		if source != expectedSource || fileName != expectedFileName {
			return errors.New("volume source/file metadata mismatch")
		}
		for key, expected := range expectedTags {
			if tags[key] != expected {
				return errors.New("volume metadata tags mismatch")
			}
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
	observed := observedLogs{
		bySequence:     map[int]int{},
		matchedShards:  map[int]struct{}{},
		hashSlotShards: map[int]int{},
	}
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
						if config.profile == "volume" {
							eventTimeMS, parseErr := strconv.ParseInt(fields["event_time_ms"], 10, 64)
							if parseErr != nil || timestampMS/1000 != eventTimeMS/1000 {
								return observed, fmt.Errorf("seq=%d timestamp does not match event_time_ms", sequence)
							}
						} else if timestampMS < config.startMS-60000 || timestampMS > config.endMS+60000 {
							return observed, fmt.Errorf("seq=%d timestamp outside expected window", sequence)
						}
						groupMatched = true
						observed.matches++
						observed.bySequence[sequence]++
						if config.profile == "volume" {
							if config.scenario == "hash-routing" {
								slot, parseErr := strconv.Atoi(fields["hash_slot"])
								if parseErr != nil || slot < 0 || slot >= volumeHashSlotCount {
									return observed, fmt.Errorf("seq=%d hash slot is invalid", sequence)
								}
								if previous, exists := observed.hashSlotShards[slot]; exists && previous != int(shard.ShardID) {
									return observed, fmt.Errorf("hash slot=%d maps to multiple shards", slot)
								}
								observed.hashSlotShards[slot] = int(shard.ShardID)
							}
						}
					}
					if groupMatched {
						if err := validateGroupMetadata(group.GetSource(), group.GetFileName(), tags, config); err != nil {
							return observed, err
						}
						observed.metadataSeen++
						observed.matchedShards[int(shard.ShardID)] = struct{}{}
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
	if err := validateMatchedShardTopology(observed, config); err != nil {
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
		fmt.Fprintf(os.Stderr, "BOE_CONSUME_VERIFY_FAILED reason=%s matches=%d unique=%d shards=%d matched_shards=%d pages=%d\n",
			err, consume.matches, len(consume.bySequence), consume.shards, len(consume.matchedShards), consume.pages)
		os.Exit(4)
	}
	fmt.Printf("BOE_CONSUME_VERIFY_OK run_id=%s matches=%d unique=%d duplicates=%d shards=%d matched_shards=%d hash_slots=%d pages=%d metadata_groups=%d\n",
		config.runID, consume.matches, len(consume.bySequence), consume.matches-len(consume.bySequence), consume.shards, len(consume.matchedShards), len(consume.hashSlotShards), consume.pages, consume.metadataSeen)
}

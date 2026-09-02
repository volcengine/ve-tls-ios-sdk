package main

import "testing"

func TestSafeIdentifier(t *testing.T) {
	valid := []string{
		"buffered-high-concurrency",
		"device-instruments-online-30m-ef1b69e-20260902T050836Z",
		"ABC_123",
	}
	for _, value := range valid {
		if !safeIdentifier(value) {
			t.Fatalf("safeIdentifier(%q) = false, want true", value)
		}
	}

	invalid := []string{"", "contains space", "path/component", "line\nbreak", "query=value"}
	for _, value := range invalid {
		if safeIdentifier(value) {
			t.Fatalf("safeIdentifier(%q) = true, want false", value)
		}
	}
}

func TestVolumeExpectedFieldsAllowIndependentLogScenario(t *testing.T) {
	config := verifyConfig{
		runID:       "run-20260902T050836Z",
		profile:     "volume",
		scenario:    "buffered-high-concurrency",
		logScenario: "device_instruments_online_30m",
		persistence: "buffered",
	}
	values := expectedFieldValues(7, config)
	if got := values["scenario"]; got != config.logScenario {
		t.Fatalf("scenario = %q, want %q", got, config.logScenario)
	}
	if got := values["profile"]; got != config.scenario {
		t.Fatalf("profile = %q, want %q", got, config.scenario)
	}
}

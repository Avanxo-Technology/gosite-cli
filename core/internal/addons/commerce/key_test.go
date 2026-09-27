package commerce

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPublishableKeyReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "publishable_key")
	k := NewPublishableKey(path)

	if k.Reload() {
		t.Fatal("Reload reported loaded for a missing file")
	}
	if _, ok := k.Get(); ok {
		t.Fatal("Get returned a key before it was written")
	}

	if err := os.WriteFile(path, []byte("  pk_test_123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !k.Reload() {
		t.Fatal("Reload did not read the written file")
	}
	if key, ok := k.Get(); !ok || key != "pk_test_123" {
		t.Fatalf("Get = %q, %v; want the trimmed key", key, ok)
	}
}

func TestPublishableKeyRejectsEmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "publishable_key")
	if err := os.WriteFile(path, []byte("\n  \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	k := NewPublishableKey(path)
	if k.Reload() {
		t.Fatal("an empty file is not a key")
	}
}

func TestPublishableKeyWaitReturnsImmediatelyWhenPresent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "publishable_key")
	if err := os.WriteFile(path, []byte("pk_ready"), 0o600); err != nil {
		t.Fatal(err)
	}
	k := NewPublishableKey(path)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { k.Wait(ctx, time.Hour, nil); close(done) }()

	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("Wait did not return although the key was already present")
	}
}

func TestPublishableKeyWaitRetriesUntilWritten(t *testing.T) {
	path := filepath.Join(t.TempDir(), "publishable_key")
	k := NewPublishableKey(path)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { k.Wait(ctx, 10*time.Millisecond, nil); close(done) }()

	// The seed writes the file a moment after the site starts.
	time.Sleep(40 * time.Millisecond)
	if err := os.WriteFile(path, []byte("pk_late"), 0o600); err != nil {
		t.Fatal(err)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Wait did not return after the key appeared")
	}
	if key, ok := k.Get(); !ok || key != "pk_late" {
		t.Fatalf("Get = %q, %v", key, ok)
	}
}

func TestPublishableKeyWaitStopsOnCancel(t *testing.T) {
	k := NewPublishableKey(filepath.Join(t.TempDir(), "absent"))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { k.Wait(ctx, 10*time.Millisecond, nil); close(done) }()

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Wait ignored cancellation")
	}
}

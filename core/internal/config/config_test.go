package config

import "testing"

func TestCacheKeyPrefixIncludesEnvironment(t *testing.T) {
	tests := []struct {
		name string
		cfg  Config
		want string
	}{
		{"no environment keeps project prefix", Config{Project: "demo"}, "demo:cache:"},
		{"production is scoped", Config{Project: "demo", Environment: "production"}, "demo:production:cache:"},
		{"qa is scoped", Config{Project: "demo", Environment: "qa"}, "demo:qa:cache:"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.cfg.CacheKeyPrefix(); got != tt.want {
				t.Fatalf("CacheKeyPrefix() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestEnvironmentsNeverShareCachePrefix(t *testing.T) {
	prod := Config{Project: "demo", Environment: "production"}
	qa := Config{Project: "demo", Environment: "qa"}
	if prod.CacheKeyPrefix() == qa.CacheKeyPrefix() {
		t.Fatalf("production and qa share %q", prod.CacheKeyPrefix())
	}
}

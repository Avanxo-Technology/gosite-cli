// Package siteconfig reads gosite.yml, the file that declares a site.
//
// The format is deliberately a small subset of YAML - "key: value" lines and
// "- item" lists under a key with no value - because the gosite CLI reads and
// writes the same file from bash, with no YAML library. Anything outside that
// subset is an error here rather than a silent misread.
package siteconfig

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// File is the name gosite.Run looks for in the working directory.
const File = "gosite.yml"

// Config is a parsed gosite.yml.
type Config struct {
	Values map[string]string
	Lists  map[string][]string
}

// Addons is the enabled addon list.
func (c Config) Addons() []string { return c.Lists["addons"] }

// Load reads path. A missing file is not an error: it yields an empty Config,
// which is a site with no addons.
func Load(path string) (Config, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return Config{Values: map[string]string{}, Lists: map[string][]string{}}, nil
	}
	if err != nil {
		return Config{}, err
	}
	defer f.Close()
	return Parse(f)
}

// Parse reads the gosite.yml subset from r.
func Parse(r io.Reader) (Config, error) {
	c := Config{Values: map[string]string{}, Lists: map[string][]string{}}
	var list string // the key whose "- item" lines follow, if any
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		line := stripComment(sc.Text())
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") || trimmed == "-" {
			if list == "" {
				return Config{}, fmt.Errorf("%s:%d: list item outside a list", File, n)
			}
			item := unquote(strings.TrimSpace(strings.TrimPrefix(trimmed, "-")))
			if item != "" {
				c.Lists[list] = append(c.Lists[list], item)
			}
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			return Config{}, fmt.Errorf("%s:%d: nested values are not supported", File, n)
		}
		key, value, ok := strings.Cut(trimmed, ":")
		if !ok {
			return Config{}, fmt.Errorf("%s:%d: expected \"key: value\"", File, n)
		}
		key, value = strings.TrimSpace(key), unquote(strings.TrimSpace(value))
		switch {
		case value == "":
			list = key
			c.Lists[key] = c.Lists[key][:0:0]
		case value == "[]":
			list = ""
			c.Lists[key] = nil
		default:
			list = ""
			c.Values[key] = value
		}
	}
	return c, sc.Err()
}

func stripComment(line string) string {
	if i := strings.Index(line, " #"); i >= 0 {
		line = line[:i]
	}
	if strings.HasPrefix(strings.TrimSpace(line), "#") {
		return ""
	}
	return line
}

func unquote(s string) string {
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	return s
}

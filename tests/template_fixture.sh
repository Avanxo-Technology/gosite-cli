#!/usr/bin/env bash
# Fixture verification of the template tree (task 10.7).
#
# Renders src/templates/ with a fixed set of placeholder values - no docker,
# no project creation - and checks the output the way real sources are
# checked:
#   - no __PLACEHOLDER__ token survives rendering
#   - gofmt -l lists no Go file
#   - go vet reports no findings (module deps are downloaded)
#   - both compose files parse as YAML
#   - cockpit/config.php passes php -l
#
# Run from the repo root:  bash tests/template_fixture.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export GOSITE_HOME="${T}/home"
export GOSITE_WORKSPACE="${T}/sites"
export GOSITE_VERBOSE=0 GOSITE_ASSUME_YES=1
mkdir -p "${GOSITE_HOME}" "${GOSITE_WORKSPACE}"

C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM='' C_BOLD='' C_NC=''
export C_RED C_GREEN C_YELLOW C_BLUE C_CYAN C_DIM C_BOLD C_NC
export GOSITE_ROOT="${PWD}/src"

# shellcheck source=../src/lib/config.sh
source src/lib/config.sh
# shellcheck source=../src/lib/helpers.sh
source src/lib/helpers.sh
# shellcheck source=../src/lib/templates.sh
source src/lib/templates.sh

# Every variable below is read by render_placeholders() in templates.sh, which
# is sourced above - shellcheck cannot follow a use that lives in another file
# and happens after this function returns, so it reports all of them as unused.
# shellcheck disable=SC2034
set_fixture_vars() {
  PROJECT_NAME="fixture"
  PROJECT_MODULE="github.com/example/fixture"
  APP_PORT="8100"
  CMS_PORT="8101"
  APP_DOMAIN="fixture.test"
  CMS_DOMAIN="cms.fixture.test"
  CMS_TOKEN="fixtur3-token"
  COCKPIT_SEC_KEY="fixtur3-sec-key"
  INSTALL_ADDONS=0
  DATABASE="mongodb"
  STORAGE_ADAPTER="s3"
  TAILWIND="$1"
  S3_KEY="fixtures3key"
  S3_SECRET="fixtures3secret"
  export S3_KEY S3_SECRET
}

fail=0
step() { printf '%s\n' "$*"; }
check() { if [ "$1" -eq 0 ]; then step "  ok $2"; else step "  FAIL $2"; fail=1; fi }

for flavor in tailwind plain; do
  tw=0
  [[ "${flavor}" == "tailwind" ]] && tw=1
  out="${T}/${flavor}"
  mkdir -p "${out}"

  set_fixture_vars "${tw}"
  render_template_tree "${GOSITE_ROOT}/templates" "${out}" full

  # Addon overlays are part of the product: an addon that also ships
  # application code must render, format and compile like the base tree, or a
  # project installing it gets a scaffold that does not build.
  render_addon_overlay "${GOSITE_ROOT}/templates" "${out}" blog >/dev/null

  while IFS= read -r f; do render_placeholders "${f}"; done < <(find "${out}" -type f)
  assert_no_placeholders "${out}"
  check $? "no unresolved placeholders (${flavor})"

  # The overlay must have landed, in the right flavor.
  [[ -f "${out}/internal/blog/blog.go" && -f "${out}/internal/app/router_blog.go" \
     && -f "${out}/internal/views/pages/blog-article.html" ]]
  check $? "blog overlay rendered (${flavor})"

  # gofmt: the Go templates must be canonically formatted.
  if command -v gofmt >/dev/null 2>&1; then
    bad="$(gofmt -l "${out}")"
    [[ -z "${bad}" ]]; check $? "gofmt clean (${flavor})${bad:+ : ${bad}}"
  else
    step "  skip gofmt (not installed)"
  fi

  # php -l on the Cockpit config.
  if command -v php >/dev/null 2>&1; then
    php -l "${out}/cockpit/config.php" >/dev/null 2>&1
    check $? "php -l config.php (${flavor})"
  else
    step "  skip php -l (not installed)"
  fi

  # YAML parse on both compose files.
  if python3 -c "import yaml" 2>/dev/null; then
    python3 -c "
import yaml, sys
for f in ('${out}/docker-compose.yml', '${out}/docker-compose.prod.yml'):
    with open(f) as fh:
        yaml.safe_load(fh)
"; check $? "compose files parse as YAML (${flavor})"
  elif command -v yq >/dev/null 2>&1; then
    yq e '.' "${out}/docker-compose.yml" >/dev/null && yq e '.' "${out}/docker-compose.prod.yml" >/dev/null
    check $? "compose files parse as YAML (${flavor})"
  else
    step "  skip YAML parse (neither pyyaml nor yq)"
  fi
done

# go vet: needs the module graph, so it runs once on the tailwind render.
if command -v go >/dev/null 2>&1; then
  step "go vet (downloading module graph)"
  if (cd "${T}/tailwind" && go mod tidy >/dev/null 2>&1 && go vet ./... >/dev/null 2>&1); then
    check 0 "go vet clean"
  else
    check 1 "go vet"
  fi
else
  step "  skip go vet (go not installed)"
fi

if [[ "${fail}" -eq 0 ]]; then
  step "fixture verification passed"
else
  step "fixture verification FAILED"
fi
exit "${fail}"

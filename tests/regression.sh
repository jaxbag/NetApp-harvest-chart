#!/bin/sh
set -eu

CHART_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELM_BIN=${HELM_BIN:-helm}
BASE_VALUES="$CHART_DIR/tests/values-lint.yaml"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/harvest-chart-tests.XXXXXX")

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

render() {
  output=$1
  shift
  "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" "$@" > "$output"
}

deployment_names() {
  awk '
    $1 == "kind:" { kind=$2 }
    kind == "Deployment" && $1 == "name:" {
      gsub(/"/, "", $2); print $2; kind=""
    }
  ' "$1"
}

selectors() {
  awk '
    $1 == "kind:" { kind=$2 }
    kind == "Deployment" && $1 == "selector:" { capture=1 }
    capture { print }
    capture && $1 == "template:" { capture=0 }
  ' "$1"
}

expect_failure() {
  description=$1
  expected=$2
  shift 2
  if "$@" > "$TMP_DIR/failure.out" 2> "$TMP_DIR/failure.err"; then
    fail "$description unexpectedly succeeded"
  fi
  if ! grep -F "$expected" "$TMP_DIR/failure.err" "$TMP_DIR/failure.out" >/dev/null; then
    fail "$description did not contain expected error: $expected"
  fi
  pass "$description"
}

# Required Helm checks.
"$HELM_BIN" lint --strict "$CHART_DIR" >/dev/null 2>&1
"$HELM_BIN" lint --strict "$CHART_DIR" -f "$BASE_VALUES" >/dev/null 2>&1
"$HELM_BIN" lint --strict "$CHART_DIR" -f "$CHART_DIR/examples/values-ontap.yaml" >/dev/null 2>&1
render "$TMP_DIR/base.yaml"
"$HELM_BIN" template harvest "$CHART_DIR" -f "$CHART_DIR/examples/values-ontap.yaml" > "$TMP_DIR/example.yaml"
pass "helm lint --strict (default/test/example) and required templates"

# H-01: short names retain readability; all truncating cases use identity hash.
short_names=$(deployment_names "$TMP_DIR/base.yaml")
printf '%s\n' "$short_names" | grep -Fx 'harvest-alpha' >/dev/null || fail "short alpha name"
printf '%s\n' "$short_names" | grep -Fx 'harvest-beta' >/dev/null || fail "short beta name"

FULLNAME_63=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
[ "${#FULLNAME_63}" -eq 63 ] || fail "fullnameOverride test fixture is not 63 characters"
render "$TMP_DIR/fullname63.yaml" --set-string fullnameOverride="$FULLNAME_63"

LONG_A=poller-with-a-very-long-shared-prefix-that-keeps-going-alpha
LONG_B=poller-with-a-very-long-shared-prefix-that-keeps-going-bravo
cat > "$TMP_DIR/long-pollers.yaml" <<EOF
pollers:
  configure-me: null
  $LONG_A:
    datacenter: test
    addr: 192.0.2.20
    auth:
      username: harvest
      existingSecret: harvest-long-a
      passwordKey: password
  $LONG_B:
    datacenter: test
    addr: 192.0.2.21
    auth:
      username: harvest
      existingSecret: harvest-long-b
      passwordKey: password
EOF
"$HELM_BIN" template harvest "$CHART_DIR" -f "$TMP_DIR/long-pollers.yaml" > "$TMP_DIR/long.yaml"
"$HELM_BIN" template harvest "$CHART_DIR" -f "$TMP_DIR/long-pollers.yaml" > "$TMP_DIR/long-second.yaml"
cmp -s "$TMP_DIR/long.yaml" "$TMP_DIR/long-second.yaml" || fail "long-name rendering is not deterministic"

LONG_RELEASE=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
[ "${#LONG_RELEASE}" -eq 53 ] || fail "release-name test fixture is not 53 characters"
"$HELM_BIN" template "$LONG_RELEASE" "$CHART_DIR" -f "$BASE_VALUES" > "$TMP_DIR/release-long.yaml"

for rendered in "$TMP_DIR/base.yaml" "$TMP_DIR/fullname63.yaml" "$TMP_DIR/long.yaml" "$TMP_DIR/release-long.yaml"; do
  names=$(deployment_names "$rendered")
  [ -n "$names" ] || fail "no Deployment names in $rendered"
  [ "$(printf '%s\n' "$names" | sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ] || fail "duplicate Deployment name in $rendered"
  printf '%s\n' "$names" | while IFS= read -r name; do
    [ "${#name}" -le 63 ] || fail "Deployment name exceeds 63 characters: $name"
  done
done
pass "H-01 collision-safe deterministic Deployment names"

# H-02: selector identity is independent from mutable metadata and rollout inputs.
selectors "$TMP_DIR/base.yaml" > "$TMP_DIR/selectors.base"
render "$TMP_DIR/image.yaml" --set-string image.tag=24.08.0-test
render "$TMP_DIR/pod-label.yaml" --set-string podLabels.team=operations
render "$TMP_DIR/restart.yaml" --set-string rollout.restartToken=rotation-1
render "$TMP_DIR/name-override.yaml" --set-string nameOverride=renamed-metadata

cp -R "$CHART_DIR" "$TMP_DIR/chart-version"
awk '$1 == "version:" {$2="9.9.9"} {print}' "$TMP_DIR/chart-version/Chart.yaml" > "$TMP_DIR/Chart.yaml.new"
mv "$TMP_DIR/Chart.yaml.new" "$TMP_DIR/chart-version/Chart.yaml"
"$HELM_BIN" template harvest "$TMP_DIR/chart-version" -f "$BASE_VALUES" > "$TMP_DIR/chart-version.yaml"

for rendered in image pod-label restart name-override chart-version; do
  selectors "$TMP_DIR/$rendered.yaml" > "$TMP_DIR/selectors.$rendered"
  cmp -s "$TMP_DIR/selectors.base" "$TMP_DIR/selectors.$rendered" || fail "selector changed for $rendered"
done
pass "H-02 immutable selectors remain byte-identical"

# H-03: numeric-looking Secret names/keys remain YAML strings after parsing.
cat > "$TMP_DIR/strings.yaml" <<'EOF'
pollers:
  configure-me: null
  "123":
    datacenter: test
    addr: 192.0.2.30
    auth:
      username: harvest
      existingSecret: "123"
      passwordKey: "456"
ontapTLS:
  verify: true
  existingCASecret: "789"
  caKey: "123"
EOF
"$HELM_BIN" template harvest "$CHART_DIR" -f "$TMP_DIR/strings.yaml" > "$TMP_DIR/strings-rendered.yaml"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  config = docs.find { |d| d["kind"] == "ConfigMap" }
  dep = docs.find { |d| d["kind"] == "Deployment" }
  env = dep.dig("spec", "template", "spec", "containers", 0, "env")
  ref = env.find { |e| e["name"] == "HARVEST_PASSWORD" }.dig("valueFrom", "secretKeyRef")
  ca = dep.dig("spec", "template", "spec", "volumes").find { |v| v["name"] == "ontap-ca" }.fetch("secret")
  cfg = dep.dig("spec", "template", "spec", "volumes").find { |v| v["name"] == "config" }.dig("configMap", "name")
  harvest_config = YAML.safe_load(config.dig("data", "harvest.yml"))
  values = [ref["name"], ref["key"], ca["secretName"], ca["items"][0]["key"], ca["items"][0]["path"], cfg, harvest_config["Pollers"].keys.first]
  abort "non-string value: #{values.inspect}" unless values.all? { |v| v.is_a?(String) }
  abort "numeric poller key changed: #{values.inspect}" unless harvest_config["Pollers"].key?("123")
' "$TMP_DIR/strings-rendered.yaml"
pass "H-03 Kubernetes string fields retain string types"

# M-01 and M-05 schema behavior.
expect_failure "M-01 documentation-only default blocked" "replace the reserved pollers.configure-me" "$HELM_BIN" template harvest "$CHART_DIR"
cat > "$TMP_DIR/empty-pollers.yaml" <<'EOF'
pollers:
  configure-me: null
EOF
expect_failure "M-01 empty pollers rejected" "pollers" "$HELM_BIN" template harvest "$CHART_DIR" -f "$TMP_DIR/empty-pollers.yaml"
render "$TMP_DIR/collector-zapi.yaml" --set-json 'harvest.collectors=["Zapi"]'
render "$TMP_DIR/collector-rest.yaml" --set-json 'harvest.collectors=["Rest"]'
expect_failure "M-05 invalid collector rejected" "value must be one of" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'harvest.collectors=["Zappi"]'
pass "M-05 Zapi and Rest collectors accepted"

# M-03 reserved pod metadata must fail before duplicate YAML can be emitted.
cat > "$TMP_DIR/reserved-annotation.yaml" <<'EOF'
podAnnotations:
  checksum/config: evil
EOF
cat > "$TMP_DIR/reserved-label.yaml" <<'EOF'
podLabels:
  app.kubernetes.io/name: evil
EOF
expect_failure "M-03 reserved annotation rejected" "is reserved by the chart" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" -f "$TMP_DIR/reserved-annotation.yaml"
expect_failure "M-03 selector label override rejected" "is reserved by the chart" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" -f "$TMP_DIR/reserved-label.yaml"

# M-06 obvious structural errors and L-01 digest behavior.
cat > "$TMP_DIR/bad-tolerations.yaml" <<'EOF'
tolerations: bad
EOF
expect_failure "M-06 non-array tolerations rejected" "tolerations" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" -f "$TMP_DIR/bad-tolerations.yaml"
expect_failure "M-06 resources type rejected" "resources" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'resources="bad"'
expect_failure "M-06 securityContext type rejected" "securityContext" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'securityContext="bad"'
expect_failure "M-06 podSecurityContext type rejected" "podSecurityContext" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'podSecurityContext="bad"'
expect_failure "M-06 nodeSelector type rejected" "nodeSelector" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'nodeSelector="bad"'
expect_failure "M-06 affinity type rejected" "affinity" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'affinity="bad"'
expect_failure "M-06 imagePullSecrets type rejected" "imagePullSecrets" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-json 'imagePullSecrets="bad"'
expect_failure "M-06 existingSecret type rejected" "existingSecret" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set pollers.alpha.auth.existingSecret=123
expect_failure "M-06 passwordKey type rejected" "passwordKey" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set pollers.alpha.auth.passwordKey=456
expect_failure "M-06 existingCASecret type rejected" "existingCASecret" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set ontapTLS.existingCASecret=789
expect_failure "M-06 caKey type rejected" "caKey" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set ontapTLS.caKey=123
DIGEST=sha256:9292d5556d8b0e78178a37fa698a48ed8f77ae1b79a33849c6398651e2afe06a
render "$TMP_DIR/digest.yaml" --set-string image.digest="$DIGEST"
grep -F "image: \"ghcr.io/netapp/harvest@$DIGEST\"" "$TMP_DIR/digest.yaml" >/dev/null || fail "digest image reference"
expect_failure "L-01 malformed digest rejected" "image/digest" "$HELM_BIN" template harvest "$CHART_DIR" -f "$BASE_VALUES" --set-string image.digest=sha256:bad
pass "L-01 digest image reference"

# Determinism and scoped upgrade diffs.
render "$TMP_DIR/same.yaml"
cmp -s "$TMP_DIR/base.yaml" "$TMP_DIR/same.yaml" || fail "identical inputs are not byte-identical"

render "$TMP_DIR/config.yaml" --set harvest.exporter.sortLabels=false
diff -u "$TMP_DIR/base.yaml" "$TMP_DIR/config.yaml" > "$TMP_DIR/config.diff" || true
[ "$(grep -E '^[+-][^+-]' "$TMP_DIR/config.diff" | wc -l | tr -d ' ')" -eq 6 ] || fail "config diff contains unexpected changes"
grep -F 'sort_labels:' "$TMP_DIR/config.diff" >/dev/null || fail "config diff lacks changed config"
grep -F 'checksum/config:' "$TMP_DIR/config.diff" >/dev/null || fail "config diff lacks checksums"

diff -u "$TMP_DIR/base.yaml" "$TMP_DIR/image.yaml" > "$TMP_DIR/image.diff" || true
[ "$(grep -E '^[+-][^+-]' "$TMP_DIR/image.diff" | wc -l | tr -d ' ')" -eq 4 ] || fail "image diff contains changes beyond two Deployment images"
grep -F 'image:' "$TMP_DIR/image.diff" >/dev/null || fail "image diff lacks image field"

diff -u "$TMP_DIR/base.yaml" "$TMP_DIR/restart.yaml" > "$TMP_DIR/restart.diff" || true
[ "$(grep -E '^[+-][^+-]' "$TMP_DIR/restart.diff" | wc -l | tr -d ' ')" -eq 4 ] || fail "restartToken diff contains unexpected changes"
grep -F 'harvest.netapp.io/restart-token:' "$TMP_DIR/restart.diff" >/dev/null || fail "restart diff lacks restart token"
pass "determinism and scoped upgrade diffs"

# Lifecycle safety static audits.
if grep -R -n 'helm\.sh/hook' "$CHART_DIR/templates" > "$TMP_DIR/hooks.audit"; then
  fail "Helm hooks found"
fi
if grep -R -E -n 'kubectl[[:space:]]+(delete|patch|replace)|helm[[:space:]]+uninstall|rm[[:space:]]+-rf|HTTP[[:space:]]+DELETE' "$CHART_DIR/templates" > "$TMP_DIR/destructive.audit"; then
  fail "destructive operation found in templates"
fi
pass "no Helm hooks and no destructive template operations"

printf 'All regression tests passed. Artifacts: %s\n' "$TMP_DIR"

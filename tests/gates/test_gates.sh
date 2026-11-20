#!/usr/bin/env bash
# Proves each CI security gate is enforced: the real make target, pointed at a planted bad
# input, fails and names the expected rule; pointed at this repo, it passes. A gate that
# fails for another reason (a download error, say) is reported as FAIL, not PASS.
#
# Bad inputs are generated here at run time, so the repo itself never contains a
# secret-shaped string or a vulnerable pin for its own gates to find.
set -uo pipefail
cd "$(dirname "$0")/../.."

WORK=.cache/gates   # gitignored; recreated on every run
FIXTURE_IMAGE=gate-fixture:vulnerable
FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

rm -rf -- "${WORK:?}" && mkdir -p "$WORK"
trap 'docker rmi -f "$FIXTURE_IMAGE" >/dev/null 2>&1' EXIT

# expect_reject <description> <regex the output must contain> <make args...>
expect_reject() {
  local desc=$1 pattern=$2; shift 2
  local out="$WORK/out.log"
  if make -s "$@" >"$out" 2>&1; then
    fail "$desc: gate passed"
  elif grep -qE "$pattern" "$out"; then
    pass "$desc ($(grep -oE "$pattern" "$out" | head -1))"
  else
    fail "$desc: gate failed, but not with /$pattern/"; tail -5 "$out" | sed 's/^/      /'
  fi
}

# expect_accept <description> <make args...>
expect_accept() {
  local desc=$1; shift
  local out="$WORK/out.log"
  if make -s "$@" >"$out" 2>&1; then pass "$desc"; else fail "$desc: gate failed"; tail -15 "$out" | sed 's/^/      /'; fi
}

echo "== Secrets scan (gitleaks, full history)"
# A GitHub-token-shaped random string, committed and then deleted in a later commit: the
# current tree is clean, only the history has it.
repo="$WORK/secret-repo"
git init -q "$repo"
token="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
echo "GITHUB_TOKEN=$token" >"$repo/config.env"
g() { git -C "$repo" -c user.name=gate-test -c user.email=gate-test@example.invalid "$@"; }
g add config.env && g commit -qm "add config"
g rm -q config.env && g commit -qm "remove token"
expect_reject "token deleted in a later commit is still found in history" "github-pat" secrets-scan SECRETS_REPO="$repo"
expect_accept "this repo's history has no secrets" secrets-scan

echo; echo "== Pre-commit hook (gitleaks, staged changes)"
# A fresh repo using this repo's hook, as `make hooks` sets it up; the commit is what's tested.
hrepo="$WORK/hook-repo"
git init -q "$hrepo"
git -C "$hrepo" config core.hooksPath "$PWD/tools/hooks"
h() { git -C "$hrepo" -c user.name=gate-test -c user.email=gate-test@example.invalid "$@"; }
echo "GITHUB_TOKEN=ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)" >"$hrepo/config.env"
h add config.env
if h commit -qm "add token" >"$WORK/out.log" 2>&1; then
  fail "commit with a staged token: hook let it through"
elif grep -q "github-pat" "$WORK/out.log" && [ -z "$(git -C "$hrepo" rev-list --all 2>/dev/null)" ]; then
  pass "commit with a staged token is blocked, nothing enters history (github-pat)"
else
  fail "commit with a staged token: failed, but not with github-pat"; tail -5 "$WORK/out.log" | sed 's/^/      /'
fi
h rm -q --cached config.env && rm -f "$hrepo/config.env"
echo "APP_GREETING=hello" >"$hrepo/config.env"
h add config.env
if h commit -qm "add config" >"$WORK/out.log" 2>&1; then pass "commit without a secret goes through"
else fail "commit without a secret: hook blocked it"; tail -5 "$WORK/out.log" | sed 's/^/      /'; fi

echo; echo "== SAST (Bandit)"
mkdir -p "$WORK/sast"
cat >"$WORK/sast/handler.py" <<'EOF'
import subprocess


def ping(host):
    return subprocess.run("ping -c1 " + host, shell=True)
EOF
expect_reject "shell command built from input is rejected" "B602" sast SAST_SRC="$WORK/sast"
expect_accept "app/src passes" sast

echo; echo "== Dependency audit (pip-audit)"
# Werkzeug 2.2.2 has published advisories (fixed in 2.2.3 and later).
printf 'Werkzeug==2.2.2\nMarkupSafe==3.0.4\n' >"$WORK/requirements.txt"
expect_reject "known-vulnerable pin is rejected" "werkzeug +2\.2\.2" deps-audit AUDIT_REQS="$WORK/requirements.txt"
expect_accept "app/requirements.txt passes" deps-audit

echo; echo "== Image scan (Trivy)"
# A minimal image holding only the metadata of an installed Werkzeug 2.2.2, built locally.
mkdir -p "$WORK/image/deps/Werkzeug-2.2.2.dist-info"
printf 'Metadata-Version: 2.1\nName: Werkzeug\nVersion: 2.2.2\n' >"$WORK/image/deps/Werkzeug-2.2.2.dist-info/METADATA"
printf 'FROM scratch\nCOPY deps /deps\n' >"$WORK/image/Dockerfile"
docker build -q -t "$FIXTURE_IMAGE" "$WORK/image" >/dev/null
expect_reject "image with a fixable HIGH vulnerability is rejected" "CVE-[0-9]+-[0-9]+" scan-image SCAN_IMAGE="$FIXTURE_IMAGE"
expect_accept "app image passes" scan-image

echo; echo "== IaC scan (Trivy config)"
mkdir -p "$WORK/iac"
cat >"$WORK/iac/pod.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad
  namespace: app
spec:
  containers:
    - name: c
      image: localhost:5001/secure-k8s-app@sha256:0000000000000000000000000000000000000000000000000000000000000000
      securityContext:
        privileged: true
EOF
expect_reject "privileged pod manifest is rejected" "KSV-0017" scan-iac IAC_DIR="$WORK/iac"
expect_accept "chart, platform/ and Dockerfile pass" scan-iac
# Accepted findings must expire: with every expiry moved into the past, each one fails again.
sed -E 's/expired_at: .*/expired_at: 2020-01-01/' tools/trivy/trivyignore.yaml >"$WORK/expired-ignore.yaml"
for id in $(grep -oE 'id: [A-Z]+-[0-9]+' tools/trivy/trivyignore.yaml | cut -d' ' -f2); do
  expect_reject "accepted $id fails again once its entry expires" "$id" scan-iac TRIVY_IGNORE="$WORK/expired-ignore.yaml"
done

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL GATE TESTS PASSED"; else echo "GATE TESTS FAILED" >&2; exit 1; fi

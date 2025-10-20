#!/bin/bash
# Basic validation tests for RKE2 cluster bootstrapping

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED_TESTS=0

log_test() {
    echo "TEST: $1"
}

log_pass() {
    echo "  ✓ PASS: $1"
}

log_fail() {
    echo "  ✗ FAIL: $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

# Test 1: Check if required files exist
log_test "Required files exist"
for file in \
    "setup-cluster.sh" \
    "README.md" \
    "vm/machines.txt" \
    "vm/machines-ha.txt" \
    "server/config/server.yaml" \
    "server/config/server-ha.yaml" \
    "server/config/server-ha-join.yaml" \
    "server/manifests/argocd.yaml" \
    "server/manifests/argocd-app-of-apps.yaml"
do
    if [ -f "$SCRIPT_DIR/$file" ]; then
        log_pass "File exists: $file"
    else
        log_fail "File missing: $file"
    fi
done

# Test 2: Check if ArgoCD app manifests exist
log_test "ArgoCD application manifests exist"
for app in cert-manager rancher loki grafana tempo mimir; do
    file="server/manifests/argocd-apps/${app}-app.yaml"
    if [ -f "$SCRIPT_DIR/$file" ]; then
        log_pass "App manifest exists: $app"
    else
        log_fail "App manifest missing: $app"
    fi
done

# Test 3: Validate YAML syntax
log_test "YAML syntax validation"
if command -v yamllint &> /dev/null; then
    if yamllint -d relaxed "$SCRIPT_DIR"/server/manifests/*.yaml "$SCRIPT_DIR"/server/config/*.yaml &> /dev/null; then
        log_pass "YAML syntax is valid"
    else
        log_fail "YAML syntax errors found"
    fi
else
    echo "  ⊘ SKIP: yamllint not available"
fi

# Test 4: Validate shell script syntax
log_test "Shell script syntax validation"
if bash -n "$SCRIPT_DIR/setup-cluster.sh"; then
    log_pass "Shell script syntax is valid"
else
    log_fail "Shell script syntax errors found"
fi

# Test 5: Check if setup script is executable
log_test "Setup script permissions"
if [ -x "$SCRIPT_DIR/setup-cluster.sh" ]; then
    log_pass "Setup script is executable"
else
    log_fail "Setup script is not executable"
fi

# Test 6: Check setup script help output
log_test "Setup script help output"
if "$SCRIPT_DIR/setup-cluster.sh" --help | grep -q "Usage:"; then
    log_pass "Setup script help works"
else
    log_fail "Setup script help failed"
fi

# Test 7: Verify ArgoCD app-of-apps structure
log_test "ArgoCD app-of-apps configuration"
if grep -q "argocd-apps" "$SCRIPT_DIR/server/manifests/argocd-app-of-apps.yaml"; then
    log_pass "App-of-apps points to correct directory"
else
    log_fail "App-of-apps configuration incorrect"
fi

# Test 8: Check PSS override includes ArgoCD namespace
log_test "PSS override configuration"
if grep -q "argocd" "$SCRIPT_DIR/server/rke2-pss-override,yaml"; then
    log_pass "PSS override includes argocd namespace"
else
    log_fail "PSS override missing argocd namespace"
fi

# Test 9: Verify HA config includes multiple server TLS SANs
log_test "HA configuration validation"
if grep -q "server-0.cluster.local" "$SCRIPT_DIR/server/config/server-ha.yaml"; then
    log_pass "HA config includes server-0 TLS SAN"
else
    log_fail "HA config missing server-0 TLS SAN"
fi

if grep -q "server-1.cluster.local" "$SCRIPT_DIR/server/config/server-ha.yaml"; then
    log_pass "HA config includes server-1 TLS SAN"
else
    log_fail "HA config missing server-1 TLS SAN"
fi

# Test 10: Check README documentation
log_test "README documentation"
if grep -q "Quick Start" "$SCRIPT_DIR/README.md"; then
    log_pass "README includes Quick Start section"
else
    log_fail "README missing Quick Start section"
fi

if grep -q "ArgoCD" "$SCRIPT_DIR/README.md"; then
    log_pass "README includes ArgoCD documentation"
else
    log_fail "README missing ArgoCD documentation"
fi

if grep -q "LGTM" "$SCRIPT_DIR/README.md"; then
    log_pass "README includes LGTM stack documentation"
else
    log_fail "README missing LGTM stack documentation"
fi

if grep -q "High Availability" "$SCRIPT_DIR/README.md"; then
    log_pass "README includes HA documentation"
else
    log_fail "README missing HA documentation"
fi

# Summary
echo ""
echo "========================================"
if [ $FAILED_TESTS -eq 0 ]; then
    echo "✓ ALL TESTS PASSED"
    echo "========================================"
    exit 0
else
    echo "✗ $FAILED_TESTS TESTS FAILED"
    echo "========================================"
    exit 1
fi

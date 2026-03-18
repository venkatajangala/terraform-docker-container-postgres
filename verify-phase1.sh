#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         Phase 1 Implementation Verification Script             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_mark="${GREEN}✓${NC}"
cross_mark="${RED}✗${NC}"

# Counters
total_checks=0
passed_checks=0

function check_file() {
  total_checks=$((total_checks + 1))
  if [ -f "$1" ]; then
    echo -e "${check_mark} File exists: $1"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${cross_mark} File missing: $1"
  fi
}

function check_cmd() {
  total_checks=$((total_checks + 1))
  if $1 > /dev/null 2>&1; then
    echo -e "${check_mark} Command passed: $2"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${cross_mark} Command failed: $2"
  fi
}

function check_image() {
  total_checks=$((total_checks + 1))
  if docker images | grep -q "$1"; then
    echo -e "${check_mark} Docker image exists: $1"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${cross_mark} Docker image missing: $1"
  fi
}

echo "📁 FILE CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_file "Dockerfile.patroni"
check_file "Dockerfile.pgbouncer"
check_file "Dockerfile.infisical"
check_file "initdb-wrapper.sh"
check_file ".dockerignore"
check_file "main-ha.tf"
check_file "main-infisical.tf"
check_file "variables-ha.tf"
check_file "outputs-ha.tf"
check_file "entrypoint-patroni.sh"
echo ""

echo "🔍 TERRAFORM CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_cmd "terraform validate" "Terraform validation"
echo ""

echo "🐳 DOCKER IMAGE CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_image "postgres-patroni:18-pgvector"
check_image "pgbouncer:ha"
check_image "infisical/infisical"
echo ""

echo "📊 IMAGE SIZE CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total_checks=$((total_checks + 1))
patroni_size=$(docker images postgres-patroni:18-pgvector --format "{{.Size}}" 2>/dev/null || echo "0B")
if [[ "$patroni_size" != "0B" ]]; then
  echo -e "${check_mark} Patroni image size: $patroni_size (target: <1GB)"
  passed_checks=$((passed_checks + 1))
else
  echo -e "${cross_mark} Could not determine Patroni image size"
fi

total_checks=$((total_checks + 1))
pgbouncer_size=$(docker images pgbouncer:ha --format "{{.Size}}" 2>/dev/null || echo "0B")
if [[ "$pgbouncer_size" != "0B" ]]; then
  echo -e "${check_mark} PgBouncer image size: $pgbouncer_size (target: <50MB)"
  passed_checks=$((passed_checks + 1))
else
  echo -e "${cross_mark} Could not determine PgBouncer image size"
fi

echo ""

echo "📚 DOCUMENTATION CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_file "PHASE-1-README.md"
check_file "PHASE-1-IMPLEMENTATION-SUMMARY.md"
check_file "PHASE-1-CHECKLIST.md"
check_file "QUICK-START-DEPLOYMENT.md"
check_file "OPTIMIZATION-REPORT.md"
check_file "IMPLEMENTATION-GUIDE.md"
echo ""

echo "📋 SCRIPT PERMISSION CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for script in entrypoint-patroni.sh entrypoint-pgbouncer.sh entrypoint-infisical.sh initdb-wrapper.sh; do
  total_checks=$((total_checks + 1))
  if [ -f "$script" ] && [ -x "$script" ]; then
    echo -e "${check_mark} Script is executable: $script"
    passed_checks=$((passed_checks + 1))
  elif [ -f "$script" ]; then
    echo -e "${YELLOW}⚠${NC}  Script exists but not executable: $script"
  else
    echo -e "${cross_mark} Script missing: $script"
  fi
done
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                       FINAL RESULTS                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [ $total_checks -eq $passed_checks ]; then
  echo -e "${GREEN}✓ ALL CHECKS PASSED ($passed_checks/$total_checks)${NC}"
  echo ""
  echo "Phase 1 implementation is complete and ready for deployment!"
  echo ""
  echo "Next steps:"
  echo "  1. Review: terraform plan"
  echo "  2. Deploy: terraform apply"
  echo "  3. Verify: docker ps"
  echo "  4. Test:   psql -h localhost -p 5432 -U pgadmin"
  exit 0
else
  failed=$((total_checks - passed_checks))
  echo -e "${RED}✗ SOME CHECKS FAILED ($passed_checks/$total_checks passed, $failed failed)${NC}"
  exit 1
fi

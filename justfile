import? 'justfile.local'

default:
    @just --list

# 1. Dependency Setup
setup:
    nimble install --depsOnly -y
    nimble setup
    cd docs && npm install --legacy-peer-deps

# 2. Test Suite Execution
test:
    @just test-nim

test-nim:
    nimble test

test-unit:
    nimble testUnit

test-threaded:
    nimble testThreaded

# 3. Linter Execution
lint:
    @just lint-nim

lint-nim:
    nph --check .
    nimble check

# 4. Formatter Execution
fmt:
    nph .

# 5. Build Artifacts
build:
    nimble build -d:release

# 6. Documentation Dev Server
docs:
    nimble docgen
    cd docs && npm run dev

# 7. Documentation Production Build
docs-build:
    nimble docgen
    cd docs && npm run build

# 8. Clean Build Artifacts
clean:
    rm -rf nimcache htmldocs site docs/dist docs/.astro tools/docgen dist .venv
    find . -name '*.exe' -delete

# 9. Secret Scanning
check-secrets:
    @if command -v gitleaks >/dev/null 2>&1; then \
        gitleaks detect -v; \
    elif command -v pre-commit >/dev/null 2>&1; then \
        pre-commit run gitleaks --all-files; \
    else \
        echo "Error: neither gitleaks nor pre-commit found. Install gitleaks or pre-commit." >&2; exit 1; \
    fi

# 10. Upstream Template Synchronization
update-template:
    uvx copier update --trust

import? 'justfile.local'

default:
    @just --list

# 1. Dependency Setup
setup:
    nimble install --depsOnly -y
    cd docs && npm install

# 2. Test Suite Execution
test:
    nimble test

# 3. Linter Execution
lint:
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
    rm -rf nimcache htmldocs site docs/dist docs/.astro tools/docgen
    find . -name '*.exe' -delete

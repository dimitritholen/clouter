#!/usr/bin/env bash
set -u

# Resolve repo root from script location
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

# learned.py's store for any test that forgets its own CLOUTER_LEARNED:
# the suite must never write the real ~/.config/clouter/learned.json.
learned_dir="$(mktemp -d)"
trap 'rm -rf "$learned_dir"' EXIT
export CLOUTER_LEARNED="$learned_dir/learned.json"

# Collect totals
total_ok=0
total_fail=0
total_todo=0
any_failed=0
file_count=0

# Run tests in sorted order
while IFS= read -r test_file; do
    test_name=$(basename "$test_file")
    file_count=$((file_count + 1))

    # Run the test and capture output
    output=$(bash "$test_file" 2>&1)
    exit_code=$?

    # Count lines starting with exactly ok, FAIL, or todo
    ok_count=$(printf '%s' "$output" | grep -c '^ok ' || true)
    fail_count=$(printf '%s' "$output" | grep -c '^FAIL ' || true)
    todo_count=$(printf '%s' "$output" | grep -c '^todo ' || true)

    # If test exited non-zero but printed no FAIL line, count it as a failure
    if [ $exit_code -ne 0 ] && [ $fail_count -eq 0 ]; then
        fail_count=1
    fi

    # Print status line
    if [ $fail_count -eq 0 ]; then
        printf 'ok   %-40s %d ok, %d todo\n' "$test_name" "$ok_count" "$todo_count"
    else
        printf 'FAIL %-40s %d FAIL\n' "$test_name" "$fail_count"
        # Print FAIL lines indented
        printf '%s' "$output" | grep '^FAIL ' | sed 's/^/  /' || true
    fi

    # Accumulate totals
    total_ok=$((total_ok + ok_count))
    total_fail=$((total_fail + fail_count))
    total_todo=$((total_todo + todo_count))

    # Track if any failed
    if [ $fail_count -gt 0 ]; then
        any_failed=1
    fi

done < <(find tests -maxdepth 1 -name "*.test.sh" ! -name "run-all.sh" -type f | sort)

# Print summary
printf '%d files, %d ok, %d FAIL, %d todo\n' "$file_count" "$total_ok" "$total_fail" "$total_todo"

exit $any_failed

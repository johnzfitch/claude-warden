#!/usr/bin/env bash
# Test destructive command position-matching regex
# Run directly: bash tests/test-destructive-regex.sh

PASS=0 FAIL=0

_DESTRUCTIVE_TOOLS='(mkfs|wipefs|fdisk|gdisk|parted|cfdisk|sfdisk|blockdev|hdparm)'
_DESTRUCTIVE_PREFIX='((sudo|doas)[[:space:]]+|(env[[:space:]]+[A-Za-z_]+=[^[:space:]]+[[:space:]]+))*'
_DESTRUCTIVE_PATH='(/[^[:space:]]*/)?'

_test() {
    local cmd="$1" expected="$2"
    NORM_CMD=$(echo "$cmd" | tr -s '[:space:]' ' ')
    local matched="allow"
    if [[ "$NORM_CMD" =~ (^|[;\&\|][[:space:]]*)${_DESTRUCTIVE_PREFIX}${_DESTRUCTIVE_PATH}${_DESTRUCTIVE_TOOLS}([[:space:].]|$) ]]; then
        matched="deny"
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

echo "--- True positives (must deny) ---"
_test 'mkfs.ext4 /dev/sdc1' deny
_test 'mkfs /dev/sdc' deny
_test 'sudo wipefs -a /dev/sdc' deny
_test 'sudo /sbin/fdisk /dev/sdb' deny
_test 'env FOO=1 wipefs -a /dev/sdc' deny
_test '/sbin/wipefs -a /dev/sdc' deny
_test 'echo ok && fdisk /dev/sdb' deny
_test 'doas mkfs /dev/sdc' deny
_test 'gdisk /dev/nvme0n1' deny
_test 'parted /dev/sda' deny
_test 'sudo env LANG=C fdisk /dev/sdb' deny
_test 'hdparm -S 0 /dev/sda' deny
_test 'blockdev --setrw /dev/sda' deny
_test 'echo ok; sudo /usr/sbin/wipefs -a /dev/sdc' deny
_test 'true | sudo mkfs.vfat -F 32 /dev/sdc1' deny

echo ""
echo "--- False positives (must NOT deny) ---"
_test "grep -iE 'mkfs|wipefs' /var/log/syslog" allow
_test 'echo "do not run mkfs"' allow
_test 'grep mkfs log.txt' allow
_test 'rg mkfs /var/log/' allow
_test 'fdisk_handler check' allow
_test 'check_mkfs_status' allow
_test 'cat /proc/partitions | head' allow
_test 'man fdisk' allow

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL

#!/bin/sh
set -eu

# Run inside the built Linux image as root. All files below are disposable
# synthetic fixtures; no real project files, certificates or databases are used.
if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
    echo 'Run this test in the Linux PHP image as root.' >&2
    exit 1
fi

fixture=$(mktemp -d /tmp/epay-permissions-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
chmod 0755 "$fixture"
project=$fixture/project
merchant_a=$project/plugins/wxpayn/cert/merchant-a
merchant_b=$project/plugins/wxpaynp/cert/merchant-b
nested_cert=$project/plugins/jdpay/inc/cert
mkdir -p "$merchant_a" "$merchant_b" "$nested_cert"
chmod 0755 "$project"

for file in \
    "$project/plugins/wxpayn/wxpayn_plugin.php" \
    "$merchant_a/apiclient_key.pem" "$merchant_a/cert.pem" \
    "$merchant_b/apiclient_key.pem" "$merchant_b/pub_key.pem" \
    "$nested_cert/merchant private.key" "$nested_cert/client.pfx"; do
    printf 'synthetic fixture: %s\n' "${file##*/}" > "$file"
    chmod 0600 "$file"
done
find "$project/plugins" -type d -exec chmod 0700 {} +
find "$project/plugins" -type f -exec sha256sum {} + > "$fixture/checksums"

epay-fix-plugin-permissions "$project"
php_group=$(id -g www-data)
assert_mode() {
    [ "$(stat -c %a "$2")" = "$1" ] || {
        echo "Unexpected mode for $2 (expected $1)" >&2
        exit 1
    }
    [ "$(stat -c %g "$2")" = "$php_group" ]
}
assert_mode 640 "$project/plugins/wxpayn/wxpayn_plugin.php"
assert_mode 2770 "$merchant_a"
assert_mode 640 "$merchant_a/apiclient_key.pem"
assert_mode 660 "$merchant_a/cert.pem"
assert_mode 640 "$merchant_b/pub_key.pem"
assert_mode 640 "$nested_cert/merchant private.key"
assert_mode 640 "$nested_cert/client.pfx"

su -s /bin/sh www-data -c "
    test -r '$merchant_a/apiclient_key.pem' &&
    test ! -w '$merchant_a/apiclient_key.pem' &&
    test -w '$merchant_a/cert.pem' &&
    test -w '$merchant_b' &&
    test ! -w '$project/plugins/wxpayn/wxpayn_plugin.php'
"

# Running again must preserve file contents and final modes.
epay-fix-plugin-permissions "$project"
sha256sum -c "$fixture/checksums"
assert_mode 640 "$merchant_a/apiclient_key.pem"
assert_mode 660 "$merchant_a/cert.pem"

# A new merchant imported with root-only permissions is handled by the same
# command, with no merchant-specific arguments or container restart.
merchant_c=$project/plugins/wxpayn/cert/merchant-c
mkdir -m 0700 "$merchant_c"
printf 'new synthetic private key\n' > "$merchant_c/apiclient_key.pem"
chmod 0600 "$merchant_c/apiclient_key.pem"
epay-fix-plugin-permissions "$project"
assert_mode 2770 "$merchant_c"
assert_mode 640 "$merchant_c/apiclient_key.pem"
su -s /bin/sh www-data -c "test -r '$merchant_c/apiclient_key.pem'"

# Test entrypoint dispatch without starting FPM or touching the real project.
mkdir "$fixture/bin"
cat > "$fixture/bin/epay-fix-plugin-permissions" <<'SH'
#!/bin/sh
echo prepare >> "$EPAY_TEST_TRACE"
exit "${EPAY_TEST_PREPARE_EXIT:-0}"
SH
cat > "$fixture/bin/docker-php-entrypoint" <<'SH'
#!/bin/sh
printf 'official:%s\n' "$*" >> "$EPAY_TEST_TRACE"
SH
chmod 0755 "$fixture/bin/epay-fix-plugin-permissions" "$fixture/bin/docker-php-entrypoint"
export EPAY_TEST_TRACE=$fixture/trace

check_dispatch() {
    expected=$1
    shift
    : > "$EPAY_TEST_TRACE"
    PATH="$fixture/bin:$PATH" epay-entrypoint "$@"
    actual=$(grep -c '^prepare$' "$EPAY_TEST_TRACE" || :)
    [ "$actual" = "$expected" ]
    grep -q '^official:' "$EPAY_TEST_TRACE"
}
check_dispatch 1
check_dispatch 1 php-fpm
check_dispatch 1 -F
check_dispatch 1 php-fpm -F
check_dispatch 1 /usr/local/sbin/php-fpm -F
check_dispatch 0 php -v
check_dispatch 0 sh -c 'exit 0'
for option in -t -tt --test -i --info -v --version -h --help; do
    check_dispatch 0 php-fpm "$option"
done

: > "$EPAY_TEST_TRACE"
if EPAY_TEST_PREPARE_EXIT=42 PATH="$fixture/bin:$PATH" epay-entrypoint php-fpm; then
    echo 'FPM must not start after permission setup fails.' >&2
    exit 1
else
    [ "$?" -eq 42 ]
fi
if grep -q '^official:' "$EPAY_TEST_TRACE"; then
    echo 'Official entrypoint unexpectedly ran after a permission error.' >&2
    exit 1
fi

echo 'Plugin permission and entrypoint checks OK'

# Signature checks without PHP's sodium (as WD's own PHP lacks it): none available -> null (a signed repository is
# refused), with the Store's own store_verify (from its package), with the PHP app's PHP 8.5 (which has sodium), and with
# sodium in PHP itself
pass(){ echo "PASS $1"; }; fail(){ echo "FAIL $1"; }
V=/tmp/v; mkdir -p $V/Nas_Prog; export STORE_TEST_VOLUME=$V
cat > /tmp/verify.php <<'P'
<?php
require getenv('STORE_TEST_PROJECT') . '/apps/store/lib/store.php';
$data = file_get_contents('/www/repo/store.json'); $sig = file_get_contents('/www/repo/store.json.sig');
$key = json_decode($data, true)['public_key'];
$other = 'ed25519:MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=';
echo var_export(store_verify($data, $sig, $key), true), ' ', var_export(store_verify($data . ' ', $sig, $key), true), ' ', var_export(store_verify($data, $sig, $other), true), "\n";
P
check() { r=$(php $1 /tmp/verify.php); [ "$r" = "$2" ] && pass "$3: valid/changed/wrong key = $r" || fail "$3: $r (expected $2)"; }

# An OpenSSL 3 command line can check them too; WD's NAS has OpenSSL 1.1, like the PHP 7.4 test image
if openssl version | grep -q '^OpenSSL [3-9]'; then
    check -n 'true false false' 'no sodium, no PHP app, OpenSSL 3'
else
    check -n 'NULL NULL NULL' "no sodium, no PHP app, OpenSSL 1.1 (can't check: refused)"
fi
# The Store's own checker, from its package (the PHP 7.4 test image's OpenSSL is 1.1, as WD's is)
STORE_VERSION=$(cat $STORE_TEST_PROJECT/packages/store/latest)
mkdir -p $V/Nas_Prog/store; tar -xzf $STORE_TEST_PROJECT/packages/store/$STORE_VERSION/store_${STORE_VERSION}_amd64.tar.gz -C $V/Nas_Prog/store ./binaries/store_verify
check -n 'true false false' "no sodium, with the Store's own store_verify"
rm -rf $V/Nas_Prog/store
# The PHP app's own php, from its package
PHP_VERSION=$(cat $STORE_TEST_PROJECT/packages/php/latest)
mkdir -p $V/Nas_Prog/php; tar -xzf $STORE_TEST_PROJECT/packages/php/$PHP_VERSION/php_${PHP_VERSION}_amd64.tar.gz -C $V/Nas_Prog/php ./binaries/php
check -n 'true false false' "no sodium, with the PHP app's PHP"
check '-d display_errors=0' 'true false false' 'sodium in PHP'

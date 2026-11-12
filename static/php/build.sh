#!/bin/bash

# Builds PHP's CLI and FPM for the Intel models and the ARM ones, with every extension built in: those of the NAS's own
# PHP 7.4 (so that it can replace it), plus opcache, intl, redis (for ValKey), sodium, zip, sockets and pcntl, and the
# other extensions popular PHP apps ask for (WordPress, Nextcloud, Laravel, Drupal...): PostgreSQL drivers, gmp, ldap,
# igbinary (also used by redis), xsl, soap, calendar, ftp, shared memory / semaphores, tidy, yaml, and mbstring's
# regular expressions (mbregex, with the Oniguruma library: mb_split(), mb_ereg()... - Laravel uses mb_split()).
#
# - Intel: fully static binaries, built with static-php-cli. Static binaries can't load extensions from .so files, so
#   none are needed (or possible).
# - ARM: static-php-cli can't cross-build PHP's libraries, so armhf.sh compiles PHP with Debian's cross-compiler,
#   against Debian's own builds of its libraries - inside the Dockerfile's Debian stage (/armhf-root, with chroot) -
#   and bundles those libraries and glibc with it. It's checked here with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=8.5.12
# php.net's published SHA256 of the source (php-${VERSION}.tar.gz), checked before building
PHP_SHA256=81a0f450349e84b08eb43faa85f8a4c835684f3cc1c50471775d1317a046c525
SPC_VERSION=2.8.5
# Its x86_64 binary's digest, as GitHub publishes it for the release
SPC_SHA256=523ba4279c54c7a377156c0dd3a36adf92ee64b01e9a7f5e9e2ec084b8e458e5
# The PECL extensions the ARM build adds to PHP's source (static-php-cli's choice for the Intel build: the same files)
APCU_VERSION=5.1.28
APCU_SHA256=ca9c1820810a168786f8048a4c3f8c9e3fd941407ad1553259fb2e30b5f057bf
IGBINARY_VERSION=3.2.17RC1
IGBINARY_SHA256=91da821443db125282a6aea039f24588dd28ff5d71e8187f6ecc41165bceafbc
REDIS_VERSION=6.3.0
REDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
YAML_VERSION=2.3.0
YAML_SHA256=bc8404807a3a4dc896b310af21a7f8063aa238424ff77f27eb6ffa88b5874b8a
# GNU libiconv, built into the ARM build's PHP (as static-php-cli does for the Intel build: the same file): glibc's own
# iconv needs its character set modules from Debian's folders, which the NAS doesn't have
LIBICONV_VERSION=1.19.1
LIBICONV_SHA256=9a06844846d664d7122161700c10a64480d7c7bcead3091925a785b38c91edab
# The architectures built (each into packages/static/php/<version>/<arch>)
ARCHES='amd64 armhf'

# The NAS's PHP 7.4 extensions, then the extras
EXTENSIONS='apcu,bcmath,bz2,ctype,curl,dom,exif,fileinfo,filter,gd,gettext,iconv,mbstring,mysqli,mysqlnd,openssl,pdo,pdo_mysql,pdo_sqlite,posix,readline,session,simplexml,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib'
EXTENSIONS="${EXTENSIONS},opcache,intl,redis,sodium,zip,sockets,pcntl"
EXTENSIONS="${EXTENSIONS},pgsql,pdo_pgsql,gmp,ldap,igbinary,xsl,soap,calendar,ftp,shmop,sysvsem,sysvshm,sysvmsg,tidy,yaml"
EXTENSIONS="${EXTENSIONS},mbregex"
# Image formats for gd
LIBS='freetype,libjpeg,libpng,libwebp'

BUILD_PATH=/build
OUTPUT_ROOT=/data/packages/static/php/${VERSION}
OUTPUT_PATH=${OUTPUT_ROOT}/amd64
# The ARM build environment (the Dockerfile's Debian stage), and where the ARM build is made inside it: the app's final
# path on the NAS, as php and php-fpm find their libraries by their full paths
ARM_ROOT=/armhf-root
ARM_BINARIES=/mnt/HD/HD_a2/Nas_Prog/php/binaries

function build_php() {
    cd ${BUILD_PATH}

    # static-php-cli itself (a single self-contained binary)
    sh /data/static/fetch.sh \
        "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-linux-$(uname -m).tar.gz" \
        spc.tar.gz "${SPC_SHA256}"
    tar -xzf spc.tar.gz
    chmod +x spc

    # Build tools, then the sources (PHP pinned to this exact version). Every library is built from its source (not
    # static-php-cli's pre-built ones), so that the sources kept below are exactly what's in the binaries
    ./spc doctor --auto-fix
    ./spc download --for-extensions="${EXTENSIONS}" --for-libs="${LIBS}" \
        --custom-url="php-src:https://www.php.net/distributions/php-${VERSION}.tar.gz"
    # Stops the build if the source isn't there under its own name, rather than skipping the check
    echo "${PHP_SHA256}  downloads/php-${VERSION}.tar.gz" | sha256sum -c -
    ./spc build "${EXTENSIONS}" --with-libs="${LIBS}" --build-cli --build-fpm
}

# Builds PHP for the ARM models with armhf.sh, in the Debian stage (with chroot: its own /dev entries made first, as
# configure scripts need them), into ${BUILD_PATH}/armhf-out (until it's checked) - and its bundled libraries' sources,
# with the Intel build's.
function build_arm_php() {
    local work=${ARM_ROOT}/work
    local device

    rm -rf ${work}
    mkdir -p ${work}
    cd ${work}
    sh /data/static/fetch.sh "https://www.php.net/distributions/php-${VERSION}.tar.gz" php.tar.gz "${PHP_SHA256}"
    sh /data/static/fetch.sh "https://pecl.php.net/get/apcu-${APCU_VERSION}.tgz" apcu.tgz "${APCU_SHA256}"
    sh /data/static/fetch.sh "https://pecl.php.net/get/igbinary-${IGBINARY_VERSION}.tgz" igbinary.tgz \
        "${IGBINARY_SHA256}"
    sh /data/static/fetch.sh "https://pecl.php.net/get/redis-${REDIS_VERSION}.tgz" redis.tgz "${REDIS_SHA256}"
    sh /data/static/fetch.sh "https://pecl.php.net/get/yaml-${YAML_VERSION}.tgz" yaml.tgz "${YAML_SHA256}"
    sh /data/static/fetch.sh "https://ftp.gnu.org/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz" libiconv.tar.gz \
        "${LIBICONV_SHA256}"
    cp /data/static/php/armhf.sh ${work}/

    for device in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9'; do
        set -- ${device}
        [ -e ${ARM_ROOT}/dev/$1 ] || mknod -m 666 ${ARM_ROOT}/dev/$1 c $2 $3
    done

    cp /etc/resolv.conf ${ARM_ROOT}/etc/resolv.conf
    chroot ${ARM_ROOT} /usr/bin/env VERSION=${VERSION} /bin/bash /work/armhf.sh

    rm -rf ${BUILD_PATH}/armhf-out
    mkdir -p ${BUILD_PATH}/armhf-out
    cp -a ${ARM_ROOT}${ARM_BINARIES}/. ${BUILD_PATH}/armhf-out/
    rm -rf ${OUTPUT_PATH}.sources/armhf-debian
    cp -r ${work}/sources ${OUTPUT_PATH}.sources/armhf-debian
    du -sh ${BUILD_PATH}/armhf-out ${OUTPUT_PATH}.sources/armhf-debian
}

# Checks the ARM build with QEMU's emulator (as a Cortex-A9, the ARM models' processors' kind), at the app's path on the
# NAS (where it finds its loader and libraries), without the Debian stage's libraries anywhere it could find them:
# its version, the same extensions as the Intel build, and that the main ones work - and php-fpm.
function check_arm_php() {
    local php="qemu-arm -cpu cortex-a9 ${ARM_BINARIES}/php"
    local test=${BUILD_PATH}/armhf-test

    rm -rf ${ARM_BINARIES} ${test}
    mkdir -p ${ARM_BINARIES} ${test}
    cp -a ${BUILD_PATH}/armhf-out/. ${ARM_BINARIES}/

    ${php} -n -v | tee ${test}/version.txt
    grep -q "^PHP ${VERSION} (cli)" ${test}/version.txt
    ${php} -n -m > ${BUILD_PATH}/armhf-out/extensions.txt
    diff ${OUTPUT_PATH}/extensions.txt ${BUILD_PATH}/armhf-out/extensions.txt

    cat > ${test}/check.php <<'PHP'
<?php
$checks = [
    'sodium'   => function () {
        $keys = sodium_crypto_sign_keypair();
        $sig  = sodium_crypto_sign_detached('data', sodium_crypto_sign_secretkey($keys));

        return sodium_crypto_sign_verify_detached($sig, 'data', sodium_crypto_sign_publickey($keys));
    },
    'openssl'  => function () {
        return strlen(openssl_random_pseudo_bytes(16)) === 16 && openssl_digest('a', 'sha256') !== false;
    },
    'argon2'   => function () {
        return password_verify('secret', password_hash('secret', PASSWORD_ARGON2ID));
    },
    'bcrypt'   => function () {
        return password_verify('secret', password_hash('secret', PASSWORD_BCRYPT));
    },
    'intl'     => function () {
        return (new NumberFormatter('de_DE', NumberFormatter::DECIMAL))->format(1234.5) === '1.234,5';
    },
    'mbstring' => function () {
        return mb_strtoupper('ärger') === 'ÄRGER' && mb_split('\s', 'a b') === ['a', 'b'];
    },
    'iconv'    => function () {
        return iconv('UTF-8', 'ISO-8859-1', 'é') === "\xE9";
    },
    'gd'       => function () {
        $image = imagecreatetruecolor(4, 4);
        ob_start();
        imagewebp($image);
        imagejpeg($image);
        imagepng($image);

        return strlen(ob_get_clean()) > 100 && function_exists('imagettftext');
    },
    'sqlite'   => function () {
        $db = new PDO('sqlite::memory:');
        $db->exec('CREATE TABLE t (v TEXT)');
        $db->exec("INSERT INTO t VALUES ('ok')");

        return $db->query('SELECT v FROM t')->fetchColumn() === 'ok';
    },
    'xml'      => function () {
        // (XSLT's namespace, split so that it isn't taken for a download: ci/sources.py)
        $ns  = 'http'.'://www.w3.org/1999/XSL/Transform';
        $xsl = new XSLTProcessor();
        $xsl->importStylesheet(new SimpleXMLElement('<xsl:stylesheet version="1.0" xmlns:xsl="'.$ns.'"><xsl:template match="/">ok</xsl:template></xsl:stylesheet>'));

        return strpos((string)$xsl->transformToXml(new SimpleXMLElement('<a/>')), 'ok') !== false;
    },
    'zip'      => function () {
        $file = tempnam(sys_get_temp_dir(), 'zip');
        $zip  = new ZipArchive();
        $zip->open($file, ZipArchive::OVERWRITE);
        $zip->addFromString('a.txt', 'ok');
        $zip->close();
        $zip->open($file);

        return $zip->getFromName('a.txt') === 'ok';
    },
    'curl'     => function () {
        return strpos(curl_version()['ssl_version'], 'OpenSSL') === 0;
    },
    'gmp'      => function () {
        return gmp_strval(gmp_pow(2, 100)) === '1267650600228229401496703205376';
    },
    'bcmath'   => function () {
        return bcadd('0.1', '0.2', 1) === '0.3';
    },
    'yaml'     => function () {
        return yaml_parse('a: 1') === ['a' => 1];
    },
    'igbinary' => function () {
        return igbinary_unserialize(igbinary_serialize(['a' => 1])) === ['a' => 1];
    },
    'apcu'     => function () {
        return function_exists('apcu_store');
    },
    'tidy'     => function () {
        return strpos((string)tidy_repair_string('<p>a'), '</p>') !== false;
    },
    'fileinfo' => function () {
        return (new finfo(FILEINFO_MIME_TYPE))->buffer("%PDF-1.4\n%abc\n1 0 obj\n") === 'application/pdf';
    },
];
$failed = [];

foreach ($checks as $name => $check) {
    if (!$check()) {
        $failed[] = $name;
    }
}

echo $failed ? 'FAILED: '.implode(', ', $failed)."\n" : "ok\n";
exit($failed ? 1 : 0);
PHP
    ${php} -n -d display_errors=1 ${test}/check.php

    # php-fpm: its version, and a configuration it accepts
    qemu-arm -cpu cortex-a9 ${ARM_BINARIES}/php-fpm -n -v | grep "^PHP ${VERSION} (fpm-fcgi)" > /dev/null
    printf '[global]\nerror_log = %s/fpm.log\n[www]\nuser = nobody\nlisten = %s/fpm.sock\npm = static\npm.max_children = 1\n' \
        ${test} ${test} > ${test}/php-fpm.conf
    qemu-arm -cpu cortex-a9 ${ARM_BINARIES}/php-fpm -n -t -y ${test}/php-fpm.conf
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    # The Intel build (unless it's already made: e.g. only the ARM build is missing - it takes far longer)
    if [ -x ${OUTPUT_PATH}/php ] && [ -x ${OUTPUT_PATH}/php-fpm ] && [ -f ${OUTPUT_PATH}/extensions.txt ] \
        && [ -d ${OUTPUT_PATH}.sources/spc-downloads ]; then
        echo "PHP ${VERSION} (amd64) is already built: ${OUTPUT_PATH}"
    else
        build_php

        # Copy to output
        mkdir -p ${OUTPUT_PATH}
        cp ${BUILD_PATH}/buildroot/bin/php ${BUILD_PATH}/buildroot/bin/php-fpm ${OUTPUT_PATH}/
        ${OUTPUT_PATH}/php -v
        ${OUTPUT_PATH}/php -m > ${OUTPUT_PATH}/extensions.txt

        # The sources of PHP and the libraries built into it, for the app's releases (ci/README.md, Sources)
        rm -rf ${OUTPUT_PATH}.sources
        mkdir -p ${OUTPUT_PATH}.sources/spc-downloads
        # (archives, folders of sources checked out, and static-php-cli's record of their versions: .lock.json)
        cp -r ${BUILD_PATH}/downloads/. ${OUTPUT_PATH}.sources/spc-downloads/
        du -sh ${OUTPUT_PATH}.sources
    fi

    build_arm_php
    check_arm_php
    # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
    rm -rf ${OUTPUT_ROOT}/armhf
    mkdir -p ${OUTPUT_ROOT}/armhf
    cp -a ${BUILD_PATH}/armhf-out/. ${OUTPUT_ROOT}/armhf/

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run

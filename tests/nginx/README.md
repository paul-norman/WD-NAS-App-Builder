# Nginx tests

Tests for the [Nginx app](../../apps/nginx/README.md), installed from its package in a stand-in for the NAS, with stand-ins for what it proxies to *(the NAS's dashboard on port 80, Navidrome on 4533, Calibre-Web on 8083 - each answering with what it received)* and the [PHP app](../../apps/php/README.md)'s php-fpm *(its binary only: WD's own PHP isn't swapped)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh nginx php    # first: both packages
tests/nginx/run_tests.sh                             # the page on PHP 7.4 - WD's version
tests/nginx/run_tests.sh --php both                  # and on 8.5 (the PHP app's)
```

What it checks:

- **First start**: answering on 443 with its temporary self-signed certificate; the page's status *(running, configuration OK, PHP available, the installed apps found)*; the page refused without a NAS admin's login or with a wrong CSRF token.
- **Apps**: saving them writes their sites and reloads Nginx; `music.<domain>` reaches Navidrome with its name *(Host)*, `https` *(X-Forwarded-Proto)*, the visitor's address *(X-Real-IP)* and X-Forwarded-Host; the domain itself shows the home app *(the NAS's dashboard)*; the start page *(`apps.<domain>`)* lists the apps and answers any other name - never an app; HTTP/2; uploads *(Calibre-Web: no size limit, a 64MB upload)* and streaming *(Navidrome: not buffered)*; refused: a bad name, a target that isn't http(s), a name used twice - with nothing changed.
- **Apps added by other apps** *(as the Store adds a recipe's site)*: `add-app` reaches it and knows its address; a name used for another target refused; `remove-app`.
- **User sites**: a static site; a `.php` file in a site without PHP neither run nor shown; a PHP site through the PHP app's php-fpm *(PHP 8.5)*; a site can't take an app's name.
- **Its own certificate**: one with another's key refused; a valid one served, its key root's only.
- **A configuration error** in a file of the user's: the reload refused with the error, Nginx carrying on with the previous configuration.
- **Stopping**.

Not covered here *(tested on the NAS)*: Let's Encrypt certificates *(lego's DNS-01 challenge needs a real domain and DNS provider)*, HTTP/3 *(QUIC)* and the NAS's own dashboard behind it.

Needs Docker. Logs go in `$NGINX_TEST_WORK`, by default `/tmp/nginx-tests`.

# Nginx App

[Nginx](https://nginx.org/) gives the NAS's apps proper HTTPS addresses - e.g. `https://jellyfin.nas.example.com` instead of `http://nas:8096` - with free, automatically renewed certificates from [Let's Encrypt](https://letsencrypt.org/) *(or another ACME certificate authority)*. **Intel models only**.

- Nginx listens on port `443` *(HTTPS, with HTTP/2 and HTTP/3)* next to the NAS's own web interface *(which keeps ports 80 and 8543)*. **It's meant for the local network only**: forwarding port 443 from the Internet would expose every app.
- Nginx is a static build *(`static/nginx`: OpenSSL 3.5, PCRE2, zlib and Brotli built in)*; certificates come from [lego](https://go-acme.github.io/lego/), downloaded from its official releases and checked against their published checksums.
- Its worker processes run as `nobody`. Access logging is off by default *(it would keep the NAS's disks from spinning down)*; the error log stays on.

## Management page

Nginx's Configuration page in the NAS dashboard *(Apps → Nginx → Configuration)* sets everything up. Only NAS admins can use it *(see [Management pages](../README.md#management-pages))*.

### Getting a certificate (once)

Scroll down to the Certificate section.

Remember, **this app is only designed to be for LAN use**, so in addition to getting a certificate, you will also need to add this domain to your local DNS resolver (e.g. [Pi Hole](../../recipes/pihole/README.md)) manually. You can forward port 443 on your router if you wish, but it's not recommended.

There are two types of certificate possible, a self-signed certificate ([guide](OWN-CERTIFICATE.md)), or one from a certificate authority. Since domain names are cheap *(~$10-15 USD per year)* and SSL certificates are free these days, it's far better to use the latter method.

No domain? [deSEC](https://desec.io/) *(free `dedyn.io` names, wildcards supported)* and [Duck DNS](https://www.duckdns.org/) work too.

If you choose to use an official domain name *(recommended)*, you need to ensure your registrar uses a [supported DNS provider](https://go-acme.github.io/lego/dns/) - the list is quite long, so there's plenty of choice. If your domain name is being used online, it's best to use a subdomain in this system, e.g. `nas.example.com`. You select your DNS provider from the dropdown, enter whatever information that provider requires and then press the "Save and get the certificate" button.

Issuing a certificate takes a few minutes: the DNS record has to spread before the CA checks it, and some providers confirm each change slowly (on Route 53, `AWS_WAIT_FOR_RECORD_SETS_CHANGED=false` skips that wait - lego still checks the record is visible before the CA does). The staging server is only tried again after the settings change.

If the domain has a wildcard CNAME *(e.g. `*.example.com → example.com`)*, lego follows it and writes the challenge record at its target - add `LEGO_DISABLE_CNAME_SUPPORT=true` under "Other variables" to keep it at `_acme-challenge.<domain>`. `LEGO_DNS_RESOLVERS=1.1.1.1:53` helps where a local DNS server answers for the domain itself.

### Assigning apps pretty URLs

- **Apps** - the installed apps with a web interface are listed, each reached at `https://<app_name>.<domain>` - except the NAS's dashboard, which is at the domain itself *(`https://<domain>` - its own login still applies)*. Which app the domain shows can be changed on the page *(or set to the start page)*. Each app brings its own site *(see [below](#how-apps-bring-their-own-site))*: it can be renamed or switched off, and the rest is the app's, kept up to date as the app changes. Other addresses can be added *(anything on the network, e.g. a router)*, with these options:

  - **Host** - the name sent to the app, for apps that check it *(e.g. Syncthing: `localhost`)*;
  - **Path** - only this path is passed on *(e.g. `/phpMyAdmin/`)*, and the site's root goes to it;
  - **Start** - the page the site's root goes to, with every path still passed on *(e.g. Pi-hole's `/admin/`, whose pages call its `/api`)*;
  - **Uploads** - no size limit on requests, and long ones allowed *(e.g. photos and videos, git pushes)*;
  - **Streaming** - each response passed on as it comes, and connections kept open *(e.g. music, notifications, live updates)*.
- **Certificate** - a wildcard certificate for the domain *(`domain` and `*.domain`)*:
  - **From an ACME CA, using a DNS-01 challenge:** lego briefly adds a TXT record through the DNS provider's API, so nothing on the NAS has to be reachable from the internet. Every DNS provider lego supports can be chosen *(over 200, e.g. Cloudflare, Route 53, Gandi, OVH, Hetzner, deSEC, Duck DNS)*: the page builds each provider's form from lego's own description of it. Credentials are saved root-only and never shown again. It's tried on the CA's staging server first *(where it has one)*, and renewed automatically *(checked daily; the NAS shows an alert if renewal fails)*.
  - **Your own certificate**, pasted in *(PEM)*.
  - Until either is set up, a temporary self-signed certificate is used *(browsers warn about it)*.
- **Sites** - your own websites, each a folder on the NAS *(e.g. `/mnt/HD/HD_a2/Web/blog`)* reached at `https://<app_name>.<domain>`, with or without PHP *(see below)*.
- **Quick links** - every app and site, once the certificate is trusted.
- **Local DNS** - the records to add *(e.g. to Pi-hole or a router)* so that devices find the NAS under those names.
- **Start page** - `https://apps.<domain>` lists every app and site that's switched on *(`apps` is kept for it - apps and sites can't use that name)*, each with its icon and its address, and the NAS's dashboard as a link at the top. A recipe's sites are together under its name *(e.g. the Arr stack's)*. Apps with their own page in the NAS dashboard get a **Configure** link, as does each recipe *(its page in the Store)*: it opens the dashboard *(its own site, which must be on - its login first, if it asks)*, then that page. That works because the Nginx app adds a small script to the dashboard's pages, on the dashboard's site only *(`lib/dashboard.js`)*: the NAS only shows apps' pages inside the dashboard. The start page also answers for any name without a site of its own.

## How apps bring their own site

Each app declares its site, and the Nginx app reads the declarations every time it writes its sites *(when it starts, when the page saves, and when an app runs `sites.php generate`)*:

- **An app** ships `nginx.json` in its package *(so it's at `Nas_Prog/<app>/nginx.json`)*, with the fields above - `name` *(the one it's offered as)*, `label`, `target`, and any of `host`, `path`, `start`, `uploads` and `stream`. An app can add `auth_file` *(one without a login of its own, or as a second lock in front of its login)*: a password file it keeps in its data folder *(e.g. `"auth_file": "_kvweb/htpasswd"`, relative to `Nas_Prog` - an htpasswd file, owned by root and readable by the group Nginx's workers run as - `nobody`'s own: `nogroup` on most systems, the share users' group on WD's NAS - e.g. SHA-512 crypt hashes)*. Its site then asks for a user name and password before anything is passed on, and refuses everything while the file is missing:

  ```json
  {
  	"name": "git",
  	"label": "Forgejo",
  	"target": "http://127.0.0.1:3002",
  	"uploads": true
  }
  ```

- **A [Docker recipe](../../recipes/README.md)** installed by the Store: its `recipe.json`'s `web` block *(`port`, `path` as its start page, and `nginx`: `name`, `uploads`, `stream`)*, read from the recipe's folder.
- **The NAS's dashboard and Plex** *(packaged by Plex)* are built in, as are this project's apps installed before they shipped `nginx.json` *(only while their folder has none)*.

Only whether each is on, its name and its label are the user's *(on the page)*. When an app's needs change, its update changes its site. When it's removed, its site goes *(its name and label are kept for a reinstall)*. An app whose name is already taken is offered as `<name>-2`. A declaration that isn't valid is ignored. An app should run `php <Nginx app>/lib/sites.php generate <its data>` and reload Nginx when it's installed or removed, so that its site comes or goes straight away.

## Adding a site from a script

Scripts can also add, update and remove a site, without editing `apps.json`:

```sh
php /mnt/HD/HD_a2/Nas_Prog/nginx/lib/sites.php add-app /mnt/HD/HD_a2/Nas_Prog/_nginx photos http://127.0.0.1:2283 "Immich" --uploads
php /mnt/HD/HD_a2/Nas_Prog/nginx/lib/sites.php url /mnt/HD/HD_a2/Nas_Prog/_nginx photos      # https://photos.<domain>/
php /mnt/HD/HD_a2/Nas_Prog/nginx/lib/sites.php remove-app /mnt/HD/HD_a2/Nas_Prog/_nginx photos
sh /mnt/HD/HD_a2/Nas_Prog/nginx/nginx_ctl.sh reload
```

- `add-app <data> <name> <target> [<label>]` takes `--uploads`, `--stream`, `--host=<host>`, `--path=<path>` and `--start=<path>` *(as on the page)*. Adding a name that's already there with the same target updates it, keeping whether it's switched on; a name used for another target, or by one of your sites, is refused.
- `add-app` and `remove-app` leave an app's own site *(above)* as it is: its app decides.
- `url` prints its address, or nothing *(exit status 1)* while it has none - no domain set yet, or switched off.

## Sites and PHP

Sites with PHP use **PHP 8.5 from the [PHP app](../php/README.md)** *(install it too)*, through a php-fpm of the Nginx app's own - separate from the NAS's *(which runs WD's web interface as root)*:

- It runs as the unprivileged `nobody` user *(like Nginx's workers)*, with workers started only when requests come in. Only Nginx can connect to it *(`/var/run/nginx-php.sock`)*.
- Its settings are `_nginx/php/php.ini` *(sessions in `_nginx/php/sessions`, errors in `_nginx/logs/php-errors.log`, the NAS's timezone)* and `_nginx/php/php-fpm.conf`; restart PHP from the page after changing them.
- It runs as `nginx-php-fpm` *(a hard link to the PHP app's php-fpm)*: WD's own `php-fpm.sh` finds its php-fpm by its file name, and would otherwise stop the sites' PHP with it.
- Files it creates are writable by everyone *(like the NAS's shares)*, so they can still be changed over SMB.
- The PHP app's switch *(replacing the NAS's own PHP 7.4)* is independent: sites get PHP 8.5 either way.

Each site can send unknown paths to `index.php` *(front controllers, e.g. WordPress, or Laravel with the folder set to its `public` folder)*. Without PHP, a site refuses `.php` files *(`server.d/php-off.conf`)* rather than showing their source.

### Locking down DNS credentials

Give lego credentials that can only do what it needs. For example, on AWS Route 53 an IAM user with only this policy *(fill in the hosted zone's ID and domain)* can add and remove `_acme-challenge` TXT records and nothing else - set `AWS_HOSTED_ZONE_ID` on the page too, so that it doesn't need to list your hosted zones:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "route53:GetChange", "Resource": "arn:aws:route53:::change/*" },
    { "Effect": "Allow", "Action": "route53:ListResourceRecordSets", "Resource": "arn:aws:route53:::hostedzone/ZONE_ID" },
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/ZONE_ID",
      "Condition": {
        "ForAllValues:StringEquals": { "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"] },
        "ForAllValues:StringLike": { "route53:ChangeResourceRecordSetsNormalizedRecordNames": ["_acme-challenge.example.com", "_acme-challenge.*.example.com"] }
      }
    }
  ]
}
```

Most other providers offer tokens limited to one domain's DNS.

## Configuration

Everything lives in `Nas_Prog/_nginx` *(kept across reinstalls)*, in folders named after the block their files are included in. Every included file ends in `.conf`, so renaming one *(e.g. to `.conf.off`)* switches it off:

| Folder       | Included in   | Holds                                                                                                                                                                |
|--------------|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `nginx.conf` | -             | The skeleton: includes the folders below                                                                                                                             |
| `modules/`   | the top level | e.g. a `stream { }` block for TCP / UDP proxying                                                                                                                     |
| `http.d/`    | `http { }`    | TLS, gzip, Brotli, proxy buffers, timeouts, logs, MIME types...                                                                                                      |
| `server.d/`  | `server { }`  | `https.conf` *(the HTTPS listen lines and certificate)*, `proxy.conf` *(proxy and WebSocket headers)*, `php.conf` / `php-off.conf`, `headers.conf`, `hidden.conf`... |
| `ssl.d/`     | `server { }`  | `default.conf`: the default certificate                                                                                                                              |
| `sites/`     | `http { }`    | One file per site                                                                                                                                                    |
| `params/`    | -             | Nginx's MIME types and FastCGI parameters                                                                                                                            |
| `php/`       | -             | The sites' PHP: `php.ini` and `php-fpm.conf`                                                                                                                         |

So a site only needs:

```nginx
server {
    include     server.d/https.conf;
    server_name jellyfin.example.com;

    location / {
        include          server.d/proxy.conf;
        proxy_set_header Host $host;
        proxy_pass       http://127.0.0.1:8096;
    }
}
```

The app's own files are only added where missing, so edits are kept. Sites the app generates *(`sites/00-app-start.conf`, `sites/50-site-*.conf` and `sites/60-app-*.conf`)* start with a comment saying so and are rewritten from the page - add your own sites under other names. Before every reload the configuration is checked *(`nginx -t`)*: if it has an error, Nginx carries on with the last working one and the page shows the error.

`nginx_ctl.sh` *(`setup`, `start`, `stop`, `reload`, `test`, `php-restart`)* and `cert.sh` *(`issue`, `renew`)* in the app's install directory do the same over SSH.

## Building the Nginx app

From the project root directory:

```bash
./build.sh nginx
```

The WD bin files will be created in `packages/nginx/`. The Nginx version is set in `apkg.rc` and `static/nginx/build.sh` *(which must match)*, the lego version in `build.sh`.

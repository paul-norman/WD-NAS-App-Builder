<?php
// phpBB's router for PHP's own web server (run by phpbb_ctl.sh, from phpBB's folder): what phpBB's .htaccess files do
// on Apache, and its sample Nginx configuration (docs/nginx.sample.conf) - its private folders and files are never
// served (its settings, cache, attachments, uploaded avatars, backups, code and packages), nor hidden ones. Everything
// else is left to PHP's server: files as they are, scripts run (also with a path after them, e.g. app.php/help/faq).

// (Not parse_url(): it reads a path starting with // as a host name)
$path = rawurldecode((string)strtok(isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/', '?#'));
// One form of the path: no doubled slashes, and nothing that climbs out of a folder
$path = '/'.ltrim((string)preg_replace('#/+#', '/', str_replace('\\', '/', $path)), '/');

$private = '#^/(config\.php|common\.php|composer\.(json|lock)|config|cache|files|images/avatars/upload|includes|phpbb|store'
    .'|vendor|bin|install|install\.dist|docs/[^/]+\.(yml|php))(/|$)#i';

if (strpos($path, '/.') !== false || preg_match($private, $path)) {
    http_response_code(403);
    header('Content-Type: text/plain');
    echo "Forbidden\n";

    return true;
}

return false;

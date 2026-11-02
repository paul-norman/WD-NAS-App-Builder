<?php
// The daily check for new versions (from root's crontab - see init.sh): reads every repository's catalogue again, as
// the page's Refresh does, so that updates show without opening the Store. Run with the NAS's PHP CLI:
//     php refresh.php
require __DIR__.'/store.php';

foreach (store_refresh_all() as $url => $error) {
    fwrite(STDERR, $url.': '.$error."\n");
}

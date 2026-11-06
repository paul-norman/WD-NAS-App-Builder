<?php
// Loaded before BookStack's every request and command (PHP's auto_prepend_file, set by bookstack_ctl.sh): what older
// PHP apps' PHP lacks and BookStack's framework (Laravel) uses. Before 8.5.12-3 its mbstring had no regular expressions
// (mbregex, which needs the Oniguruma library), so mb_split() was missing - Laravel only splits on whitespace with it
// (\s+), which PCRE does the same way in UTF-8 mode. With a newer PHP app this defines nothing.

if (!function_exists('mb_split')) {
    /**
     * Splits a string with a regular expression, as mbstring's mb_split() does (UTF-8, the encoding BookStack uses).
     *
     * @param string $pattern The regular expression, without delimiters (e.g. \s+)
     * @param string $string  The string
     * @param int    $limit   At most this many parts (-1: no limit)
     *
     * @return list<string>|false The parts, or false if the expression isn't valid
     */
    function mb_split(string $pattern, string $string, int $limit = -1)
    {
        return preg_split('/'.str_replace('/', '\/', $pattern).'/u', $string, $limit);
    }
}

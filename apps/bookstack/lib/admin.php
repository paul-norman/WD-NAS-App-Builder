<?php
// BookStack's administrator, set up by the app (run by bookstack_ctl.sh as BookStack's own user, with the PHP app's PHP,
// from BookStack's folder - so that it uses BookStack's own settings, database and password hashing). The password is
// read from the standard input (one line), never from the command line:
//     php admin.php first <email>  - BookStack's default administrator (admin@admin.com, password "password") given the
//                                    email address and the password: prints its ID
//     php admin.php set <id>       - the administrator with that ID given the password (its other sessions end)

/**
 * Boots BookStack (Laravel) from the current folder, as its own console commands do.
 *
 * @return void
 */
function bookstack_boot(): void
{
    require getcwd().'/vendor/autoload.php';

    $app = require getcwd().'/bootstrap/app.php';

    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
}

/**
 * Gives a user a password (hashed as BookStack hashes them), ending their other sessions ("remember me" too).
 *
 * @param BookStack\Users\Models\User $user     The user
 * @param string                      $password The password
 *
 * @return void
 */
function bookstack_set_password(BookStack\Users\Models\User $user, string $password): void
{
    $user->password = Illuminate\Support\Facades\Hash::make($password);
    $user->setRememberToken(Illuminate\Support\Str::random(60));
    $user->save();
}

$command  = isset($argv[1]) ? $argv[1] : '';
$argument = isset($argv[2]) ? $argv[2] : '';
$password = trim((string)fgets(STDIN));

if (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $password)) {
    fwrite(STDERR, "Passwords are 12-128 characters: letters, digits and . _ ~ -\n");

    exit(1);
}

bookstack_boot();

if ($command === 'first') {
    // Its default administrator, made by its database's set-up - or, if that's gone (e.g. a database kept from an
    // earlier install), the one already made with this email address
    $user = BookStack\Users\Models\User::query()->where('email', 'admin@admin.com')->first()
        ?: BookStack\Users\Models\User::query()->where('email', $argument)->first();

    if (!$user || !$user->hasSystemRole('admin')) {
        fwrite(STDERR, "BookStack's default administrator wasn't found\n");

        exit(1);
    }

    $user->email           = $argument;
    $user->email_confirmed = true;
    bookstack_set_password($user, $password);
    echo $user->id."\n";

    exit(0);
}

if ($command === 'set') {
    $user = BookStack\Users\Models\User::query()->find((int)$argument);

    if (!$user) {
        fwrite(STDERR, "The administrator (ID {$argument}) wasn't found\n");

        exit(1);
    }

    bookstack_set_password($user, $password);

    exit(0);
}

fwrite(STDERR, "Usage: php admin.php first <email> | set <id> (the password on the input)\n");

exit(2);

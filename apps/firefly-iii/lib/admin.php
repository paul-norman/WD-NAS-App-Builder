<?php
// Firefly III's owner, set up by the app (run by firefly_ctl.sh as Firefly III's own user, with the PHP app's PHP, from
// Firefly III's folder - so that it uses Firefly III's own settings, database and password hashing). The password is
// read from the standard input (one line), never from the command line:
//     php admin.php first <email>  - its owner (its first user, who manages the others) made with the email address and
//                                    the password, as its own sign-up makes it: prints its ID
//     php admin.php set <id>       - the user with that ID given the password (its other sessions end)

/**
 * Boots Firefly III (Laravel) from the current folder, as its own console commands do.
 *
 * @return void
 */
function firefly_boot(): void
{
    require getcwd().'/vendor/autoload.php';

    $app = require getcwd().'/bootstrap/app.php';

    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
}

/**
 * Gives a user a password (hashed as Firefly III hashes them), ending their other sessions ("remember me" too).
 *
 * @param FireflyIII\User $user     The user
 * @param string          $password The password
 *
 * @return void
 */
function firefly_set_password(FireflyIII\User $user, string $password): void
{
    $user->password = Illuminate\Support\Facades\Hash::make($password);
    $user->setRememberToken(Illuminate\Support\Str::random(60));
    $user->save();
}

$command  = isset($argv[1]) ? $argv[1] : '';
$argument = isset($argv[2]) ? $argv[2] : '';
$password = trim((string)fgets(STDIN));

// (any visible characters - the management page checked its length)
if ($password === '' || preg_match('/[\x00-\x1f\x7f]/', $password)) {
    fwrite(STDERR, "Passwords are visible characters only (no control characters)\n");

    exit(1);
}

firefly_boot();

/** @var FireflyIII\Repositories\User\UserRepositoryInterface $repository */
$repository = app(FireflyIII\Repositories\User\UserRepositoryInterface::class);

if ($command === 'first') {
    // A database kept from an earlier install: its owner with this email address, else its first owner
    $user = FireflyIII\User::query()->where('email', $argument)->first();

    if (!$user) {
        foreach (FireflyIII\User::query()->orderBy('id')->get() as $candidate) {
            if ($repository->hasRole($candidate, 'owner')) {
                $user = $candidate;

                break;
            }
        }
    }

    if (!$user) {
        if ($repository->count() > 0) {
            fwrite(STDERR, "Firefly III already has users, none of them its owner\n");

            exit(1);
        }

        // As its sign-up makes its first user: the owner's role (given to the first user), its own financial
        // administration (group), and its currencies' exchange rates
        $user = $repository->store([
            'blocked'      => false,
            'blocked_code' => null,
            'email'        => $argument,
        ]);
        firefly_set_password($user, $password);
        $owner = new FireflyIII\Notifications\Notifiables\OwnerNotifiable();
        event(new FireflyIII\Events\Security\System\NewUserRegistered($owner, $user));
        echo $user->id."\n";

        exit(0);
    }

    if (!$repository->hasRole($user, 'owner')) {
        fwrite(STDERR, "The user {$argument} isn't Firefly III's owner\n");

        exit(1);
    }

    firefly_set_password($user, $password);
    echo $user->id."\n";

    exit(0);
}

if ($command === 'set') {
    $user = FireflyIII\User::query()->find((int)$argument);

    if (!$user) {
        fwrite(STDERR, "The owner (ID {$argument}) wasn't found\n");

        exit(1);
    }

    firefly_set_password($user, $password);

    exit(0);
}

fwrite(STDERR, "Usage: php admin.php first <email> | set <id> (the password on the input)\n");

exit(2);

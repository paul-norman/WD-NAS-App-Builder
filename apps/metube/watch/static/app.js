// The Watch page: logging in, downloading a link (through MeTube, into the person's own folder), their videos with a
// player, Keep / Delete, and their clean-up days. Talks to watch.py's API (same origin, the session cookie)
(function () {
    'use strict';

    const part = function (id) {
        return document.getElementById(id);
    };

    let playing   = null;
    let markedFor = null;
    let timer     = null;
    let fade      = null;
    let segments  = [];
    let settings  = null;
    let built     = false;
    let lists     = {};
    let latest    = null;
    let failed    = [];

    // SponsorBlock's categories, as the settings name them
    const categoryNames = {
        sponsor:        'Sponsors',
        selfpromo:      'Self-promotion',
        interaction:    'Like / subscribe reminders',
        intro:          'Intros',
        outro:          'Outros and end cards',
        preview:        'Previews and recaps',
        hook:           'Hooks and teasers',
        music_offtopic: 'Non-music in music videos',
        filler:         'Filler and tangents'
    };

    /**
     * Shows a message at the top of the page (above the download box): good news goes after a few seconds, a problem
     * stays until the next message.
     *
     * @param {string}  text What to say ('' clears it)
     * @param {boolean} good Whether it's good news (else shown as a problem)
     *
     * @return {void}
     */
    function say(text, good) {
        clearTimeout(fade);
        part('message').textContent = text;
        part('message').className   = good ? '' : 'bad';

        if (good && text) {
            fade = setTimeout(function () {
                part('message').textContent = '';
            }, 5000);
        }
    }

    /**
     * Calls the API: a GET without data, else a JSON POST marked as the page's (the server refuses others' posts).
     *
     * @param {string} path The API's path (e.g. api/videos)
     * @param {Object} data What to post
     *
     * @return {Promise.<Object>} The answer (rejected with its text when it failed; a 401 shows the login form)
     */
    function api(path, data) {
        let options = { credentials: 'same-origin', headers: {} };

        if (data !== undefined) {
            options.method                      = 'POST';
            options.headers['Content-Type']     = 'application/json';
            options.headers['X-Requested-With'] = 'watch';
            options.body                        = JSON.stringify(data);
        }

        return fetch(path, options).then(function (response) {
            return response.text().then(function (text) {
                if (response.status === 401 && path !== 'api/login') {
                    showLogin();
                }

                if (!response.ok) {
                    throw new Error(text || response.statusText);
                }

                return text ? JSON.parse(text) : {};
            });
        });
    }

    /**
     * A file's address under one of the server's routes (each part of its path encoded).
     *
     * @param {string} route media or thumb
     * @param {string} file  The file, relative to the person's folder
     *
     * @return {string} Its address
     */
    function fileUrl(route, file) {
        return route + '/' + file.split('/').map(encodeURIComponent).join('/');
    }

    /**
     * A size in bytes, for people.
     *
     * @param {number} bytes The size
     *
     * @return {string} e.g. 12.3 MB
     */
    function size(bytes) {
        let units = ['B', 'KB', 'MB', 'GB'];
        let i     = 0;

        while (bytes >= 1024 && i < units.length - 1) {
            bytes /= 1024;
            i++;
        }

        return `${bytes.toFixed(i ? 1 : 0)} ${units[i]}`;
    }

    /**
     * Shows the login form (and nothing else).
     *
     * @return {void}
     */
    function showLogin() {
        clearInterval(timer);
        part('login').hidden  = false;
        part('app').hidden    = true;
        part('who').hidden    = true;
        part('logout').hidden = true;
    }

    /**
     * Makes an element with a class and text.
     *
     * @param {string} tag       Its tag
     * @param {string} className Its class ('' for none)
     * @param {string} text      Its text
     *
     * @return {HTMLElement} The element
     */
    function make(tag, className, text) {
        let element = document.createElement(tag);

        if (className) {
            element.className = className;
        }

        if (text !== undefined) {
            element.textContent = text;
        }

        return element;
    }

    /**
     * A small button that runs an action.
     *
     * @param {string}   text   Its label
     * @param {Function} action What it does
     *
     * @return {HTMLButtonElement} The button
     */
    function smallButton(text, action) {
        let button = make('button', 'quiet', text);

        button.type = 'button';
        button.addEventListener('click', action);

        return button;
    }

    /**
     * Plays a video (or audio) in the player, marking it watched once it's nearly over.
     *
     * @param {Object} video The video, as the API lists it
     *
     * @return {void}
     */
    function play(video) {
        let player = part('player');

        playing       = video.file;
        markedFor     = null;
        player.src    = fileUrl('media', video.file);
        player.poster = video.thumbnail ? fileUrl('thumb', video.thumbnail) : '';
        part('player-title').textContent = video.title + (video.playlist && lists[video.playlist] ?
            ` (${lists[video.playlist].indexOf(video) + 1} of ${lists[video.playlist].length}, ${video.playlist})` : '');
        part('player-box').hidden        = false;
        part('skipped').textContent      = '';
        part('player-box').scrollIntoView({ behavior: 'smooth' });

        // The person's own speed (a new source resets it)
        player.defaultPlaybackRate = settings ? settings.speed : 1;
        player.playbackRate        = player.defaultPlaybackRate;
        part('speed').value        = String(player.playbackRate);

        player.play().catch(function () {
            // (the browser may want a tap first)
        });

        // SponsorBlock's segments to skip (none unless it's a YouTube video, skipping is on, and it wasn't cut)
        segments = [];

        if (video.video_id && !video.cut && settings && settings.sb_skip) {
            api(`api/segments?file=${encodeURIComponent(video.file)}`).then(function (response) {
                if (playing === video.file) {
                    segments = response.segments;
                }
            }, function () {});
        }
    }

    /**
     * Fills the speed menu (0.25x steps, from the server) and the SponsorBlock categories, once.
     *
     * @param {number[]} speeds     The speeds offered
     * @param {string[]} categories SponsorBlock's categories
     *
     * @return {void}
     */
    function buildChoices(speeds, categories) {
        if (built) {
            return;
        }

        speeds.forEach(function (speed) {
            let option = make('option', '', `${speed}×`);

            option.value = String(speed);
            part('speed').appendChild(option);
        });

        categories.forEach(function (category) {
            let label = make('label');
            let box   = make('input');

            box.type          = 'checkbox';
            box.value         = category;
            box.dataset.group = 'category';
            label.appendChild(box);
            label.appendChild(document.createTextNode(` ${categoryNames[category] || category}`));
            part('sb-categories').appendChild(label);
        });

        built = true;
    }

    /**
     * Saves some of the person's own settings.
     *
     * @param {Object} changes The settings changed
     * @param {string} done    What to say once saved ('' for nothing)
     *
     * @return {Promise} Done once saved
     */
    function saveSettings(changes, done) {
        return api('api/settings', changes).then(function () {
            Object.assign(settings, changes);

            if (done) {
                say(done, true);
            }
        }, function (error) {
            say(error.message, false);
        });
    }

    /**
     * Shows the downloads in progress (and failed ones), each with Cancel / Clear.
     *
     * @param {Object[]} queue The downloads, as the API lists them
     *
     * @return {void}
     */
    function showQueue(queue) {
        let list = part('queue');

        list.textContent            = '';
        part('queue-box').hidden    = !queue.length;
        part('clear-failed').hidden = !queue.some(function (item) {
            return item.status === 'error' && item.id;
        });
        failed = queue.filter(function (item) {
            return item.status === 'error' && item.id;
        });

        queue.forEach(function (item) {
            let row    = make('li');
            let failed = item.status === 'error';

            row.appendChild(make('span', 'title', item.title));

            if (failed) {
                row.appendChild(make('span', 'error', item.error || 'Failed'));
            } else if (item.percent !== null && item.percent !== undefined) {
                let bar = make('progress');

                bar.max   = 100;
                bar.value = item.percent;
                row.appendChild(bar);
            } else {
                row.appendChild(make('span', 'meta', item.status === 'pending' ? 'Waiting' : 'Starting…'));
            }

            if (item.id) {
                row.appendChild(smallButton(failed ? 'Clear' : 'Cancel', function () {
                    api('api/cancel', { id: item.id, where: item.where }).then(refresh, function (error) {
                        say(error.message, false);
                    });
                }));
            }

            list.appendChild(row);
        });
    }

    /**
     * A video's card: its thumbnail (which plays it), what's known of it, and Keep / Delete.
     *
     * @param {Object} video The video, as the API lists it
     *
     * @return {HTMLElement} The card
     */
    function videoCard(video) {
        let card    = make('li', 'video');
        let thumb   = make(video.thumbnail ? 'img' : 'button', 'thumb');
        let info    = make('div', 'info');
        let meta    = make('span', 'meta');
        let actions = make('div', 'actions');
        let notes   = [size(video.size), new Date(video.added * 1000).toLocaleDateString()];

        if (video.thumbnail) {
            thumb.src     = fileUrl('thumb', video.thumbnail);
            thumb.alt     = '';
            thumb.loading = 'lazy';
        } else {
            thumb.type        = 'button';
            thumb.textContent = video.audio ? '♪' : '▶';
        }

        thumb.addEventListener('click', function () {
            play(video);
        });

        if (video.kept) {
            notes.push('kept');
        } else if (video.days_left !== null) {
            notes.push(video.days_left ? `deleted in ${video.days_left} day${video.days_left === 1 ? '' : 's'}` : 'deleted soon');
        }

        meta.textContent = notes.join(' · ');
        info.appendChild(make('span', 'title', (video.index ? `${video.index}. ` : '') + video.title));

        if (video.watched) {
            info.appendChild(make('span', 'meta watched', `Watched ${new Date(video.watched * 1000).toLocaleDateString()}` +
                (video.watched_elsewhere ? ' (media server)' : '')));
        }

        info.appendChild(meta);
        actions.appendChild(smallButton(video.kept ? 'Don\'t keep' : 'Keep', function () {
            api('api/keep', { file: video.file, keep: !video.kept }).then(refresh, function (error) {
                say(error.message, false);
            });
        }));
        actions.appendChild(smallButton('Rename', function () {
            let title = window.prompt('Its new title:', video.title);

            if (!title || title.trim() === video.title) {
                return;
            }

            api('api/rename', { file: video.file, title: title.trim() }).then(function (response) {
                // (still playing: the same file, under its new name)
                if (playing === video.file) {
                    playing   = response.file;
                    markedFor = markedFor === video.file ? response.file : markedFor;
                }

                say('Renamed.', true);
                refresh();
            }, function (error) {
                say(error.message, false);
            });
        }));
        actions.appendChild(smallButton('Delete', function () {
            if (!window.confirm(`Delete "${video.title}"?`)) {
                return;
            }

            if (playing === video.file) {
                closePlayer();
            }

            api('api/delete', { file: video.file }).then(function () {
                say('Deleted.', true);
                refresh();
            }, function (error) {
                say(error.message, false);
            });
        }));
        info.appendChild(actions);
        card.appendChild(thumb);
        card.appendChild(info);

        return card;
    }

    /**
     * The playlist the page shows (its address: #playlist=<name>), or null for the main view.
     *
     * @return {(string|null)} Its name
     */
    function shownPlaylist() {
        let match = /^#playlist=(.+)$/.exec(window.location.hash);

        return match ? decodeURIComponent(match[1]) : null;
    }

    /**
     * Opens a playlist's page (or the main view), as a new address - so the browser's Back goes back.
     *
     * @param {(string|null)} name The playlist, or null for the main view
     *
     * @return {void}
     */
    function openPlaylist(name) {
        window.location.hash = name ? `playlist=${encodeURIComponent(name)}` : '';
        window.scrollTo(0, 0);
    }

    /**
     * A playlist's card on the main view: its first video's thumbnail, its name, how many videos (and unwatched) - it
     * opens the playlist's page.
     *
     * @param {string}   name   The playlist
     * @param {Object[]} videos Its videos, in its order
     *
     * @return {HTMLElement} The card
     */
    function playlistCard(name, videos) {
        let card   = make('li', 'video playlist-card');
        let first  = videos.find(function (video) {
            return video.thumbnail;
        });
        let thumb  = make(first ? 'img' : 'button', 'thumb');
        let info   = make('div', 'info');
        let unseen = videos.filter(function (video) {
            return !video.watched;
        }).length;

        if (first) {
            thumb.src     = fileUrl('thumb', first.thumbnail);
            thumb.alt     = '';
            thumb.loading = 'lazy';
        } else {
            thumb.type        = 'button';
            thumb.textContent = '☰';
        }

        thumb.addEventListener('click', function () {
            openPlaylist(name);
        });
        info.appendChild(make('span', 'title', name));
        info.appendChild(make('span', 'meta count', videos.length ?
            `${videos.length} video${videos.length === 1 ? '' : 's'}` + (unseen ? `, ${unseen} not watched` : ', all watched') : 'Empty'));
        info.appendChild(smallButton('Open', function () {
            openPlaylist(name);
        }));
        card.appendChild(thumb);
        card.appendChild(info);

        return card;
    }

    /**
     * Shows the main view (single videos, newest first; playlists as cards) or one playlist's page (its videos in its
     * order, Play all, Delete playlist, back to the main view) - as the address says.
     *
     * @param {Object[]} videos    The videos, as the API lists them (newest first)
     * @param {string[]} playlists The playlists (folders), empty ones too
     *
     * @return {void}
     */
    function showVideos(videos, playlists) {
        let singles = videos.filter(function (video) {
            return !video.playlist;
        });
        let view    = shownPlaylist();

        lists = {};

        playlists.forEach(function (name) {
            lists[name] = [];
        });

        videos.forEach(function (video) {
            if (video.playlist) {
                (lists[video.playlist] = lists[video.playlist] || []).push(video);
            }
        });

        // In its order: a downloaded playlist by its numbers; one of the person's own by when each was added
        Object.keys(lists).forEach(function (name) {
            lists[name].sort(function (a, b) {
                let folderA = a.file.slice(0, a.file.lastIndexOf('/'));
                let folderB = b.file.slice(0, b.file.lastIndexOf('/'));

                return folderA.localeCompare(folderB) || (a.index || 0) - (b.index || 0) || a.added - b.added;
            });
        });

        if (view !== null && !lists[view]) {
            view = null;
            openPlaylist(null);
        }

        part('main-view').hidden     = view !== null;
        part('playlist-view').hidden = view === null;
        part('add-into').hidden      = view === null;
        part('add-into').textContent = view === null ? '' : `Downloads go into "${view}".`;

        if (view !== null) {
            showPlaylistPage(view, lists[view]);

            return;
        }

        part('videos').textContent = '';
        part('empty').hidden       = singles.length > 0;

        singles.forEach(function (video) {
            part('videos').appendChild(videoCard(video));
        });

        // The most recently added playlists first
        let names = Object.keys(lists).sort(function (a, b) {
            let last = function (name) {
                return Math.max.apply(null, [0].concat(lists[name].map(function (video) {
                    return video.added;
                })));
            };

            return last(b) - last(a) || a.localeCompare(b);
        });

        part('playlists').textContent = '';
        part('no-playlists').hidden   = names.length > 0;

        names.forEach(function (name) {
            part('playlists').appendChild(playlistCard(name, lists[name]));
        });
    }

    /**
     * Shows a playlist's page: its name and count, and its videos in its order.
     *
     * @param {string}   name   The playlist
     * @param {Object[]} videos Its videos, in its order
     *
     * @return {void}
     */
    function showPlaylistPage(name, videos) {
        part('playlist-name').textContent  = name;
        part('playlist-count').textContent = `${videos.length} video${videos.length === 1 ? '' : 's'}`;
        part('play-all').hidden            = !videos.length;
        part('playlist-empty').hidden      = videos.length > 0;

        part('playlist-videos').textContent = '';

        videos.forEach(function (video) {
            part('playlist-videos').appendChild(videoCard(video));
        });
    }

    /**
     * The video after one in its playlist (in its order), if any.
     *
     * @param {string} file The video, relative to the person's folder
     *
     * @return {(Object|null)} The next video
     */
    function nextInPlaylist(file) {
        let name   = file.indexOf('/') > 0 ? file.split('/')[0] : null;
        let videos = name ? lists[name] || [] : [];
        let at     = videos.findIndex(function (video) {
            return video.file === file;
        });

        return at >= 0 && at < videos.length - 1 ? videos[at + 1] : null;
    }

    /**
     * Loads the person's videos and downloads, and shows them (with their clean-up days, unless being edited).
     *
     * @return {Promise} Done once shown
     */
    function refresh() {
        return api('api/videos').then(function (response) {
            part('login').hidden    = true;
            part('app').hidden      = false;
            part('who').hidden      = false;
            part('logout').hidden   = false;
            part('who').textContent = response.name;

            if (!response.folder) {
                say('The NAS\'s admin hasn\'t set a download folder up yet (the MeTube app\'s page).', false);
            }

            showQueue(response.queue);
            showVideos(response.videos, response.playlists);
            latest = response;

            buildChoices(response.speeds, response.sponsor_categories);
            settings = response.settings;

            if (!part('settings-box').contains(document.activeElement)) {
                part('watched-days').value   = settings.watched_days;
                part('unwatched-days').value = settings.unwatched_days;
                part('sb-skip').checked      = settings.sb_skip;
                part('sb-cut').checked       = settings.sb_cut;

                document.querySelectorAll('[data-group="category"]').forEach(function (box) {
                    box.checked = settings.sb_categories.indexOf(box.value) >= 0;
                });
            }

            // Faster while something is downloading
            clearInterval(timer);
            timer = setInterval(refresh, response.queue.length ? 3000 : 30000);
        }, function (error) {
            if (part('login').hidden) {
                say(error.message, false);
            }
        });
    }

    /**
     * Stops and hides the player.
     *
     * @return {void}
     */
    function closePlayer() {
        let player = part('player');

        player.pause();
        player.removeAttribute('src');
        player.load();
        part('player-box').hidden = true;
        playing                   = null;
    }

    part('login').addEventListener('submit', function (event) {
        event.preventDefault();
        api('api/login', { name: part('login-name').value, password: part('login-password').value }).then(function () {
            part('login-password').value = '';
            say('', true);
            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    part('logout').addEventListener('click', function () {
        api('api/logout', {}).then(showLogin);
    });

    part('kind').addEventListener('change', function () {
        part('quality').hidden = part('kind').value === 'audio';
    });

    part('add').addEventListener('submit', function (event) {
        event.preventDefault();
        say('Adding…', true);
        api('api/add', { url: part('url').value.trim(), kind: part('kind').value, quality: part('quality').value, limit: Number(part('limit').value),
            playlist: shownPlaylist() || '' }).then(function () {
            part('url').value = '';
            say('Added: its progress shows under Downloading, then it appears in your videos.', true);
            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    part('player-close').addEventListener('click', closePlayer);

    // The address changed (a playlist opened, or Back): show that view again from the last answer
    window.addEventListener('hashchange', function () {
        if (latest) {
            showVideos(latest.videos, latest.playlists);
        }
    });

    part('back').addEventListener('click', function () {
        openPlaylist(null);
    });

    part('play-all').addEventListener('click', function () {
        let videos = lists[shownPlaylist()] || [];
        let next   = videos.find(function (video) {
            return !video.watched;
        });

        if (videos.length) {
            play(next || videos[0]);
        }
    });

    part('delete-playlist').addEventListener('click', function () {
        let name     = shownPlaylist();
        let videos   = lists[name] || [];
        let kept     = videos.filter(function (video) {
            return video.kept;
        }).length;
        let question = videos.length ? `Delete the playlist "${name}" and its ${videos.length - kept} videos?` +
            (kept ? ` (The ${kept} kept stay, and so does the playlist.)` : '') : `Delete the empty playlist "${name}"?`;

        if (!window.confirm(question)) {
            return;
        }

        if (playing && playing.indexOf(`${name}/`) === 0) {
            closePlayer();
        }

        api('api/delete-playlist', { playlist: name }).then(function (response) {
            say(`Deleted ${response.deleted} video${response.deleted === 1 ? '' : 's'}.`, true);

            if (!response.kept) {
                openPlaylist(null);
            }

            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    part('rename-playlist').addEventListener('click', function () {
        let name    = shownPlaylist();
        let renamed = window.prompt('The playlist\'s new name:', name);

        if (!renamed || renamed.trim() === name) {
            return;
        }

        api('api/rename-playlist', { playlist: name, name: renamed.trim() }).then(function (response) {
            if (playing && playing.indexOf(`${name}/`) === 0) {
                playing = response.name + playing.slice(name.length);
            }

            say('Renamed.', true);
            openPlaylist(response.name);
            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    part('new-playlist').addEventListener('click', function () {
        let name = window.prompt('The new playlist\'s name:');

        if (!name || !name.trim()) {
            return;
        }

        api('api/new-playlist', { name: name.trim() }).then(function (response) {
            say(`"${response.name}" made: what you download here now goes into it.`, true);
            openPlaylist(response.name);
            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    part('clear-failed').addEventListener('click', function () {
        Promise.all(failed.map(function (item) {
            return api('api/cancel', { id: item.id, where: 'done' }).catch(function () {});
        })).then(refresh);
    });

    // A playlist's video over: on to the next one in it
    part('player').addEventListener('ended', function () {
        let next = playing ? nextInPlaylist(playing) : null;

        if (next) {
            play(next);
        }
    });

    // SponsorBlock: jump over a segment as soon as playback is inside it
    part('player').addEventListener('timeupdate', function () {
        let player = part('player');
        let now    = player.currentTime;

        segments.forEach(function (segment) {
            if (now >= segment.start && now < segment.end - 0.3) {
                player.currentTime = segment.end;
                part('skipped').textContent = `Skipped: ${categoryNames[segment.category] || segment.category}`;

                setTimeout(function () {
                    part('skipped').textContent = '';
                }, 3000);
            }
        });
    });

    part('speed').addEventListener('change', function () {
        let speed = Number(part('speed').value);

        part('player').playbackRate        = speed;
        part('player').defaultPlaybackRate = speed;
        saveSettings({ speed: speed }, '');
    });

    part('sponsor-save').addEventListener('click', function () {
        let categories = [];

        document.querySelectorAll('[data-group="category"]').forEach(function (box) {
            if (box.checked) {
                categories.push(box.value);
            }
        });

        saveSettings({ sb_skip: part('sb-skip').checked, sb_categories: categories, sb_cut: part('sb-cut').checked },
            'SponsorBlock settings saved.');
    });

    // Watched once nearly over (90%), or at its end
    part('player').addEventListener('timeupdate', function () {
        let player = part('player');

        if (!playing || markedFor === playing || !player.duration || player.currentTime < player.duration * 0.9) {
            return;
        }

        markedFor = playing;
        api('api/watched', { file: playing }).then(refresh, function () {});
    });

    part('settings-save').addEventListener('click', function () {
        api('api/settings', {
            watched_days:   Number(part('watched-days').value),
            unwatched_days: Number(part('unwatched-days').value)
        }).then(function () {
            say('Clean-up saved.', true);
            refresh();
        }, function (error) {
            say(error.message, false);
        });
    });

    refresh();
})();

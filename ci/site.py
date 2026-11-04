"""
Builds the project's website (GitHub Pages) from the published catalogue
(store.json) and the apps' and recipes' READMEs: a home page (what the
project is, the visitor's NAS model, the Store first, then every app and
recipe as cards), and a page of its own for each app and recipe - the
address to share (e.g. .../jellyfin/), with its downloads for each model.
The pages work without JavaScript; site/assets/site.js adds the model
choice (remembered), filters and the download for that model.

    python3 ci/site.py <store.json> <output folder> [--url <site URL>]

The templates, stylesheet and script are in site/. The site's URL (for
links people share) defaults to GitHub Pages' for $GITHUB_REPOSITORY.
"""

import argparse
import datetime
import hashlib
import html
import json
import os
import pathlib
import re
import shutil
import string
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
SITE = REPO / "site"
# Every OS5 model WD made: (its id, as packages name it; its name; what it
# is; Intel or ARM)
MODELS = [
    ("MyCloudPR4100", "My Cloud PR4100", "4 bays", "intel"),
    ("MyCloudPR2100", "My Cloud PR2100", "2 bays", "intel"),
    ("WDMyCloudDL4100", "My Cloud DL4100", "4 bays", "intel"),
    ("WDMyCloudDL2100", "My Cloud DL2100", "2 bays", "intel"),
    ("WDMyCloudEX4100", "My Cloud EX4100", "4 bays", "arm"),
    ("WDMyCloudEX2100", "My Cloud EX2100", "2 bays", "arm"),
    ("MyCloudEX2Ultra", "My Cloud EX2 Ultra", "2 bays", "arm"),
    ("WDMyCloudMirror", "My Cloud Mirror (Gen 2)", "2 bays", "arm"),
    ("WDMyCloud", "My Cloud (Gen 2)", "1 bay", "arm"),
    ("WDCloud", "WD Cloud", "1 bay", "arm"),
]
MODEL_NAMES = {model: name for model, name, _, _ in MODELS}
# The apps' and recipes' ids (each has a page): set by build()
SITE_IDS = set()
# The categories, in the order the Store lists them
CATEGORIES = [
    "media",
    "music",
    "photos",
    "books",
    "backup",
    "files",
    "monitoring",
    "network",
    "security",
    "development",
    "databases",
    "productivity",
    "home",
    "system",
]


def esc(text):
    """
    Text made safe for HTML (and its attributes).

    :param str text: The text

    :return: It, escaped
    """
    return html.escape(str(text), quote=True)


def size(nbytes):
    """
    A size for people (e.g. 187 MB).

    :param int nbytes: The size in bytes

    :return: It, as text
    """
    if nbytes >= 1 << 20:
        return f"{nbytes / (1 << 20):.0f} MB"

    return f"{max(1, nbytes // 1024)} KB"


def inline(text, link_base):
    """
    A line of Markdown as HTML: code, bold, italics and links (only to
    HTTPS addresses - relative ones go to the repository on GitHub).

    :param str text:      The Markdown (not yet escaped)
    :param str link_base: Where relative links lead (ends in /)

    :return: The HTML
    """
    codes = []

    def keep_code(match):
        codes.append(f"<code>{esc(match.group(1))}</code>")

        return f"\0{len(codes) - 1}\0"

    text = re.sub(r"`([^`]+)`", keep_code, text)
    links = []

    # A link's text stays where it is (formatted with the rest): only where
    # it starts and ends is marked
    def mark_link(match):
        label, target = match.group(1), match.group(2).strip()
        other = re.match(r"^\.\./([\w-]+)/README\.md$", target)

        # Another app's or recipe's README: its page on the site
        if other and other.group(1) in SITE_IDS:
            links.append(f'<a href="../{esc(other.group(1))}/">')

            return f"\1{len(links) - 1}\1{label}\2"

        if not re.match(r"^(https://|#)", target):
            target = link_base + target

        if not (target.startswith("https://") or target.startswith("#")):
            return label

        links.append(f'<a href="{esc(target)}">')

        return f"\1{len(links) - 1}\1{label}\2"

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", mark_link, text)
    text = esc(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*([^*]+?)\*(?![*\w])", r"<em>\1</em>", text)
    text = re.sub("\1(\\d+)\1", lambda m: links[int(m.group(1))], text)
    text = text.replace("\2", "</a>")

    return re.sub("\0(\\d+)\0", lambda m: codes[int(m.group(1))], text)


def markdown(text, link_base):
    """
    A README as HTML - a safe subset of Markdown: headings, paragraphs,
    lists (one level), code blocks and tables. Its "Building the ..." part
    (for developers) is left out, and its title (the page has its own).

    :param str text:      The Markdown
    :param str link_base: Where relative links lead (ends in /)

    :return: The HTML
    """
    text = re.split(r"^## Building ", text, flags=re.M)[0]
    out = []
    lines = text.splitlines()
    i = 0

    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            block = []
            i += 1

            while i < len(lines) and not lines[i].startswith("```"):
                block.append(lines[i])
                i += 1

            out.append(f"<pre><code>{esc(chr(10).join(block))}</code></pre>")
            i += 1
        elif re.match(r"^#{1,6} ", line):
            level = len(line.split(" ")[0])

            # The README's title: the page has its own
            if level > 1:
                level = min(level + 1, 4)
                out.append(
                    f"<h{level}>"
                    f"{inline(line[line.index(' ') + 1:], link_base)}"
                    f"</h{level}>"
                )

            i += 1
        elif re.match(r"^\s*([-*]|\d+\.) ", line):
            tag = "ol" if re.match(r"^\s*\d+\.", line) else "ul"
            items = []

            while i < len(lines) and lines[i].strip():
                if re.match(r"^\s*([-*]|\d+\.) ", lines[i]):
                    items.append(re.sub(r"^\s*([-*]|\d+\.) ", "", lines[i]))
                elif items:
                    items[-1] += " " + lines[i].strip()

                i += 1

            out.append(
                f"<{tag}>"
                + "".join(
                    f"<li>{inline(item, link_base)}</li>" for item in items
                )
                + f"</{tag}>"
            )
        elif line.startswith("|"):
            rows = []

            while i < len(lines) and lines[i].startswith("|"):
                cells = [
                    cell.strip()
                    for cell in lines[i].strip().strip("|").split("|")
                ]

                if not all(re.match(r"^:?-+:?$", cell) for cell in cells):
                    rows.append(cells)

                i += 1

            head = "".join(
                f"<th>{inline(cell, link_base)}</th>" for cell in rows[0]
            )
            body = "".join(
                "<tr>"
                + "".join(
                    f"<td>{inline(cell, link_base)}</td>" for cell in row
                )
                + "</tr>"
                for row in rows[1:]
            )
            out.append(
                '<div class="table"><table>'
                f"<thead><tr>{head}</tr></thead><tbody>{body}</tbody>"
                "</table></div>"
            )
        elif line.strip():
            para = [line.strip()]
            i += 1

            while (
                i < len(lines)
                and lines[i].strip()
                and not re.match(r"^(#|```|\||\s*([-*]|\d+\.) )", lines[i])
            ):
                para.append(lines[i].strip())
                i += 1

            out.append(f"<p>{inline(' '.join(para), link_base)}</p>")
        else:
            i += 1

    return "\n".join(out)


def icon_url(entry, root, out):
    """
    An app's or recipe's icon for the site: one in the repository is copied
    into the site's icons folder; another site's is used where it is.

    :param dict         entry: The app or recipe, as store.json has it
    :param str          root:  The way from the page to the site's root
    :param pathlib.Path out:   The site's folder

    :return: Its address, from the page (or '')
    """
    icon = entry.get("icon", "")
    (out / "icons").mkdir(exist_ok=True)

    # Another site's icon (e.g. Plex's, Emby's): a copy of its own, so that
    # pages don't depend on that site (or its address) - else its address
    if icon.startswith("https://"):
        suffix = pathlib.PurePosixPath(icon).suffix.lower()
        name = (
            f"{entry['id']}{suffix if suffix in ('.png', '.svg') else '.png'}"
        )

        if not (out / "icons" / name).is_file():
            try:
                with urllib.request.urlopen(icon, timeout=30) as response:
                    (out / "icons" / name).write_bytes(
                        response.read(512 * 1024)
                    )
            except OSError as error:
                print(f"warning: {icon}: {error}", file=sys.stderr)

                return icon

        return f"{root}icons/{name}"

    source = REPO / icon

    if not icon or not source.is_file():
        return f"{root}assets/favicon.svg"

    name = f"{entry['id']}{source.suffix}"
    shutil.copyfile(source, out / "icons" / name)

    return f"{root}icons/{name}"


def readme(kind, entry_id):
    """
    An app's or recipe's README, if it has one.

    :param str kind:     apps or recipes
    :param str entry_id: Its id

    :return: Its Markdown, or ''
    """
    path = REPO / kind / entry_id / "README.md"

    return path.read_text(encoding="utf-8") if path.is_file() else ""


def model_buttons(apps):
    """
    The model picker's buttons, each with how many apps it can run.

    :param list apps: The catalogue's apps

    :return: Their HTML
    """
    out = []

    for model, name, bays, chip in MODELS:
        count = sum(
            1 for app in apps for p in app["packages"] if p["model"] == model
        )
        out.append(
            template("model-button.html")
            .safe_substitute(
                chip=chip,
                model=esc(model),
                name=esc(name),
                bays=bays,
                chip_name="Intel" if chip == "intel" else "ARM",
                count=count,
            )
            .rstrip("\n")
        )

    return "\n".join(out)


def card(entry, kind, root, out):
    """
    An app's or recipe's card on the home page. Its downloads (by model) are
    in data-downloads, for the script; without it, the card leads to the
    app's page, which lists them all.

    :param dict         entry: The app or recipe
    :param str          kind:  apps or recipes
    :param str          root:  The way from the page to the site's root
    :param pathlib.Path out:   The site's folder

    :return: Its HTML
    """
    categories = [c for c in entry.get("categories", []) if c in CATEGORIES]
    page = f"{root}{entry['id']}/"

    if kind == "apps":
        downloads = downloads_by_model(entry)
        data = (
            f' data-models="{esc(" ".join(downloads))}"'
            f' data-downloads="{esc(json.dumps(downloads))}"'
        )
        action = (
            '<a class="button primary" data-site="download" '
            f'href="{esc(page)}">Download</a>'
        )
        publisher = (
            '<span class="badge badge-publisher">'
            f'by {esc(entry["publisher"])}</span>'
            if entry.get("publisher")
            else ""
        )
    else:
        arch = entry.get("requires", {}).get("arch", "")
        models = [
            m
            for m, _, _, chip in MODELS
            if not arch or (arch == "amd64") == (chip == "intel")
        ]
        data = f' data-models="{esc(" ".join(models))}" data-recipe="1"'
        action = '<span class="button ghost">Install with the Store</span>'
        publisher = '<span class="badge badge-recipe">Docker recipe</span>'

    # Apps that improve the NAS's security: a badge (the reason on hover),
    # and a filter of their own
    security = entry.get("security", "")
    filters = categories + (["security-upgrade"] if security else [])

    return (
        template("card.html")
        .safe_substitute(
            data=data,
            search_name=esc(f"{entry['name']} {entry['id']}".lower()),
            search_summary=esc(entry.get("summary", "").lower()),
            categories=esc(" ".join(filters)),
            security_data=' data-security="1"' if security else "",
            security=(
                '<span class="badge badge-security" '
                f'title="{esc(security)}">Security</span>'
                if security
                else ""
            ),
            page=esc(page),
            icon=esc(icon_url(entry, root, out)),
            name=esc(entry["name"]),
            version=esc(entry["version"]),
            summary=esc(entry.get("summary", "")),
            publisher=publisher,
            badges="".join(
                f'<span class="badge">{esc(c)}</span>' for c in categories
            ),
            action=action,
        )
        .rstrip("\n")
    )


def store_card(store_app, out):
    """
    The Store's own card, first and larger: what it does, and how to install
    it (the one app installed by hand).

    :param dict         store_app: The Store, as the catalogue has it
    :param pathlib.Path out:       The site's folder

    :return: Its HTML
    """
    downloads = downloads_by_model(store_app)

    return (
        template("store-card.html")
        .safe_substitute(
            models=esc(" ".join(downloads)),
            downloads=esc(json.dumps(downloads)),
            icon=esc(icon_url(store_app, "", out)),
            version=esc(store_app["version"]),
        )
        .rstrip("\n")
    )


def downloads_by_model(entry):
    """
    An app's downloads, for the script: its package's address and size, by
    model.

    :param dict entry: The app, as the catalogue has it

    :return: [address, size] by model
    """
    return {p["model"]: [p["url"], size(p["size"])] for p in entry["packages"]}


def template(name):
    """
    One of the site's templates (site/templates).

    :param str name: Its file's name

    :return: It, for string.Template's safe_substitute
    """
    return string.Template(
        (SITE / "templates" / name).read_text(encoding="utf-8")
    )


def app_page(entry, kind, catalogue, url, out):
    """
    An app's or recipe's own page: its downloads for each model (apps), what
    it needs, links, and its README.

    :param dict         entry:     The app or recipe
    :param str          kind:      apps or recipes
    :param dict         catalogue: store.json
    :param str          url:       The site's address (ends in /)
    :param pathlib.Path out:       The site's folder

    :return: Its title, description, image and main HTML
    """
    root = "../"
    base = catalogue.get("base_url", "")
    sources = entry.get("sources", "")
    link_base = (
        sources.replace("/tree/", "/blob/") + "/"
        if sources
        else f"{catalogue.get('homepage', '')}/blob/main/{kind}/{entry['id']}/"
    )
    icon = icon_url(entry, root, out)
    links = []
    facts = []

    if kind == "apps":
        rows = []
        packages = {p["model"]: p for p in entry["packages"]}

        for model, name, bays, chip in MODELS:
            package = packages.get(model)

            if package:
                rows.append(
                    f'<tr data-model="{esc(model)}"><td>{esc(name)}</td>'
                    f'<td>{size(package["size"])}</td>'
                    '<td><a class="button primary" '
                    f'href="{esc(package["url"])}">Download</a></td>'
                    '<td class="sha" title="SHA256">'
                    f"{esc(package['sha256'][:16])}&hellip;</td></tr>"
                )

        unavailable = [
            name for model, name, _, _ in MODELS if model not in packages
        ]
        downloads = (
            '<p class="muted" data-site="your-download"></p>'
            '<div class="table"><table class="downloads"><thead><tr>'
            "<th>NAS</th><th>Size</th><th></th>"
            "<th>SHA256</th></tr></thead><tbody>"
            + "".join(rows)
            + "</tbody></table></div>"
            + (
                '<p class="muted">Not available for: '
                f'{esc(", ".join(unavailable))}.</p>'
                if unavailable
                else ""
            )
            + (
                '<p class="muted">Easier: install it from the '
                '<a href="../store/">Store</a>, which also updates it.</p>'
                if entry["id"] != "store"
                else ""
            )
        )

        if entry.get("release_notes"):
            links.append(
                f'<li><a href="{esc(entry["release_notes"])}">'
                f"Release notes ({esc(entry['version'])})</a></li>"
            )

        if entry.get("keeps_data"):
            facts.append(
                "<dt>Updates</dt><dd>By the Store, keeping its data</dd>"
            )

        if entry.get("data_folder"):
            facts.append(
                "<dt>Its data</dt><dd><code>"
                f"Nas_Prog/{esc(entry['data_folder'])}</code></dd>"
            )
    else:
        downloads = (
            '<p>A Docker recipe: the <a href="../store/">Store</a> installs '
            "it (Recipes tab), asks for its settings, starts it and keeps it "
            "up to date. It needs the Docker app.</p>"
        )

    requires = entry.get("requires", {})

    if requires.get("apps"):
        needed = ", ".join(
            f'<a href="../{esc(a)}/">{esc(a)}</a>' for a in requires["apps"]
        )
        facts.append(f"<dt>Needs</dt><dd>{needed}</dd>")

    if requires.get("ram_mb"):
        facts.append(
            "<dt>Memory</dt><dd>"
            f"{requires['ram_mb'] // 1024 or requires['ram_mb']}"
            f"{' GB' if requires['ram_mb'] >= 1024 else ' MB'} or more</dd>"
        )

    if entry.get("license"):
        facts.append(f"<dt>Licence</dt><dd>{esc(entry['license'])}</dd>")

    if entry.get("publisher"):
        facts.append(f"<dt>Made by</dt><dd>{esc(entry['publisher'])}</dd>")

    if entry.get("homepage"):
        links.append(
            f'<li><a href="{esc(entry["homepage"])}">Its own website</a></li>'
        )

    if sources:
        links.append(
            f'<li><a href="{esc(sources)}">How it\'s built (source)</a></li>'
        )

    text = readme(kind, entry["id"])
    description = (
        f'<div class="readme">{markdown(text, link_base)}</div>'
        if text
        else (
            f'<p>{esc(entry.get("summary", ""))}.</p>'
            if entry.get("summary")
            else ""
        )
    )
    security = (
        '<p class="notice notice-security"><strong>Security:</strong> '
        f'{esc(entry["security"])}.</p>'
        if entry.get("security")
        else ""
    )
    notice = (
        f'<p class="notice">Made by {esc(entry["publisher"])}: its own '
        "package for WD's NAS models, which this project lists.</p>"
        if entry.get("publisher")
        else ""
    )
    badges = (
        '<span class="badge badge-security">Security</span>'
        if entry.get("security")
        else ""
    ) + "".join(
        f'<span class="badge">{esc(c)}</span>'
        for c in entry.get("categories", [])
        if c in CATEGORIES
    )
    template = string.Template(
        (SITE / "templates" / "app.html").read_text(encoding="utf-8")
    )
    main = template.safe_substitute(
        root=root,
        icon=esc(icon),
        name=esc(entry["name"]),
        version=esc(entry["version"]),
        summary=esc(entry.get("summary", "")),
        badges=badges,
        security=security,
        notice=notice,
        downloads=downloads,
        description=description,
        links="\n".join(links),
        facts="\n".join(facts),
        url=esc(f"{url}{entry['id']}/"),
    )
    image = icon if icon.startswith("https://") else url + icon[len(root) :]

    return entry["name"], entry.get("summary", ""), image, main


def page(
    title,
    description,
    image,
    address,
    root,
    main,
    updated,
    repository,
    asset_version,
):
    """
    A whole page: the layout around its main part.

    :param str title:         Its title
    :param str description:   Its description (for link previews)
    :param str image:         Its image's address (for link previews)
    :param str address:       Its own address
    :param str root:          The way from the page to the site's root
    :param str main:          Its main part's HTML
    :param str updated:       When the catalogue was updated (for people)
    :param str repository:    The project's repository on GitHub
    :param str asset_version: The stylesheet's and script's version

    :return: Its HTML
    """
    template = string.Template(
        (SITE / "templates" / "layout.html").read_text(encoding="utf-8")
    )

    return template.safe_substitute(
        title=esc(title),
        description=esc(description),
        image=esc(image),
        url=esc(address),
        root=root,
        main=main,
        updated=esc(updated),
        repository=esc(repository),
        asset_version=asset_version,
    )


def build(catalogue, out, url):
    """
    Writes the site.

    :param dict         catalogue: store.json
    :param pathlib.Path out:       Its folder (emptied first)
    :param str          url:       Its address (ends in /)
    """
    if out.exists():
        shutil.rmtree(out)

    out.mkdir(parents=True)
    shutil.copytree(SITE / "assets", out / "assets")
    asset_version = hashlib.sha256(
        b"".join(
            (SITE / "assets" / name).read_bytes()
            for name in ("site.css", "site.js")
        )
    ).hexdigest()[:10]
    repository = catalogue.get("homepage", "")
    updated = datetime.datetime.strptime(
        catalogue["updated"], "%Y-%m-%dT%H:%M:%SZ"
    ).strftime("%-d %B %Y")
    apps = sorted(catalogue["apps"], key=lambda a: a["name"].lower())
    recipes = sorted(
        catalogue.get("recipes", []), key=lambda r: r["name"].lower()
    )
    store_app = next((a for a in apps if a["id"] == "store"), None)
    # The counts are of the apps listed under Apps: the Store has its own card
    listed = [a for a in apps if a["id"] != "store"]
    ids = [a["id"] for a in apps] + [r["id"] for r in recipes]

    if len(set(ids)) != len(ids) or {"assets", "icons"} & set(ids):
        sys.exit(
            "An app and a recipe (or the site's own folders) share a name"
        )

    SITE_IDS.update(ids)

    used = sorted(
        {
            c
            for e in apps + recipes
            for c in e.get("categories", [])
            if c in CATEGORIES
        },
        key=CATEGORIES.index,
    )
    template = string.Template(
        (SITE / "templates" / "index.html").read_text(encoding="utf-8")
    )
    main = template.safe_substitute(
        app_count=len(listed),
        recipe_count=len(recipes),
        model_buttons=model_buttons(listed),
        store_card=store_card(store_app, out) if store_app else "",
        category_options="\n".join(
            " " * 28 + f'<option value="{c}">{c.capitalize()}</option>'
            for c in used
        ),
        app_cards="\n".join(
            card(a, "apps", "", out) for a in apps if a["id"] != "store"
        ),
        recipe_cards="\n".join(card(r, "recipes", "", out) for r in recipes),
    )
    (out / "index.html").write_text(
        page(
            "WD NAS App Builder - apps for WD My Cloud NAS devices",
            catalogue.get("summary", ""),
            url + "assets/favicon.svg",
            url,
            "",
            main,
            updated,
            repository,
            asset_version,
        ),
        encoding="utf-8",
    )

    for kind, entries in (("apps", apps), ("recipes", recipes)):
        for entry in entries:
            title, description, image, main = app_page(
                entry, kind, catalogue, url, out
            )
            (out / entry["id"]).mkdir()
            (out / entry["id"] / "index.html").write_text(
                page(
                    f"{title} for WD My Cloud NAS",
                    description,
                    image,
                    f"{url}{entry['id']}/",
                    "../",
                    main,
                    updated,
                    repository,
                    asset_version,
                ),
                encoding="utf-8",
            )

    # As published, for anyone who wants the catalogue itself; and no
    # Jekyll (GitHub Pages' default) - the files as they are
    (out / "store.json").write_text(
        json.dumps(catalogue, indent=4), encoding="utf-8"
    )
    (out / ".nojekyll").write_text("")
    print(f"wrote {out}: {len(apps)} apps, {len(recipes)} recipes")


def merge_security(catalogue, metadata):
    """
    Gives the catalogue's apps the security reasons in the metadata (the
    published store.json only has them after CI's next release).

    :param dict catalogue: store.json
    :param dict metadata:  store/metadata.json
    """
    reasons = {}

    for section in ("apps", "external"):
        for app_id, entry in metadata.get(section, {}).items():
            if isinstance(entry, dict) and entry.get("security"):
                reasons[app_id] = entry["security"]

    for app in catalogue["apps"]:
        if app["id"] in reasons:
            app["security"] = reasons[app["id"]]


def main():
    """Builds the site from the command line's store.json."""
    parser = argparse.ArgumentParser(
        description="Builds the project's website"
    )
    parser.add_argument("store", help="store.json, as published")
    parser.add_argument("output", help="the site's folder (emptied first)")
    parser.add_argument("--url", help="the site's address")
    parser.add_argument(
        "--metadata",
        help=(
            "store/metadata.json, for previews: its security reasons are"
            " used where the published store.json predates them"
        ),
    )
    args = parser.parse_args()
    repo = os.environ.get(
        "GITHUB_REPOSITORY", "paul-norman/WD-NAS-App-Builder"
    )
    owner, name = repo.split("/", 1)
    url = (args.url or f"https://{owner.lower()}.github.io/{name}/").rstrip(
        "/"
    ) + "/"
    catalogue = json.loads(
        pathlib.Path(args.store).read_text(encoding="utf-8")
    )

    if args.metadata:
        merge_security(
            catalogue,
            json.loads(
                pathlib.Path(args.metadata).read_text(encoding="utf-8")
            ),
        )

    build(catalogue, pathlib.Path(args.output), url)


if __name__ == "__main__":
    main()

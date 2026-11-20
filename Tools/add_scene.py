"""Pair a reference image with a prepared Gaussian scene for PinchDrop and its phone gallery."""
import argparse
from contextlib import ExitStack
from html import escape
import json
from pathlib import Path
import re
import shutil



ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'Vision/App/SceneAssets'
PHONE = ROOT / 'Phone'


def add_scene(args, stage):
    key = args.id
    if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', key) or key in {'gallery', 'language'}:
        raise ValueError('Use lowercase letters, numbers and hyphens for the scene ID (gallery and language are reserved).')
    if args.point_budget is not None and args.point_budget < 1:
        raise ValueError('The point budget must be a positive integer.')
    photo_ext = args.photo.suffix.lower()
    model_ext = args.model.suffix.lower()
    if photo_ext not in {'.jpeg', '.jpg', '.png'} or model_ext not in {'.sog', '.splat', '.ply', '.spz'}:
        raise ValueError('Supply a JPEG/PNG reference and a SOG v2, SPLAT, Gaussian PLY or SPZ model.')
    for source in (args.photo, args.model):
        if not source.is_file() or not source.stat().st_size:
            raise ValueError(f'Missing or empty input: {source}')

    manifest = ASSETS / 'Scenes.json'
    scenes = json.loads(manifest.read_text(encoding='utf-8'))
    if any(item['id'].casefold() == key for item in scenes):
        raise ValueError(f'Scene ID already exists: {key}. Choose another ID to add a scene.')
    folder = 'scene-' + key
    photo_name = 'Photo' + ('.jpg' if photo_ext == '.jpeg' else photo_ext)
    model_name = 'World' + model_ext
    app_folder = ASSETS / 'Gallery' / folder
    phone_file = PHONE / folder / photo_name
    photo_url = phone_file.relative_to(PHONE).as_posix()
    page = PHONE / 'index.html'
    html = page.read_text(encoding='utf-8')
    title = args.title.strip()
    english = (args.title_en or title).strip()
    if not title or not english:
        raise ValueError('Supply a nonempty scene title.')
    zh, en = escape(title), escape(english)
    additions = {
        '<!-- Add scene cards here -->': f'<a href="#{key}"><img loading="lazy" src="{photo_url}" alt=""><span data-en="{en}">{zh}</span></a>',
        '<!-- Add full photos here -->': f'<section class="photo" id="{key}"><img loading="lazy" src="{photo_url}" alt="{zh}" data-alt-en="{en}"><a href="#gallery" data-en="Choose another photo">换照片</a></section>'
    }
    for marker, entry in additions.items():
        if html.count(marker) != 1:
            raise ValueError(f'Phone/index.html needs exactly one {marker}')
        html = html.replace(marker, entry + '\n' + marker)
    scenes.append(dict(id=key, title=title, titleEN=english,
                       photo=(app_folder / photo_name).relative_to(ASSETS).as_posix(),
                       model=(app_folder / model_name).relative_to(ASSETS).as_posix(),
                       propTitle='', sourcePhoto=args.photo.name))

    if args.point_budget is not None:
        scenes[-1]['pointBudget'] = args.point_budget

    files = [(args.photo, app_folder / photo_name), (args.model, app_folder / model_name),
             (args.photo, phone_file)]
    updates = {page: html, manifest: json.dumps(scenes, ensure_ascii=False, indent=2) + '\n'}
    # Stage all inputs first. Publish resources before entries that reference them.
    prepared = []
    for index, (source, target) in enumerate(files):
        if target.exists():
            raise ValueError(f'File already exists: {target}')
        staged = stage / f'asset-{index}'
        shutil.copyfile(source, staged)
        prepared.append((staged, target))
    with ExitStack() as rollback:
        for staged, target in prepared:
            target.parent.mkdir(parents=True, exist_ok=True)
            staged.replace(target)
            rollback.callback(target.unlink)
        for index, (target, content) in enumerate(updates.items()):
            backup = stage / f'original-{index}'
            shutil.copyfile(target, backup)
            updated = stage / f'updated-{index}'
            updated.write_text(content, encoding='utf-8')
            updated.replace(target)
            rollback.callback(backup.replace, target)
        rollback.pop_all()
    print(f'Phone photo: {phone_file}\nPhone gallery: Phone/index.html#{key}')
    print('Rebuild the Vision app.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('photo', type=Path)
    parser.add_argument('model', type=Path)
    parser.add_argument('--id', required=True, help='Unique scene ID, e.g. waterfall')
    parser.add_argument('--title', required=True, help='Scene title in Chinese or your preferred language')
    parser.add_argument('--point-budget', type=int, help='Maximum world Gaussians for this scene (default: 650000).')
    parser.add_argument('--title-en', help='English title (defaults to --title)')
    args = parser.parse_args()
    stage = ROOT / '.pinchdrop-import'
    try:
        stage.mkdir()
    except FileExistsError:
        parser.exit(1, 'Another import is in progress. If an import was interrupted, inspect .pinchdrop-import before retrying.\n')
    try:
        add_scene(args, stage)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    finally:
        shutil.rmtree(stage)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check English extraction and seven-language catalogs after scripts/test.sh.

Pass --app-build or --package-build when using a different build directory.
Only compiler data from the named source owners is checked (never test copy).
"""
from collections import Counter
import argparse
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app-build', type=Path, default=root / 'DerivedData/Build/Intermediates.noindex')
parser.add_argument('--package-build', type=Path, default=root / 'Packages/UnderpressuredKit/.build')
args = parser.parse_args()
errors = []


def values(node, context):
    if not isinstance(node, dict):
        errors.append(f'{context}: expected an object')
        return
    if 'stringUnit' in node:
        unit = node['stringUnit']
        if not isinstance(unit, dict) or not isinstance(unit.get('value'), str):
            errors.append(f'{context}: stringUnit requires a string value')
        else:
            yield unit['value']
    variations = node.get('variations', {})
    if not isinstance(variations, dict):
        errors.append(f'{context}: variations must be an object')
        return
    for kind, children in variations.items():
        if not isinstance(children, dict):
            errors.append(f'{context}: {kind} variations must be an object')
            continue
        for category, child in children.items():
            yield from values(child, f'{context}/{kind}/{category}')


def read_object(path):
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError('expected a JSON object')
        return data
    except (OSError, ValueError) as error:
        errors.append(f'{path}: cannot read JSON object: {error}')
        return None


languages = ('es', 'pt-BR', 'de', 'fr', 'ar', 'ja', 'zh-Hans')
placeholder = re.compile(r'%(?:(\d+)\$)?(@|lld)')


def signature(value):
    # Compare argument identity and type, allowing translator-controlled positional reordering.
    return Counter((int(match[1]) if match[1] else index, match[2])
                   for index, match in enumerate(placeholder.finditer(value), 1))


for owner, catalog_path, build in [
    (root / 'App', root / 'App/Localizable.xcstrings', args.app_build),
    (root / 'Packages/UnderpressuredKit/Sources/AppModel', root / 'Packages/UnderpressuredKit/Sources/AppModel/Resources/Localizable.xcstrings', args.package_build),
]:
    catalog = read_object(catalog_path)
    if catalog is None:
        continue
    if catalog.get('sourceLanguage') != 'en':
        errors.append(f'{catalog_path}: sourceLanguage must be en')
    entries = catalog.get('strings')
    if not isinstance(entries, dict):
        errors.append(f'{catalog_path}: strings must be an object')
        continue
    extracted = set()
    sources = set()
    for path in build.rglob('*.stringsdata'):
        data = read_object(path)
        if data is None:
            continue
        if not isinstance(data.get('source', ''), str):
            errors.append(f'{path}: source must be a path string')
            continue
        source = Path(data.get('source', '')).resolve()
        if source.parent != owner:
            continue
        sources.add(source)
        tables = data.get('tables', {})
        table = tables.get('Localizable', []) if isinstance(tables, dict) else None
        if not isinstance(table, list):
            errors.append(f'{path}: tables.Localizable must be an array')
            continue
        for entry in table:
            if not isinstance(entry, dict) or not isinstance(entry.get('key'), str):
                errors.append(f'{path}: extracted entry requires a string key')
                continue
            if entry['key']:
                extracted.add(entry['key'])
    if not sources:
        errors.append(f'{owner.name}: no compiler extraction found under {build}; build first')
    for key in sorted(extracted - entries.keys()):
        errors.append(f'{owner.name}: missing extracted key {key!r}')
    for key, entry in entries.items():
        context = f'{owner.name}: {key!r}'
        if not isinstance(entry, dict):
            errors.append(f'{context}: catalog entry must be an object')
            continue
        localizations = entry.get('localizations', {})
        if not isinstance(localizations, dict):
            errors.append(f'{context}: localizations must be an object')
            continue
        english = list(values(localizations.get('en', {}), f'{context}/en'))
        if not english or any(not value.strip() for value in english):
            errors.append(f'{owner.name}: no explicit English value for {key!r}')
        if re.search(r'%(?:\d+\$)?(?:@|lld)', key) and not entry.get('comment'):
            errors.append(f'{owner.name}: placeholder lacks translator context: {key!r}')
        expected = signature(english[0]) if english else Counter()
        for language in languages:
            node = localizations.get(language, {})
            translations = list(values(node, f'{context}/{language}'))
            if not translations or any(not value.strip() for value in translations):
                errors.append(f'{owner.name}: missing {language} value for {key!r}')
            for value in translations:
                if signature(value) != expected:
                    errors.append(f'{owner.name}: {language} placeholder mismatch for {key!r}: {value!r}')
                for brand in ('Underpressured', 'JPEG', 'PNG', 'HDR', 'EXIF', 'GPS', 'RAW', 'TIFF', 'GIF'):
                    if english and brand in english[0] and brand not in value:
                        errors.append(f'{owner.name}: {language} missing {brand} in {key!r}')
            if not isinstance(node, dict):
                continue
            if isinstance(node.get('variations'), dict):
                plural = node['variations'].get('plural', {})
                categories = set(plural) if isinstance(plural, dict) else set()
                required = {'zero', 'one', 'two', 'few', 'many', 'other'} if language == 'ar' else {'other'}
                if not required <= categories:
                    errors.append(f'{owner.name}: {language} incomplete plural categories for {key!r}')
            english_has_variations = isinstance(localizations.get('en'), dict) and 'variations' in localizations['en']
            if (english_has_variations or '%lld' in key and 'position' not in key) and language == 'ar':
                if 'variations' not in node:
                    errors.append(f'{owner.name}: Arabic count lacks plural variations for {key!r}')
        if entry.get('extractionState') == 'stale':
            errors.append(f'{owner.name}: stale catalog key {key!r}')
    print(f'{owner.name}: {len(entries)} English catalog keys; {len(extracted)} compiler keys from {len(sources)} source files')
if errors:
    raise SystemExit('\n'.join(errors))
print('Localization catalog audit passed.')

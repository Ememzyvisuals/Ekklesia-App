import zipfile, json, re, os, hashlib

BASE = '/mnt/user-data/uploads'
OUT = '/home/claude/work/build/out'
os.makedirs(OUT, exist_ok=True)

kz = zipfile.ZipFile(f'{BASE}/Bible-kjv-master.zip')
book_order = json.loads(kz.read('Bible-kjv-master/Books.json'))  # canonical 66-book order, display names

code_map = {
 '1CH':'1Chronicles','1CO':'1Corinthians','1JN':'1John','1KI':'1Kings','1PE':'1Peter','1SA':'1Samuel',
 '1TH':'1Thessalonians','1TI':'1Timothy','2CH':'2Chronicles','2CO':'2Corinthians','2JN':'2John','2KI':'2Kings',
 '2PE':'2Peter','2SA':'2Samuel','2TH':'2Thessalonians','2TI':'2Timothy','3JN':'3John','ACT':'Acts','AMO':'Amos',
 'COL':'Colossians','DAN':'Daniel','DEU':'Deuteronomy','ECC':'Ecclesiastes','EPH':'Ephesians','EST':'Esther',
 'EXO':'Exodus','EZK':'Ezekiel','EZR':'Ezra','GAL':'Galatians','GEN':'Genesis','HAB':'Habakkuk','HAG':'Haggai',
 'HEB':'Hebrews','HOS':'Hosea','ISA':'Isaiah','JAS':'James','JDG':'Judges','JER':'Jeremiah','JHN':'John',
 'JOB':'Job','JOL':'Joel','JON':'Jonah','JOS':'Joshua','JUD':'Jude','LAM':'Lamentations','LEV':'Leviticus',
 'LUK':'Luke','MAL':'Malachi','MAT':'Matthew','MIC':'Micah','MRK':'Mark','NAM':'Nahum','NEH':'Nehemiah',
 'NUM':'Numbers','OBA':'Obadiah','PHM':'Philemon','PHP':'Philippians','PRO':'Proverbs','PSA':'Psalms',
 'REV':'Revelation','ROM':'Romans','RUT':'Ruth','SNG':'SongofSolomon','TIT':'Titus','ZEC':'Zechariah','ZEP':'Zephaniah'
}
filename_to_code = {v: k for k, v in code_map.items()}
# book_order entries have spaces e.g. "1 Samuel" / "Song of Solomon" -> normalize to kjv filename keys
def norm_book_filename(name):
    return name.replace(' ', '')

position_of = {}
for i, name in enumerate(book_order):
    position_of[norm_book_filename(name)] = i + 1  # 1-indexed canonical position

OT_COUNT = 39  # Genesis..Malachi

# Known verses omitted in modern critical-text translations but present in KJV / Textus Receptus.
# This is standard, well-documented textual-criticism metadata (not copyrighted text) used to keep
# verse numbering aligned with standard versification when a translation's line count is one short.
KNOWN_OMISSIONS = {
    ('Matthew', 17): [21], ('Matthew', 18): [11], ('Matthew', 23): [14],
    ('Mark', 7): [16], ('Mark', 9): [44, 46], ('Mark', 11): [26], ('Mark', 15): [28],
    ('Luke', 17): [36], ('Luke', 23): [17],
    ('John', 5): [4],
    ('Acts', 8): [37], ('Acts', 15): [34], ('Acts', 24): [7], ('Acts', 28): [29],
    ('Romans', 16): [24],
}

kjv_cache = {}
def kjv_data(book):
    if book not in kjv_cache:
        kjv_cache[book] = json.loads(kz.read(f'Bible-kjv-master/{book}.json'))
    return kjv_cache[book]

def kjv_chapter_verse_count(book, chapter):
    data = kjv_data(book)
    for c in data['chapters']:
        if c['chapter'] == str(chapter):
            return len(c['verses'])
    return None

def build_english():
    books_out = []
    for name in book_order:
        fname = norm_book_filename(name)
        code = filename_to_code[fname]
        data = kjv_data(fname)
        pos = position_of[fname]
        chapters_out = []
        for c in data['chapters']:
            verses = [{"number": int(v['verse']), "text": v['text']} for v in c['verses']]
            chapters_out.append({
                "number": int(c['chapter']),
                "verseCount": len(verses),
                "verses": verses,
            })
        books_out.append({
            "code": code, "name": name, "testament": "OT" if pos <= OT_COUNT else "NT", "position": pos,
            "chapters": chapters_out,
        })
    return {"language": "english", "sourceNote": "KJV (public domain), verse-numbered source.", "books": books_out}

fnpat = re.compile(r'^\w+_(\d+)_([A-Z0-9]+)_(\d+)_read\.txt$')

def build_translation(zipname, langid, langlabel):
    z = zipfile.ZipFile(f'{BASE}/{zipname}')
    by_book = {}
    for entry in z.namelist():
        m = fnpat.match(entry)
        if not m:
            continue
        _, code, chnum = m.groups()
        if code not in code_map:
            continue
        by_book.setdefault(code, {})[int(chnum)] = entry

    books_out = []
    anomalies = []
    for name in book_order:
        fname = norm_book_filename(name)
        code = filename_to_code[fname]
        pos = position_of[fname]
        chapters_map = by_book.get(code, {})
        chapters_out = []
        for chnum in sorted(chapters_map.keys()):
            entry = chapters_map[chnum]
            raw = z.read(entry).decode('utf-8-sig')
            lines = [l.strip() for l in raw.split('\n') if l.strip()]
            local_title = lines[0].rstrip('.') if lines else name
            content_lines = lines[2:]  # skip title + chapter-number lines
            expected = kjv_chapter_verse_count(fname, chnum)
            omissions = KNOWN_OMISSIONS.get((fname, chnum), [])

            verses = []
            if expected is not None and len(content_lines) == expected:
                # direct 1:1 line -> verse mapping, standard versification
                for i, text in enumerate(content_lines, start=1):
                    verses.append({"number": i, "text": text, "approximate": False})
            elif expected is not None and omissions and len(content_lines) == expected - len(omissions):
                # re-insert gaps at the known omitted verse numbers so numbering stays standard
                li = 0
                for vn in range(1, expected + 1):
                    if vn in omissions:
                        verses.append({"number": vn, "text": None, "omitted": True, "approximate": False})
                    else:
                        verses.append({"number": vn, "text": content_lines[li], "approximate": False})
                        li += 1
            else:
                # source restructured this chapter (condensed/split verses) - best-effort sequential
                # numbering, flagged so the app can show an "approximate numbering" indicator.
                for i, text in enumerate(content_lines, start=1):
                    verses.append({"number": i, "text": text, "approximate": True})
                anomalies.append({"book": name, "chapter": chnum, "lines": len(content_lines), "kjvVerses": expected})

            chapters_out.append({"number": chnum, "verseCount": len(verses), "localTitle": local_title, "verses": verses})

        books_out.append({"code": code, "name": name, "testament": "OT" if pos <= OT_COUNT else "NT",
                           "position": pos, "chapters": chapters_out})

    return {"language": langid, "label": langlabel,
            "sourceNote": "Verse numbers reconstructed from a read-aloud script (verse numbers stripped by source, one verse per line preserved). See anomalies for the small number of chapters where source restructured verses.",
            "anomalies": anomalies, "books": books_out}

en = build_english()
with open(f'{OUT}/en.json', 'w', encoding='utf-8') as f:
    json.dump(en, f, ensure_ascii=False)

langs = [('yor_readaloud.zip', 'yo', 'Yoruba'), ('hausa_readaloud.zip', 'ha', 'Hausa'),
         ('ibo_readaloud.zip', 'ig', 'Igbo'), ('pcm_readaloud.zip', 'pcm', 'Nigerian Pidgin')]

summary = {"english": {"books": len(en['books']), "chapters": sum(len(b['chapters']) for b in en['books'])}}
for zipname, langid, label in langs:
    d = build_translation(zipname, langid, label)
    with open(f'{OUT}/{langid}.json', 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    total_ch = sum(len(b['chapters']) for b in d['books'])
    total_v = sum(len(c['verses']) for b in d['books'] for c in b['chapters'])
    summary[langid] = {"label": label, "books": len(d['books']), "chapters": total_ch,
                        "verses": total_v, "anomalyChapters": len(d['anomalies']), "anomalies": d['anomalies']}

with open(f'{OUT}/import_summary.json', 'w', encoding='utf-8') as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)

print(json.dumps(summary, ensure_ascii=False, indent=2))

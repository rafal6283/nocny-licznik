# Uruchom w katalogu pakietu: python3 tool/gen_przyklady.py. Generuje lib/src/wymiana_przyklady.g.dart z wymiana/*.json (uruchom po zmianie przykładów).
import glob, json, os
out = ["// Wygenerowane przez tool/gen_przyklady.py z wymiana/*.json — nie edytować ręcznie.", "",
       "/// Przykładowe pliki wymiany (nazwa → treść JSON) do testów zgodności w aplikacjach.",
       "const wymianaPrzyklady = <String, String>{"]
for f in sorted(glob.glob('wymiana/*.json')):
    name = os.path.basename(f)[:-5]
    txt = json.dumps(json.load(open(f)), ensure_ascii=False, separators=(',', ':'))
    out.append("  '%s': r'''%s'''," % (name, txt))
out.append("};")
open('lib/src/wymiana_przyklady.g.dart', 'w').write("\n".join(out) + "\n")

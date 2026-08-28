#!/usr/bin/env zsh
# tests/py/run.sh — tests for the python modules (store_lookup, webforms, mdtable).
#
# webforms runs a REAL headless Chrome against a local HTML file: the React-clear
# fallback, overlay dismissal, checkbox label-clicking and autocomplete matching
# are only meaningful against a live DOM. mdtable is tested against an in-process
# fake HTTP transport speaking the same wire format a tracker would. store_lookup's pure
# helpers are unit-tested; live API calls are skipped without network.
#
# Usage: zsh tests/py/run.sh [-v]

emulate -L zsh
setopt pipe_fail

readonly ROOT="${0:A:h:h:h}"
typeset -g VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

typeset -gi PASS=0 FAIL=0
typeset -ga FAILURES=()
ok()   { (( PASS++ )); (( VERBOSE )) && print -P "%F{green}  ok%f   $1"; return 0; }
nope() { (( FAIL++ )); FAILURES+=("$1"); print -P "%F{red}  FAIL%f $1${2:+  -- $2}"; return 0; }

print -P "%F{cyan}== python modules ==%f"

command -v python3 >/dev/null 2>&1 || { print "python3 required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-py-XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- store_lookup: pure helpers --------------------------------------------
python3 - "$ROOT" "$TMP" <<'PY' && ok "store_lookup: compiles + CLI parses" || nope "store_lookup: compile/CLI"
import sys, importlib.util, subprocess
root, tmp = sys.argv[1], sys.argv[2]
import sys as _s
spec = importlib.util.spec_from_file_location("sl", f"{root}/lib/py/store_lookup.py")
sl = importlib.util.module_from_spec(spec); _s.modules["sl"] = sl; spec.loader.exec_module(sl)
r = subprocess.run([sys.executable, f"{root}/lib/py/store_lookup.py", "--help"],
                   capture_output=True, text=True)
sys.exit(0 if "itunes" in (r.stdout + r.stderr).lower() else 1)
PY

python3 - "$ROOT" <<'PY' && ok "store_lookup: dedupe + digit filter" || nope "store_lookup: dedupe/filter"
import sys, importlib.util
root = sys.argv[1]
import sys as _s
spec = importlib.util.spec_from_file_location("sl", f"{root}/lib/py/store_lookup.py")
sl = importlib.util.module_from_spec(spec); _s.modules["sl"] = sl; spec.loader.exec_module(sl)
ids = sl.itunes_lookup_ids([" 123 ", "123", "abc", "456"])
found, unresolved = ids
assert "123" in found or "123" in unresolved, "123 must be tracked exactly once"
assert "abc" not in found and "abc" not in unresolved, "non-digit ids must be dropped"
sys.exit(0)
PY

# ---- mdtable ----------------------------------------------------------------
python3 - "$ROOT" <<'PY' 2>&1 | while IFS= read -r line; do print -r -- "$line"; done
import sys, importlib.util
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("md", f"{root}/lib/py/mdtable.py")
md = importlib.util.module_from_spec(spec); sys.modules["md"] = md; spec.loader.exec_module(md)

results = []
def check(name, cond):
    results.append((name, bool(cond)))

doc = """# Deployment status

| Product | Link Config | Availability | Deployed |
|---|---|---|---|
| alpha | ✅ | ✅ | ✅ |
| beta  | ✅ | ✅ | ✅ |
| gamma | ❌ | ❌ | ❌ |
"""
before, table, after = md.split_table(doc)
check("split_table finds table", table.startswith("| Product"))

new = md.transform_rows(table, updates={
    "gamma": {"link config": "✅", "deployed": "✅"},   # header match is fuzzy
}, drop_rows=["beta"])
lines = new.split("\n")
check("update row via fuzzy column names", any(l.strip().startswith("| gamma | ✅ |") and l.strip().endswith("| ✅ |") for l in lines))
check("drop row", not any(l.strip().startswith("| beta") for l in lines))
check("untouched row byte-identical", "| alpha | ✅ | ✅ | ✅ |" in lines)

try:
    md.transform_rows(table, updates={"alpha": {"no such column": "x"}})
    check("unknown column rejected", False)
except KeyError:
    check("unknown column rejected", True)

d = md.diff_tables(table, new)
check("diff non-empty", len(d.strip()) > 0)

# fake YouTrack-shaped transport
class FakeYT:
    def __init__(self, text, stamp="1000", fail_post=0, race=False):
        self.text, self.updated = text, stamp
        self.fail_post, self.race, self.posts = fail_post, race, 0
        self.gets = 0
    def get_field(self):
        self.gets += 1
        if self.race and self.gets > 1:
            self.updated = "9999"   # edited after our fetch, before our post
        return self.text, self.updated, 200
    def post_field(self, text, updated_guard=""):
        self.posts += 1
        # a real transport re-reads the timestamp before writing — emulate that
        _, latest, _ = self.get_field()
        if updated_guard and latest != updated_guard:
            return "concurrency guard tripped", 0
        if self.fail_post:
            return "boom", self.fail_post
        self.text = text
        return "", 200

t = FakeYT(doc)
changed, msg = md.edit_document(t, updates={"gamma": {"Deployed": "✅"}}, dry_run=True)
check("dry-run posts nothing", t.posts == 0 and not changed)
changed, msg = md.edit_document(t, updates={"gamma": {"Deployed": "✅"}})
check("live edit posts once and verifies", changed and t.posts == 1)
t2 = FakeYT(doc); t2.race = True
changed, msg = md.edit_document(t2, updates={"gamma": {"Deployed": "✅"}})
check("racing editor is refused", not changed and bool(msg))
check("racing editor never wrote", "| gamma | ❌ | ❌ | ❌ |" in t2.text)
t3 = FakeYT(doc)
changed, msg = md.edit_document(t3)   # no updates at all
check("no-op edit detected", not changed and "nothing to do" in msg)

for name, ok_ in results:
    print(("PASS " if ok_ else "FAIL ") + name)
sys.exit(0 if all(r[1] for r in results) else 1)
PY
if [[ ${pipestatus[1]} -eq 0 ]]; then
  print -P "%F{green}  ok%f   mdtable: transforms, guards, no-op (12 checks)"
else
  nope "mdtable: see output above"
fi

# ---- webforms against real headless Chrome ---------------------------------
CAN_CHROME=0
python3 -c 'import selenium' 2>/dev/null \
  && { command -v google-chrome >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; } \
  && CAN_CHROME=1
if (( CAN_CHROME )); then
cat > "$TMP/form.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><style>
  body{font-family:sans-serif;max-width:420px;margin:2em auto}
  #overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:10;
           display:flex;align-items:center;justify-content:center}
  .hidden{display:none}
  ul.ac{border:1px solid #ccc;list-style:none;margin:0;padding:0}
  ul.ac li{padding:6px 10px;cursor:pointer}
</style></head><body>
<div id="overlay"><div class="cookie-banner">
  <p>We use cookies</p><button id="onetrust-accept-btn-handler">Accept</button>
</div></div>
<form>
  <label>Email <input id="login-email" name="email"></label><br>
  <label>Notes <textarea id="notes"></textarea></label><br>
  <input type="checkbox" id="persist" name="persist"><label for="persist">Remember me</label><br>
  <input type="radio" id="plan-pro" name="plan" value="pro"><label for="plan-pro">Pro</label><br>
  <select id="country"><option value="">Choose…</option>
    <option value="cy">Cyprus</option><option value="de">Germany</option></select><br>
  <input id="search" placeholder="search…" autocomplete="off">
  <ul class="ac" id="ac" class="hidden"></ul><br>
  <button type="button" id="submit-btn" style="position:relative">Save</button>
</form>
<script>
  // minimal framework-like input: ignores element.clear() semantics by
  // re-asserting state via a setter wrapper, like React's controlled inputs.
  const email = document.getElementById('login-email');
  let state = { email: '' };
  const origSet = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value').set;
  email.addEventListener('input', () => { state.email = email.value; });
  // re-assert: any programmatic .value assignment without an input event
  // gets reverted on the next tick — mimicking React reverting stale state.
  const assertInt = setInterval(() => {
    if (document.activeElement !== email && state.email !== email.value
        && !email._js_touched) {
      origSet.call(email, state.email);
    }
  }, 50);
  const ac = document.getElementById('ac');
  const items = ['done\nAlpha App', 'done\nAlpha App Two', 'Beta App', 'Gamma'];
  document.getElementById('search').addEventListener('input', e => {
    const v = e.target.value.toLowerCase();
    ac.innerHTML = items.filter(i => i.toLowerCase().includes(v))
      .map(i => `<li>${i}</li>`).join('');
  });
  document.getElementById('onetrust-accept-btn-handler').onclick = () =>
    document.getElementById('overlay').remove();
  let saved = false;
  document.getElementById('submit-btn').onclick = () => { saved = true; };
  window.__getSaved = () => saved;
</script>
</body></html>
HTML

python3 - "$ROOT" "$TMP/form.html" <<'PY' && ok "webforms: live Chrome — overlays, React-clear, checkbox, autocomplete, select" \
                                              || nope "webforms: live Chrome run"
import sys, importlib.util, json
root, page = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wf", f"{root}/lib/py/webforms.py")
wf = importlib.util.module_from_spec(spec); sys.modules["wf"] = wf; spec.loader.exec_module(wf)

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By

opts = Options()
opts.add_argument("--headless=new")
opts.add_argument("--no-sandbox")
opts.add_argument("--disable-dev-shm-usage")
d = webdriver.Chrome(options=opts)
try:
    d.get(f"file://{page}")
    assert d.find_element(By.ID, "overlay").is_displayed(), "overlay should start visible"

    form = {
        "email": wf.Control("Email", By.ID, "login-email", "input_text", "user@example.com"),
        "notes": wf.Control("Notes", By.ID, "notes", "textarea", "hello"),
        "remember": wf.Control("Remember", By.ID, "persist", "checkbox", True),
        "plan": wf.Control("Pro", By.ID, "plan-pro", "radio", True),
        "country": wf.Control("Country", By.ID, "country", "select", "Germany"),
        "search": wf.Control("Search", By.CSS_SELECTOR, "#search", "autocomplete",
                             "Alpha App", class_search="ac"),
        "save": wf.Control("Save", By.ID, "submit-btn", "button", ""),
    }
    res = wf.fill_form(d, form, verbose=False)
    assert res["email"] == "ok", res
    assert d.find_element(By.ID, "login-email").get_attribute("value") == "user@example.com"
    assert d.find_element(By.ID, "notes").get_attribute("value") == "hello"
    assert d.find_element(By.ID, "persist").is_selected()
    assert d.find_element(By.ID, "plan-pro").is_selected()
    val = d.find_element(By.ID, "country").get_attribute("value")
    assert val == "de", f"select by visible text -> {val}"
    # overlay was dismissed by the engine before interaction
    assert not d.find_elements(By.ID, "overlay"), "overlay should be gone"
    # autocomplete picked the prefix-matching option
    assert d.find_element(By.ID, "search").get_attribute("value").startswith("Alpha"), "autocomplete"
    assert d.execute_script("return window.__getSaved()") is True
    assert res["save"] == "ok"

    # missing control -> tolerated skip, not a crash
    res2 = wf.fill_form(d, {"ghost": wf.Control("Ghost", By.ID, "nope-xyz", "input_text", "x")}, verbose=False)
    assert res2["ghost"] == "skipped-missing", res2
finally:
    d.quit()
sys.exit(0)
PY
else
  print -P "%F{yellow}  skip%f webforms live Chrome (selenium or a chrome binary is missing)"
fi

python3 - "$ROOT" "$TMP" <<'PY' && ok "webforms: load_form templates + strict missing-var refusal" || nope "webforms: load_form"
import sys, importlib.util, json, os
root, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wf", f"{root}/lib/py/webforms.py")
wf = importlib.util.module_from_spec(spec); sys.modules["wf"] = wf; spec.loader.exec_module(wf)

path = os.path.join(tmp, "form.json")
json.dump({"email": {"description": "Email", "by": "ID", "locator": "e",
                     "type": "input_text", "value": "{username}@example.com"}},
          open(path, "w"))
form = wf.load_form(path, context={"username": "daniil"})
assert form["email"].value == "daniil@example.com", form["email"].value
try:
    wf.load_form(path, context={})
    sys.exit(1)  # must NOT silently type a {placeholder}
except KeyError:
    pass
sys.exit(0)
PY

print -P "%F{cyan}────────────────────────────────────────%f"
if (( FAIL == 0 )); then
  print -P "%F{green}python modules: all $PASS groups passed.%f"; exit 0
else
  print -P "%F{red}$FAIL failed%f, $PASS passed."; print -l -- "${FAILURES[@]}" | sed 's/^/  - /'; exit 1
fi

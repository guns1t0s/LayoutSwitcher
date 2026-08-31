#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cita-previa availability checker for the Spanish immigration portal
(icp.administracionelectronica.gob.es).

Checks whether appointment slots ("citas") are currently offered for a given
trámite — by default the TIE fingerprinting appointment:

    POLICÍA-TOMA DE HUELLAS (EXPEDICIÓN DE TARJETA), INICIAL, RENOVACIÓN,
    DUPLICADO Y LEY 14/2013

and (Madrid / Barcelona / Palma only) the alternative named in DGGM
resolutions:

    POLICÍA-EXPEDICIÓN DE TARJETAS CUYA AUTORIZACIÓN RESUELVE LA
    DIRECCIÓN GENERAL DE GESTIÓN MIGRATORIA

The script only CHECKS availability and notifies you — it never books
anything. The final booking steps require an SMS confirmation code, so
complete the booking manually (use --headful to do it in the same window
the moment slots appear).

Requires: Python 3.9+, playwright (`pip install playwright`,
then `playwright install chromium`).
"""

import argparse
import datetime
import json
import os
import platform
import random
import re
import signal
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

try:
    from playwright.sync_api import sync_playwright, Error as PWError
except ImportError:  # pragma: no cover
    print(
        "Playwright is not installed. Run:\n"
        "  pip install -r requirements.txt\n"
        "  playwright install chromium",
        file=sys.stderr,
    )
    sys.exit(2)

BASE_HOST = "https://icp.administracionelectronica.gob.es"

# INE province codes used by the portal's ?p= parameter. Barcelona lives on
# its own sub-portal (icpplustieb); everything else goes through icpplus.
PROVINCES = {
    "araba": 1, "alava": 1, "albacete": 2, "alicante": 3, "almeria": 4,
    "avila": 5, "badajoz": 6, "illes balears": 7, "baleares": 7, "palma": 7,
    "barcelona": 8, "burgos": 9, "caceres": 10, "cadiz": 11, "castellon": 12,
    "ciudad real": 13, "cordoba": 14, "a coruna": 15, "coruna": 15,
    "cuenca": 16, "girona": 17, "granada": 18, "guadalajara": 19,
    "gipuzkoa": 20, "guipuzcoa": 20, "huelva": 21, "huesca": 22, "jaen": 23,
    "leon": 24, "lleida": 25, "la rioja": 26, "lugo": 27, "madrid": 28,
    "malaga": 29, "murcia": 30, "navarra": 31, "ourense": 32, "asturias": 33,
    "palencia": 34, "las palmas": 35, "pontevedra": 36, "salamanca": 37,
    "santa cruz de tenerife": 38, "tenerife": 38, "cantabria": 39,
    "segovia": 40, "sevilla": 41, "soria": 42, "tarragona": 43, "teruel": 44,
    "toledo": 45, "valencia": 46, "valladolid": 47, "bizkaia": 48,
    "vizcaya": 48, "zamora": 49, "zaragoza": 50, "ceuta": 51, "melilla": 52,
}
SPECIAL_BASE_PATH = {8: "icpplustieb"}  # Barcelona has a dedicated sub-portal

# Default trámite filters (accent-free, matched case-insensitively against
# accent-stripped option text): the huellas option and the DGGM option.
DEFAULT_TRAMITES = [r"TOMA DE HUELLAS", r"GESTION MIGRATORIA"]

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

# --- page states -----------------------------------------------------------

S_TRAMITE = "tramite-select"
S_INFO = "info-page"
S_FORM = "personal-form"
S_CONTINUE = "continue"
S_OFFICE = "office-select"
S_PHONE = "phone-form"
S_SLOTS = "slots-available"
S_NO_CITAS = "no-citas"
S_CAPTCHA = "captcha"
S_BLOCKED = "blocked"
S_UNKNOWN = "unknown"

NO_CITAS_MARKERS = [
    "no hay citas disponibles",
    "no hay suficientes citas",
    "no existen citas disponibles",
    "en breve, la oficina pondra a su disposicion nuevas citas",
]
BLOCKED_MARKERS = [
    "request rejected",
    "too many requests",
    "demasiadas peticiones",
    "acceso no autorizado",
    "el servicio no se encuentra disponible en este momento",
    "servicio no disponible",
]
SLOTS_MARKERS = [
    "seleccione una de las siguientes citas",
    "elija una de las siguientes citas",
]

CONTINUE_BUTTONS = ["#btnEntrar", "#btnEnviar", "#btnSiguiente", "#btnAceptar",
                    "#btnConsultar"]


def norm(text):
    """Lowercase, strip accents, collapse whitespace."""
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text).strip().lower()


def log(msg):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {msg}", flush=True)


def human_pause(a=1.2, b=2.8):
    time.sleep(random.uniform(a, b))


# --- notifications ---------------------------------------------------------

def notify(cfg, title, message):
    print("\a", end="", flush=True)  # terminal bell
    system = platform.system()
    try:
        if system == "Darwin":
            script = (
                'display notification "{}" with title "{}" sound name "Glass"'
                .format(message.replace('"', "'"), title.replace('"', "'"))
            )
            subprocess.run(["osascript", "-e", script], timeout=10,
                           capture_output=True)
            for _ in range(3):
                subprocess.run(
                    ["afplay", "/System/Library/Sounds/Glass.aiff"],
                    timeout=10, capture_output=True)
        elif system == "Linux":
            subprocess.run(["notify-send", title, message], timeout=10,
                           capture_output=True)
    except Exception:
        pass
    token = cfg.telegram_token
    chat = cfg.telegram_chat
    if token and chat:
        try:
            data = urllib.parse.urlencode(
                {"chat_id": chat, "text": f"{title}\n{message}"}).encode()
            urllib.request.urlopen(
                f"https://api.telegram.org/bot{token}/sendMessage",
                data=data, timeout=15)
        except Exception as exc:
            log(f"Telegram notification failed: {exc}")


# --- portal navigation -----------------------------------------------------

class FlowResult:
    def __init__(self, state, message="", offices=None, screenshot=None):
        self.state = state
        self.message = message
        self.offices = offices or []
        self.screenshot = screenshot


class Checker:
    def __init__(self, cfg, browser):
        self.cfg = cfg
        self.browser = browser

    def entry_url(self):
        return f"{self.cfg.base_url}/citar?p={self.cfg.province_code}&locale=es"

    # -- page inspection helpers

    def body_text(self, page):
        try:
            return norm(page.inner_text("body", timeout=5000))
        except PWError:
            return ""

    def visible(self, page, selector):
        try:
            loc = page.locator(selector).first
            return loc.count() > 0 and loc.is_visible()
        except PWError:
            return False

    def classify(self, page):
        text = self.body_text(page)
        if not text:
            return S_UNKNOWN
        if any(m in text for m in BLOCKED_MARKERS):
            return S_BLOCKED
        if any(m in text for m in NO_CITAS_MARKERS):
            return S_NO_CITAS
        if (self.visible(page, ".g-recaptcha")
                or self.visible(page, 'iframe[src*="captcha"]')
                or self.visible(page, 'img[src*="captcha"]')):
            return S_CAPTCHA
        if (self.visible(page, 'input[type="radio"][name^="rdbCita"]')
                or any(m in text for m in SLOTS_MARKERS)):
            return S_SLOTS
        if self.visible(page, "select#idSede"):
            return S_OFFICE
        if self.visible(page, "#txtIdCitado"):
            return S_FORM
        if self.visible(page, "#txtTelefonoCitado"):
            return S_PHONE
        if self.visible(page, 'select[name^="tramiteGrupo"]'):
            return S_TRAMITE
        if self.visible(page, "#btnEntrar"):
            return S_INFO
        if any(self.visible(page, b) for b in CONTINUE_BUTTONS):
            return S_CONTINUE
        return S_UNKNOWN

    def click_continue(self, page, preferred=None):
        for sel in (preferred or []) + CONTINUE_BUTTONS + [
                'input[type="submit"]', 'button[type="submit"]']:
            if self.visible(page, sel):
                page.locator(sel).first.click()
                page.wait_for_load_state("domcontentloaded")
                return True
        return False

    def dump(self, page, tag):
        os.makedirs(self.cfg.debug_dir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        base = os.path.join(self.cfg.debug_dir, f"{stamp}-{tag}")
        shot = None
        try:
            shot = base + ".png"
            page.screenshot(path=shot, full_page=True)
        except PWError:
            shot = None
        try:
            with open(base + ".html", "w", encoding="utf-8") as fh:
                fh.write(page.content())
        except PWError:
            pass
        return shot

    # -- individual steps

    def list_tramites(self, page):
        """Return [(value, text)] from every tramiteGrupo select on the page."""
        out = []
        selects = page.locator('select[name^="tramiteGrupo"]')
        for i in range(selects.count()):
            for opt in selects.nth(i).locator("option").all():
                value = opt.get_attribute("value") or ""
                text = re.sub(r"\s+", " ", opt.inner_text()).strip()
                if value and value not in ("-1",):
                    out.append((value, text))
        return out

    def select_tramite(self, page, value):
        selects = page.locator('select[name^="tramiteGrupo"]')
        for i in range(selects.count()):
            sel = selects.nth(i)
            values = [o.get_attribute("value")
                      for o in sel.locator("option").all()]
            if value in values:
                sel.select_option(value=value)
                human_pause(0.4, 1.0)
                return True
        return False

    def fill_personal_form(self, page):
        cfg = self.cfg
        radio = {"nie": "#rdbTipoDocNie", "dni": "#rdbTipoDocDni",
                 "passport": "#rdbTipoDocPas"}.get(cfg.doc_type)
        if radio and self.visible(page, radio):
            page.locator(radio).check()
        page.locator("#txtIdCitado").fill(cfg.doc)
        if self.visible(page, "#txtDesCitado"):
            page.locator("#txtDesCitado").fill(cfg.name)
        if self.visible(page, "#txtAnnoCitado"):
            if not cfg.year:
                raise RuntimeError(
                    "The form asks for the year of birth: pass --year YYYY")
            page.locator("#txtAnnoCitado").fill(str(cfg.year))
        if self.visible(page, "select#txtPaisNac"):
            sel = page.locator("select#txtPaisNac")
            wanted = norm(cfg.country)
            for opt in sel.locator("option").all():
                if wanted in norm(opt.inner_text()):
                    sel.select_option(value=opt.get_attribute("value"))
                    break
            else:
                raise RuntimeError(
                    f"Country '{cfg.country}' not found in the #txtPaisNac "
                    "list; pass --country exactly as the portal spells it")

    def fill_phone_form(self, page):
        # This data is only used to advance to the slots screen; nothing is
        # ever booked by this script.
        cfg = self.cfg
        page.locator("#txtTelefonoCitado").fill(cfg.phone)
        for sel in ("#emailUNO", "#emailDOS"):
            if self.visible(page, sel):
                page.locator(sel).fill(cfg.email)

    def select_office(self, page, office_value):
        sel = page.locator("select#idSede")
        sel.select_option(value=office_value)
        human_pause(0.4, 1.0)

    def office_options(self, page):
        out = []
        for opt in page.locator("select#idSede option").all():
            value = opt.get_attribute("value") or ""
            text = re.sub(r"\s+", " ", opt.inner_text()).strip()
            if value and value not in ("-1",):
                out.append((value, text))
        return out

    def wait_out_captcha(self, page):
        """In headful mode give the human up to 5 minutes to solve the
        captcha and press the portal's own continue button."""
        log(">>> CAPTCHA detected. Solve it in the browser window and press "
            "the portal's continue button; waiting up to 5 minutes...")
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            time.sleep(2)
            if self.classify(page) != S_CAPTCHA:
                return True
        return False

    # -- one full pass through the flow

    def run_flow(self, tramite_value, office_value=None, collect_offices=False):
        """Walk the wizard for one trámite (and optionally one office).

        Returns a FlowResult. With collect_offices=True the flow stops at the
        office-selection page and returns the list of offices instead.
        """
        cfg = self.cfg
        context = self.browser.new_context(
            locale="es-ES", user_agent=USER_AGENT,
            viewport={"width": 1280, "height": 900},
        )
        context.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', "
            "{get: () => undefined})")
        page = context.new_page()
        page.set_default_timeout(20000)
        office_chosen = False
        hold_open = False
        try:
            page.goto(self.entry_url(), wait_until="domcontentloaded",
                      timeout=30000)
            for _ in range(12):
                human_pause()
                state = self.classify(page)
                if cfg.verbose:
                    log(f"    page state: {state}")
                if state == S_BLOCKED:
                    return FlowResult(S_BLOCKED, self.body_text(page)[:200])
                if state == S_NO_CITAS:
                    return FlowResult(S_NO_CITAS)
                if state == S_SLOTS:
                    shot = self.dump(page, "slots")
                    hold_open = cfg.keep_open
                    if cfg.headful:
                        log(">>> Slots visible — the browser window stays "
                            "open. Book the cita there, then press Enter "
                            "here to continue.")
                        notify(cfg, "Cita previa: HAY CITAS",
                               "Book it in the open browser window NOW")
                        try:
                            input()
                        except EOFError:
                            pass
                    return FlowResult(S_SLOTS, screenshot=shot)
                if state == S_CAPTCHA:
                    if cfg.headful and self.wait_out_captcha(page):
                        continue
                    return FlowResult(S_CAPTCHA)
                if state == S_TRAMITE:
                    if not self.select_tramite(page, tramite_value):
                        return FlowResult(
                            S_UNKNOWN, "trámite option disappeared from list")
                    self.click_continue(page, ["#btnAceptar"])
                elif state == S_INFO:
                    self.click_continue(page, ["#btnEntrar"])
                elif state == S_FORM:
                    self.fill_personal_form(page)
                    self.click_continue(page, ["#btnEnviar"])
                elif state == S_OFFICE:
                    if collect_offices and office_value is None:
                        return FlowResult(S_OFFICE,
                                          offices=self.office_options(page))
                    if office_value is None:
                        opts = self.office_options(page)
                        if not opts:
                            return FlowResult(S_UNKNOWN, "empty office list")
                        office_value = opts[0][0]
                    if office_chosen:
                        return FlowResult(
                            S_UNKNOWN, "office page shown twice; aborting")
                    self.select_office(page, office_value)
                    office_chosen = True
                    self.click_continue(page, ["#btnSiguiente"])
                elif state == S_PHONE:
                    self.fill_phone_form(page)
                    self.click_continue(page, ["#btnSiguiente", "#btnEnviar"])
                elif state == S_CONTINUE:
                    self.click_continue(page)
                else:  # S_UNKNOWN
                    shot = self.dump(page, "unknown")
                    return FlowResult(
                        S_UNKNOWN,
                        f"unrecognized page (dump: {shot})")
            return FlowResult(S_UNKNOWN, "too many steps without a verdict")
        finally:
            if not (cfg.headful and hold_open):
                context.close()

    # -- top-level: resolve trámites, then check each (per office if needed)

    def resolve_tramites(self):
        context = self.browser.new_context(
            locale="es-ES", user_agent=USER_AGENT)
        page = context.new_page()
        page.set_default_timeout(20000)
        try:
            page.goto(self.entry_url(), wait_until="domcontentloaded",
                      timeout=30000)
            human_pause()
            state = self.classify(page)
            if state == S_BLOCKED:
                raise RuntimeError(
                    "portal refused the request (blocked / rate-limited): "
                    + self.body_text(page)[:200])
            if state != S_TRAMITE:
                shot = self.dump(page, "entry")
                raise RuntimeError(
                    f"expected the trámite list, got '{state}' (dump: {shot})")
            return self.list_tramites(page)
        finally:
            context.close()


def check_once(cfg, browser):
    """Run one full availability check. Returns True iff slots were found."""
    checker = Checker(cfg, browser)
    tramites = checker.resolve_tramites()
    patterns = [re.compile(p, re.I) for p in cfg.tramites]
    matched = [(v, t) for v, t in tramites
               if any(p.search(norm(t)) or p.search(t) for p in patterns)]
    # dedupe by value, keep order
    seen, targets = set(), []
    for v, t in matched:
        if v not in seen:
            seen.add(v)
            targets.append((v, t))
    if not targets:
        log("No trámite matched your filters. Available trámites:")
        for v, t in tramites:
            log(f"  [{v}] {t}")
        raise RuntimeError("no matching trámite; adjust --tramite")

    found_any = False
    for value, text in targets:
        log(f"Checking trámite [{value}] {text}")
        result = checker.run_flow(value, collect_offices=True)

        if result.state == S_OFFICE:
            offices = result.offices
            if cfg.office:
                pat = re.compile(cfg.office, re.I)
                offices = [(v, t) for v, t in offices
                           if pat.search(norm(t)) or pat.search(t)]
                if not offices:
                    log(f"  --office '{cfg.office}' matched nothing; "
                        f"offices are: {[t for _, t in result.offices]}")
                    continue
            if cfg.max_offices > 0:
                offices = offices[:cfg.max_offices]
            for ov, ot in offices:
                log(f"  office: {ot}")
                sub = checker.run_flow(value, office_value=ov)
                found_any |= report(cfg, text, ot, sub)
                if sub.state == S_SLOTS and cfg.stop_on_first:
                    return True
                human_pause(2.0, 5.0)
        else:
            found_any |= report(cfg, text, None, result)
            if result.state == S_SLOTS and cfg.stop_on_first:
                return True
        human_pause(2.0, 5.0)
    return found_any


def report(cfg, tramite, office, result):
    """Log one flow outcome; fire notifications on availability."""
    where = f" @ {office}" if office else ""
    if result.state == S_SLOTS:
        msg = f"HAY CITAS — slots available for: {tramite}{where}"
        log("=" * 60)
        log(msg)
        if result.screenshot:
            log(f"Screenshot: {result.screenshot}")
        log(f"Book NOW (manually): {cfg.base_url}/citar?p={cfg.province_code}"
            "&locale=es")
        log("=" * 60)
        notify(cfg, "Cita previa: HAY CITAS", msg)
        return True
    if result.state == S_NO_CITAS:
        log(f"  no slots{where} (portal says: no hay citas disponibles)")
    elif result.state == S_CAPTCHA:
        log(f"  captcha wall{where} — rerun with --headful and solve it "
            "manually")
    elif result.state == S_BLOCKED:
        log(f"  request blocked / rate-limited{where}: {result.message}")
    else:
        log(f"  inconclusive ({result.state}){where}: {result.message}")
    return False


# --- CLI -------------------------------------------------------------------

def build_parser():
    env = os.environ.get
    p = argparse.ArgumentParser(
        description="Check for cita-previa availability on "
                    "icp.administracionelectronica.gob.es (TIE / toma de "
                    "huellas by default). Checks only — never books.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--province", default=env("CITA_PROVINCE", "barcelona"),
                   help="province name (e.g. barcelona, madrid, palma)")
    p.add_argument("--base-url", default=None,
                   help="override the portal base URL (advanced)")
    p.add_argument("--p", dest="province_code", type=int, default=None,
                   help="override the numeric province code (advanced)")
    p.add_argument("--tramite", action="append", default=None,
                   metavar="REGEX",
                   help="regex matched against trámite names (accent-"
                        "insensitive); repeatable. Default: TOMA DE HUELLAS "
                        "and GESTION MIGRATORIA")
    p.add_argument("--list-tramites", action="store_true",
                   help="print the trámites the portal offers and exit")
    p.add_argument("--doc", default=env("CITA_DOC"),
                   help="NIE/DNI/passport number (or env CITA_DOC)")
    p.add_argument("--doc-type", choices=["nie", "dni", "passport"],
                   default=env("CITA_DOC_TYPE", "nie"))
    p.add_argument("--name", default=env("CITA_NAME"),
                   help="full name exactly as in the resolution "
                        "(or env CITA_NAME)")
    p.add_argument("--year", default=env("CITA_YEAR"),
                   help="year of birth (some trámites ask for it)")
    p.add_argument("--country", default=env("CITA_COUNTRY", "RUSIA"),
                   help="country of nationality as the portal spells it")
    p.add_argument("--office", default=env("CITA_OFFICE"), metavar="REGEX",
                   help="only check offices matching this regex "
                        "(default: all)")
    p.add_argument("--max-offices", type=int, default=0,
                   help="check at most N offices per trámite (0 = all)")
    p.add_argument("--phone", default=env("CITA_PHONE", "600000000"),
                   help="phone used only to reach the slots screen")
    p.add_argument("--email", default=env("CITA_EMAIL", "mail@example.com"),
                   help="email used only to reach the slots screen")
    p.add_argument("--interval", type=int, default=300,
                   help="seconds between checks (keep >= 120 to avoid bans)")
    p.add_argument("--once", action="store_true",
                   help="run a single check and exit (exit code 0 = slots "
                        "found, 1 = none, 2 = error)")
    p.add_argument("--headful", action="store_true",
                   help="show the browser window (lets you solve captchas "
                        "and book on the spot)")
    p.add_argument("--keep-open", action="store_true",
                   help="with --headful: keep the window open after a hit")
    p.add_argument("--proxy", default=env("CITA_PROXY"),
                   help="proxy server, e.g. http://user:pass@host:port "
                        "(the portal blocks most datacenter/VPN IPs)")
    p.add_argument("--debug-dir", default="cita-debug",
                   help="directory for screenshots/HTML dumps")
    p.add_argument("--telegram-token", default=env("TELEGRAM_BOT_TOKEN"))
    p.add_argument("--telegram-chat", default=env("TELEGRAM_CHAT_ID"))
    p.add_argument("--no-stop-on-first", dest="stop_on_first",
                   action="store_false", default=True,
                   help="keep checking remaining offices/trámites after a hit")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def finalize_config(args):
    key = norm(args.province)
    if args.province_code is None:
        if key not in PROVINCES:
            sys.exit(f"Unknown province '{args.province}'. Known: "
                     f"{', '.join(sorted(set(PROVINCES)))}")
        args.province_code = PROVINCES[key]
    if args.base_url is None:
        path = SPECIAL_BASE_PATH.get(args.province_code, "icpplus")
        args.base_url = f"{BASE_HOST}/{path}"
    args.base_url = args.base_url.rstrip("/")
    args.tramites = args.tramite or DEFAULT_TRAMITES
    if not args.list_tramites:
        missing = [n for n, v in (("--doc", args.doc), ("--name", args.name))
                   if not v]
        if missing:
            sys.exit("Missing required options: " + ", ".join(missing)
                     + " (see --help; env vars CITA_DOC / CITA_NAME also work)")
    if args.interval < 60:
        log("WARNING: interval < 60s is likely to get your IP banned; "
            "using 60s")
        args.interval = 60
    return args


def main():
    cfg = finalize_config(build_parser().parse_args())
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

    launch_kwargs = {
        "headless": not cfg.headful,
        "args": ["--disable-blink-features=AutomationControlled"],
    }
    if cfg.proxy:
        launch_kwargs["proxy"] = {"server": cfg.proxy}

    with sync_playwright() as pw:
        browser = pw.chromium.launch(**launch_kwargs)

        if cfg.list_tramites:
            checker = Checker(cfg, browser)
            for value, text in checker.resolve_tramites():
                print(f"[{value}] {text}")
            return

        errors_in_row = 0
        while True:
            try:
                found = check_once(cfg, browser)
                errors_in_row = 0
                if cfg.once:
                    sys.exit(0 if found else 1)
                if found and cfg.stop_on_first:
                    log("Slots were found — stopping the watch loop. "
                        "Restart the script to keep watching.")
                    return
            except SystemExit:
                raise
            except Exception as exc:
                errors_in_row += 1
                log(f"Check failed: {exc}")
                if cfg.once:
                    sys.exit(2)
            backoff = min(4, 1 + errors_in_row)
            delay = cfg.interval * backoff * random.uniform(0.85, 1.15)
            log(f"Next check in {int(delay)}s")
            time.sleep(delay)


if __name__ == "__main__":
    main()

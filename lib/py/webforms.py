#!/usr/bin/env python3
"""webforms — a data-driven Selenium form engine.

Forms are described as data, not code: a dict of named Controls, each declaring
how to find the element and what value it should end up with. The engine fills
any combination of input, checkbox, label-wrapped checkbox, radio, select,
button, autocomplete and image-badge controls, and knows how to survive the
things that make real websites hard:

  * React/Vue controlled inputs that ignore `element.clear()` — cleared through
    the native value setter so the framework's internal state actually updates
  * stale elements after re-renders — every retry re-finds fresh
  * overlay/cookie banners intercepting clicks — dismissed (then force-removed
    via JS) before interaction
  * autocomplete dropdowns — typed value verified, options awaited, matched by
    prefix, and a failed select re-types rather than appending
  * intercepting elements over buttons — JS click fallback after scrolling

Two ways to describe a form:

  1. From Python:   fields = {"name": Control(...), ...}
  2. From a JSON/YAML file (see load_form()) — the whole form is data, so the
     same engine drives a different site by swapping the data file.

Values may be templated against a context dict, e.g. value="{username}@", so one
form definition serves many accounts. Missing-context keys raise before any
browser interaction happens — never mid-fill.

Requires: selenium (undetected-chromedriver optional; plain webdriver works).
"""

from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Any

try:
    from selenium.common.exceptions import (
        ElementClickInterceptedException,
        ElementNotInteractableException,
        NoSuchElementException,
        StaleElementReferenceException,
        TimeoutException,
    )
    from selenium.webdriver.common.by import By
    from selenium.webdriver.common.keys import Keys
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait
except ImportError:  # allow import for linting without selenium installed
    By = Keys = EC = WebDriverWait = None  # type: ignore[assignment]

# How many times fill_form retries a single control before giving up on it.
DEFAULT_RETRIES = 2
# Seconds to wait for a control to become usable.
DEFAULT_TIMEOUT = 5

# Selectors for common consent/password overlays that intercept first
# interaction on most sites. Extend for your target site via Control data or
# the `overlay_selectors` argument of fill_form.
DEFAULT_OVERLAY_SELECTORS = [
    "#onetrust-accept-btn-handler",
    "button[title='Accept']",
    ".onetrust-pc-dark-filter.accept-cookies-container button",
    "[aria-label='Accept cookies']",
    ".cookie-banner button",
    "[class*='cookie'][class*='banner'] button",
]

# Overlay-ish elements to force-remove via JS when clicking Accept is not
# enough (persistent dark filters, save-password bubbles, modal shells).
DEFAULT_OVERLAY_REMOVE = (
    "'.onetrust-pc-dark-filter,"
    "[class*=cookie-banner],"
    "[class*=save-password-bubble],"
    "[class*=overlay-modal],"
    "[class*=cookie-overlay]'"
)

CONTROL_TYPES = (
    "input_text",
    "textarea",
    "button",
    "checkbox",
    "label_checkbox",
    "radio",
    "select",
    "autocomplete",
    "image_badge",
    "click",
)


@dataclass
class Control:
    """One form control and how to reach it.

    by/locator:  any selenium By strategy + target (CSS, XPATH, ID, NAME, ...)
    _type:       one of CONTROL_TYPES — drives the interaction strategy
    value:       text to type / checkbox desired-state / option to select
    class_search: for autocomplete — class of the dropdown <ul> to await
    """

    description: str
    by: str
    locator: str
    _type: str
    value: Any = ""
    platform: str = "any"          # informational filter key, see filter_fields()
    class_search: str = ""
    retries: int = DEFAULT_RETRIES


# ---------------------------------------------------------------------------
# Form definition from a data file
# ---------------------------------------------------------------------------

def load_form(path: str, context: dict[str, str] | None = None) -> dict[str, Control]:
    """Load a form definition from JSON (or JSON-loaded YAML upstream).

    File shape — one entry per control::

        {
          "username": {"description": "Email",
                        "by": "ID", "locator": "login-email",
                        "type": "input_text", "value": "{username}"},
          "remember": {"description": "Remember me",
                        "by": "NAME", "locator": "persist",
                        "type": "checkbox", "value": true}
        }

    `value` strings are templated with {key} from `context`. A missing key
    raises KeyError here — before the browser is touched — rather than typing
    a literal "{username}" into a live form.
    """
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    ctx = context or {}
    fields: dict[str, Control] = {}
    for name, spec in raw.items():
        val = spec.get("value", "")
        if isinstance(val, str) and "{" in val:
            val = _template(spec["value"], ctx)
        fields[name] = Control(
            description=spec.get("description", name),
            by=spec.get("by", "ID"),
            locator=spec["locator"],
            _type=spec["type"],
            value=val,
            platform=spec.get("platform", "any"),
            class_search=spec.get("class_search", ""),
            retries=int(spec.get("retries", DEFAULT_RETRIES)),
        )
    return fields


class _StrictDict(dict):
    """format_map mapping that raises a clear error on a missing {key}."""
    def __missing__(self, key):
        raise KeyError(f"form template variable {key!r} missing from context — "
                       "refusing to type a placeholder into a live form")

def _template(text: str, ctx: dict[str, str]) -> str:
    return text.format_map(_StrictDict(ctx))


def filter_fields(
    form: dict[str, Control], platforms: tuple[bool, ...]
) -> dict[str, Control]:
    """Keep controls relevant to the platforms present.

    platform="both"/"any" controls always pass; a control tagged "android" is
    kept only when platforms[0]; "ios" only when platforms[1]. Arbitrary
    platform tags compare against the truthy flags positionally.
    """
    out: dict[str, Control] = {}
    # First flag means "android present", second "ios present"; extend the
    # tuple and the tag list below for more platforms.
    tag_for_index = ("android", "ios")
    for name, c in form.items():
        p = (c.platform or "any").lower()
        if p in ("any", "both", "all"):
            out[name] = c
            continue
        for i, present in enumerate(platforms):
            if present and p == tag_for_index[i]:
                out[name] = c
                break
    return out


# ---------------------------------------------------------------------------
# Interaction helpers
# ---------------------------------------------------------------------------

def dismiss_overlays(driver, selectors: list[str] | None = None) -> None:
    """Click visible consent/dismiss buttons, then force-remove leftovers."""
    sels = selectors if selectors is not None else DEFAULT_OVERLAY_SELECTORS
    try:
        for sel in sels:
            for el in driver.find_elements(By.CSS_SELECTOR, sel):
                try:
                    if el.is_displayed() and el.is_enabled():
                        el.click()
                        time.sleep(0.25)
                except Exception:
                    pass
        driver.execute_script(
            f"document.querySelectorAll({DEFAULT_OVERLAY_REMOVE}).forEach(el => el.remove());"
        )
    except Exception:
        pass


def set_react_value(driver, el, value: str) -> bool:
    """Set an input through the NATIVE value setter so React notices.

    Plain `el.value=''` from JS leaves React's internal tracker stale and the
    next keystroke reverts the field; going through the prototype descriptor's
    setter and dispatching an `input` event updates the framework state.
    """
    try:
        driver.execute_script(
            "var d=Object.getOwnPropertyDescriptor("
            "window.HTMLInputElement.prototype,'value');"
            "if(d&&d.set){d.set.call(arguments[0],'');}"
            "arguments[0].dispatchEvent(new Event('input',{bubbles:true}));",
            el,
        )
        el.send_keys(value)
        return (el.get_attribute("value") or "").strip() == value.strip()
    except Exception:
        return False


def set_search_value(driver, locator_css: str, value: str,
                     timeout: int = DEFAULT_TIMEOUT, attempts: int = 4) -> bool:
    """Reliably set a (framework-controlled) search/autocomplete input.

    Each attempt re-finds the element fresh, focuses it, clears it (select-all
    + DELETE, then the native-setter JS clear if the keys didn't take),
    VERIFIES the box is empty before typing, types, and verifies it landed.
    Catches the 'stuck on the previous value' failure where a silently-failed
    clear makes the subsequent send_keys append ('OldValueNewValue'), which
    makes the autocomplete match nothing — or the wrong entry.
    """
    want = (value or "").strip()
    want_lc = want.lower()
    for _ in range(attempts):
        try:
            el = WebDriverWait(driver, timeout).until(
                EC.visibility_of_element_located((By.CSS_SELECTOR, locator_css))
            )
            # Locate by visibility and do NOT click first — clicking a search
            # input can remount it and drop the keystrokes.
            el.send_keys(Keys.CONTROL + "a")
            el.send_keys(Keys.DELETE)
            if (el.get_attribute("value") or "").strip():
                set_react_value(driver, el, want)
            else:
                el.send_keys(want)
            # If a failed clear left '<old><want>', the mismatch trips a retry.
            if (el.get_attribute("value") or "").strip().lower() == want_lc:
                return True
        except (StaleElementReferenceException, Exception):
            continue
    return False


def _norm_option_text(text: str) -> str:
    """Lowercase, strip, and drop icon-glyph prefixes (e.g. a checkmark line)."""
    t = (text or "").lower().strip()
    for junk in ("\ndone\n", "done\n", "✓", "✔"):
        t = t.replace(junk, "")
    return t.strip()


# ---------------------------------------------------------------------------
# The engine
# ---------------------------------------------------------------------------

def fill_form(
    driver,
    form_fields: dict[str, Control],
    overlay_selectors: list[str] | None = None,
    verbose: bool = True,
) -> dict[str, str]:
    """Fill every control in `form_fields`. Returns {name: outcome}.

    Outcomes: 'ok', 'skipped-missing' (element absent and that is tolerated),
    'retries-exhausted'. The function does NOT raise on a stubborn control —
    it records it and moves on, so one bad field doesn't strand a half-filled
    form with no report of what happened.
    """
    results: dict[str, str] = {}

    def say(msg: str) -> None:
        if verbose:
            print(msg, file=sys.stderr)

    for name, c in form_fields.items():
        outcome = _fill_one(driver, c, overlay_selectors, say)
        results[name] = outcome
    return results


def _fill_one(driver, c: Control, overlay_selectors, say) -> str:
    for attempt in range(max(1, c.retries)):
        try:
            say(f"[{c._type}] '{c.description}' ({c.by}={c.locator}) <- {c.value!r}")
            match c._type:
                case "input_text" | "textarea":
                    el = driver.find_element(c.by, c.locator)
                    el.clear()
                    el.send_keys(str(c.value))
                    if (el.get_attribute("value") or "").strip() != str(c.value).strip():
                        set_react_value(driver, el, str(c.value))
                    return "ok"

                case "click" | "button":
                    els = driver.find_elements(c.by, c.locator)
                    if not els:
                        return "skipped-missing"
                    el = els[0]
                    try:
                        el.click()
                    except ElementClickInterceptedException:
                        # A sticky header can overlap the button so the native
                        # click is a silent no-op — bypass via JS after scroll.
                        driver.execute_script(
                            "arguments[0].scrollIntoView({block:'center'});", el)
                        driver.execute_script("arguments[0].click();", el)
                    return "ok"

                case "image_badge":
                    els = driver.find_elements(c.by, c.locator)
                    if els:
                        time.sleep(0.25)
                        try:
                            els[0].click()
                            say("  badge removed")
                        except (TimeoutException, NoSuchElementException,
                                ElementClickInterceptedException,
                                ElementNotInteractableException):
                            say("  badge not clickable, continuing")
                    return "ok" if els else "skipped-missing"

                case "checkbox":
                    el = driver.find_element(c.by, c.locator)
                    if el.is_selected() == bool(c.value):
                        return "ok"
                    try:
                        el.click()
                        return "ok" if el.is_selected() == bool(c.value) else "retries-exhausted"
                    except (ElementClickInterceptedException, ElementNotInteractableException):
                        # The visible label is the real click target on many
                        # sites; the input itself is visually hidden.
                        label = driver.find_element(
                            By.CSS_SELECTOR, f"label[for='{c.locator}']")
                        label.click()
                        return "ok" if el.is_selected() == bool(c.value) else "retries-exhausted"

                case "label_checkbox":
                    input_el = driver.find_element(By.ID, c.locator)
                    if input_el.is_selected() == bool(c.value):
                        return "ok"
                    label = WebDriverWait(driver, DEFAULT_TIMEOUT).until(
                        EC.element_to_be_clickable(
                            (By.CSS_SELECTOR, f"label[for='{c.locator}']")))
                    label.click()
                    return "ok" if input_el.is_selected() == bool(c.value) else "retries-exhausted"

                case "radio":
                    el = driver.find_element(c.by, c.locator)
                    if c.value and not el.is_selected():
                        el.click()
                    return "ok"

                case "select":
                    from selenium.webdriver.support.ui import Select  # local: optional dep
                    sel = Select(driver.find_element(c.by, c.locator))
                    try:
                        sel.select_by_visible_text(str(c.value))
                    except Exception:
                        sel.select_by_value(str(c.value))
                    return "ok"

                case "autocomplete":
                    return _fill_autocomplete(driver, c, overlay_selectors, say)

                case _:
                    say(f"  unknown control type {c._type!r} — skipped")
                    return "skipped-missing"

        except StaleElementReferenceException:
            say(f"  stale element on '{c.description}' — refinding")
            continue
        except (TimeoutException, NoSuchElementException):
            return "skipped-missing"
        except ElementClickInterceptedException:
            dismiss_overlays(driver, overlay_selectors)
            continue

    return "retries-exhausted"


def _fill_autocomplete(driver, c: Control, overlay_selectors, say) -> str:
    """Type into a search box, await the dropdown, pick the prefix match."""
    if not c.class_search:
        raise ValueError(
            f"autocomplete control '{c.description}' needs class_search "
            "(the dropdown container class) to await options")
    dismiss_overlays(driver, overlay_selectors)

    wait = WebDriverWait(driver, DEFAULT_TIMEOUT)
    if not set_search_value(driver, c.locator, str(c.value)):
        return "retries-exhausted"
    time.sleep(0.4)

    def _has_options(d):
        lists = d.find_elements(By.CLASS_NAME, c.class_search)
        return bool(lists) and bool(lists[0].find_elements(By.TAG_NAME, "li"))

    try:
        wait.until(_has_options)
    except TimeoutException:
        # one re-type: a first send_keys can be swallowed by a remount
        if not set_search_value(driver, c.locator, str(c.value)):
            return "retries-exhausted"
        time.sleep(0.4)
        try:
            wait.until(_has_options)
        except TimeoutException:
            return "retries-exhausted"

    options_ul = wait.until(
        EC.visibility_of_element_located((By.CLASS_NAME, c.class_search)))
    want = _norm_option_text(str(c.value))
    try:
        options = options_ul.find_elements(By.TAG_NAME, "li")
    except StaleElementReferenceException:
        options_ul = wait.until(
            EC.visibility_of_element_located((By.CLASS_NAME, c.class_search)))
        options = options_ul.find_elements(By.TAG_NAME, "li")

    for option in options:
        try:
            text = _norm_option_text(option.text)
        except StaleElementReferenceException:
            continue
        if text.startswith(want):
            option.click()
            return "ok"
    say("  no autocomplete option matched")
    return "retries-exhausted"


__all__ = [
    "Control",
    "CONTROL_TYPES",
    "DEFAULT_OVERLAY_SELECTORS",
    "fill_form",
    "filter_fields",
    "load_form",
    "dismiss_overlays",
    "set_react_value",
    "set_search_value",
]

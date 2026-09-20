#!/usr/bin/env python3
"""Exercise a built Lightpanda binary against a live fingerprint endpoint."""

from __future__ import annotations

import argparse
import html.parser
import json
import re
import subprocess
import sys
import time
from pathlib import Path


ENDPOINT = "https://tls.peet.ws/api/all"
FINGERPRINTS = {
    "chrome146": {
        "ja4": "t13d1517h2_8daaf6152771_b6f405a00624",
        "peetprint_hash": "d44d68f0fce54cd423d6792272a242b8",
        "akamai": "1:65536;2:0;4:6291456;6:262144|15663105|0|m,a,s,p",
    },
}

INJECT_SCRIPT = r"""
Promise.all([
  fetch(location.href).then(response => response.json()),
  navigator.userAgentData.getHighEntropyValues([
    'uaFullVersion',
    'fullVersionList',
  ]),
]).then(([network, high]) => {
  document.documentElement.innerHTML = '<body id="result"></body>';
  document.body.textContent = JSON.stringify({
    network,
    navigator: {
      userAgent: navigator.userAgent,
      brands: navigator.userAgentData.brands,
      high,
    },
  });
  document.body.dataset.done = '1';
});
""".strip()


class ResultBodyParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_result = False
        self.chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "body" and dict(attrs).get("id") == "result":
            self.in_result = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "body":
            self.in_result = False

    def handle_data(self, data: str) -> None:
        if self.in_result:
            self.chunks.append(data)


def zon_string(source: str, field: str) -> str | None:
    match = re.search(rf"^\s*\.{re.escape(field)}\s*=\s*(null|\"(?:[^\"\\]|\\.)*\")\s*,", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing .{field} in UA profile")
    value = match.group(1)
    return None if value == "null" else json.loads(value)


def zon_bool(source: str, field: str) -> bool:
    match = re.search(rf"^\s*\.{re.escape(field)}\s*=\s*(true|false)\s*,", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing .{field} in UA profile")
    return match.group(1) == "true"


def expected_ua_profile(path: Path) -> tuple[str, str, bool]:
    source = path.read_text(encoding="utf-8")
    full_version = zon_string(source, "full_version")
    if full_version is None:
        raise ValueError(".full_version cannot be null")
    major = full_version.split(".", 1)[0]
    configured_ua = zon_string(source, "user_agent")
    user_agent = configured_ua or (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) Chrome/{major}.0.0.0 Safari/537.36"
    )
    return user_agent, full_version, zon_bool(source, "include_google_chrome_brand")


def run_binary(binary: Path, profile: str, endpoint: str) -> dict:
    command = [
        str(binary),
        "fetch",
        "--json",
        "--dump",
        "html",
        "--inject-script",
        INJECT_SCRIPT,
        "--wait-script",
        "document.body && document.body.dataset.done === '1'",
        "--wait-ms",
        "15000",
        "--terminate-ms",
        "30000",
        "--http-timeout",
        "15000",
        "--log-filter",
        "all",
        "--curl-impersonate",
        profile,
        endpoint,
    ]
    failures: list[str] = []

    for attempt in range(1, 4):
        try:
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=45,
            )
        except subprocess.TimeoutExpired:
            failures.append(f"attempt {attempt}: timed out")
        else:
            if completed.returncode == 0:
                wrapper = json.loads(completed.stdout)
                if wrapper.get("error") is not None:
                    failures.append(f"attempt {attempt}: {wrapper['error']}")
                else:
                    parser = ResultBodyParser()
                    parser.feed(wrapper["content"])
                    if parser.chunks:
                        return json.loads("".join(parser.chunks))
                    failures.append(f"attempt {attempt}: result body missing")
            else:
                detail = completed.stderr.strip() or completed.stdout.strip()
                failures.append(f"attempt {attempt}: exit {completed.returncode}: {detail}")
        if attempt < 3:
            time.sleep(attempt)

    raise RuntimeError("live request failed after 3 attempts\n" + "\n".join(failures))


def headers_from_capture(network: dict) -> dict[str, str]:
    for frame in network["http2"]["sent_frames"]:
        if frame.get("frame_type") != "HEADERS":
            continue
        headers: dict[str, str] = {}
        for line in frame["headers"]:
            if line.startswith(":"):
                continue
            name, value = line.split(": ", 1)
            headers[name.lower()] = value
        return headers
    raise AssertionError("HTTP/2 HEADERS frame was not captured")


def check_equal(label: str, actual: object, expected: object, failures: list[str]) -> None:
    if actual != expected:
        failures.append(f"{label}: expected {expected!r}, got {actual!r}")


def client_hint_brands(value: str) -> list[tuple[str, str]]:
    return re.findall(r'"([^"\\]*)";v="([^"\\]*)"', value)


def validate(capture: dict, profile: str, ua_profile: Path) -> None:
    expected = FINGERPRINTS.get(profile)
    if expected is None:
        raise ValueError(f"no expected live fingerprint is registered for {profile!r}")

    expected_ua, full_version, include_chrome = expected_ua_profile(ua_profile)
    major = full_version.split(".", 1)[0]
    network = capture["network"]
    navigator = capture["navigator"]
    high = navigator["high"]
    headers = headers_from_capture(network)
    low_brands = {item["brand"]: item["version"] for item in navigator["brands"]}
    full_brands = {item["brand"]: item["version"] for item in high["fullVersionList"]}
    failures: list[str] = []

    check_equal("HTTP protocol", network["http_version"], "h2", failures)
    check_equal("JA4", network["tls"]["ja4"], expected["ja4"], failures)
    check_equal("PeetPrint hash", network["tls"]["peetprint_hash"], expected["peetprint_hash"], failures)
    check_equal("Akamai HTTP/2 fingerprint", network["http2"]["akamai_fingerprint"], expected["akamai"], failures)
    check_equal("reported User-Agent", network["user_agent"], expected_ua, failures)
    check_equal("User-Agent header", headers.get("user-agent"), expected_ua, failures)
    check_equal("navigator.userAgent", navigator["userAgent"], expected_ua, failures)
    check_equal("navigator Chromium brand", low_brands.get("Chromium"), major, failures)
    check_equal("high-entropy Chromium brand", full_brands.get("Chromium"), full_version, failures)
    check_equal("uaFullVersion", high["uaFullVersion"], full_version, failures)

    chrome_low = low_brands.get("Google Chrome")
    chrome_full = full_brands.get("Google Chrome")
    check_equal("navigator Google Chrome brand", chrome_low, major if include_chrome else None, failures)
    check_equal("high-entropy Google Chrome brand", chrome_full, full_version if include_chrome else None, failures)

    sec_ch_ua = headers.get("sec-ch-ua", "")
    sec_ch_ua_full = headers.get("sec-ch-ua-full-version-list", "")
    navigator_brands = [(item["brand"], item["version"]) for item in navigator["brands"]]
    navigator_full_brands = [(item["brand"], item["version"]) for item in high["fullVersionList"]]
    check_equal("Sec-CH-UA vs Navigator brands", client_hint_brands(sec_ch_ua), navigator_brands, failures)
    check_equal(
        "Sec-CH-UA-Full-Version-List vs Navigator brands",
        client_hint_brands(sec_ch_ua_full),
        navigator_full_brands,
        failures,
    )
    if f'"Chromium";v="{major}"' not in sec_ch_ua:
        failures.append(f"Sec-CH-UA does not contain the expected Chromium major: {sec_ch_ua!r}")
    if f'"Chromium";v="{full_version}"' not in sec_ch_ua_full:
        failures.append(f"Sec-CH-UA-Full-Version-List does not contain the expected version: {sec_ch_ua_full!r}")

    if failures:
        raise AssertionError("impersonation live test failed:\n- " + "\n- ".join(failures))

    print(f"PASS: {profile} TLS/HTTP2 fingerprint")
    print(f"PASS: UA profile {full_version} across headers and Navigator")
    print(f"  JA4: {network['tls']['ja4']}")
    print(f"  HTTP/2: {network['http2']['akamai_fingerprint']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--curl-profile", default="chrome146")
    parser.add_argument("--ua-profile", type=Path, default=Path("ua-profile.zon"))
    parser.add_argument("--endpoint", default=ENDPOINT)
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"binary does not exist: {binary}")

    try:
        capture = run_binary(binary, args.curl_profile, args.endpoint)
        validate(capture, args.curl_profile, args.ua_profile)
    except (AssertionError, KeyError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Small authenticated ARM client with deliberately redacted failures."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import requests


class AzureRequestError(RuntimeError):
    """A bounded Azure request failed without disclosing its payload or token."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


@dataclass
class AzureJsonClient:
    credential: Any
    session: requests.Session
    timeout_seconds: float = 30.0

    def request(
        self,
        method: str,
        url: str,
        *,
        scope: str,
        body: dict[str, object] | None = None,
        expected_statuses: tuple[int, ...] = (200,),
        allow_empty_response: bool = False,
    ) -> dict[str, Any]:
        token = self.credential.get_token(scope).token
        response = self.session.request(
            method,
            url,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=body,
            timeout=self.timeout_seconds,
            allow_redirects=False,
        )
        if response.status_code not in expected_statuses:
            request_id = safe_diagnostic(
                response.headers.get("x-ms-request-id") or response.headers.get("request-id") or "unavailable"
            )
            error_code = "unknown"
            try:
                payload = response.json()
                if isinstance(payload, dict):
                    error = payload.get("error")
                    if isinstance(error, dict) and isinstance(error.get("code"), str):
                        error_code = safe_diagnostic(error["code"])
                    elif isinstance(payload.get("code"), str):
                        error_code = safe_diagnostic(payload["code"])
            except (ValueError, requests.RequestException):
                pass
            safe_url = _redacted_url(url)
            raise AzureRequestError(
                f"{method.upper()} {safe_url} failed with HTTP {response.status_code}; "
                f"code={error_code}; request-id={request_id}",
                status_code=response.status_code,
            )
        try:
            payload = response.json()
        except ValueError as error:
            if allow_empty_response and getattr(response, "content", b"") in {b"", ""}:
                return {}
            raise AzureRequestError(f"{method.upper()} {_redacted_url(url)} returned non-JSON") from error
        if not isinstance(payload, dict):
            raise AzureRequestError(f"{method.upper()} {_redacted_url(url)} returned an unexpected JSON type")
        return payload


def _redacted_url(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


def safe_diagnostic(value: object) -> str:
    rendered = str(value)
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,100}", rendered):
        return "unavailable"
    return rendered

from __future__ import annotations

import pytest

from qam_foundry.http import AzureJsonClient, AzureRequestError


class Credential:
    def get_token(self, scope: str):
        assert scope == "https://management.azure.com/.default"
        return type("Token", (), {"token": "VERY_SECRET_TOKEN"})()


class Response:
    def __init__(
        self,
        status_code: int,
        body: object,
        headers: dict[str, str] | None = None,
        content: bytes = b"json",
    ):
        self.status_code = status_code
        self._body = body
        self.headers = headers or {}
        self.content = content

    def json(self):
        return self._body


class Session:
    def __init__(self, response: Response):
        self.response = response
        self.headers: dict[str, str] | None = None
        self.allow_redirects: bool | None = None

    def request(self, method, url, *, headers, json, timeout, allow_redirects):
        self.headers = headers
        self.allow_redirects = allow_redirects
        return self.response


def test_failure_redacts_token_query_and_response_message() -> None:
    session = Session(
        Response(
            401,
            {"error": {"code": "Denied", "message": "VERY_SECRET_TOKEN leaked"}},
            {"x-ms-request-id": "request-1"},
        )
    )
    client = AzureJsonClient(Credential(), session)  # type: ignore[arg-type]
    with pytest.raises(AzureRequestError) as caught:
        client.request(
            "PUT",
            "https://management.azure.com/resource?api-version=preview&secret=VERY_SECRET_TOKEN",
            scope="https://management.azure.com/.default",
            body={},
        )
    message = str(caught.value)
    assert caught.value.status_code == 401
    assert "Denied" in message
    assert "request-1" in message
    assert "VERY_SECRET_TOKEN" not in message
    assert "api-version" not in message
    assert session.headers == {
        "Authorization": "Bearer VERY_SECRET_TOKEN",
        "Content-Type": "application/json",
    }
    assert session.allow_redirects is False


def test_success_requires_a_json_object() -> None:
    client = AzureJsonClient(Credential(), Session(Response(200, {"ok": True})))  # type: ignore[arg-type]
    assert client.request(
        "GET", "https://management.azure.com/resource", scope="https://management.azure.com/.default"
    ) == {"ok": True}


def test_explicit_async_empty_response_can_be_polled_afterward() -> None:
    class EmptyResponse(Response):
        def json(self):
            raise ValueError("empty")

    client = AzureJsonClient(  # type: ignore[arg-type]
        Credential(), Session(EmptyResponse(202, None, content=b""))
    )
    assert (
        client.request(
            "PUT",
            "https://management.azure.com/resource",
            scope="https://management.azure.com/.default",
            expected_statuses=(202,),
            allow_empty_response=True,
        )
        == {}
    )

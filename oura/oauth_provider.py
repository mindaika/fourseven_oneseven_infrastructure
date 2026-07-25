"""Minimal single-user OAuth 2.1 authorization server for the Oura MCP
server, adapted from the MCP Python SDK's bundled reference implementation
(examples/servers/simple-auth). Not a general-purpose auth system — there's
exactly one account, its credentials come from the environment, and the
whole thing exists to satisfy Claude Desktop's requirement that remote MCP
connectors support OAuth (dynamic client registration + authorization code
flow), nothing more.

The real security boundary for this server is downstream of here: the
`claude_reader` database role only has SELECT on the `reporting` schema of
views (see reporting_schema.sql), and this endpoint is only reachable from
the home LAN in the first place (see the nginx server block). This login
gate is a third, outermost layer on top of those two, not the thing doing
the actual enforcement.
"""

import secrets
import time

from pydantic import AnyUrl
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import HTMLResponse, RedirectResponse, Response

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    OAuthAuthorizationServerProvider,
    RefreshToken,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

MCP_SCOPE = "user"


class _PermissiveClientInfo(OAuthClientInformationFull):
    """Accepts whatever redirect_uri the caller presents, instead of
    requiring an exact match against a pre-declared list.

    Only used for the one static, pre-shared client_id/secret we hand out
    manually (see SingleUserOAuthProvider.__init__) as a fallback for MCP
    clients that don't do dynamic client registration (RFC 7591) — we
    can't know their real redirect_uri in advance the way we would if they
    registered themselves via POST /register, so strict matching isn't
    possible here. This doesn't weaken anything that's actually load-
    bearing: reaching this client still requires the pre-shared secret,
    then the username/password login gate, on a server only reachable
    from the LAN in the first place."""

    def validate_redirect_uri(self, redirect_uri):
        if redirect_uri is not None:
            return redirect_uri
        if self.redirect_uris:
            return self.redirect_uris[0]
        raise ValueError("redirect_uri must be specified")


class SingleUserOAuthProvider(OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]):
    def __init__(
        self,
        username: str,
        password: str,
        auth_callback_url: str,
        server_url: str,
        static_client_id: str | None = None,
        static_client_secret: str | None = None,
    ):
        self.username = username
        self.password = password
        self.auth_callback_url = auth_callback_url
        self.server_url = server_url
        self.clients: dict[str, OAuthClientInformationFull] = {}
        self.auth_codes: dict[str, AuthorizationCode] = {}
        self.tokens: dict[str, AccessToken] = {}
        self.state_mapping: dict[str, dict[str, str | None]] = {}

        if static_client_id:
            self.clients[static_client_id] = _PermissiveClientInfo(
                client_id=static_client_id,
                client_secret=static_client_secret,
                # Placeholder only — _PermissiveClientInfo.validate_redirect_uri
                # ignores this and accepts whatever the caller actually presents.
                # The field just needs a schema-valid, non-empty value.
                redirect_uris=["http://localhost"],
                grant_types=["authorization_code", "refresh_token"],
                response_types=["code"],
                token_endpoint_auth_method="client_secret_post",
                scope=MCP_SCOPE,
                client_name="Claude Desktop (static)",
            )

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return self.clients.get(client_id)

    async def register_client(self, client_info: OAuthClientInformationFull):
        if not client_info.client_id:
            raise ValueError("No client_id provided")
        self.clients[client_info.client_id] = client_info

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        state = params.state or secrets.token_hex(16)
        self.state_mapping[state] = {
            "redirect_uri": str(params.redirect_uri),
            "code_challenge": params.code_challenge,
            "redirect_uri_provided_explicitly": str(params.redirect_uri_provided_explicitly),
            "client_id": client.client_id,
            "resource": params.resource,
        }
        return f"{self.auth_callback_url}?state={state}&client_id={client.client_id}"

    async def get_login_page(self, state: str) -> HTMLResponse:
        if not state:
            raise HTTPException(400, "Missing state parameter")
        html_content = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Oura MCP Sign In</title>
            <style>
                body {{ font-family: -apple-system, sans-serif; max-width: 420px; margin: 80px auto; padding: 20px; }}
                .form-group {{ margin-bottom: 15px; }}
                input {{ width: 100%; padding: 8px; margin-top: 5px; box-sizing: border-box; }}
                button {{ background-color: #4CAF50; color: white; padding: 10px 15px; border: none; cursor: pointer; width: 100%; }}
            </style>
        </head>
        <body>
            <h2>Oura MCP Server</h2>
            <p>Sign in to grant access.</p>
            <form action="{self.server_url.rstrip('/')}/login/callback" method="post">
                <input type="hidden" name="state" value="{state}">
                <div class="form-group">
                    <label>Username:</label>
                    <input type="text" name="username" required>
                </div>
                <div class="form-group">
                    <label>Password:</label>
                    <input type="password" name="password" required>
                </div>
                <button type="submit">Sign In</button>
            </form>
        </body>
        </html>
        """
        return HTMLResponse(content=html_content)

    async def handle_login_callback(self, request: Request) -> Response:
        form = await request.form()
        username = form.get("username")
        password = form.get("password")
        state = form.get("state")
        if not username or not password or not state:
            raise HTTPException(400, "Missing username, password, or state parameter")
        if not isinstance(username, str) or not isinstance(password, str) or not isinstance(state, str):
            raise HTTPException(400, "Invalid parameter types")

        state_data = self.state_mapping.get(state)
        if not state_data:
            raise HTTPException(400, "Invalid state parameter")

        if username != self.username or password != self.password:
            # Redirect back to the login page with the same state rather than
            # a bare 401, so a mistyped password is just "try again."
            return RedirectResponse(url=f"{self.server_url.rstrip('/')}/login?state={state}", status_code=302)

        redirect_uri = state_data["redirect_uri"]
        code_challenge = state_data["code_challenge"]
        redirect_uri_provided_explicitly = state_data["redirect_uri_provided_explicitly"] == "True"
        client_id = state_data["client_id"]
        resource = state_data.get("resource")
        assert redirect_uri is not None
        assert client_id is not None

        new_code = f"mcp_{secrets.token_hex(16)}"
        self.auth_codes[new_code] = AuthorizationCode(
            code=new_code,
            client_id=client_id,
            redirect_uri=AnyUrl(redirect_uri),
            redirect_uri_provided_explicitly=redirect_uri_provided_explicitly,
            expires_at=time.time() + 300,
            scopes=[MCP_SCOPE],
            code_challenge=code_challenge,
            resource=resource,
            subject=username,
        )
        del self.state_mapping[state]
        return RedirectResponse(
            url=construct_redirect_uri(redirect_uri, code=new_code, state=state), status_code=302
        )

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        return self.auth_codes.get(authorization_code)

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
    ) -> OAuthToken:
        if authorization_code.code not in self.auth_codes:
            raise ValueError("Invalid authorization code")
        if not client.client_id:
            raise ValueError("No client_id provided")

        mcp_token = f"mcp_{secrets.token_hex(32)}"
        self.tokens[mcp_token] = AccessToken(
            token=mcp_token,
            client_id=client.client_id,
            scopes=authorization_code.scopes,
            expires_at=int(time.time()) + 3600 * 24 * 30,  # 30 days — this is a
            # personal single-user server behind a LAN-restricted endpoint, not
            # worth making the user re-auth in Claude Desktop every hour.
            resource=authorization_code.resource,
            subject=authorization_code.subject,
        )
        del self.auth_codes[authorization_code.code]
        return OAuthToken(
            access_token=mcp_token,
            token_type="Bearer",
            expires_in=3600 * 24 * 30,
            scope=" ".join(authorization_code.scopes),
        )

    async def load_access_token(self, token: str) -> AccessToken | None:
        access_token = self.tokens.get(token)
        if not access_token:
            return None
        if access_token.expires_at and access_token.expires_at < time.time():
            del self.tokens[token]
            return None
        return access_token

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        return None

    async def exchange_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]
    ) -> OAuthToken:
        raise NotImplementedError("Refresh tokens not supported — access tokens are long-lived instead.")

    async def revoke_token(self, token: str, token_type_hint: str | None = None) -> None:  # type: ignore[override]
        self.tokens.pop(token, None)

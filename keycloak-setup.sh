#!/bin/bash
set -e

KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
REALM="${REALM:-ci-platform}"
CLIENT_ID="${CLIENT_ID:-ci-platform-web}"
TEST_USER="${TEST_USER:-test}"
TEST_PASSWORD="${TEST_PASSWORD:-test}"

echo "==> Waiting for Keycloak at $KC_URL..."
for i in $(seq 1 30); do
  if curl -sf "$KC_URL/health/ready" > /dev/null 2>&1 || \
     curl -sf "$KC_URL/realms/master" > /dev/null 2>&1; then
    echo "    Keycloak ready."
    break
  fi
  echo "    attempt $i/30 — waiting 3s..."
  sleep 3
done

echo "==> Getting admin token..."
TOKEN=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=$KC_ADMIN&password=$KC_ADMIN_PASSWORD" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "ERROR: could not get admin token"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

echo "==> Patching master realm ssl_required=NONE..."
curl -sf -X PUT "$KC_URL/admin/realms/master" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"sslRequired":"none"}' && echo "    master patched."

echo "==> Creating realm '$REALM'..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"sslRequired\":\"none\"}")
if [ "$STATUS" = "201" ]; then
  echo "    Realm created."
elif [ "$STATUS" = "409" ]; then
  echo "    Realm already exists — patching ssl_required..."
  curl -sf -X PUT "$KC_URL/admin/realms/$REALM" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"sslRequired":"none"}'
else
  echo "ERROR: realm creation returned HTTP $STATUS"
  exit 1
fi

echo "==> Creating client '$CLIENT_ID'..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"$CLIENT_ID\",
    \"enabled\": true,
    \"publicClient\": true,
    \"standardFlowEnabled\": true,
    \"directAccessGrantsEnabled\": true,
    \"redirectUris\": [\"http://localhost:*\", \"http://104.248.18.53:*\", \"*\"],
    \"webOrigins\": [\"*\"]
  }")
if [ "$STATUS" = "201" ]; then
  echo "    Client created."
elif [ "$STATUS" = "409" ]; then
  echo "    Client already exists."
else
  echo "ERROR: client creation returned HTTP $STATUS"
  exit 1
fi

echo "==> Adding audience mapper to client..."
CLIENT_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  -H "$AUTH" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{
    "name": "account-audience",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "config": {
      "included.client.audience": "account",
      "access.token.claim": "true",
      "id.token.claim": "false"
    }
  }')
if [ "$STATUS" = "201" ]; then
  echo "    Audience mapper added."
elif [ "$STATUS" = "409" ]; then
  echo "    Audience mapper already exists."
else
  echo "    WARNING: mapper returned HTTP $STATUS — skipping."
fi

echo "==> Creating realm role 'tenant-user'..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/roles" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"name":"tenant-user","description":"Regular tenant member"}')
if [ "$STATUS" = "201" ]; then
  echo "    Role 'tenant-user' created."
elif [ "$STATUS" = "409" ]; then
  echo "    Role 'tenant-user' already exists."
else
  echo "    WARNING: role creation returned HTTP $STATUS"
fi

echo "==> Removing legacy role 'org-user' if present..."
ORG_USER_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" "$KC_URL/admin/realms/$REALM/roles/org-user" -H "$AUTH")
if [ "$ORG_USER_EXISTS" = "200" ]; then
  curl -sf -X DELETE "$KC_URL/admin/realms/$REALM/roles/org-user" -H "$AUTH" && echo "    Role 'org-user' removed."
else
  echo "    Role 'org-user' not present — nothing to remove."
fi

echo "==> Creating test user '$TEST_USER'..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/users" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{
    \"username\": \"$TEST_USER\",
    \"email\": \"$TEST_USER@example.com\",
    \"firstName\": \"Test\",
    \"lastName\": \"User\",
    \"enabled\": true,
    \"emailVerified\": true,
    \"requiredActions\": [],
    \"credentials\": [{
      \"type\": \"password\",
      \"value\": \"$TEST_PASSWORD\",
      \"temporary\": false
    }]
  }")
if [ "$STATUS" = "201" ]; then
  echo "    User created."
elif [ "$STATUS" = "409" ]; then
  echo "    User already exists."
else
  echo "ERROR: user creation returned HTTP $STATUS"
  exit 1
fi

echo ""
echo "==> Setup complete. Test with:"
echo "    curl -s -X POST $KC_URL/realms/$REALM/protocol/openid-connect/token \\"
echo "      -d 'client_id=$CLIENT_ID&grant_type=password&username=$TEST_USER&password=$TEST_PASSWORD' \\"
echo "      | jq .access_token"

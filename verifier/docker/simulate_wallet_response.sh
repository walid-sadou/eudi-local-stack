#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  ./simulate_wallet_response.sh "<eudi-openid4vp://...? ...>" [options]
  ./simulate_wallet_response.sh "<URL .../wallet/request.jwt/<tx>>" [options]

Options:
  --alg none|hs256|rs256     Algo du JWT de réponse (defaut: none)
  --kid <kid>                kid à mettre dans l'en-tête JWT (optionnel)
  --key <path>               Clé (fichier): HS256 = secret brut ; RS256 = PEM
  --payload <path.json>      Payload JSON à utiliser tel quel (écrase l’auto)
  --insecure                 Autoriser HTTP / TLS non fiable pour curl
  -h, --help                 Aide

Le script :
  1) Récupère le request.jwt (Accept: application/oauth-authz-req+jwt)
  2) Extrait response_uri, client_id, state, nonce
  3) Construit un JWT minimal (alg none par défaut)
  4) POSTe le JWT vers response_uri en form-urlencoded: response=<jwt>
EOF
}

url_decode() {
  # URL-decode (POSIX)
  local data="${1//+/ }"; printf '%b' "${data//%/\\x}"
}

b64url_encode() {
  # stdin -> base64url(1 line)
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

b64url_decode() {
  # base64url string -> stdout
  local s="$1" pad=$(( (4 - ${#1} % 4) % 4 ))
  s="${s//-/+}"; s="${s//_//}"
  printf '%s' "$s" | sed -e "s/$/$(printf '=%.0s' $(seq 1 $pad))/" | openssl base64 -A -d 2>/dev/null
}

json_get() {
  # naive JSON getter (jq si dispo, sinon sed)
  if command -v jq >/dev/null 2>&1; then
    jq -r "$2 // empty" <<<"$1"
  else
    # très simple (clé top-level seulement)
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
  fi
}

now_s() { date +%s; }

# --- Parse args ------------------------------------------------------------

ALG="none"
KID=""
KEY_FILE=""
INSECURE=0
PAYLOAD_FILE=""
ARG="${1:-}"

if [[ $# -lt 1 ]]; then usage; exit 1; fi
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alg) ALG="$2"; shift 2;;
    --kid) KID="$2"; shift 2;;
    --key) KEY_FILE="$2"; shift 2;;
    --payload) PAYLOAD_FILE="$2"; shift 2;;
    --insecure) INSECURE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

CURL_OPTS=(-sS -L)
[[ $INSECURE -eq 1 ]] && CURL_OPTS+=(-k)

# --- 1) Obtenir l’URL du request.jwt --------------------------------------

REQUEST_URL=""
if [[ "$ARG" == eudi-openid4vp://* ]]; then
  # extraire request_uri=
  q="${ARG#*://?}"
  # trouver request_uri=... (url-encodée)
  enc_req_uri="$(printf '%s' "$q" | sed -n 's/.*request_uri=\([^&]*\).*/\1/p')"
  if [[ -z "$enc_req_uri" ]]; then
    echo "ERROR: request_uri parameter not found in deeplink" >&2; exit 2
  fi
  req_uri="$(url_decode "$enc_req_uri")"
  # corriger des artefacts fréquents (http%2F%2Fhttp%2F, :8080:8080)
  req_uri="${req_uri/http:\/\/http\//http:\/\/}"
  req_uri="${req_uri/https:\/\/https\//https:\/\/}"
  req_uri="${req_uri/:8080:8080/:8080}"
  REQUEST_URL="$req_uri"
else
  REQUEST_URL="$ARG"
fi

echo "[1/6] GET request.jwt from: $REQUEST_URL"

JWT_RAW="$(curl "${CURL_OPTS[@]}" -H 'Accept: application/oauth-authz-req+jwt' "$REQUEST_URL" || true)"
if [[ -z "$JWT_RAW" ]]; then
  echo "ERROR: empty response fetching request.jwt" >&2; exit 3
fi

if [[ "$(printf '%s' "$JWT_RAW" | tr -cd '.' | wc -c | tr -d ' ')" -lt 2 ]]; then
  echo "ERROR: invalid JWT format" >&2
  echo "Body was: $(printf '%.200s' "$JWT_RAW")" >&2
  exit 4
fi
echo " -> received JWT (len $(echo -n "$JWT_RAW" | wc -c | tr -d ' '))"

# --- 2) Décoder le JWT et extraire response_uri, client_id, state, nonce ---

JWT_HEADER_B64="${JWT_RAW%%.*}"
JWT_PAYLOAD_B64="$(echo "$JWT_RAW" | cut -d. -f2)"
JWT_PAYLOAD_JSON="$(b64url_decode "$JWT_PAYLOAD_B64" || true)"

if [[ -z "$JWT_PAYLOAD_JSON" ]]; then
  echo "ERROR: cannot base64url-decode JWT payload" >&2; exit 5
fi

RESPONSE_URI="$(json_get "$JWT_PAYLOAD_JSON" '.response_uri')"
CLIENT_ID="$(json_get "$JWT_PAYLOAD_JSON" '.client_id')"
STATE="$(json_get "$JWT_PAYLOAD_JSON" '.state')"
NONCE="$(json_get "$JWT_PAYLOAD_JSON" '.nonce')"

echo "[2/6] Extracted:"
echo "       response_uri: $RESPONSE_URI"
echo "       client_id   : $CLIENT_ID"
echo "       state       : $STATE"
echo "       nonce       : $NONCE"

if [[ -z "$RESPONSE_URI" ]]; then
  echo "ERROR: response_uri not found in request.jwt" >&2; exit 6
fi

# --- 3) Construire le JWT de réponse --------------------------------------

if [[ -n "$PAYLOAD_FILE" ]]; then
  RESP_PAYLOAD="$(cat "$PAYLOAD_FILE")"
else
  NOW="$(now_s)"
  EXP=$((NOW + 300))
  # Payload "minimum vital" façon JARM: iss/aud/iat/exp + echo du state/nonce.
  # Ajoute un "vp_token" factice pour aider certains backends.
  RESP_PAYLOAD="$(cat <<JSON
{
  "iss": "mock-wallet",
  "aud": "${CLIENT_ID:-Verifier}",
  "iat": $NOW,
  "exp": $EXP,
  "state": "${STATE:-}",
  "nonce": "${NONCE:-}",
  "vp_token": {
    "presentation_submission": {
      "definition_id": "mock-def",
      "descriptor_map": []
    },
    "verifiableCredential": []
  }
}
JSON
)"
fi

# En-tête
if [[ "$ALG" == "none" ]]; then
  HEADER='{"alg":"none","typ":"JWT"}'
elif [[ "$ALG" == "hs256" ]]; then
  HEADER='{"alg":"HS256","typ":"JWT"}'
  [[ -n "$KID" ]] && HEADER='{"alg":"HS256","typ":"JWT","kid":"'"$KID"'"}'
  [[ -z "$KEY_FILE" ]] && { echo "ERROR: --key required for hs256" >&2; exit 7; }
elif [[ "$ALG" == "rs256" ]]; then
  HEADER='{"alg":"RS256","typ":"JWT"}'
  [[ -n "$KID" ]] && HEADER='{"alg":"RS256","typ":"JWT","kid":"'"$KID"'"}'
  [[ -z "$KEY_FILE" ]] && { echo "ERROR: --key (PEM) required for rs256" >&2; exit 8; }
else
  echo "ERROR: unsupported --alg '$ALG'"; exit 9
fi

H_B64="$(printf '%s' "$HEADER" | b64url_encode)"
P_B64="$(printf '%s' "$RESP_PAYLOAD" | b64url_encode)"

if [[ "$ALG" == "none" ]]; then
  SIGN=""
  JWT_RESP="${H_B64}.${P_B64}."
elif [[ "$ALG" == "hs256" ]]; then
  SIGN="$(printf '%s' "${H_B64}.${P_B64}" | openssl dgst -sha256 -mac HMAC -macopt "key:$(cat "$KEY_FILE")" -binary | b64url_encode)"
  JWT_RESP="${H_B64}.${P_B64}.${SIGN}"
else
  SIGN="$(printf '%s' "${H_B64}.${P_B64}" | openssl dgst -sha256 -sign "$KEY_FILE" -binary | b64url_encode)"
  JWT_RESP="${H_B64}.${P_B64}.${SIGN}"
fi

echo "[3/6] Built response JWT (alg=$ALG, len $(echo -n "$JWT_RESP" | wc -c | tr -d ' '))"

# --- 4) POST vers response_uri --------------------------------------------

echo "[4/6] POST form to response_uri (response=<jwt>)"
HTTP_OUT="$(mktemp)"
HTTP_CODE="$(curl "${CURL_OPTS[@]}" -o "$HTTP_OUT" -w '%{http_code}' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "response=${JWT_RESP}" \
  "$RESPONSE_URI" || true)"

echo "[5/6] HTTP status: $HTTP_CODE"
echo "----- body (first 500 chars) -----"
head -c 500 "$HTTP_OUT" || true
echo
rm -f "$HTTP_OUT"

echo "[6/6] Done."


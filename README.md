# EUDI Local Stack – Wallet / Issuer / Verifier

Ce dépôt permet de lancer en local un scénario de bout en bout :

> Issuer ↔ Wallet (PID) ↔ Verifier local (via émulateur Android + HTTPS)

Il regroupe :

- `wallet/`   → Wallet Android EUDI  
- `verifier/` → Verifier (backend + UI web)  
- `issuer/`   → Issuer PID (+ Keycloak + HAProxy)  

L’objectif est que n’importe quel·le collègue puisse rejouer le flux **sans** avoir à reconfigurer TLS, Docker, Android, Keycloak, etc.

---

## 1. Prérequis

À installer sur votre machine :

- **Git**
- **Docker Desktop** (ou Docker Engine + Docker Compose)
- **Android Studio** (avec un SDK Android 13+ et un émulateur configuré)

Cloner ce repo :

```bash
git clone git@github.com:walid-sadou/eudi-local-stack.git
cd eudi-local-stack
```

Test rapide Docker :

```bash
docker version
docker compose version
```

Test rapide Android :

- Android Studio doit s’ouvrir,
- vous devez pouvoir créer et lancer un émulateur (Pixel 5 / Android 13 par exemple).

---

## 2. Vue d’ensemble de l’architecture

En local, on va :

- faire tourner **Issuer** et **Verifier** dans des conteneurs Docker,  
- faire tourner **HAProxy** devant ces services pour gérer le HTTPS,  
- lancer le **Wallet Android** dans un émulateur, qui communiquera avec les backends via l’IP spéciale `10.0.2.2`.

🔍 `10.0.2.2` est l’alias standard dans l’émulateur Android qui pointe sur le **localhost de votre machine** (là où tourne Docker).

**Architecture logique du test :**

1. Le **Wallet** déclenche un flux d’**émission** et appelle l’**Issuer local** (`https://10.0.2.2:9443/...`) pour obtenir un PID.  
2. Le Wallet stocke ce PID (mDoc).  
3. Le **Verifier** lance une requête de présentation.  
4. Le Wallet, sur l’émulateur, appelle le verifier via `https://10.0.2.2:9444/...` et présente le PID.  

---

## 3. Lancer le Verifier local

On commence par le composant verifier (backend + UI + HAProxy).

### 3.1. Aller dans le dossier verifier

Depuis la racine du repo :

```bash
cd verifier/docker
```

*(Adaptez le chemin si besoin pour pointer sur le dossier contenant le `docker-compose.yml` du verifier.)*

### 3.2. `docker-compose.yml` du verifier

Le fichier `docker-compose.yml` ressemble à ceci :

```yaml
version: "3.8"

services:
  verifier-backend:
    image: ghcr.io/eu-digital-identity-wallet/eudi-srv-web-verifier-endpoint-23220-4-kt:latest
    container_name: verifier-backend
    environment:
      # URL vue par le Wallet (depuis l'émulateur Android)
      VERIFIER_PUBLICURL: "https://10.0.2.2:9444"
      # Mode de retour utilisé dans la requête d'autorisation (direct_post)
      VERIFIER_RESPONSE_MODE: "DirectPost"
    networks:
      - verifier_net

  verifier-ui:
    image: ghcr.io/eu-digital-identity-wallet/eudi-web-verifier:latest
    container_name: verifier-ui
    ports:
      - "4300:4300"
    environment:
      DOMAIN_NAME: ""
      # Comment l’UI atteint le backend (via HAProxy et la même URL que le Wallet)
      HOST_API: "https://10.0.2.2:9444"
    networks:
      - verifier_net

  verifier-haproxy:
    image: haproxy:2.8.3
    container_name: verifier-haproxy
    depends_on:
      - verifier-backend
      - verifier-ui
    ports:
      # HTTP (debug éventuel)
      - "9081:8080"
      # HTTPS exposé au Wallet (10.0.2.2:9444)
      - "9444:8443"
    volumes:
      # Configuration HAProxy
      - ./haproxy.conf:/usr/local/etc/haproxy/haproxy.cfg:ro
      # Certificat self-signed pour le HTTPS local
      - ./haproxy.pem:/etc/ssl/certs/mysite.pem:ro
    networks:
      - verifier_net

networks:
  verifier_net:
    driver: bridge
```

Points importants :

- `VERIFIER_PUBLICURL="https://10.0.2.2:9444"`  
  → URL utilisée par le Wallet **depuis l’émulateur**.  
- `HOST_API="https://10.0.2.2:9444"`  
  → l’UI parle au même endpoint que le Wallet (via HAProxy).  
- `9444:8443`  
  → 8443 = port HTTPS interne dans le conteneur HAProxy, exposé sur 9444 sur votre machine.  

### 3.3. Démarrer le verifier

Depuis `verifier/docker` :

```bash
docker compose up -d
docker compose ps
```

Vous devez voir les services `verifier-backend`, `verifier-ui`, `verifier-haproxy` en **Up**.

### 3.4. Test rapide depuis votre machine

Depuis votre machine (hors émulateur) :

```bash
curl -vk https://localhost:9444/
```

- Vous devez obtenir soit une page HTML (UI), soit une 404, mais **pas** une erreur de connexion.  

---

## 4. Lancer l’Issuer local

L’Issuer s’appuie sur **Keycloak** et un **HAProxy** dédié. Il est utilisé comme backend d’émission lorsque le Wallet demande un PID.

### 4.1. Aller dans le dossier issuer

Depuis la racine du repo :

```bash
cd issuer/docker
```

### 4.2. `docker-compose.yml` de l’issuer

Le fichier `docker-compose.yml` ressemble à ceci :

```yaml
version: "3.8"

services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.3.2-0
    container_name: keycloak
    command:
      - start-dev
      - --import-realm
    environment:
      # Keycloak derrière HAProxy (TLS terminé devant)
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME: "10.0.2.2"              # hostname externe vu par le wallet
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_HTTP_RELATIVE_PATH: "/idp"        # donc URL externe = https://10.0.2.2:9443/idp/...
      KC_PROXY_HEADERS: "xforwarded"       # fait confiance à X-Forwarded-*
      KC_PROXY: "edge"                     # Keycloak derrière un reverse proxy en mode edge

      # Admin (console)
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin

      # Bootstrap (utilisé au 1er démarrage, tu peux les laisser)
      KC_BOOTSTRAP_ADMIN_USERNAME: "admin"
      KC_BOOTSTRAP_ADMIN_PASSWORD: "password"
    ports:
      - "8081:8080"                        # UI d’admin Keycloak (http://localhost:8081/idp)
    healthcheck:
      test: ["CMD-SHELL", "bash /opt/keycloak/health-check.sh"]
      interval: 5s
      timeout: 10s
      retries: 12
      start_period: 30s
    volumes:
      - ./keycloak/extra/health-check.sh:/opt/keycloak/health-check.sh
      - ./keycloak/realms/:/opt/keycloak/data/import
    networks:
      - default

  pid-issuer:
    image: ghcr.io/eu-digital-identity-wallet/eudi-srv-pid-issuer:edge
    container_name: pid-issuer
    depends_on:
      keycloak:
        condition: service_healthy
    environment:
      SPRING_PROFILES_ACTIVE: "insecure"
      SERVER_PORT: 8080
      SERVER_FORWARD_HEADERS_STRATEGY: "FRAMEWORK"

      # URL publique vue par le wallet
      ISSUER_PUBLICURL: "https://10.0.2.2:9443"

      # URL publique de l’AS vue par le wallet
      ISSUER_AUTHORIZATIONSERVER_PUBLICURL: "https://10.0.2.2:9443/idp/realms/pid-issuer-realm"

      # Metadata OIDC côté issuer (interne vers Keycloak)
      ISSUER_AUTHORIZATIONSERVER_METADATA: "http://keycloak:8080/idp/realms/pid-issuer-realm/.well-known/openid-configuration"

      # URL d’introspection côté issuer (interne, via HAProxy)
      ISSUER_AUTHORIZATIONSERVER_INTROSPECTION: "https://haproxy:8443/idp/realms/pid-issuer-realm/protocol/openid-connect/token/introspect"

      # Ressource server en mode OPAQUE
      SPRING_SECURITY_OAUTH2_RESOURCESERVER_OPAQUETOKEN_CLIENT_ID: "pid-issuer-srv"
      SPRING_SECURITY_OAUTH2_RESOURCESERVER_OPAQUETOKEN_CLIENT_SECRET: "zIKAV9DIIIaJCzHCVBPlySgU8KgY68U2"

      ISSUER_CREDENTIALRESPONSEENCRYPTION_SUPPORTED: "true"
      ISSUER_CREDENTIALRESPONSEENCRYPTION_REQUIRED: "true"
      ISSUER_CREDENTIALRESPONSEENCRYPTION_ALGORITHMSSUPPORTED: "ECDH-ES"
      ISSUER_CREDENTIALRESPONSEENCRYPTION_ENCRYPTIONMETHODS: "A128GCM"

      ISSUER_PID_MSO_MDOC_ENABLED: "true"
      ISSUER_PID_MSO_MDOC_ENCODER_DURATION: "P30D"
      ISSUER_PID_MSO_MDOC_NOTIFICATIONS_ENABLED: "true"

      ISSUER_PID_SD_JWT_VC_ENABLED: "true"
      ISSUER_PID_SD_JWT_VC_NOTUSEBEFORE: "PT20S"
      ISSUER_PID_SD_JWT_VC_NOTIFICATIONS_ENABLED: "true"

      ISSUER_PID_ISSUINGCOUNTRY: "GR"
      ISSUER_PID_ISSUINGJURISDICTION: "GR-I"

      ISSUER_MDL_ENABLED: "true"
      ISSUER_MDL_MSO_MDOC_ENCODER_DURATION: "P5D"
      ISSUER_MDL_NOTIFICATIONS_ENABLED: "true"

      ISSUER_CREDENTIALOFFER_URI: "openid-credential-offer://"
      ISSUER_SIGNING_KEY: "GenerateRandom"

      ISSUER_KEYCLOAK_SERVER_URL: "http://keycloak:8080/idp"
      ISSUER_KEYCLOAK_AUTHENTICATION_REALM: "master"
      ISSUER_KEYCLOAK_CLIENT_ID: "admin-cli"
      ISSUER_KEYCLOAK_USERNAME: "admin"
      ISSUER_KEYCLOAK_PASSWORD: "password"
      ISSUER_KEYCLOAK_USER_REALM: "pid-issuer-realm"

      ISSUER_DPOP_PROOF_MAX_AGE: "PT1M"
      ISSUER_DPOP_CACHE_PURGE_INTERVAL: "PT10M"
      ISSUER_DPOP_REALM: "pid-issuer"
      ISSUER_DPOP_NONCE_ENABLED: "false"

      ISSUER_CREDENTIALENDPOINT_BATCHISSUANCE_ENABLED: "true"
      ISSUER_CREDENTIALENDPOINT_BATCHISSUANCE_BATCHSIZE: "10"
      ISSUER_CNONCE_EXPIRATION: "PT5M"

  haproxy:
    image: haproxy:2.8.3
    container_name: haproxy
    depends_on:
      keycloak:
        condition: service_healthy
      pid-issuer:
        condition: service_started
    ports:
      - "9080:8080"                        # HTTP (debug)
      - "9443:8443"                        # HTTPS → utilisé par l’émulateur (https://10.0.2.2:9443/...)
    volumes:
      - ./haproxy/haproxy.conf:/usr/local/etc/haproxy/haproxy.cfg
      - ./haproxy/certs/:/etc/ssl/certs/
    networks:
      - default

networks:
  default:
    driver: bridge
```

Points à retenir :

- Keycloak est exposé **en HTTP** en interne (`keycloak:8080`), TLS est géré par HAProxy en frontal.  
- Le Wallet voit l’issuer à l’URL : `https://10.0.2.2:9443`.  
- L’issuer parle à Keycloak :
  - en **interne** via `http://keycloak:8080/...` pour la configuration OIDC,  
  - en **interne** via `https://haproxy:8443/...` pour l’introspection, en passant par HAProxy.  

### 4.3. Démarrer l’issuer

```bash
docker compose up -d
docker compose ps
```

Vous devez voir les services `keycloak`, `pid-issuer`, `haproxy` en **Up**.

### 4.4. Test rapide

- Accéder à l’admin Keycloak : <http://localhost:8081/idp> (**admin / password**).  
- L’issuer sera atteint par le Wallet via : `https://10.0.2.2:9443`.  

### 4.5. Utilisateur de test pré-généré dans le realm

Le realm importé pour cet environnement contient un **utilisateur de test** déjà créé, avec des attributs réalistes permettant de tester l’émission d’un PID :

```json
{
  "realm": "pid-issuer-realm",
  "users": [
    {
      "id": "60b8ba5f-c73f-4976-b0da-48d0e53335de",
      "createdTimestamp": 1700060364127,
      "username": "tneal",
      "enabled": true,
      "email": "tyler.neal@example.com",
      "emailVerified": true,
      "firstName": "Tyler",
      "lastName": "Neal",
      "attributes": {
        "gender": ["1"],
        "gender_as_string": ["male"],
        "birthdate": ["1955-04-12"],
        "street": ["Trauner"],
        "address_house_number": ["101"],
        "locality": ["Gemeinde Biberbach"],
        "region": ["Lower Austria"],
        "postal_code": ["3331"],
        "country": ["AT"],
        "birth_country": ["AT"],
        "birth_city": ["Gemeinde Biberbach"],
        "birth_place": ["101 Trauner"],
        "nationality": ["AT"],
        "birth_family_name": ["Neal"],
        "birth_given_name": ["Tyler"]
      },
      "realmRoles": [
        "eid-holder-natural-person"
      ]
    },
    {
      "username": "service-account-pid-issuer-srv",
      "serviceAccountClientId": "pid-issuer-srv",
      "realmRoles": [
        "default-roles-pid-issuer-realm"
      ],
      "clientRoles": {
        "pid-issuer-srv": [
          "uma_protection"
        ]
      }
    }
  ]
}
```

En pratique :

- **username** : `tneal`  
- **rôle** : `eid-holder-natural-person` (titulaire « citoyen »)  
- **usage** : permet de tester un flux complet d’authentification / émission de PID sans créer d’utilisateur à la main.

Le mot de passe est déjà défini dans le JSON du realm (`keycloak/realms/...`).  
Si besoin, vous pouvez le réinitialiser via l’UI :

1. Ouvrir Keycloak (`http://localhost:8081/idp`),  
2. Aller dans le realm `pid-issuer-realm` → **Users**,  
3. Sélectionner `tneal` et définir un nouveau mot de passe pour vos tests.

---

## 5. Lancer le Wallet Android

### 5.1. Ouvrir le projet wallet

Dans Android Studio :

- `File → Open…`
- ouvrir le dossier :

```text
eudi-local-stack/wallet
```

Android Studio va :

- télécharger les dépendances,
- indexer le projet,
- proposer une configuration `app` à lancer.

### 5.2. Configuration OpenID4VP (déjà faite)

La configuration spécifique au verifier local est déjà câblée dans le code, dans la partie `configureOpenId4Vp` :

- un `PreregisteredVerifier` avec :
  - `clientId = "Verifier"`
  - `verifierApi = "https://10.0.2.2:9444"`
  - `legalName = "Local Demo Verifier"`
- les formats sont restreints pour éviter les erreurs liées à SD-JWT non configuré (ex. : uniquement `Format.MsoMdoc.ES256`).

👉 Pour le scénario standard, vous n’avez rien à modifier dans le code.

### 5.3. Lancer l’émulateur + l’app

- Créer un AVD si nécessaire (Pixel 5, Android 13 par ex.).  
- Sélectionner la configuration `app` et cliquer sur **Run ▶**.  
- L’app Wallet doit se lancer dans l’émulateur.

---

## 6. Scénario de test de bout en bout

Une fois toutes les briques démarrées :

### 6.1. Vérifier que l’Issuer est UP

- Vérifier que les conteneurs `keycloak`, `pid-issuer`, `haproxy` sont **Up** :  

```bash
docker compose ps
```

- Accéder à Keycloak : <http://localhost:8081/idp>.

### 6.2. Émettre un PID vers le Wallet (flux initié depuis le Wallet)

Dans ce setup, **c’est le Wallet qui initie l’émission de PID** vers l’issuer local :

1. Dans l’app Wallet (dans l’émulateur), aller dans le menu permettant d’**ajouter un nouveau credential / PID**.  
2. Choisir l’option correspondant à l’**issuer local** (configuré pour pointer vers `https://10.0.2.2:9443`).  
3. Le Wallet redirige vers Keycloak (authentification de l’utilisateur `tneal` dans le realm `pid-issuer-realm`).  
4. Une fois l’auth terminée, l’issuer renvoie un PID au Wallet.  
5. Vérifier dans le Wallet que le PID (mDoc) est bien stocké.

> 📌 Il n’y a pas de QR à scanner ni d’URL à copier/coller : toute l’initiation du flux se fait directement dans l’UI du Wallet, qui contacte l’issuer local.

### 6.3. Tester la présentation du PID vers le Verifier (depuis l’émulateur via deep link)

1. Dans le navigateur de l’émulateur Android, ouvrir l’UI du verifier, par exemple :  
   `https://10.0.2.2:4300`
2. Depuis cette UI, démarrer une nouvelle “verification request”.  
   L’UI génère alors un lien de présentation utilisant un schéma de type `openid4vp://` / `eudi-openid4vp://`.
3. Cliquer sur ce lien **dans l’émulateur** : le deep link ouvre automatiquement le Wallet.
4. Dans le Wallet, sélectionner le PID précédemment émis et valider l’envoi.

Le Wallet doit :

- appeler `https://10.0.2.2:9444/wallet/request.jwt/...`,  
- proposer le PID en présentation,  
- envoyer la réponse vers le verifier.  

Le verifier doit afficher le résultat de la vérification (succès).

---

## 7. Dépannage rapide (FAQ)

Quelques messages d’erreur typiques et leur cause :

### `fail to connect to /10.0.2.2:9444`

→ HAProxy/verifier ne tourne pas, ou le port 9444 n’est pas exposé.  
→ Vérifier :

```bash
docker compose ps
curl -vk https://localhost:9444
```

### `fail to connect to /10.0.2.2:9443`

→ HAProxy de l’issuer ne tourne pas, ou le port 9443 n’est pas exposé.  
→ Vérifier :

```bash
docker compose ps
curl -vk https://localhost:9443
```

### Erreur de certificat TLS dans l’émulateur

→ Certificat self-signed utilisé par les HAProxy.  
→ Pour la démo, le flux a été ajusté pour que le Wallet puisse fonctionner dans ce contexte de test.

### `Invalid resolution: UnsupportedClientIdPrefix` dans les logs Wallet

→ Schéma de `client_id` non reconnu (ancienne config).  
→ Dans ce repo, cela a été corrigé : le verifier "Verifier" est pré-enregistré dans le Wallet, vous ne devriez plus voir cette erreur.

### `{"error":"InvalidVpToken", "description": "... sd-jwt vc requires issuer-metadata ..."}` côté verifier

→ Le verifier reçoit un SD-JWT VC alors que la vérification via issuer-metadata n’est pas activée.  
→ Ici, le Wallet est configuré pour n’envoyer que du `mso_mdoc` pour ce scénario, ce qui contourne le problème pour la démo.

# EUDI Local Stack – Wallet / Issuer / Verifier

Ce dépôt permet de lancer en local un scénario de bout en bout :

> Issuer → Wallet (PID) → Verifier local (via émulateur Android + HTTPS)

Il regroupe :

- `wallet/`   → Wallet Android EUDI  
- `verifier/` → Verifier (backend + UI web)  
- `issuer/`   → Issuer PID  

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
- faire tourner **HAProxy** devant le verifier pour gérer le HTTPS,  
- lancer le **Wallet Android** dans un émulateur, qui communiquera avec le verifier via l’IP spéciale `10.0.2.2`.

🔍 `10.0.2.2` est l’alias standard dans l’émulateur Android qui pointe sur le **localhost de votre machine** (là où tourne Docker).

**Architecture logique du test :**

- L’Issuer émet un PID vers le Wallet.  
- Le Wallet stocke ce PID (mDoc).  
- Le Verifier lance une requête de présentation.  
- Le Wallet, sur l’émulateur, appelle le verifier via `https://10.0.2.2:9444/...` et présente le PID.  

---

## 3. Lancer le Verifier local

On commence par le composant le plus sensible : le verifier (backend + UI + proxy TLS).

### 3.1. Aller dans le dossier verifier

Depuis la racine du repo :

```bash
cd verifier/docker
```

*(Adaptez le chemin si besoin pour pointer sur le dossier contenant le `docker-compose.yml` du verifier.)*

### 3.2. Vérifier / adapter le `docker-compose.yml`

Le fichier `docker-compose.yml` doit ressembler à ceci :

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

L’Issuer est utilisé pour émettre un PID vers le Wallet.

### 4.1. Aller dans le dossier issuer

Depuis la racine du repo :

```bash
cd issuer/docker
```

### 4.2. Fichier `.env` / configuration

Un fichier `.env` (ou équivalent) doit être présent avec des valeurs déjà adaptées au contexte local (URLs, ports, certifs, etc.).

Si besoin, dupliquez un `.env.example` en `.env` :

```bash
cp .env.example .env
```

En principe, vous n’avez pas besoin de modifier les valeurs pour le scénario de base.

### 4.3. Démarrer l’issuer

```bash
docker compose up -d
docker compose ps
```

Vous devez voir les services issuer en Up (API, UI, proxy éventuel).

### 4.4. Test rapide

Ouvrir dans un navigateur l’UI issuer locale (URL indiquée dans le README du dossier issuer ou dans le `.env`) ; vous devez pouvoir déclencher un flux d’émission de PID.

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

- Accéder à son UI dans le navigateur.
- Vérifier que l’endpoint d’émission PID est disponible.

### 6.2. Émettre un PID vers le Wallet

- Suivre le flux prévu par l’issuer (QR code ou deep link).
- Scanner le QR ou ouvrir le lien depuis l’émulateur (selon le setup fourni).
- Vérifier que le Wallet reçoit et stocke un PID (mDoc).

### 6.3. Tester la présentation du PID vers le Verifier

- Ouvrir l’UI du verifier (port `4300` sur votre machine).
- Démarrer une nouvelle “verification request” via l’UI.
- Scanner le QR avec le Wallet dans l’émulateur.

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

### Erreur de certificat TLS dans l’émulateur

→ Certificat self-signed utilisé par HAProxy.  
→ Pour la démo, le flux a été ajusté pour que le Wallet puisse fonctionner dans ce contexte de test.

### `Invalid resolution: UnsupportedClientIdPrefix` dans les logs Wallet

→ Schéma de `client_id` non reconnu (ancienne config).  
→ Dans ce repo, cela a été corrigé : le verifier "Verifier" est pré-enregistré dans le Wallet, vous ne devriez plus voir cette erreur.

### `{"error":"InvalidVpToken", "description": "... sd-jwt vc requires issuer-metadata ..."}` côté verifier

→ Le verifier reçoit un SD-JWT VC alors que la vérification via issuer-metadata n’est pas activée.  
→ Ici, le Wallet est configuré pour n’envoyer que du mso_mdoc pour ce scénario, ce qui contourne le problème pour la démo.

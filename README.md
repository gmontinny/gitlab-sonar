# GitLab + SonarQube + Registry + Portainer (Docker-in-Docker)

Esteira CI/CD completa com versionamento, análise de qualidade, registry de imagens e deploy via Portainer.
A integração entre GitLab e SonarQube é feita automaticamente pelo container `setup`.

## Arquitetura

```
                                ┌──────────────┐
                           ┌───▶│  SonarQube   │
                           │    │  :9000       │
┌─────────────┐     ┌──────┴───────┐     ┌─────────────┐     ┌─────────────┐
│  GitLab CE   │────▶│ GitLab Runner │────▶│  Registry   │────▶│  Portainer  │
│  :8080       │     │  (DinD)       │     │  :5050      │     │  :9443      │
└──────┬───────┘     └──────────────┘     └─────────────┘     └─────────────┘
       │
       └──────── setup (automático)
                 • Cria PAT no GitLab (via rails runner)
                 • Configura ALM no SonarQube
                 • Gera SONAR_TOKEN (global)
                 • Registra variáveis CI/CD
```

### Fluxo da pipeline

```
git push → build → test → quality (SonarQube) → publish (Registry) → deploy (Portainer)
```

## Estrutura do Projeto

```
gitlab-sonar/
├── .env                        # Variáveis de ambiente (editável)
├── .gitlab-ci.yml              # Pipeline CI/CD (build → test → sonar → publish)
├── docker-compose.yml          # Todos os serviços
├── Dockerfile.runner           # Runner com Docker-in-Docker
├── Dockerfile.setup            # Container de setup (alpine + curl + docker-cli)
├── setup.sh                    # Script de integração automática
├── gitlab-runner/
│   └── config.toml             # Template de configuração do runner
└── README.md
```

## Serviços

| Serviço          | URL                          | Descrição                              |
|------------------|------------------------------|----------------------------------------|
| GitLab CE        | `http://localhost:8080`      | Repositório Git + CI/CD                |
| GitLab Registry  | `http://gitlab.local:5050`   | Registry de imagens Docker             |
| SonarQube        | `http://localhost:9000`      | Análise de qualidade de código         |
| Portainer        | `https://localhost:9443`     | UI para gerenciar e executar containers|

## Pré-requisitos

- Docker e Docker Compose v2+
- Mínimo 8GB RAM (GitLab consome bastante)
- No Linux, ajustar vm.max_map_count para o SonarQube:
  ```bash
  sudo sysctl -w vm.max_map_count=524288
  ```

### Configurar insecure registry

O GitLab Registry roda em HTTP (sem TLS) localmente. O Docker precisa confiar nele.

**Docker Desktop (Windows/Mac):**

Adicione ao arquivo `~/.docker/daemon.json` (ou via Settings > Docker Engine):

```json
{
  "insecure-registries": ["gitlab.local:5050"]
}
```

Reinicie o Docker Desktop após a alteração.

**Linux:**

Edite `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["gitlab.local:5050"]
}
```

```bash
sudo systemctl restart docker
```

## Subir o ambiente

```bash
docker compose up -d
```

> **Nota:** O GitLab pode levar de 5 a 10 minutos para inicializar completamente.
> O healthcheck está configurado com `start_period: 600s` e `20 retries` para acomodar esse tempo.
> O Runner sobe junto com o GitLab sem aguardar o healthcheck — registre-o somente após o GitLab estar acessível.

### O que acontece automaticamente

Quando o GitLab e o SonarQube estiverem saudáveis, o container `setup` executa:

1. Lê a senha root do GitLab (via volume compartilhado `gitlab-config`)
2. Cria um Personal Access Token no GitLab (via `docker exec` + `gitlab-rails runner`)
3. Altera a senha admin do SonarQube (conforme `.env`)
4. Configura a integração GitLab no SonarQube (ALM + API URL)
5. Cria um projeto inicial no SonarQube
6. Gera um `SONAR_TOKEN` **global** (funciona para qualquer projeto)
7. Registra variáveis CI/CD globais no GitLab (`SONAR_TOKEN`, `SONAR_HOST_URL`, `SONAR_ADMIN_PASSWORD`, `GITLAB_HOSTNAME`, `REGISTRY_PORT`)

> O container `setup` monta o Docker socket (`/var/run/docker.sock`) para executar
> comandos no container do GitLab via `docker exec`. Isso é necessário porque a API
> REST do GitLab não permite criar PATs com OAuth tokens de forma confiável.

### Verificar status dos containers

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Aguarde até o container `gitlab` mostrar `(healthy)` antes de prosseguir.

### Acompanhar o setup automático

```bash
docker logs -f setup
```

Saída esperada:

```
[setup] ✔ GitLab pronto
[setup] ✔ Senha root obtida
[setup] ✔ PAT criado
[setup] ✔ SonarQube pronto
[setup] ✔ Senha alterada
[setup] ✔ ALM configurado
[setup] ✔ Projeto 'meu-projeto' criado
[setup] ✔ SONAR_TOKEN gerado
[setup] ✔ Variáveis CI/CD registradas
[setup] ✅ Setup concluído!
```

Quando finalizar, as credenciais ficam salvas no volume `setup-output`:

```bash
docker run --rm -v gitlab-sonar_setup-output:/data alpine cat /data/setup-result.env
```

### Erro 502 ao acessar o GitLab?

É normal durante a inicialização. O Puma (servidor Rails) é o último serviço a subir e pode levar de 5 a 10 minutos. Enquanto ele não estiver pronto, o Workhorse retorna 502.

Para verificar se o Puma já subiu:

```bash
docker exec gitlab gitlab-ctl status puma
```

Se aparecer `run: puma: (pid XXXX) Xs`, aguarde mais ~1-2 minutos para ele carregar a aplicação e tente novamente.

## Configuração manual restante

### 1. Acessar o GitLab

- URL: `http://localhost:8080`
- Usuário: `root`
- Senha:
  ```bash
  docker exec gitlab cat /etc/gitlab/initial_root_password | grep "Password:"
  ```

### 2. Registrar o Runner

Acesse `http://localhost:8080/admin/runners`, crie um novo runner e copie o token. Depois:

```bash
docker exec gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "http://gitlab:8080" \
  --token "<SEU_RUNNER_TOKEN>" \
  --executor "docker" \
  --docker-image "docker:24-dind" \
  --docker-privileged \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --docker-network-mode "gitlab-sonar_cicd-net" \
  --description "docker-runner"
```

> **Nota:** A partir do GitLab Runner 18.x, tags e outras configurações (locked, access-level, run-untagged, etc.) são gerenciadas diretamente na UI do GitLab ao criar o runner, não mais via CLI.

### 3. Configurar o Portainer

1. Acesse `https://localhost:9443`
2. Crie a senha de admin no primeiro acesso
3. Selecione o ambiente **local** (Docker)
4. Para conectar ao GitLab Registry:
   - Vá em **Settings > Registries > Add registry > Custom**
   - **Registry URL:** `gitlab.local:5050`
   - **Authentication:** marque e use `root` + sua senha do GitLab

### 4. Usar a pipeline

O `.gitlab-ci.yml` é **agnóstico de linguagem** — usa o `Dockerfile` da aplicação para build/test, o `sonar-scanner` para qualidade e publica a imagem no GitLab Registry.

| Stage     | Descrição                                    |
|-----------|----------------------------------------------|
| `build`   | Build da imagem Docker via `Dockerfile`      |
| `test`    | Executa `TEST_CMD` dentro do container       |
| `quality` | Análise SonarQube + Quality Gate             |
| `publish` | Push da imagem para o GitLab Registry        |

**Não é necessário criar token ou projeto no SonarQube para cada repositório.**
O `SONAR_TOKEN` é global e o pipeline cria o projeto no SonarQube automaticamente na primeira execução.

Para customizar os testes, defina a variável `TEST_CMD` no GitLab (Settings > CI/CD > Variables):

| Linguagem | `TEST_CMD`              |
|-----------|-------------------------|
| Java      | `mvn verify`            |
| Node.js   | `npm test`              |
| Python    | `pytest`                |
| PHP       | `vendor/bin/phpunit`    |
| Go        | `go test ./...`         |

#### Detecção automática (Java)

Para projetos Java, o pipeline detecta automaticamente:
- Se o `Dockerfile` tem um stage `build`, extrai os binários compilados (`target/classes` ou `build/classes`)
- O `sonar-scanner` recebe os binários via `sonar.java.binaries`, evitando o erro de "compiled classes not found"
- Funciona tanto com Maven (`target/`) quanto Gradle (`build/`)

Para outras linguagens (Python, Node.js, PHP, Go), o scanner analisa o código-fonte diretamente sem necessidade de binários.

### 5. Versionar um projeto

Copie o `.gitlab-ci.yml` para a raiz do seu projeto, crie o repositório no GitLab e faça o push:

```bash
# Copiar o pipeline para o projeto
cp /caminho/para/gitlab-sonar/.gitlab-ci.yml /caminho/para/seu-projeto/

# Versionar
cd /caminho/para/seu-projeto
git init
git remote add origin http://gitlab.local:8080/root/seu-projeto.git
git add .
git commit -m "primeiro commit"
git push -u origin main
```

A pipeline dispara automaticamente a cada push. Acompanhe em:
`http://localhost:8080/root/seu-projeto/-/pipelines`

> **Requisitos:** Runner registrado e `gitlab.local` configurado no arquivo `hosts`.

### 6. Executar imagem via Portainer

Após o pipeline publicar a imagem no Registry, execute-a pelo Portainer:

**Opção A — Container avulso:**

1. Acesse `https://localhost:9443`
2. Vá em **Containers > Add container**
3. Preencha **Name** e **Image**:
   ```
   gitlab.local:5050/grupo/projeto:latest
   ```
4. Abaixo do formulário principal, há abas: **Command & logging**, **Volumes**, **Network**, **Env**, **Labels**, etc.
5. Na aba **Network**, configure o mapeamento de portas (ex: `8081 → 8080`)
6. Na aba **Env**, clique em **Add an environment variable** para cada variável:
   | Name | Value |
   |------|-------|
   | `SPRING_DATASOURCE_URL` | `jdbc:postgresql://db:5432/seplag_album` |
   | `SPRING_DATASOURCE_USERNAME` | `user` |
   | `SPRING_DATASOURCE_PASSWORD` | `password` |
7. Em **Registry**, selecione o registry do GitLab cadastrado
8. Clique em **Deploy the container**

**Opção B — Stack via Web editor (recomendado):**

Use **Stacks > Add stack > Web editor** e cole um docker-compose:

```yaml
services:
  seplag-album:
    image: gitlab.local:5050/seplag/seplag_album:latest
    ports:
      - "8081:8080"
    environment:
      SPRING_DATASOURCE_URL: jdbc:postgresql://db:5432/seplag_album
      SPRING_DATASOURCE_USERNAME: user
      SPRING_DATASOURCE_PASSWORD: password
    networks:
      - gitlab-sonar_cicd-net

networks:
  gitlab-sonar_cicd-net:
    external: true
```

**Opção C — Stack via Git repository:**

Use **Stacks > Add stack > Repository** para puxar o compose direto do GitLab:

| Campo                    | Valor                                                      |
|--------------------------|------------------------------------------------------------|
| **Repository URL**       | `http://gitlab.local:8080/seplag/seplag_album.git`         |
| **Repository reference** | `refs/heads/main`                                          |
| **Compose path**         | `docker-compose.yml`                                       |
| **Authentication**       | Marque e use `root` + senha do GitLab                      |

> Habilite **GitOps updates** para o Portainer re-deployar automaticamente quando o compose mudar no repositório.

#### Conflitos comuns ao deployar stacks

- **Container name already in use** — Remova o container antigo (`docker rm -f nome_container`) ou renomeie o `container_name` no compose
- **Port already allocated** — A porta `9000` já é usada pelo SonarQube. Se a aplicação usa MinIO ou outro serviço na `9000`, mapeie para outra porta (ex: `9002:9000`)

#### Exemplo: deploy do seplag-album

```
Image:    gitlab.local:5050/seplag/seplag_album:latest
Port:     8081 → 8080
Network:  gitlab-sonar_cicd-net (se precisar acessar o banco na mesma rede)
```

#### Alternativa via CLI

```bash
docker run -d \
  --name seplag-album \
  -p 8081:8080 \
  --network gitlab-sonar_cicd-net \
  gitlab.local:5050/seplag/seplag_album:latest
```

## Variáveis de Ambiente (.env)

| Variável                   | Descrição                          | Padrão                                       |
|----------------------------|------------------------------------|----------------------------------------------|
| `GITLAB_HOSTNAME`          | Hostname do GitLab                 | `gitlab.local`                               |
| `GITLAB_HTTP_PORT`         | Porta HTTP do GitLab               | `8080`                                       |
| `GITLAB_SSH_PORT`          | Porta SSH do GitLab                | `2222`                                       |
| `REGISTRY_PORT`            | Porta do Container Registry        | `5050`                                       |
| `SONAR_JDBC_URL`           | URL JDBC do PostgreSQL (Sonar)     | `jdbc:postgresql://sonar-db:5432/sonarqube`  |
| `SONAR_JDBC_USERNAME`      | Usuário do banco do SonarQube      | `sonar`                                      |
| `SONAR_JDBC_PASSWORD`      | Senha do banco do SonarQube        | `sonar_pass`                                 |
| `SONAR_ADMIN_PASSWORD`     | Senha atual do admin SonarQube     | `admin`                                      |
| `SONAR_NEW_ADMIN_PASSWORD` | Nova senha do admin SonarQube      | `S0nar@2024`                                 |
| `GITLAB_PAT_NAME`          | Nome do PAT criado no GitLab       | `sonarqube-integration`                      |
| `SONAR_PROJECT_KEY`        | Chave do projeto inicial           | `meu-projeto`                                |
| `SONAR_PROJECT_NAME`       | Nome do projeto inicial            | `Meu Projeto`                                |
| `PORTAINER_PORT`           | Porta HTTPS do Portainer           | `9443`                                       |

## Variáveis CI/CD (configuradas automaticamente)

O container `setup` registra estas variáveis globais no GitLab:

| Variável               | Descrição                                                 |
|------------------------|-----------------------------------------------------------|
| `SONAR_TOKEN`          | Token global de análise (funciona para todos os projetos) |
| `SONAR_HOST_URL`       | URL interna do SonarQube (`http://sonarqube:9000`)        |
| `SONAR_ADMIN_PASSWORD` | Senha admin do SonarQube (para auto-criação de projetos)  |
| `GITLAB_HOSTNAME`      | Hostname do GitLab (`gitlab.local`)                       |
| `REGISTRY_PORT`        | Porta do Registry (`5050`)                                |

## Detalhes técnicos

- O GitLab usa `external_url` com porta (`http://gitlab.local:8080`) + `puma['port'] = 0` para evitar conflito de porta entre Puma e Nginx
- O GitLab Registry roda em HTTP via `registry_nginx['listen_https'] = false` — requer configuração de `insecure-registries` no Docker do host
- O healthcheck do SonarQube usa `wget` (não `curl`) pois a imagem `sonarqube:lts-community` não inclui `curl`
- O container `setup` usa `docker-cli` para executar `gitlab-rails runner` no container do GitLab, criando o PAT de forma confiável
- O `SONAR_TOKEN` é do tipo `GLOBAL_ANALYSIS_TOKEN`, permitindo análise de qualquer projeto sem criar tokens individuais
- O pipeline cria o projeto no SonarQube automaticamente via API na primeira execução de cada repositório
- O stage `publish` roda apenas na branch `main` e publica a imagem com tags `latest` e `commit SHA`
- O Portainer acessa o Docker socket do host para gerenciar todos os containers

## Hosts (Windows)

Adicione ao `C:\Windows\System32\drivers\etc\hosts`:

```
127.0.0.1 gitlab.local
```

Ou via PowerShell (como Administrador):

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1 gitlab.local"
```

## Parar o ambiente

```bash
docker compose down        # mantém dados
docker compose down -v     # remove tudo
```

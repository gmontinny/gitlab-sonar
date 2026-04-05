# GitLab + SonarQube + Runner (Docker-in-Docker)

Esteira CI/CD com versionamento e análise de qualidade de código.
A integração entre GitLab e SonarQube é feita automaticamente pelo container `setup`.

## Arquitetura

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  GitLab CE   │────▶│ GitLab Runner │────▶│  SonarQube  │
│  :8080       │     │  (DinD)       │     │  :9000      │
└─────────────┘     └──────────────┘     └──────┬──────┘
        │                                        │
        └──────── setup (automático) ────────────┘
                  • Cria PAT no GitLab (via rails runner)
                  • Configura ALM no SonarQube
                  • Gera SONAR_TOKEN (global)
                  • Registra variáveis CI/CD
```

## Estrutura do Projeto

```
gitlab-sonar/
├── .env                        # Variáveis de ambiente (editável)
├── .gitlab-ci.yml              # Pipeline CI/CD (build → test → sonar)
├── docker-compose.yml          # Todos os serviços
├── Dockerfile.runner           # Runner com Docker-in-Docker
├── Dockerfile.setup            # Container de setup (alpine + curl + docker-cli)
├── setup.sh                    # Script de integração automática
├── gitlab-runner/
│   └── config.toml             # Template de configuração do runner
└── README.md
```

## Pré-requisitos

- Docker e Docker Compose v2+
- Mínimo 8GB RAM (GitLab consome bastante)
- No Linux, ajustar vm.max_map_count para o SonarQube:
  ```bash
  sudo sysctl -w vm.max_map_count=524288
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
7. Registra `SONAR_TOKEN`, `SONAR_HOST_URL` e `SONAR_ADMIN_PASSWORD` como variáveis CI/CD globais no GitLab

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

### 3. Usar a pipeline

O `.gitlab-ci.yml` é **agnóstico de linguagem** — usa o `Dockerfile` da aplicação para build/test e o `sonar-scanner` para análise de qualidade. Funciona com Java, Python, Node.js, PHP, Go, etc.

| Stage     | Descrição                                    |
|-----------|----------------------------------------------|
| `build`   | Build da imagem Docker via `Dockerfile`      |
| `test`    | Executa `TEST_CMD` dentro do container       |
| `quality` | Análise SonarQube + Quality Gate             |

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

### 4. Versionar um projeto

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

## Variáveis de Ambiente (.env)

| Variável                   | Descrição                          | Padrão                                       |
|----------------------------|------------------------------------|----------------------------------------------|
| `GITLAB_HOSTNAME`          | Hostname do GitLab                 | `gitlab.local`                               |
| `GITLAB_HTTP_PORT`         | Porta HTTP do GitLab               | `8080`                                       |
| `GITLAB_SSH_PORT`          | Porta SSH do GitLab                | `2222`                                       |
| `SONAR_JDBC_URL`           | URL JDBC do PostgreSQL (Sonar)     | `jdbc:postgresql://sonar-db:5432/sonarqube`  |
| `SONAR_JDBC_USERNAME`      | Usuário do banco do SonarQube      | `sonar`                                      |
| `SONAR_JDBC_PASSWORD`      | Senha do banco do SonarQube        | `sonar_pass`                                 |
| `SONAR_ADMIN_PASSWORD`     | Senha atual do admin SonarQube     | `admin`                                      |
| `SONAR_NEW_ADMIN_PASSWORD` | Nova senha do admin SonarQube      | `S0nar@2024`                                 |
| `GITLAB_PAT_NAME`          | Nome do PAT criado no GitLab       | `sonarqube-integration`                      |
| `SONAR_PROJECT_KEY`        | Chave do projeto inicial           | `meu-projeto`                                |
| `SONAR_PROJECT_NAME`       | Nome do projeto inicial            | `Meu Projeto`                                |

## Variáveis CI/CD (configuradas automaticamente)

O container `setup` registra estas variáveis globais no GitLab:

| Variável               | Descrição                                      |
|------------------------|-------------------------------------------------|
| `SONAR_TOKEN`          | Token global de análise (funciona para todos os projetos) |
| `SONAR_HOST_URL`       | URL interna do SonarQube (`http://sonarqube:9000`)        |
| `SONAR_ADMIN_PASSWORD` | Senha admin do SonarQube (para auto-criação de projetos)  |

## Detalhes técnicos

- O GitLab usa `external_url` com porta (`http://gitlab.local:8080`) + `puma['port'] = 0` para evitar conflito de porta entre Puma e Nginx
- O healthcheck do SonarQube usa `wget` (não `curl`) pois a imagem `sonarqube:lts-community` não inclui `curl`
- O container `setup` usa `docker-cli` para executar `gitlab-rails runner` no container do GitLab, criando o PAT de forma confiável
- O `SONAR_TOKEN` é do tipo `GLOBAL_ANALYSIS_TOKEN`, permitindo análise de qualquer projeto sem criar tokens individuais
- O pipeline cria o projeto no SonarQube automaticamente via API na primeira execução de cada repositório

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

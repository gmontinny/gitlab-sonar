### Título
**Arquitetura DevOps Local com GitLab, SonarQube, Registry e Portainer: uma Abordagem Reprodutível com Docker Compose e Automação de Bootstrap**

### Resumo
- Este trabalho apresenta uma arquitetura DevOps autocontida para ambientes de desenvolvimento e laboratório, integrando `GitLab CE`, `GitLab Runner` (com execução via Docker), `SonarQube`, `PostgreSQL`, `GitLab Container Registry` e `Portainer`.
- O diferencial do projeto está no `bootstrap` automatizado da integração entre GitLab e SonarQube, reduzindo atividades manuais e aumentando reprodutibilidade operacional.
- A solução foi concebida sobre princípios de `Infrastructure as Code (IaC)` com `Docker Compose`, privilegiando versionamento da infraestrutura, previsibilidade de execução, isolamento por serviços e persistência por volumes.

### 1. Introdução
A maturidade DevOps depende de três pilares complementares: **automação**, **observabilidade da qualidade** e **padronização ambiental**. Em cenários de equipes pequenas, laboratórios acadêmicos e células de inovação, é comum encontrar esteiras fragmentadas — código em um sistema, qualidade em outro, entrega sem rastreabilidade e operação sem governança unificada.

O projeto `gitlab-sonar` responde a esse desafio propondo uma plataforma integrada, local e reprodutível, na qual o fluxo de entrega contínua ocorre de forma coordenada desde o `commit` até a disponibilização de imagens para implantação. Além disso, o projeto adota práticas de IaC para que o ambiente seja **declarativo**, **versionável** e **replicável**.

### 2. Problema e Motivação
Em pipelines tradicionais não padronizados, observam-se gargalos recorrentes:
- setup manual de ferramentas e integrações;
- baixa confiabilidade entre ambientes ("na minha máquina funciona");
- ausência de gate de qualidade formal;
- publicação de artefatos sem rastreabilidade;
- acoplamento entre conhecimento tácito do time e operação da esteira.

A proposta desta arquitetura é mitigar esses pontos por meio de:
- orquestração declarativa de serviços (`docker-compose.yml`);
- pipeline CI/CD em estágios (`.gitlab-ci.yml`);
- análise contínua de qualidade com SonarQube;
- registry privado para versionamento de imagens;
- camada operacional visual com Portainer;
- automação de integração inicial via container `setup`.

### 3. Metodologia e Base IaC
A infraestrutura foi modelada por código e organizada em artefatos centrais:
- `docker-compose.yml`: definição declarativa de serviços, rede, volumes, dependências e healthchecks;
- `.env`: parametrização externa de portas, credenciais e chaves de integração;
- `.gitlab-ci.yml`: especificação da pipeline CI/CD;
- `Dockerfile.runner` e `Dockerfile.setup`: customização do Runner e do processo de bootstrap;
- `setup.sh`: automação da integração entre plataformas.

Sob o ponto de vista IaC, a abordagem adota:
- **reprodutibilidade**: ambiente sobe com o mesmo conjunto de serviços e configurações;
- **imutabilidade operacional parcial**: serviços definidos por imagem e configuração declarativa;
- **rastreabilidade**: mudanças na infraestrutura ficam registradas no versionamento do repositório;
- **idempotência prática de provisionamento**: processo orientado para reexecução com mínimo retrabalho manual.

### 4. Arquitetura da Solução
#### 4.1 Componentes e responsabilidades
- `GitLab CE` (`:8080`): gestão de repositório, CI/CD e governança de projeto.
- `GitLab Runner`: executor de jobs de pipeline com acesso ao engine Docker.
- `SonarQube` (`:9000`): inspeção estática e qualidade contínua.
- `sonar-db` (PostgreSQL 15): persistência do SonarQube.
- `Registry` (`:5050`): armazenamento e distribuição de imagens Docker versionadas.
- `Portainer` (`:9443`): operação e observabilidade de containers/serviços.
- `setup`: automação da integração GitLab ↔ SonarQube, incluindo geração/configuração de tokens e parâmetros.

#### 4.2 Topologia e isolamento
Todos os serviços compartilham a rede `cicd-net` (bridge), garantindo comunicação interna previsível e desacoplamento de rede externa. O estado persistente é segregado em volumes dedicados (`gitlab-data`, `sonar-data`, `portainer-data`, etc.), preservando dados críticos em reinicializações/redeploys.

#### 4.3 Estratégia de inicialização confiável
A arquitetura implementa readiness/healthchecks para reduzir condições de corrida:
- GitLab possui `start_period` elevado (`600s`), aderente ao tempo de boot típico;
- SonarQube valida estado via `api/system/status`;
- PostgreSQL valida disponibilidade com `pg_isready`.

O serviço `setup` só executa quando GitLab e SonarQube estão saudáveis (`depends_on` com condição de health), reforçando robustez da integração automática.

### 5. Pipeline CI/CD: desenho e racional técnico
A pipeline em `.gitlab-ci.yml` é estruturada em quatro estágios:

1. `build`
- constrói imagem da aplicação (`--target build` com fallback para build padrão);
- extrai artefatos compilados quando disponíveis (`/app/target` ou `/app/build`), habilitando consumo posterior por análise de qualidade.

2. `test`
- executa testes dentro do container de build;
- usa `TEST_CMD` parametrizável, tornando a esteira adaptável a múltiplos stacks sem reescrita da pipeline.

3. `quality` (`sonarqube`)
- provisiona/verifica projeto no SonarQube via API;
- calcula argumentos de scanner dinamicamente (`projectKey`, `projectName`, `sources`, `tests`, `java.binaries`);
- habilita `quality gate wait`, permitindo análise síncrona de resultado de qualidade.

4. `publish`
- autentica no registry (`CI_REGISTRY`/fallback);
- gera e publica imagens com duas estratégias de tag: `CI_COMMIT_SHORT_SHA` (imutável por revisão) e `latest` (canal corrente);
- restringe publicação à branch `main`, alinhando governança de release.

Esse desenho equilibra **portabilidade**, **rastreabilidade** e **simplicidade operacional**.

### 6. Integração GitLab–SonarQube: ganho operacional
O ponto de maior valor arquitetural é o container `setup`, que automatiza tarefas que normalmente são manuais e propensas a erro:
- leitura de credencial inicial do GitLab (via volume compartilhado `gitlab-config`);
- criação de Personal Access Token no GitLab (via `docker exec` + `gitlab-rails runner`, necessário porque a API REST com OAuth não suporta criação de PATs de forma confiável);
- atualização de senha administrativa do SonarQube;
- configuração ALM (Application Lifecycle Management) no SonarQube com URL/API do GitLab;
- geração de `GLOBAL_ANALYSIS_TOKEN` no SonarQube, eliminando a necessidade de criar tokens por projeto;
- registro automático de variáveis CI/CD globais no GitLab (`SONAR_TOKEN`, `SONAR_HOST_URL`, `SONAR_ADMIN_PASSWORD`, `GITLAB_HOSTNAME`, `REGISTRY_PORT`).

O uso de token global é uma decisão arquitetural relevante: permite que qualquer novo repositório execute análise de qualidade sem configuração adicional. O pipeline cria o projeto no SonarQube automaticamente via API na primeira execução.

Em termos DevOps, isso reduz `lead time` de provisionamento, aumenta repetibilidade e elimina dependência de runbook informal para setup inicial.

### 7. Qualidade, Segurança e Confiabilidade
#### 7.1 Qualidade contínua
- O SonarQube introduz governança de código baseada em métricas e regras.
- O pipeline já contempla inspeção contínua; em evolução, recomenda-se tornar reprovação de quality gate bloqueante em cenários produtivos.

#### 7.2 Segurança
- O uso de registry HTTP (`insecure registry`) é aceitável para laboratório/local, mas não recomendado para produção.
- Recomendações para endurecimento:
  - TLS ponta a ponta (GitLab/Registry);
  - rotação e gestão de segredos (evitar defaults em `.env`);
  - menor privilégio para tokens e credenciais;
  - scanning de imagem (SAST/Container Scan) como estágio adicional.

#### 7.3 Confiabilidade
- Healthchecks e dependências condicionais reduzem falhas por inicialização prematura.
- Volumes dedicados protegem continuidade de dados de ferramentas críticas.
- Padronização via Compose reduz desvio de configuração entre ambientes.

### 8. Discussão Técnica (DevOps + IaC)
Do ponto de vista de engenharia de plataforma, o projeto demonstra um padrão sólido de **plataforma de entrega local** com forte orientação a automação. A decomposição em serviços independentes favorece evolução incremental (por exemplo, substituir executor, introduzir observabilidade, migrar para TLS completo).

#### 8.1 Desafios técnicos resolvidos
Durante a implementação, foram identificados e resolvidos desafios técnicos relevantes:

- **Conflito de porta Puma/Nginx**: quando `external_url` inclui porta, o GitLab tenta fazer bind do Puma na mesma porta do Nginx. A solução foi `puma['port'] = 0`, forçando comunicação exclusiva via socket Unix.
- **Healthcheck do SonarQube**: a imagem `sonarqube:lts-community` não inclui `curl`, exigindo uso de `wget` no healthcheck.
- **Criação de PAT via API**: a API REST do GitLab com OAuth token não aceita criação de PATs com scopes válidos. A solução foi montar o Docker socket no container `setup` e executar `gitlab-rails runner` diretamente no container do GitLab.
- **Runner 18.x**: a partir desta versão, parâmetros como `--tag-list`, `--locked` e `--access-level` não são mais aceitos via CLI no registro com authentication token — são gerenciados exclusivamente pela UI.
- **Pipeline agnóstico com suporte a Java**: projetos Java requerem `sonar.java.binaries` para análise. O pipeline extrai automaticamente os binários compilados do stage `build` do Dockerfile (`target/classes` ou `build/classes`), sem necessidade de configuração manual.

#### 8.2 Maturidade IaC
Em IaC, a solução é aderente a práticas fundamentais (declaratividade, versionamento e replicação), embora ainda exista espaço para maturidade enterprise, como:
- externalização segura de segredos (`Vault`, `SOPS`, variáveis protegidas);
- policy-as-code para compliance de pipeline;
- promoção entre ambientes (dev/hml/prd) com templates e parametrização por contexto;
- gates de segurança adicionais antes de `publish`.

### 9. Limitações e Oportunidades de Evolução
Limitações atuais (esperadas para contexto local/lab):
- ausência de TLS obrigatório no registry;
- `allow_failure: true` no estágio Sonar, que reduz enforcement de qualidade;
- credenciais iniciais com foco em conveniência de bootstrap;
- Runner requer registro manual (criação do token na UI do GitLab).

Evoluções recomendadas:
- tornar quality gate bloqueante para `main`;
- adicionar SBOM e assinatura de imagem;
- integrar scanners de vulnerabilidade e dependências;
- aplicar segregação de ambientes e políticas de promoção de release;
- formalizar observabilidade (métricas/logs/tracing) para SLOs da plataforma CI/CD;
- deploy automatizado via Portainer GitOps (stack vinculada a repositório com auto-update);
- integração com Portainer API para deploy programático pós-publish.

### 10. Conclusão
A arquitetura apresentada entrega uma base DevOps robusta para ambientes locais e de experimentação, unificando ciclo de vida de software em uma esteira reprodutível e orientada por qualidade. O uso de IaC com Docker Compose, combinado à automação de integração GitLab–SonarQube, evidencia maturidade no desenho operacional e reduz significativamente custo de setup.

O pipeline agnóstico de linguagem, com detecção automática de binários Java e criação automática de projetos no SonarQube, demonstra que é possível manter uma esteira genérica sem sacrificar funcionalidade específica. A adição do GitLab Registry e Portainer completa o ciclo de entrega, permitindo que imagens sejam publicadas, versionadas e executadas a partir de uma única plataforma.

Como contribuição prática, o projeto oferece um caminho realista para equipes que precisam acelerar adoção DevOps sem abrir mão de princípios arquiteturais. Como agenda futura, o fortalecimento de segurança, compliance e gates de qualidade pode elevar a solução de um laboratório avançado para um padrão próximo de produção.

### Referências
- Projeto e documentação base: `README.md` do repositório `gitlab-sonar`.
- Orquestração de infraestrutura: `docker-compose.yml`.
- Pipeline de integração e entrega: `.gitlab-ci.yml`.
- Parametrização de ambiente: `.env`.
- Docker Docs: `https://docs.docker.com/`
- GitLab CI/CD Docs: `https://docs.gitlab.com/ee/ci/`
- SonarQube Docs: `https://docs.sonarsource.com/sonarqube/`
- Portainer Docs: `https://docs.portainer.io/`
- PostgreSQL Docs: `https://www.postgresql.org/docs/`
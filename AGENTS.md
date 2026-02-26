# AGENTS.md — Protocolo de Engenharia de Agentes do nullclaw

Este arquivo define o protocolo de trabalho padrão para agentes de codificação neste repositório.
Escopo: repositório completo.

## 1) Instantâneo do Projeto (Leia Primeiro)

nullclaw é um ambiente de execução de assistente de IA autônomo focado em Zig, otimizado para:

- tamanho de binário mínimo (meta: < 1 MB ReleaseSmall)
- pegada de memória mínima (meta: < 5 MB de RSS de pico)
- zero dependências além da libc e SQLite opcional
- paridade total de recursos com o ZeroClaw (implementação de referência em Rust)

A arquitetura central é **baseada em vtable** e modular. Todo o trabalho de extensão é feito implementando structs de vtable e registrando-as em funções de fábrica.

Principais pontos de extensão:

- `src/providers/root.zig` (`Provider`) — provedores de modelos de IA
- `src/channels/root.zig` (`Channel`) — canais de mensagens
- `src/tools/root.zig` (`Tool`) — superfície de execução de ferramentas
- `src/memory/root.zig` (`Memory`) — backends de memória
- `src/observability.zig` (`Observer`) — ganchos de observabilidade
- `src/runtime.zig` (`RuntimeAdapter`) — ambientes de execução
- `src/peripherals.zig` (`Peripheral`) — placas de hardware (Arduino, STM32, RPi)

Escala atual: **151 arquivos-fonte, ~96 mil linhas de código, 3.371 testes**.

Compilação e teste:

```bash
zig build                           # compilação de desenvolvimento
zig build -Doptimize=ReleaseSmall  # compilação de lançamento
zig build test --summary all        # executar todos os testes
```

## 2) Observações Profundas de Arquitetura (Por Que Este Protocolo Existe)

Estas realidades da base de código devem guiar cada decisão de design:

1. **A arquitetura Vtable + fábrica é a espinha dorsal da estabilidade**
   - Os pontos de extensão são explícitos e permutáveis via `ptr: *anyopaque` + `vtable: *const VTable`.
   - Os chamadores devem POSSUIR a struct de implementação (variável local ou alocação em heap). Nunca retorne uma interface vtable apontando para um temporário — o ponteiro ficará pendente (dangling).
   - A maioria dos recursos deve ser adicionada via implementação vtable + registro na fábrica, não por reescritas transversais.

2. **O tamanho do binário e a memória são restrições rígidas do produto**
   - `zig build -Doptimize=ReleaseSmall` é o alvo de lançamento. Cada dependência e abstração tem um custo de tamanho.
   - Evite adicionar chamadas libc, alocações em tempo de execução ou tabelas de dados grandes sem justificativa.
   - O `MaxRSS` durante o `zig build test` deve permanecer bem abaixo de 50 MB.

3. **Superfícies críticas de segurança são de primeira classe**
   - `src/gateway.zig`, `src/security/`, `src/tools/`, `src/runtime.zig` carregam um alto raio de explosão (impacto).
   - Os padrões são seguros por design (pareamento, apenas HTTPS, listas de permissão, criptografia AEAD). Mantenha dessa forma.

4. **A API do Zig 0.15.2 é a linha de base — sem recursos mais recentes**
   - Cliente HTTP: `std.http.Client.fetch()` com `std.Io.Writer.Allocating` para captura do corpo da resposta.
   - Processos filhos: `std.process.Child.init(argv, allocator)`, `.Pipe` (capitalizado).
   - stdout: `std.fs.File.stdout().writer(&buf)` → use `.interface` para `print`/`flush`.
   - `std.io.getStdOut()` NÃO existe no 0.15 — use `std.fs.File.stdout()`.
   - SQLite: vinculado via `/opt/homebrew/opt/sqlite/{lib,include}` na etapa de compilação, não no módulo.
   - `ArrayListUnmanaged`: inicialize com `.empty`, passe o alocador para cada método.

5. **Todos os mais de 3.371 testes devem passar com zero vazamentos (leaks)**
   - A suíte de testes usa o `std.testing.allocator` (GPA detector de vazamentos). Toda alocação deve ser liberada.
   - `Config.load()` aloca — sempre envolva em `std.heap.ArenaAllocator` em testes e produção.
   - `ChaCha20Poly1305.decrypt` causa falha de segmentação (segfault) em falhas de tag com saída alocada no heap no macOS/Zig 0.15 — use um buffer de pilha e depois `allocator.dupe()`.

## 3) Princípios de Engenharia (Normativos)

Estes princípios são obrigatórios. São restrições de implementação, não sugestões.

### 3.1 KISS (Mantenha Simples)

Obrigatório:
- Prefira fluxo de controle direto em vez de meta-programação.
- Prefira ramificações explícitas em tempo de compilação (comptime) e structs tipadas em vez de comportamento dinâmico oculto.
- Mantenha os caminhos de erro óbvios e localizados.

### 3.2 YAGNI (Você Não Vai Precisar Disso)

Obrigatório:
- Não adicione chaves de configuração, métodos vtable ou sinalizadores de recursos sem um chamador concreto.
- Não introduza abstrações especulativas.
- Mantenha os caminhos não suportados explícitos (`return error.NotSupported`) em vez de operações vazias (no-ops) silenciosas.

### 3.3 DRY (Não Se Repita) + Regra de Três

Obrigatório:
- Duplique pequenas lógicas locais quando isso preservar a clareza.
- Extraia auxiliares compartilhados apenas após padrões repetidos e estáveis (regra de três).
- Ao extrair, preserve os limites do módulo e evite acoplamento oculto.

### 3.4 Falhe Rápido + Erros Explícitos

Obrigatório:
- Prefira erros explícitos para estados não suportados ou inseguros.
- Nunca amplie silenciosamente permissões ou capacidades.
- Em testes: proteções `builtin.is_test` são aceitáveis para pular efeitos colaterais (ex: abrir navegadores), mas a proteção deve ser explícita e documentada.

### 3.5 Seguro por Padrão + Menor Privilégio

Obrigatório:
- Negar por padrão para limites de acesso e exposição.
- Nunca registre segredos, tokens brutos ou cargas úteis sensíveis.
- Todas as URLs de saída devem ser HTTPS. HTTP é rejeitado na camada de ferramentas.
- Mantenha o escopo de rede/sistema de arquivos/shell o mais estreito possível.

### 3.6 Determinismo + Sem Testes Instáveis (Flaky)

Obrigatório:
- Os testes não devem iniciar conexões de rede reais, abrir navegadores ou depender do estado do sistema.
- Use `builtin.is_test` para contornar efeitos colaterais (inicialização, abertura de URLs, E/S de hardware real).
- Os testes devem ser reproduzíveis no macOS e Linux.

## 4) Mapa do Repositório (Nível Superior)

```
src/
  main.zig              Ponto de entrada do CLI e roteamento de comandos
  root.zig              Exports do módulo (raiz da biblioteca)
  agent.zig             Loop de orquestração
  config.zig            Esquema + carregamento/mesclagem de config (~/.nullclaw/config.json)
  gateway.zig           Servidor de gateway HTTP/webhook
  onboard.zig           Assistente de configuração interativo
  health.zig            Registro de saúde de componentes
  runtime.zig           Adaptadores de tempo de execução (native, docker, wasm, cloudflare)
  tunnel.zig            Provedores de túnel (cloudflared, ngrok, tailscale, custom)
  skillforge.zig        Descoberta e integração de habilidades
  migration.zig         Migração de memória de outros backends
  hardware.zig          Descoberta e gerenciamento de hardware
  peripherals.zig       Periféricos de hardware (Arduino, STM32/Nucleo, RPi)
  security/             Políticas, pareamento, segredos, backends de sandbox
  memory/               Backends SQLite + markdown, embeddings, busca vetorial
  providers/            Mais de 50 implementações de provedores de IA (9 principais + 41 compatíveis)
  channels/             17 implementações de canais
  tools/                Mais de 30 implementações de ferramentas
  agent/                Loop do agente, contexto, planejador
```

## 5) Níveis de Risco por Caminho (Contrato de Profundidade de Revisão)

- **Risco baixo**: docs, comentários, adições de testes, formatação menor
- **Risco médio**: a maioria das mudanças de comportamento em `src/**` sem impacto em segurança/limites
- **Risco alto**: `src/security/**`, `src/gateway.zig`, `src/tools/**`, `src/runtime.zig`, esquema de config, interfaces vtable

Quando houver incerteza, classifique como risco mais alto.

## 6) Fluxo de Trabalho do Agente (Obrigatório)

1. **Leia antes de escrever** — inspecione o módulo existente, a fiação vtable e os testes adjacentes antes de editar.
2. **Defina o limite do escopo** — uma preocupação por mudança; evite patches mistos de recurso + refatoração + infraestrutura.
3. **Implemente o patch mínimo** — aplique as regras KISS/YAGNI/DRY (regra de três) explicitamente.
4. **Valide** — `zig build test --summary all` deve mostrar 0 falhas e 0 vazamentos.
5. **Documente o impacto** — atualize comentários/docs para mudanças de comportamento, risco e efeitos colaterais.

### 6.1 Contrato de Nomeação de Código (Obrigatório)

Aplique estas regras de nomeação consistentemente:

- Todos os identificadores: `snake_case` para funções, variáveis, campos, módulos, arquivos.
- Tipos, structs, enums, unions: `PascalCase` (ex: `AnthropicProvider`, `BrowserTool`).
- Constantes e valores em tempo de compilação: `SCREAMING_SNAKE_CASE` ou `PascalCase` dependendo do contexto.
- Nomeação do implementador da vtable: `<Nome>Provider`, `<Nome>Channel`, `<Nome>Tool`, `<Nome>Memory`, `<Nome>Sandbox`.
- Chaves de registro na fábrica: estáveis, minúsculas, voltadas para o usuário (ex: `"openai"`, `"telegram"`, `"shell"`).
- Testes: nomeados pelo comportamento (`sujeito_comportamento_esperado`), acessórios (fixtures) usam nomes neutros.

### 6.2 Contrato de Limites de Arquitetura (Obrigatório)

- Estenda as capacidades adicionando implementações vtable + fiação na fábrica primeiro.
- Mantenha a direção da dependência voltada para os contratos: implementações concretas dependem de vtable/config/util, não umas das outras.
- Evite acoplamento entre subsistemas (código do provedor importando internos de canais, código da ferramenta modificando políticas do gateway).
- Mantenha as responsabilidades dos módulos com propósito único: orquestração em `agent/`, transporte em `channels/`, E/S de modelo em `providers/`, política em `security/`, execução em `tools/`.

## 7) Roteiros de Mudança (Playbooks)

### 7.1 Adicionando um Provedor

- Adicione `src/providers/<nome>.zig` implementando `Provider.VTable` (`chatWithSystem`, `chat`, `supportsNativeTools`, `getName`, `deinit`).
- Registre na fábrica em `src/providers/root.zig`.
- O `chatImpl` deve extrair o sistema/usuário de `request.messages` (veja provedores existentes para o padrão).
- Adicione testes para fiação vtable, caminhos de erro e parsing de config.

### 7.2 Adicionando um Canal

- Adicione `src/channels/<nome>.zig` implementando `Channel.VTable`.
- Mantenha as semânticas de `send`, `listen`, `name`, `isConfigured` consistentes com os canais existentes.
- Cubra comportamentos de autenticação/configuração/saúde com testes.

### 7.3 Adicionando uma Ferramenta

- Adicione `src/tools/<nome>.zig` implementando `Tool.VTable` (`execute`, `name`, `description`, `parameters_json`).
- Valide e sanitize todas as entradas. Retorne `ToolResult`; nunca cause pânico (panic) no caminho do runtime.
- Adicione a proteção `builtin.is_test` se a ferramenta iniciar processos ou conexões de rede.
- Registre em `src/tools/root.zig`.

### 7.4 Adicionando um Periférico

- Implemente a interface `Peripheral` em `src/peripherals.zig`.
- Periféricos expõem métodos `read`/`write` que delegam para a E/S de hardware real.
- Use o CLI `probe-rs` para acesso à flash de STM32/Nucleo; protocolo serial JSON para Arduino.
- Plataformas que não sejam Linux devem retornar `error.UnsupportedOperation` (não 0 silencioso).

### 7.5 Mudanças em Segurança / Runtime / Gateway

- Inclua notas de ameaça/risco no commit ou PR.
- Adicione/atualize testes para modos de falha e limites.
- Mantenha a observabilidade útil, mas não sensível (sem segredos em logs ou erros).

## 8) Matriz de Validação

Obrigatório antes de qualquer commit de código:

```bash
zig build test --summary all        # todos os testes devem passar, 0 vazamentos
```

Para mudanças de lançamento:

```bash
zig build -Doptimize=ReleaseSmall  # deve compilar sem erros (clean)
```

Expectativas adicionais por tipo de mudança:

- **Apenas docs/comentários**: compilação não requerida, mas verifique se não há referências de código quebradas.
- **Segurança/runtime/gateway/ferramentas**: inclua pelo menos um teste de limite/modo de falha.
- **Adições de provedor**: teste a fiação vtable + falha graciosa sem credenciais.

Se a validação completa for impraticável, documente o que foi executado e o que foi pulado.

### 8.1 Hooks do Git

O repositório vem com hooks pré-configurados em `.githooks/`. Ative uma vez por clone:

```bash
git config core.hooksPath .githooks
```

Hooks:

| Hook | O que faz |
|------|-----------|
| `pre-commit` | Executa `zig fmt --check src/` — bloqueia o commit se algum arquivo não estiver formatado |
| `pre-push` | Executa `zig build test --summary all` — bloqueia o push se algum teste falhar ou vazar memória |

Para ignorar um hook em uma emergência: `git commit --no-verify` / `git push --no-verify`.

## 9) Privacidade e Dados Sensíveis (Obrigatório)

- Nunca faça commit de chaves de API reais, tokens, credenciais, dados pessoais ou URLs privadas.
- Use marcadores (placeholders) neutros em testes: `"test-key"`, `"example.com"`, `"user_a"`.
- Os acessórios de teste (test fixtures) devem ser impessoais e focados no sistema.
- Revise o `git diff --cached` antes do push para procurar strings sensíveis acidentais.

## 10) Anti-Padrões (Não Faça)

- Não adicione dependências C ou pacotes Zig grandes sem justificativa forte (impacto no tamanho do binário).
- Não retorne interfaces vtable apontando para temporários — ponteiro pendente.
- Não use `std.io.getStdOut()` — não existe no Zig 0.15.
- Não enfraqueça silenciosamente as políticas de segurança ou restrições de acesso.
- Não adicione sinalizadores de config/recursos especulativos "por precaução".
- Não pule `defer allocator.free(...)` — toda alocação deve ser liberada.
- Não use `ArrayListUnmanaged.writer()` como `?*Io.Writer` — tipos incompatíveis.
- Não use o CLI `opencode` de dentro do `nullclaw`.
- Não inclua identidade pessoal ou informações sensíveis em testes, exemplos, docs ou commits.
- Não use `SQLITE_TRANSIENT` em código C traduzido automaticamente — use `SQLITE_STATIC` (null).
- Não use buffers de saída alocados em heap no `ChaCha20Poly1305.decrypt` — use buffer de pilha + `allocator.dupe()`.

## 11) Modelo de Entrega (Handoff) (Agente → Agente / Mantenedor)

Ao entregar o trabalho, inclua:

1. O que mudou
2. O que não mudou
3. Validação executada e resultados (`zig build test --summary all`)
4. Riscos remanescentes / desconhecidos
5. Próxima ação recomendada

## 12) Salvaguardas de "Vibe Coding"

Ao trabalhar em modo iterativo rápido:

- Mantenha cada iteração reversível (commits pequenos, rollback claro).
- Valide as suposições com busca de código antes de implementar.
- Prefira comportamento determinístico em vez de atalhos inteligentes.
- Não envie ("ship and hope") caminhos sensíveis à segurança sem testar.
- Se estiver incerto sobre a API do Zig 0.15, verifique em `src/` os padrões de uso existentes antes de tentar adivinhar.
- Se estiver incerto sobre a arquitetura, leia a definição da interface vtable antes de implementar.

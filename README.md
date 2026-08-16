# dotnet-code-review-skills

Duas skills de code review para C#/.NET, orientadas a **decisão** e não a catálogo. Elas atuam como um engenheiro sênior fazendo review: encontram o que importa, explicam o raciocínio, e **recusam** padrão que não paga aluguel.

Uma cobre .NET moderno, a outra cobre .NET Framework legado. A separação existe por um motivo prático: metade das recomendações de uma não compila no alvo da outra, e recomendar sintaxe que não compila destrói a confiança no review inteiro.

## Qual usar

| Situação | Skill |
|---|---|
| `<TargetFramework>net8.0</TargetFramework>` ou superior | `designpatterns` |
| `<TargetFrameworkVersion>v4.x</TargetFrameworkVersion>`, `packages.config`, `web.config`, `.aspx`, `Global.asax` | `designpatterns-legacy` |
| Não sei | Comece pela `designpatterns`. O passo 0 dela detecta o alvo e redireciona |

As duas se reconhecem e mandam usar a outra quando detectam o alvo errado.

## Instalação

### Windows

```powershell
git clone https://github.com/<usuario>/dotnet-code-review-skills.git
cd dotnet-code-review-skills
.\install.ps1
```

O padrão cria **junctions** de `%USERPROFILE%\.claude\skills\` para o clone, então `git pull` atualiza as skills sem reinstalar. Se preferir cópias independentes, use `.\install.ps1 -Mode copy`.

Para instalar só num projeto, em vez de no perfil:

```powershell
.\install.ps1 -ProjectPath C:\caminho\do\projeto
```

### Linux e macOS

```bash
git clone https://github.com/<usuario>/dotnet-code-review-skills.git
cd dotnet-code-review-skills
./install.sh
```

### Manual

Copie as pastas `designpatterns` e `designpatterns-legacy` para:

- `~/.claude/skills/` para uso pessoal em qualquer projeto
- `<raiz-do-projeto>/.claude/skills/` para versionar com o time

São apenas arquivos markdown, sem dependência, sem script, sem binário. Copiar funciona.

## Uso

Cole código e peça revisão. A skill adapta o formato ao tamanho do que recebeu.

```
Revise essa classe: <código>
Isso viola SOLID?
Vale usar Strategy aqui?
Analise a arquitetura dessa solution
Como refatorar isso sem quebrar nada? (não tem teste)
Esse Repository está bem implementado?
```

Também dá para invocar direto: `/designpatterns` e `/designpatterns-legacy`.

## O que elas fazem de diferente

**Recusam padrão que não paga aluguel.** Toda abstração sugerida passa pelo teste do aluguel: *qual mudança concreta e provável isso permite fazer sem editar código existente?* Se a resposta é "boa prática" ou "caso um dia troquemos de banco", o padrão vai para a seção `❌ Patterns que eu NÃO usaria`, com o motivo. Essa seção é tratada como tão valiosa quanto a de recomendações.

**Reconhecem código bom.** Um review que sempre acha doze problemas é inútil, porque o autor deixa de confiar na prioridade. Existe regra explícita para deixar as seções críticas vazias e dar nota alta quando é o caso.

**Separam problema técnico de preferência**, mas na ordem certa: o teste "dois sêniores discordariam?" só é aplicado **depois** de descartar correção, concorrência, segurança e performance mensurável. Sem essa ordem, `async void` e `.Result` seriam rebaixados a questão de gosto.

**Exigem evidência.** Todo achado precisa de arquivo e linha, ou do trecho citado.

**Dão nota com âncora.** Sete dimensões, cada faixa com descrição concreta, mais regras contra inflação e contra severidade excessiva. A versão legada acrescenta duas dimensões que orientam melhor a decisão: **risco operacional** e **custo de mudança**.

**Identificam padrão mal implementado**, não só padrão ausente: Repository vazando `IQueryable`, Singleton com estado estático, Strategy com `if` no contexto, DI usado como Service Locator, Decorator quebrando o contrato. Padrão pela metade é pior que padrão ausente, porque dá falsa sensação de qualidade.

**Nunca cortam achado grave para caber no orçamento.** O teto de extensão existe, mas se aplica a melhorias e opcionais. Crítico e importante entram sempre. Sem essa trava, o caminho mais fácil para um relatório curto seria descartar um crítico, e a nota subiria junto.

**Na versão legada, tratam código em produção como ativo.** Prioridade por risco vezes frequência de mudança, não por distância do design ideal. Refatoração sempre em fases, começando por uma comprovadamente neutra em comportamento. Uma seção `🕰️ Datação` diz explicitamente o que é antigo e está adequado, para o autor não gastar esforço no lugar errado.

## Estrutura

```
designpatterns/                  .NET 6/8/9/10, C# 10 a 14
├── SKILL.md
└── references/
    ├── catalogo-patterns.md     29 padrões em formato de decisão
    ├── solid-smells.md          SOLID com heurísticas mecânicas + code smells
    ├── dotnet-moderno.md        async, DI, EF Core, HttpClient, XSS, segurança
    ├── arquitetura.md           direção de dependências, camadas, VSA vs Clean
    └── scoring.md               âncoras concretas por faixa de nota

designpatterns-legacy/           .NET Framework 4.x, C# 5 a 7.3
├── SKILL.md
└── references/
    ├── restricoes-versoes.md    o que existe em cada versão, e equivalências
    ├── refatorar-sem-testes.md  seams, Sprout/Wrap/Extract-and-Override
    ├── smells-legado.md         deadlock, HttpContext.Current, EF6, XSS, senha
    ├── patterns-no-legado.md    padrões sem container moderno, retrofit de DI
    ├── modernizacao.md          Strangler Fig, escada de migração, bloqueadores
    └── scoring-legacy.md        notas ajustadas à plataforma
```

## Como foram construídas

Base: um manual de estudo de 29 design patterns em .NET, convertido de enciclopédia para formato de decisão (gatilho no código, quando NÃO usar, equivalente pronto no .NET, sintomas de má implementação).

Complementado com o que faltava para uso profissional: heurísticas mecânicas de detecção de SOLID e code smells com limites numéricos, checklist de defeitos reais de .NET moderno, review de arquitetura por direção de dependências, e o corpo de técnicas de trabalho com legado (seams, testes de caracterização, Strangler Fig, matriz de compatibilidade por versão de linguagem).

Depois passaram por **auditoria técnica especializada** em seis frentes: metodologia de review, arquitetura, EF Core e EF6, segurança, testes e seams, async e performance. Os relatórios estão em [`docs/auditoria/`](docs/auditoria/) e valem a leitura, porque documentam o porquê de várias decisões.

Alguns erros que a auditoria encontrou e que já estão corrigidos aqui:

- `TimeProvider` **existe** em .NET Framework 4.6.2+ via `Microsoft.Bcl.TimeProvider`, e `FakeTimeProvider` via `Microsoft.Extensions.TimeProvider.Testing`. A versão anterior mandava escrever `IClock` na mão sem necessidade.
- O mecanismo do deadlock de sync-over-async no ASP.NET clássico é **lock de exclusão mútua por requisição**, não afinidade de thread. A distinção explica por que `Task.Run(...).GetAwaiter().GetResult()` funciona como escape.
- Desde o .NET 6 o default de `BackgroundService` é `StopHost`: exceção não tratada **para o host inteiro** e sai com exit code 0, então o orquestrador pode não reiniciar. O comportamento "morre silenciosamente" é pré-.NET 6.
- `enableViewStateMac="false"` é ignorado pelo runtime desde o .NET Framework 4.5.2. O risco real é `<machineKey>` fixo e versionado, que permite forjar ViewState e ticket de Forms Auth.
- `AllowAnyOrigin` com `AllowCredentials` falha **fechada**. A variante explorável é `SetIsOriginAllowed(_ => true)` com credenciais.
- `TaskCanceledException` herda de `OperationCanceledException` e é o que `HttpClient` e EF lançam em **timeout**, então tratar tudo como cancelamento torna timeout de produção invisível.

## Licença

MIT.
